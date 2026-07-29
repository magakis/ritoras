# Ritoras — Cross-Process IPC Architecture

> **App-group UserDefaults: the canonical transport between the container app and
> the keyboard extension for dictation state and results.**

---

## 1. Overview

The container app and the keyboard extension are separate iOS processes. The
canonical cross-process transport is the **app-group shared UserDefaults**
(`UserDefaults(suiteName:)` using the runtime-resolved app group ID resolved by
`AppGroupResolver`). This replaces the earlier localhost-HTTP architecture and
the three-channel fallback chain.

The app-group approach was proven reliable by `AppGroupResolver`, which handles
the Team-ID suffix that SideStore/AltStore appends to app-group identifiers at
resign time (`group.com.ritoras.app` → `group.com.ritoras.app.<TeamID>`). The
resolver attempts original, bundle-ID-suffixed, and `embedded.mobileprovision`
strategies, succeeding on at least one in all tested SideStore configurations.

**What this means:** app-group UserDefaults are no longer "broken under
SideStore" — they are the canonical transport for all dictation results.

### What the localhost server still does

A minimal HTTP server on `127.0.0.1:47321` (Apple Network framework, `NWListener`)
remains for two auxiliary functions:

- **`/health`** — health check (used for debugging)
- **`/logs`** — log shipping (keyboard extension `FileLogger` entries are
  POSTed here, stored in the container app's `LogStore` SQLite database, surfaced
  in the Debug Log Viewer)

The dictation-transport endpoints `/state` and `/result` have been **removed**.
The localhost server no longer carries dictation data.

---

## 2. Architecture

```
+-------------------+    app-group UserDefaults     +--------------------+
|  Container App    | ◄━━━━━━━━━━━━━━━━━━━━━━━━━►  |  Keyboard Extension|
|  (Ritoras app)    |    (canonical transport)      |  (RitorasKeyboard) |
|                   |                               |                    |
|  setDictationSnapshot  DictationPayload           |  dictationSnapshot  |
|  (write BEFORE     |    { id, status, text,       |  (read)            |
|   Darwin post)     |      errorMessage,            |                    |
|                    |      timestamp, revision }    |  readSharedSnapshot |
|  stateLock         |    key: "dictation.payload"   |  (checks id + rev) |
+-------------------+                               +--------------------+
        │                                                     │
        │  Darwin Notification                                 │
        │  (com.ritoras.dictationStateChanged)                 │
        │  payload-free, fires AFTER write                     │
        └─────────────────────────────────────────────────────┘
                                                                
        ┌────────────────── emergency fallback ──────────────────┐
        │  GET /jobs/{id} on Whisper server                     │
        │  (only after 6 consecutive app-group misses)          │
        └───────────────────────────────────────────────────────┘
```

### Write-before-signal ordering

The container app writes the `DictationPayload` snapshot to app-group
UserDefaults **before** posting the Darwin notification. This ensures that when
the keyboard is woken by the notification, the fresh data is already in the
shared store — no race condition between the write and the read.

Every write is guarded by a `stateLock` and carries a monotonically increasing
`revision` counter. The keyboard's `readSharedSnapshot(for:)` helper checks both
the `id` match and the `revision` freshness, preventing stale reads.

---

## 3. Data model

### `DictationPayload` (shared/DictationPayload.swift)

```swift
struct DictationPayload: Codable, Equatable {
    let id: UUID
    let status: Status
    let text: String?
    let errorMessage: String?
    let timestamp: Date
    let revision: UInt64?
}
```

| Field | Type | Description |
|-------|------|-------------|
| `id` | `UUID` | Dictation session identifier |
| `status` | `Status` | `idle`, `recording`, `transcribing`, `done`, `error` |
| `text` | `String?` | Transcribed text (present when `status == .done`) |
| `errorMessage` | `String?` | Error description (present when `status == .error`) |
| `timestamp` | `Date` | When the payload was written |
| `revision` | `UInt64?` | Monotonically increasing counter — incremented on every write to guard against stale reads |

The payload is stored in app-group UserDefaults under the single key
`"dictation.payload"` by `SharedConfig.setDictationSnapshot(...)`. It is read by
`SharedConfig.dictationSnapshot()`.

---

## 4. State machines

### Container app (`DictationViewModel.DictationPhase`)

```
idle → recording → transcribing → done (or error)
```

Each phase transition writes a new `DictationPayload` snapshot via
`publishSnapshot(status:)` → `SharedConfig.setDictationSnapshot(payload)`, then
posts `com.ritoras.dictationStateChanged`.

### Keyboard extension (`KeyboardState`)

```
idle → openingApp → waiting → inserting → idle
                  ↑          ↓
               (timeout → error → idle)
```

The keyboard's `waiting` state reads the app-group snapshot every 500 ms via
`startSnapshotPolling()` (a `DispatchSourceTimer`). When a Darwin notification
arrives, `refreshFromSharedState()` is called immediately — no need to wait for
the next poll tick. On terminal states (`done`, `error`), the keyboard fetches
the payload via `readSharedSnapshot(for:)` and routes it through
`handleTerminalResult(id:text:errorMessage:)` for idempotent insertion.

---

## 5. Darwin notifications

A single Darwin notification drives the IPC trigger:

| Name | Direction | When fired |
|------|-----------|------------|
| `com.ritoras.dictationStateChanged` | Container app → Keyboard | On every `DictationPhase` transition, **after** the snapshot is written |

The notification is **payload-free** by iOS design — it is purely a wake-up
signal. The keyboard responds by calling `refreshFromSharedState()`, which reads
the current snapshot from app-group UserDefaults.

**`com.ritoras.dictationCompleted` has been deleted.** It was premature (fired
before data was ready) and redundant — the state-changed notification now covers
all transitions including terminal ones.

Both posting (`DarwinNotifier.post`) and observation
(`DarwinNotifier.observe`) are in `shared/DarwinNotifier.swift`. The keyboard
registers its observer (`darwinStateChangedToken`) in
`startWaitingForDictation(id:)` and re-registers on `viewDidAppear`.

---

## 6. Idempotency — id-based dedup

Results are deduplicated by payload `id`, not by wall-clock timestamp:

```
lastProcessedPayloadId ← UserDefaults key "ritoras_last_pid"
```

On each terminal result, the keyboard's `handleTerminalResult(id:text:errorMessage:)`
checks `guard id != lastProcessedPayloadId else { return }` before inserting.
Once a result is inserted (or skipped), the guard is set. This prevents
double-insertion from:

- A Darwin notification arriving alongside a poll tick
- The emergency `/jobs/{id}` fallback firing after the app-group path already
  delivered the result

**The old wall-clock timestamp guard (`ritoras_last_ts`) has been deleted.**

---

## 7. Emergency fallback — `/jobs/{id}` polling

If the container app is killed mid-transcription before it can write the terminal
snapshot to app-group UserDefaults, the keyboard falls back to polling the
Whisper server's `GET /jobs/{id}` endpoint.

### Trigger condition (6-miss threshold)

The keyboard tracks consecutive app-group snapshot misses. The fallback starts
**only after 6 consecutive misses** (~3 seconds at the 0.5 s poll interval),
proving the container app is genuinely not writing. It does not fire
unconditionally.

### Shared handler

Both the app-group path and the `/jobs/{id}` path route terminal results through
the **same** `handleTerminalResult(id:text:errorMessage:)` handler. The
id-dedup guard (`lastProcessedPayloadId`) prevents double-insertion — whichever
path delivers the result first wins; the other path finds the id already
processed and skips it.

### Server retention

The Whisper server retains jobs for at least 10 minutes after reaching a
terminal state (`ready` or `failed`). This gives the keyboard a generous window
to recover after the container app is relaunched.

---

## 8. Localhost server endpoints

The server listens on `127.0.0.1:47321` using Apple's Network framework
(`NWListener`). These are the only remaining endpoints:

| Method | Path | Request body | Response (200) | Notes |
|--------|------|-------------|-----------------|-------|
| GET | `/health` | — | `{"status":"ok","port":47321}` | Always works while server is up |
| POST | `/logs` | Array of `LogEntry` JSON objects | `{"ok":true,"count":N}` | Keyboard ships buffered log entries |
| POST | `/logs/ack` | — | `{"ok":true}` | Acknowledges receipt; keyboard rotates active log file |

**Removed endpoints:** `/state`, `/result` (dictation transport) — their
function is now served by app-group UserDefaults.

### Curl examples

```bash
curl http://127.0.0.1:47321/health
# → {"status":"ok","port":47321}
```

---

## 9. Port selection

The server listens on a fixed port, defined at a single source of truth:

```
SharedConfig.Defaults.localhostServerPort = 47321
```

**Why 47321:** An arbitrary high-numbered port unlikely to conflict with system
services. iOS's per-process sandbox does not restrict localhost port binding.
The port must be hardcoded because there is no out-of-band mechanism for the
keyboard to discover the container app's port.

**To change:** Edit the constant in `shared/Config.swift`. Both the server
(`LocalhostServer.swift`) and the client (`LocalhostClient.swift`) reference
this constant. Any value between 1024 and 65535 works.

---

## 10. Lifecycle details

### Server start

The localhost server is started in `RitorasApp.onOpenURL` when the container app
receives a `ritoras://dictate?id=<UUID>` URL (opened by the keyboard extension
via `extensionContext.open()`):

```
RitorasApp.onOpenURL(url)
  → parse id from query string
  → dictationViewModel.startLocalhostServer()
  → LocalhostServer.start() creates NWListener on 127.0.0.1:47321
```

The server is idempotent — calling `start()` while already running is a no-op.

### Server stop

There is no explicit stop path. The `NWListener` is a child of the container app
process; it dies when the app is killed.

### App-group snapshot writes

The container app's `DictationViewModel.publishSnapshot(status:text:errorMessage:)`
writes to app-group UserDefaults on every phase transition. This is the canonical
data path. The localhost server is **not** involved in data delivery — it only
serves health checks and log shipping.

### Backgrounding

The container app's `DictationViewModel` uses
`UIApplication.beginBackgroundTask(withName:expirationHandler:)` during the
transcription upload phase. This keeps the server alive for the ~30 s background
window iOS grants after the user switches away.

If transcription completes within this window, the terminal snapshot is written
to app-group UserDefaults and the Darwin notification is posted — both of which
are available to the keyboard regardless of the container app's foreground state
(app-group UserDefaults are available as long as the process is running).

---

## 11. Known limitations

- **Container app killed mid-transcription:** If the container app is killed
  before it can write the terminal snapshot to app-group UserDefaults, the
  keyboard falls back to polling `GET /jobs/{id}` on the Whisper server.
  This requires that the async transcription (`POST /transcriptions`) was used
  so the server retained the job. If the job has also expired (>10 min), the
  keyboard ultimately times out after 60 s.

- **No SSL/TLS:** Localhost connections (health, log shipping) are plain HTTP.
  This is acceptable because the loopback interface is not accessible to other
  processes without root, and iOS's ATS does not apply to `127.0.0.1`.

- **`extensionContext.open()` fragility:** The keyboard extension opens the
  container app via `extensionContext.open(ritoras://dictate?id=...)`. This API
  may break on iOS 18+ (tracked separately, out of scope for this document). If
  it fails, the container app never starts the server, but the app-group
  transport is unaffected — the keyboard still reads the snapshot that the
  container app writes (if the container app is running).

- **No request body parsing beyond `/logs`:** The server only handles `GET
  /health` and `POST /logs` (with `/logs/ack`). This is a pure log shipper; all
  dictation data goes through app-group UserDefaults.

---

## 12. Troubleshooting

### Test the health endpoint from the simulator host

```bash
curl http://127.0.0.1:47321/health
```

If the server is running, this returns `{"status":"ok","port":47321}`. If the
server is not running (container app not open, or not in a dictation), curl
hangs for ~2 s then fails with `Connection refused`.

### Read container-app logs

The container app logs all server lifecycle events via `FileLogger`. Open the
container app's settings and tap **Debug Log Viewer** (`DebugLogView`) to see
server start/stop, route hits, and log entries shipped from the keyboard.

### Read keyboard logs

Keyboard `FileLogger` entries are shipped to the container app via `POST /logs`
on the localhost transport and stored in the container app's `LogStore` SQLite
database. If the localhost server is unavailable (container not running),
keyboard logs remain in the keyboard's flat-file shipper buffer (`ritoras-debug.log`
in its `Documents/` directory) and can be retrieved via `idevicesyslog` with a
`RitorasKeyboard` filter.

### Port already in use

If port 47321 is occupied, `NWListener` throws during `start()` and the server
is unavailable for that session. This is extremely unlikely on iOS (system
services use well-known ports). If it happens, change the port in
`shared/Config.swift` and rebuild.

---

## 13. File reference

| File | Role |
|------|------|
| `shared/DictationPayload.swift` | Codable model for the cross-process snapshot |
| `shared/Config.swift` | `AppGroupResolver`, `dictationSnapshot()`, `setDictationSnapshot()`, constants |
| `app/Sources/DictationViewModel.swift` | Snapshot writes (`publishSnapshot`), background task, server wiring |
| `app/Sources/LocalhostServer.swift` | HTTP server (NWListener, `/health` + `/logs` + `/logs/ack` routing) |
| `shared/LocalhostClient.swift` | HTTP client (URLSession, `healthCheck`, `postLogs`, error mapping) |
| `shared/DarwinNotifier.swift` | Darwin notification post/observe helpers |
| `keyboard/Sources/KeyboardViewController.swift` | Client wiring (`refreshFromSharedState`, snapshot polling, Darwin observer, `/jobs/{id}` fallback) |
| `shared/DictationSnapshot.swift` | Legacy snapshot types (kept for compatibility references) |

---

## 14. Debug Log Persistence (SQLite)

### Overview

The debug logging system uses a dual-path facade. Both the container app and the
keyboard extension compile `shared/FileLogger.swift` and `shared/LogStore.swift`,
but each target takes a different persistence path at runtime.

### Container app (LogStore)

The container app persists debug logs to a **SQLite database** at:

```
<app-group-container>/ritoras-debug.sqlite
```

or, when the app-group container is unavailable:

```
<Documents>/ritoras-debug.sqlite
```

Key properties:

- **WAL mode** — concurrent readers do not block writers.
- **FTS5 full-text search** — the `message` column is indexed with the porter
  stemmer + unicode61 tokenizer. All queries are sanitized to prevent FTS5
  operator injection (each token is double-quote wrapped).
- **100,000-row retention** — `rotateIfNeeded()` prunes the oldest rows when
  the table exceeds 100,000 entries. A passive WAL checkpoint runs after
  pruning.
- **Update hook** — every INSERT/UPDATE/DELETE posts a `.logStoreDidChange`
  notification on the main queue. `DebugLogView` observes this to refresh
  automatically.
- **PII scrubbing at export** — The database stores original unscrubbed logs.
  PII scrubbing is applied only at export time (copy/share) in `DebugLogView`,
  controlled by the `scrubPII` toggle.

### Keyboard extension (flat-file shipper buffer)

The keyboard extension still writes flat files at:

```
<keyboard-Documents>/ritoras-debug.log
```

This is a **transient shipper buffer**, not a long-term store:

- Capped at **1 MB** per active file, with up to **6 rolled files** (`.log.1`
  through `.log.6`).
- The keyboard ships these logs to the container app via `POST /logs` on the
  localhost HTTP transport (see [§8](#8-localhost-server-endpoints)).
- Once shipped, the container app calls `POST /logs/ack` and the keyboard
  rotates its active file.

### Process boundary for logs

The keyboard flat files live in the keyboard's per-process `Documents/`
directory; the container app database lives in the app-group container (or the
container's `Documents/` as a fallback). Logs cross the process boundary only
via the HTTP shipper: keyboard → `POST /logs` → container app's
`LogStore.insert()`.

### Migration (`LogStoreMigration`)

On first launch after upgrading to a build with LogStore, flat-file logs are
imported into the database:

1. The migration enumerates flat files oldest-first: `.log.6` → `.log.1` → `.log`.
2. Each file is streamed line-by-line and parsed via `FileLogger.parseLine()`.
3. Parsed entries are batch-inserted into `LogStore` in a single transaction.
4. After all files are imported, they are **archived** (moved to a
   `ritoras-debug.archived-<timestamp>/` subdirectory), not deleted.
5. The migration is gated on a `UserDefaults` flag (`ritoras.logstore.migratedV1`)
   and supports resume: if interrupted mid-import, the last successfully
   imported file is recorded, and the migration resumes from the next file on
   the next launch.
6. Idempotent: running again after completion is a no-op.
