# Ritoras — Localhost IPC Architecture

> **In-process HTTP transport between the container app and the keyboard extension.**
> Replaces the broken app-group inbox under SideStore signing.

---

## 1. Overview

SideStore rewrites entitlements at resign time, which breaks the app-group
shared container (`group.com.ritoras.app`) that was the original cross-process
transport between the container app and the keyboard extension. To work around
this, the container app runs a lightweight HTTP/1.1 server on `127.0.0.1:47321`
using Apple's Network framework (`NWListener`). The keyboard extension connects
to this server via `URLSession` to read dictation state and retrieve results.

Because both processes run on the same device, localhost IPC delivers results in
~1 ms (vs ~50 ms for the clipboard fallback and ~300–1200 ms for server
polling). It is the primary in-flight transport for all dictation results.

---

## 2. Architecture

```
+-------------------+    localhost HTTP     +--------------------+
|  Container App    | ◄──────────────────►  |  Keyboard Extension|
|  (Ritoras app)    |    127.0.0.1:47321    |  (RitorasKeyboard) |
|                   |                        |                    |
|  LocalhostServer  |    GET /health         |  LocalhostClient   |
|  (NWListener)     |    GET /state?id=      |  (URLSession)      |
|                   |    GET /result?id=     |                    |
+-------------------+                        +--------------------+
        │                                             │
        │  Darwin Notifications                       │
        │  (com.ritoras.dictationCompleted,            │
        │   com.ritoras.dictationStateChanged)         │
        └─────────────────────────────────────────────┘
```

**Container app** (`app/Sources/LocalhostServer.swift`):
- Listens on `127.0.0.1:47321` using `NWListener` (TCP, Network framework).
- Serves HTTP/1.1 GET requests only (no POST, no streaming).
- Returns JSON responses with `Content-Type: application/json` and
  `Connection: close`.
- Each connection is handled on its own dispatch queue (default NWListener
  behavior — no concurrent-request limit beyond system resources).
- No SSL/TLS — localhost only, no external exposure.

**Keyboard extension** (`shared/LocalhostClient.swift`):
- Uses a dedicated ephemeral `URLSession` with:
  - `waitsForConnectivity = false` — fail fast, the server is localhost.
  - `timeoutIntervalForRequest = 2.0` — generous for an overloaded device.
  - `timeoutIntervalForResource = 3.0` — overall budget for retry chains.
  - `requestCachePolicy = .reloadIgnoringLocalCacheData` — never serve stale.
- Three public methods: `getState(id:)`, `getResult(id:)`, `healthCheck()`.

**Shared types** (`shared/DictationSnapshot.swift`):
- `DictationStateSnapshot` — phase string (`idle`/`recording`/`transcribing`/
  `done`/`error`), optional active ID, optional start timestamp.
- `DictationResultSnapshot` — id, status (`completed`/`error`), optional text,
  optional error message, timestamp.

---

## 3. Endpoints

| Method | Path | Query params | Response (200) | Notes |
|--------|------|-------------|-----------------|-------|
| GET | `/health` | — | `{"status":"ok","port":47321}` | Always works while server is up. |
| GET | `/state` | `?id=<UUID>` (optional) | `{"phase":"recording","activeID":"...","startedAt":"..."}` | 404 if no active dictation and no `id` provided. |
| GET | `/result` | `?id=<UUID>` (required) | `{"id":"...","status":"completed","text":"...","errorMessage":null,"timestamp":"..."}` | 404 if unknown id or not yet terminal. |

### Curl examples

Test the server is running:
```bash
curl http://127.0.0.1:47321/health
# → {"status":"ok","port":47321}
```

Check current state:
```bash
curl "http://127.0.0.1:47321/state"
# → {"phase":"recording","activeID":"E621E1F8-...","startedAt":"..."}
```

Check state for a specific dictation ID:
```bash
curl "http://127.0.0.1:47321/state?id=E621E1F8-C36C-495A-93FC-0C247A3E6E5F"
# → {"phase":"done","activeID":"E621E1F8-...","startedAt":"..."}
```

Retrieve a completed result:
```bash
curl "http://127.0.0.1:47321/result?id=E621E1F8-C36C-495A-93FC-0C247A3E6E5F"
# → {"id":"E621E1F8-...","status":"completed","text":"hello world","errorMessage":null,"timestamp":"..."}
```

---

## 4. State machines

### Container app (`DictationViewModel.DictationPhase`)

```
recording → transcribing → done (or error)
```

The container app also writes the phase string to the snapshot as one of:
`idle`, `recording`, `transcribing`, `done`, `error`.

### Keyboard extension (`KeyboardState`)

```
idle → openingApp → waiting → inserting → idle
                      ↑          ↓
                   (timeout → error → idle)
```

The keyboard's `waiting` state polls the localhost server every 500 ms via a
`DispatchSourceTimer`. On terminal states (`done`, `error`) it fetches the
result via `/result` and inserts the text.

---

## 5. Darwin notifications

Both notifications are posted via `CFNotificationCenterGetDarwinNotifyCenter()`
and observed by the keyboard extension.

| Name | Direction | When fired |
|------|-----------|------------|
| `com.ritoras.dictationCompleted` | Container app → Keyboard | On any `DictationPhase` transition to `.done` or `.error` (pre-existing) |
| `com.ritoras.dictationStateChanged` | Container app → Keyboard | On every `DictationPhase` transition (new in Phase 4) |

The `dictationStateChanged` notification prompts the keyboard to poll
`/state` immediately rather than waiting up to 500 ms for the next polling
tick. This reduces latency on fast transcriptions.

Both notifications are registered in `DarwinNotifier.swift`
(`shared/DarwinNotifier.swift`), and the keyboard registers observers in
`startWaitingForDictation(id:)` and re-registers them on `viewDidAppear`.

---

## 6. Fallback chain

When the keyboard extension starts waiting for a dictation result, it tries
transports in this order:

1. **Localhost HTTP** — primary transport. Polls `/state?id=...` every 500 ms.
   When the state reaches `done` or `error`, fetches the result from
   `/result?id=...`. Typical latency: ~1 ms per round trip.

2. **Darwin notification + clipboard** — fires on every terminal phase
   transition. The container app writes the result to `UIPasteboard` with a
   custom UTType `org.ritoras.dictation` alongside `public.utf8-plain-text`.
   The keyboard reads the clipboard synchronously. Typical latency: ~50 ms
   (Darwin dispatch delay + pasteboard read).

3. **Remote server polling** — `POST /dictation_result` (container app) →
   `GET /dictation_result/latest` (keyboard extension). Used when the
   container app is killed mid-transcription and the result was already
   posted to the remote server. Polls with adaptive backoff: 300 ms for the
   first 5 polls, 1.2 s thereafter. Typical latency: 300 ms–1.2 s depending
   on Tailscale/network round trip.

4. **Timeout** — 60 s after the keyboard starts waiting. Returns the keyboard
   to `idle` with an error message. The 60 s timeout is defined by
   `SharedConfig.Defaults.dictationTimeoutSeconds`.

### Fallback trigger

The keyboard tracks consecutive localhost connection failures. After **3
consecutive** `connectionRefused` errors from `LocalhostClient`, it stops
localhost polling and switches to remote server polling. This handles the
case where the container app was killed (e.g., by the OS or by the user
swiping it away) while a dictation was in progress.

```
1st refused → increment counter, keep polling
2nd refused → increment counter, keep polling
3rd refused → stop localhost, start server polling
```

The counter resets to 0 on any successful localhost response.

---

## 7. Port selection

The server listens on a fixed port, defined at a single source of truth:

```
SharedConfig.Defaults.localhostServerPort = 47321
```

**Why 47321:** An arbitrary high-numbered port unlikely to conflict with
system services. iOS's per-process sandbox does not restrict localhost port
binding. The port must be hardcoded because there is no out-of-band mechanism
for the keyboard to discover the container app's port — the keyboard does not
know the app is running until the server responds.

**To change:** Edit the constant in `shared/Config.swift`. Both the server
(`LocalhostServer.swift`) and the client (`LocalhostClient.swift`) reference
this constant. Any value between 1024 and 65535 works.

---

## 8. Lifecycle details

### Server start

The server is started in `RitorasApp.onOpenURL` when the container app
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

There is no explicit stop path. The `NWListener` is a child of the container
app process; it dies when the app is killed. Under normal operation, the
server lives for the lifetime of the app process.

### Backgrounding

The container app's `DictationViewModel` uses
`UIApplication.beginBackgroundTask(withName:expirationHandler:)` during the
transcription upload phase (the "WhisperTranscription" background task). This
keeps the server alive for the ~30 s background window iOS grants after the
user switches away. If transcription completes within this window, the
keyboard receives the result via localhost.

If the upload takes longer than the background window, iOS suspends the
container app, which kills the listener. The keyboard then falls back to
remote server polling (see Fallback chain, step 3).

---

## 9. Known limitations

- **Server dies on app kill:** If the container app is killed
  mid-transcription (before the result is posted to the remote server), the
  keyboard's remote polling returns 404. The keyboard ultimately times out
  after 60 s. This is a fundamental limitation of in-process IPC — the server
  lives and dies with its host process.

- **No SSL/TLS:** Connections are plain HTTP on localhost. This is acceptable
  because the loopback interface is not accessible to other processes without
  root, and there is no external exposure. iOS's ATS does not apply to
  `127.0.0.1` connections.

- **No explicit concurrency limit:** Each `NWConnection` is handled on its
  own dispatch queue. Under pathological conditions (thousands of concurrent
  connections), the server could exhaust the dispatch thread pool. In
  practice, the keyboard is the only client, making at most one request per
  500 ms polling tick.

- **`extensionContext.open()` fragility:** The keyboard extension opens the
  container app via `extensionContext.open(ritoras://dictate?id=...)`. This
  API may break on iOS 18+ (tracked separately, out of scope for this
  document). If it fails, the container app never starts the server, and the
  keyboard never receives a localhost response — it falls through to remote
  server polling.

- **No request body parsing:** The server only handles `GET` requests. It
  rejects `POST`, `PUT`, `DELETE`, etc. with HTTP 405. This simplifies the
  server to a read-only state provider; all mutation happens through the
  Darwin notifications + clipboard path.

---

## 10. Troubleshooting

### Test the server from the simulator host

```bash
curl http://127.0.0.1:47321/health
```

If the server is running, this returns `{"status":"ok","port":47321}`. If
the server is not running (container app not open, or not in a dictation),
curl hangs for ~2 s then fails with `Connection refused`.

### Read container-app logs

The container app logs all server lifecycle events via `FileLogger`. Open
the container app's settings and tap **Debug Log Viewer** (`DebugLogView`)
to see server start/stop, route hits, and error messages.

### Why keyboard logs may not appear in DebugLogView

Under SideStore, `FileLogger` uses per-process `Documents` directories
because the shared app-group container is not available. The keyboard
extension writes to its own sandboxed `Documents/` directory, which is
not readable by the container app. To read keyboard logs on-device:

- Attach via `idevicesyslog` and filter for `RitorasKeyboard`.
- Or enable verbose logging in Settings and reproduce the issue, then
  inspect the container app's logs for server-side clues.

### Port already in use

If port 47321 is occupied, `NWListener` throws during `start()` and the
server is unavailable for that session. This is extremely unlikely on iOS
(system services use well-known ports). If it happens, change the port in
`shared/Config.swift` and rebuild.

---

## 11. File reference

| File | Role |
|------|------|
| `app/Sources/LocalhostServer.swift` | HTTP server (NWListener, routing, JSON response formatting) |
| `shared/LocalhostClient.swift` | HTTP client (URLSession, getState/getResult/healthCheck, error mapping) |
| `shared/DictationSnapshot.swift` | Shared Codable types (DictationStateSnapshot, DictationResultSnapshot) |
| `app/Sources/DictationViewModel.swift` | Server wiring (startLocalhostServer, state snapshot, completedResults, beginBackgroundTask) |
| `keyboard/Sources/KeyboardViewController.swift` | Client wiring (refreshStateFromLocalhost, polling, Darwin observers, fallback to server polling) |
| `shared/Config.swift` | Constants (`localhostServerPort`, `darwinNotificationName`, `darwinStateChangedNotificationName`) |
| `shared/DarwinNotifier.swift` | Darwin notification post/observe helpers |
| `keyboard/Sources/KeyboardView.swift` | KeyboardState enum (idle, openingApp, waiting, waitingConfirm, inserting, error) |
| `RitorasTests/LocalhostServerTests.swift` | Server unit tests (port 0 for OS-assigned port, stub providers, health/state/result/404 routing) |
| `RitorasTests/LocalhostClientTests.swift` | Client unit tests (MockURLProtocol, getState/getResult/healthCheck, error mapping, connection refused) |
| `shared/LogStore.swift` | SQLite-backed log persistence (WAL mode, FTS5 full-text search, 100k-row rotation) |
| `shared/LogStoreMigration.swift` | One-time import of existing flat-file logs into LogStore |
| `RitorasTests/LogStoreTests.swift` | LogStore unit tests (insert, query, filter, paginate, rotate, concurrent safety) |
| `RitorasTests/LogStoreMigrationTests.swift` | Migration unit tests (import, idempotency, resume, archival) |

---

## 12. Debug Log Persistence (SQLite)

### Overview

The debug logging system migrated from a flat-file-only design to a dual-path
facade in Phase 4. Both the container app and the keyboard extension compile
`shared/FileLogger.swift` and `shared/LogStore.swift`, but each target takes a
different persistence path at runtime.

### Container app (LogStore)

The container app persists debug logs to a **SQLite database** at:

```
<container>/ritoras-debug.sqlite
```

or, when the app-group container is unavailable (SideStore):

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
- **Update hook** — every INSERT/UPDATE/DELETE posts a
  `.logStoreDidChange` notification on the main queue. `DebugLogView`
  observes this to refresh automatically.
- **PII scrubbing** — `FileLogger.log()` scrubs the message and payload
  via `LogScrubber` before calling `LogStore.insert()`. The raw column
  stores the scrubbed JSON line.

### Keyboard extension (flat-file shipper buffer)

The keyboard extension still writes flat files at:

```
<keyboard-Documents>/ritoras-debug.log
```

This is a **transient shipper buffer**, not a long-term store:

- Capped at **1 MB** per active file, with up to **6 rolled files** (`.log.1`
  through `.log.6`).
- The keyboard ships these logs to the container app via `POST /logs` on the
  localhost HTTP transport (see [Section 3](#3-endpoints)).
- Once shipped, the container app calls `POST /logs/ack` and the keyboard
  rotates its active file.

### Under SideStore (broken app group)

When the app-group container is unavailable (SideStore/AltStore resigning):

- The **database** lives in the container app's per-process `Documents/`
  directory.
- The **keyboard flat files** live in the keyboard's per-process `Documents/`
  directory.
- These directories are sandboxed per-process — neither process can read the
  other's files directly.
- Logs cross the process boundary **only** via the HTTP shipper: keyboard
  → `POST /logs` → container app's `LogStore.insert()`.

### Migration (`LogStoreMigration`)

On first launch after upgrading to a build with LogStore, flat-file logs
are imported into the database:

1. The migration enumerates flat files oldest-first: `.log.6` → `.log.1` → `.log`.
2. Each file is streamed line-by-line and parsed via `FileLogger.parseLine()`.
3. Parsed entries are batch-inserted into `LogStore` in a single transaction.
4. After all files are imported, they are **archived** (moved to a
   `ritoras-debug.archived-<timestamp>/` subdirectory), not deleted.
5. The migration is gated on a `UserDefaults` flag (`ritoras.logstore.migratedV1`)
   and supports resume: if interrupted mid-import, the last successfully
   imported file is recorded, and the migration resumes from the next file
   on the next launch.
6. Idempotent: running again after completion is a no-op.
