# Logging Standard

> **Authoritative level definitions and decision rules** for every `FileLogger` call in the Ritoras codebase. Every contributor (human or LLM agent) **MUST** follow this standard when writing or changing log calls.

---

## Four levels

`FileLogger` exposes four levels — `.debug`, `.info`, `.warn`, `.error` (defined in `LogLevel` in `shared/FileLogger.swift`). These map onto Apple's `os.Logger` severity scale:

| FileLogger | os.Logger    | syslog severity | Meaning                              |
|------------|--------------|-----------------|--------------------------------------|
| `.debug`   | `.debug`     | 7 (DEBUG)       | Diagnostic details, developers only  |
| `.info`    | `.info`      | 6 (INFO)        | Normal lifecycle / user-action       |
| `.warn`    | `.notice`    | 5 (NOTICE)      | Unexpected but recovered             |
| `.error`   | `.error`     | 3 (ERR)         | Failure with user impact             |

---

### `.debug` — Developer diagnostics

**Log this when…** you are tracing transient or internal state that is useful only when actively debugging a specific issue. These calls are gated by `SharedConfig.verboseLoggingEnabled()` and never reach the user-facing log view unless verbose logging is enabled in Settings.

**Ritoras examples:**
- VAD state transitions (`"idle → speaking"`, `"speaking → idle"`)
- Individual network health-probe responses (`"PONG received from 100.107.181.45"`)
- Poll scheduling details (`"poll scheduled in 1.0s, attempt 2/900"`)
- Trigram first-suggestion sample (`"first trigram suggestion: 'the' (score 0.34)"`)
- Stale-data checks that pass normally (`"payload age 4.2s < timeout 10.0s — accepting"`)
- Audio chunk queue depth during streaming

**Anti-examples:**
- Module initialization success → use `.info`
- A connection was established → use `.info`
- A user-initiated action succeeded → use `.info`

---

### `.info` — Normal lifecycle and user-action confirmations

**Log this when…** the system is working as expected and you want to confirm an event happened. These appear in the debug log view by default and are the primary way a user or developer verifies the system is healthy.

**Ritoras examples:**
- `"KeyboardView did load"`
- `"PredictionEngine ready"`
- `"Trigram load started / Trigram ready (N tokens)"`
- `"PONG received — connection established"`
- `"dictation inserted: N chars"`
- `"Recording started / Recording stopped"`
- `"Transcription received"`
- `"Settings updated"`
- `"Module initialized successfully"`

**Anti-examples:**
- Raw network poll noise (every health-probe response) → use `.debug`
- VAD transitions → use `.debug`
- Every keystroke event → don't log it at all

---

### `.warn` — Unexpected but recoverable

**Log this when…** something abnormal happened, the system adapted and continued operating, but a human should investigate eventually. Warnings indicate code paths that should not be hit during normal operation.

**Ritoras examples:**
- `"trigram unloaded (memory pressure)"` — adaptive unloading under 48 MB Jetsam cap
- `"containerURL nil — falling back to documents directory"`
- Fallback path used because preferred path failed (`"health probe failed, using default server"`)
- `"ignoring stale payload (age 12.0s > timeout 10.0s)"`
- Transcription retry exhausted (`"all 3 retries failed, giving up"`)
- Audio format change during recording

**Anti-examples:**
- Normal lifecycle events (view loaded, connection established) → use `.info`
- A transient network error that will be retried → use `.debug` on first attempt; only promote to `.warn` after all retries are exhausted
- A user cancelled an operation → use `.info` or don't log it

---

### `.error` — Hard failure with user impact

**Log this when…** an operation failed and the user is affected, or a module could not initialize. Every `.error` should be investigated and ideally fixed.

**Ritoras examples:**
- `"prediction engine failed to load dictionary"`
- `"audio input unavailable"`
- `"Transcription request failed — no fallback"`
- `"WhisperClient: invalid response (HTTP 500)"`
- Recording setup failure (`"AudioRecorder: prepareToRecord returned false"`)

**Anti-examples:**
- A transient error that a retry handles → `.debug` on first attempt, `.warn` after exhaustion
- Missing optional config (e.g., a settings key that was never set) → `.info`
- A user cancelled an operation → use `.info`

---

## Decision rules (quick reference)

Use this table when a call doesn't clearly fit one level:

| Situation | Level |
|---|---|
| Background operation completed (e.g., periodic poll, stats collection) | `.debug` |
| User-initiated action succeeded (e.g., dictation inserted) | `.info` |
| Retryable network error, first attempt | `.debug` |
| Retryable network error, all attempts exhausted | `.warn` |
| Memory pressure / adaptive degradation | `.warn` |
| Module failed to initialize | `.error` |
| Fallback path was used (preferred path failed) | `.warn` |
| Diagnostic state dump during development | `.debug` |
| Normal lifecycle / state transition | `.info` |
| User cancelled an operation | `.info` or do not log |
| Configuration value missing with a valid default | `.info` or do not log |

---

## Component usage

Each `LogComponent` (defined in `shared/FileLogger.swift`) maps to a subsystem in the codebase. The table below shows where each component is used and its typical log levels.

| Component | Code areas | Typical `.debug` | Typical `.info` | Typical `.warn` | Typical `.error` |
|---|---|---|---|---|---|
| `.prediction` | TrigramProvider, WordListLoader, SymSpell | trigram first-suggestion debug, stale-data checks | `"PredictionEngine ready"`, `"Trigram load started"`, `"Trigram ready (N tokens)"` | `"trigram unloaded (memory pressure)"` | `"prediction engine failed to load dictionary"` |
| `.keyboard` | KeyboardViewController, KeyboardView | layout/geometry debug, key-press timing | `"KeyboardView did load"`, `"KeyboardView will appear"` | degraded operation, unexpected input mode | hard keyboard failure |
| `.network` | WhisperClient, LocalhostServer, DictationViewModel | individual health-probe responses, poll scheduling, socket-level events | `"connection established"`, `"PONG received"`, `"localhost server started on port 47321"` | timeout after retries exhausted, stale-payload discard, server health-probe failures | `"Transcription request failed"`, `"connection failed — no fallback available"` |
| `.audio` | AudioRecorder, AudioSession | VAD state transitions, chunk queue depth | `"Recording started"`, `"Recording stopped"`, `"AudioSession category set to .playAndRecord"` | format change during recording, audio session interruption | `"audio input unavailable"`, `"prepareToRecord returned false"` |
| `.dictionary` | WordListLoader, word-frequency resources | load progress percentage | `"dictionary load completed (N items)"` | partial load under memory pressure | `"dictionary file not found"` |
| `.transcription` | DictationViewModel, WhisperClient transcription path | poll iteration details, raw response | `"transcription received"`, `"transcription inserted: N chars"` | server returned empty transcription, async job still pending after long wait | `"transcription failed — server error"` |
| `.app` | ContainerApp (RitorasApp, SettingsView) | — | `"App did finish launching"`, `"Settings updated"` | app-group container unavailable | `"AppGroup resolution failed"` |
| `.settings` | AppSettings, SettingsView | — | `"setting changed: dictationMode → stream"` | — | — |
| `.lifecycle` | AppDelegate, scene-phase changes, background/foreground | — | `"ScenePhase: active"`, `"ScenePhase: background"` | unexpected lifecycle transition | — |

---

## "When in doubt" rule

Default to `.info` for success paths, `.warn` for adaptations, `.error` for failures.

If unsure between two levels, **pick the lower one**. It is easier to escalate a noisy `.info` to `.warn` later than to quiet a noisy `.warn` after it has buried real warnings in the log.

---

## Non-FileLogger calls

### `NSLog()` in AppGroupResolver

The `AppGroupResolver` in `shared/Config.swift` intentionally uses `NSLog()` rather than `FileLogger`. This is because `FileLogger` itself depends on the resolved app-group identifier — using it inside the resolver would cause infinite recursion. These calls go to the system console and are viewable via `idevicesyslog` or `Console.app` on a connected device.

**Do not add new `NSLog()` calls elsewhere.** All other logging must use `FileLogger`.

### `os.Logger` probe

`FileLogger` contains an `os.Logger` singleton (`probeLogger` in `shared/FileLogger.swift`) that emits exactly one `notice`-level os_log probe per process lifetime, triggered on the first `.warn` or `.error` call. This is intentional — it verifies that `os.Logger` can surface ritoras diagnostics in the system log store (useful when the file log or LogStore fails). **Do not expand this probe** into a general os.Logger logging path without discussion.

---

## Memory note (keyboard extension)

The keyboard extension runs under a **48 MB Jetsam cap**. Log calls must not construct large string payloads or perform expensive formatting on the hot path. This is especially important for `.debug` calls, which may fire frequently (VAD transitions, per-keystroke events, poll iterations).

Guidelines:
- Keep message strings short and static. Avoid string interpolation over large data structures.
- Use the `payload` dictionary for structured data instead of inlining it into the message string.
- `.debug` calls that fire in a tight loop must be minimal — prefer a counter that logs every N iterations over logging every occurrence.
- Never log large in-memory buffers (audio data, full HTTP responses) — log their size or presence instead.

---

## Enforcement

This standard applies to all code in `app/`, `keyboard/`, and `shared/`. Before writing any new log call, consult the decision rules above. PR reviewers must verify that every log call in the diff complies with this standard before approving.
