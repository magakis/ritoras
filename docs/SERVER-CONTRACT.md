# Ritoras ↔ Whisper Server Contract

> **Authoritative request/response spec** between the Ritoras keyboard extension
> and the self-hosted Whisper server at `~/whisper/server-v2/`. Both sides must
> agree on this contract.

---

## 1. Endpoint

```
POST {BASE_URL}/transcribe
```

`{BASE_URL}` is the user-configured server URL (e.g. `http://localhost:5000`
or `http://100.x.y.z:5000` via Tailscale IP).

The server runs on **port 5000** (not 8000) — see [Server details](#7-server-details).

> **Synchronous, still supported.** This endpoint remains the primary batch
> transcription endpoint and is unchanged from prior versions.

---

## 2. Request format

### Headers

| Header | Value | Condition |
|--------|-------|-----------|
| `Content-Type` | `multipart/form-data; boundary={boundary}` | Always |

No `Authorization` header is sent — the server has no authentication. The
`apiKey` field is retained in `SharedConfig` for forward compatibility but is
empty by default and not used by this server.

### Multipart body

The body contains a **single** file part. No other form fields are sent.

```
--{boundary}\r\n
Content-Disposition: form-data; name="audio"; filename="audio.m4a"\r\n
Content-Type: audio/mp4\r\n
\r\n
{binary audio bytes}
\r\n
--{boundary}--\r\n
```

| Property | Value |
|----------|-------|
| Field name | `audio` |
| `filename` | `audio.m4a` |
| `Content-Type` | `audio/mp4` |

**Important:** The field name is `audio`, **not** `file`. The server is not
OpenAI-compatible — it expects the field named `audio`.

### Parameters the server ignores

The following parameters are **not** sent to this server:

- `model` — hardcoded to `small.en` on the server side
- `language` — hardcoded to English on the server side
- `response_format` — the server always returns JSON

These fields remain in `SharedConfig` for future use if the user switches to
an OpenAI-compatible server.

---

## 3. Response format

### Success (HTTP 200)

```json
{
    "success": true,
    "transcription": "This is the transcribed text. "
}
```

| Field | Type | Description |
|-------|------|-------------|
| `success` | `boolean` | Always `true` on success |
| `transcription` | `string` | The transcribed text |

**Note:** The `transcription` string always ends with a trailing space
(server-side behavior). The client handles this in post-processing.

### Error (HTTP 200 with `success: false`)

The server returns HTTP 200 even on transcription failure, with
`"success": false`. The client throws `WhisperError.httpError(200, ...)` in
this case.

```json
{
    "success": false,
    "transcription": ""
}
```

### Error (HTTP 4xx / 5xx)

Non-200 HTTP status codes (e.g. missing file, invalid request). The client
surfaces the status code and response body to the user.

```json
{ "detail": "No audio file provided" }
```

---

## 4. Audio format

Ritoras records audio using `AVAudioRecorder` with these settings:

| Property | Value |
|----------|-------|
| Format | AAC (MPEG-4 Audio) |
| File extension | `.m4a` |
| Sample rate | 16 kHz |
| Channels | 1 (mono) |
| Quality | Medium |

### Server-side processing

The server converts uploaded audio to **16 kHz mono WAV** via `ffmpeg` before
transcribing. Any audio format that `ffmpeg` supports will work — M4A, WAV,
MP3, OGG, etc. Our M4A/AAC 16 kHz mono recording is already ideal and
requires no server-side downsampling.

### Post-processing

After transcription, the server applies:

- **Word substitutions** — e.g. "athena" → "Athina", domain-specific terms
- **Time format conversion** — e.g. "three o'clock" → "3:00"
- **Text normalization** — punctuation, casing, whitespace

---

## 5. App Transport Security (ATS)

### The problem

iOS's App Transport Security (ATS) blocks plain HTTP by default. The Tailscale
100.64.0.0/10 (CGNAT, RFC 6598) range is **not** treated as "local" by ATS —
only RFC 1918 ranges (10.x, 172.16.x, 192.168.x) qualify. This means a request
to `http://100.x.y.z:5000/transcribe` **will fail** without an ATS exception,
and the error will be a silent connection failure.

### v1 solution: NSAllowsArbitraryLoads

The keyboard's `Info.plist` currently includes:

```xml
<key>NSAppTransportSecurity</key>
<dict>
    <key>NSAllowsArbitraryLoads</key>
    <true/>
</dict>
```

This disables ATS entirely for the keyboard extension. Acceptable for a
sideloaded personal-use app; **not** acceptable for App Store distribution.

### Recommended solution: HTTPS via Tailscale

Set up a Tailscale HTTPS certificate for your Whisper node:

```bash
# On the Whisper node, if it runs Tailscale:
tailscale cert your-hostname.your-tailnet.ts.net
```

Then configure Ritoras with `https://your-hostname.your-tailnet.ts.net:5000`.
No ATS exception is needed, and traffic is encrypted over Tailscale's
WireGuard tunnel + TLS.

---

## 6. Testing with curl

Use this command to test your Whisper server independently of the iOS app:

```bash
curl -X POST http://your-server:5000/transcribe \
  -F "audio=@recording.m4a"
```

Expected success response (HTTP 200):

```json
{"success": true, "transcription": "hello world this is a test transcription. "}
```

No API key, no model parameter, no language parameter — just the audio file.

---

## 7. Server details

| Property | Value |
|----------|-------|
| Framework | FastAPI + uvicorn |
| Port | 5000 (`0.0.0.0:5000`) |
| Engine | faster-whisper |
| Model | `small.en` (English-only, hardcoded) |
| Language | English (hardcoded, not configurable) |
| Quantization | int8 |
| Auth | None |
| Stream endpoint | WebSocket `/stream` (real-time streaming, used by Ritoras in stream mode — see §10) |

### File location

The server runs from `~/whisper/server-v2/` and is configured via
`server-v2/config.json`.

---

## 8. Future: OpenAI-compatible server

If the user later switches to an OpenAI-compatible Whisper server (e.g.
faster-whisper-server with `--openai-compat`, or the official OpenAI API),
the client can be extended with a configuration flag for API format selection.
The `SharedConfig.model`, `SharedConfig.language`, and `SharedConfig.apiKey`
fields are already preserved for this purpose.

---

## 9. Client implementation reference

### Batch mode (`/transcribe`)

The batch client is at `keyboard/Sources/WhisperClient.swift`. Key design
decisions:

- **No third-party HTTP libraries** — uses `URLSession.shared.data(for:)` with
  `async/await` (iOS 15+).
- **Multipart body hand-built** using `Data.append` with explicit `\r\n`
  separators. Only one field (`audio`) is sent.
- **Timeout** — configurable via `SharedConfig.timeoutSeconds` (default 30 s).
  Whisper on CPU with int8 quantization can take 10–30 seconds for longer
  recordings. Mapped to `WhisperError.timeout` on `URLError.timedOut`.
- **Error handling** — every failure path produces a `WhisperError` with a
  user-readable description for Phase 8's error UI.
- **Defensive decoding** — attempts JSON decode first (checks `success` field),
  falls back to plain text extraction if JSON parsing fails.
- **File cleanup** — the caller (Phase 8 / `KeyboardViewController`) is
  responsible for deleting `audioURL` after transcription completes.

### Stream mode (`/stream`)

The streaming client spans three files:

- `shared/WhisperStreamClient.swift` — WebSocket connection lifecycle (connect,
  send binary chunks, send END/PING, receive partial/final/error/PONG frames,
  disconnect).
- `shared/StreamingAudioRecorder.swift` — client-side energy-based VAD state
  machine running on an `AVAudioEngine` tap, emitting 16 kHz mono float32 PCM
  chunks per detected speech segment.
- `shared/Config.swift` — `DictationMode` enum (`.batch` / `.stream`) and all
  streaming tunables (see §10 for reference).

---

## 10. Streaming mode (`/stream` WebSocket)

> **Still supported.** This streaming endpoint remains the primary real-time
> transcription endpoint and is unchanged from prior versions.

### Overview

Ritoras uses the `/stream` WebSocket endpoint behind a user-facing
`DictationMode` toggle (default `.batch`, values: `.batch` | `.stream`). When
`.stream` is selected, the container app opens a persistent WebSocket
connection, streams 16 kHz mono float32 PCM chunks emitted by a client-side
energy VAD, and receives live `partial` transcriptions followed by a single
normalized `final` when the user stops dictating.

Unlike the stateless `POST /transcribe` endpoint, `/stream` maintains a session
spanning one dictation: one WebSocket connect → N binary audio frames → one
`{"type":"END"}` → drain worker → `final` response → close.

### Client → Server frames

| Frame | Shape | Purpose |
|-------|-------|---------|
| Binary | `[4-byte BE uint32 chunk_id][float32 LE PCM @ 16 kHz mono]` | One audio chunk (one Whisper call) |
| Text JSON | `{"type":"END"}` | End of session — server drains worker and responds with `final` |
| Text JSON | `{"type":"PING"}` | Keepalive — server responds `{"type":"PONG"}` |
| Text JSON | `{"type":"CONTEXT","text":"..."}` | Optional Whisper `initial_prompt` (unused by Ritoras v1) |

The server decodes binary frames as (`server.py:749-760`):

```python
chunk_id = struct.unpack("!I", raw[:4])[0]
audio = np.frombuffer(raw[4:], dtype=np.float32)
```

**Binary frame layout:**

| Offset | Size | Field |
|--------|------|-------|
| 0 | 4 | `chunk_id` (uint32, big-endian) |
| 4 | N×4 | PCM samples (float32, little-endian, 16 kHz mono) |

Total frame size: `4 + N×4` bytes, where N is the number of audio samples.

### Server → Client frames (all text JSON)

| Frame | Shape | Description |
|-------|-------|-------------|
| `partial` | `{"type":"partial","transcription":"...","chunk_id":N}` | Per-chunk result, **RAW** (not normalized) |
| `final` | `{"type":"final","transcription":"...","chunk_id":last}` | After END + worker drain, **FULLY NORMALIZED** |
| `PONG` | `{"type":"PONG"}` | Keepalive response |
| `error` | `{"type":"error","message":"..."}` | Server error |

**partial vs final:**

- `partial` transcriptions are the raw output from a single Whisper call (the
  per-chunk result). They are NOT passed through the server's post-processing
  pipeline — no substitutions, no time-format conversion, no normalization.
  Ritoras displays them live in the container app for immediate feedback.
- `final` is produced after the server receives `{"type":"END"}` and all
  outstanding workers have drained. It runs through the identical pipeline as
  `POST /transcribe`:
  `normalize_text(convert_time_format(apply_substitutions(...)))`, including the
  trailing space.

**END / PING / CONTEXT:**

- **END** (`{"type":"END"}`) — the client must send this to signal that no more
  audio chunks will follow. The server stops accepting new chunks, waits for the
  worker queue to drain, and returns a single `final` transcription.
- **PING** (`{"type":"PING"}`) — keepalive. The server's idle timeout
  (`STREAM_RECV_TIMEOUT = 600 s`, `server.py:120, 853-862`) closes the
  connection if no frame is received within that window. The client should send
  a PING well before 600 s of silence during long pauses.
- **CONTEXT** (`{"type":"CONTEXT","text":"..."}`) — sets the Whisper
  `initial_prompt` for the session. Ritoras does not send this in v1; the
  server provides automatic cross-chunk context by threading the last 300
  characters of accumulated transcript as `initial_prompt` to each new chunk
  (`server.py:828`).

### Client-side VAD (architectural note)

The server's `VAD_ENABLED` flag (`server.py:159`) and `VAD_PARAMETERS`
(threshold 0.2, min_speech 250 ms, min_silence 1000 ms, speech_pad 400 ms) are
passed to faster-whisper's built-in Silero VAD **inside** `model.transcribe()`.
This only trims silence within a single chunk before transcribing; it does
**not** perform real-time segmentation of the inbound audio stream.

Therefore, Ritoras implements client-side pause detection using an energy-based
VAD state machine in `shared/StreamingAudioRecorder.swift`. The VAD computes
RMS energy per audio frame (buffer of 4096 samples at 16 kHz) and tracks
speech/silence durations:

| Tunable | Default | Purpose |
|---------|---------|---------|
| `SharedConfig.Defaults.streamVadSpeechRms` | `0.02` | RMS threshold for speech detection. Higher = less sensitive. |
| `SharedConfig.Defaults.streamVadSilenceMs` | `600` | Silence duration (ms) before a chunk is finalized (pause timeout). |
| `SharedConfig.Defaults.streamVadMinSpeechMs` | `300` | Minimum speech duration (ms) to accept a chunk. Rejects brief noise. |
| `SharedConfig.Defaults.streamMaxChunkSeconds` | `8.0` | Maximum audio segment length before forced chunk finalization. |

When the VAD detects `streamVadSilenceMs` ms of continuous silence after
speech, it emits the accumulated audio as one binary frame (with an atomically
incrementing `chunk_id`). The same emission happens if the chunk exceeds
`streamMaxChunkSeconds` regardless of VAD state. This delivers the
"transcribe on pause" user experience.

### Chunking model

The server transcribes whatever the client sends as one binary frame as one
Whisper call. The background worker pulls `(chunk_id, audio_array)` off an
async queue and calls faster-whisper per chunk. Cross-chunk context continuity
is automatic: the server threads the last 300 characters of accumulated
transcript as `initial_prompt` for each new chunk (`server.py:828`).

### Result delivery invariant

In stream mode, exactly **one** `completed` payload is POSTed to
`/dictation_result` per session, carrying the server's `final` (normalized)
text. The payload shape is identical to batch mode. The keyboard extension
receives it via the same `/dictation_result/latest` poll.

Live `partial` transcriptions are display-only in the container app and are
**never** sent to the keyboard extension.

### Other tunables

| Tunable | Default | Purpose |
|---------|---------|---------|
| `SharedConfig.Defaults.streamWsConnectTimeout` | `8.0 s` | WebSocket connection timeout (includes PING/PONG handshake probe). |
| `SharedConfig.Defaults.streamFinalTimeout` | `30.0 s` | How long to wait for a `final` transcription after sending END. |

### ATS note for streaming

The container app connects to the WebSocket at `ws://100.x:5000/stream` (plain
WS, not WSS). Batch mode already works over plain HTTP from the container app,
and `URLSessionWebSocketTask` to `ws://` falls under the same ATS rules.

The keyboard extension's `Info.plist` already declares
`NSAllowsArbitraryLoads = true`. The container app's `Info.plist` does not
currently declare an ATS exception, but if an on-device test reveals an ATS
block for the WebSocket connection, the fix is to mirror the keyboard's
`NSAppTransportSecurity` → `NSAllowsArbitraryLoads = true` block into
`app/Info.plist`.

### Testing with Python

A self-contained test using the `websockets` library:

```python
import asyncio, json, struct, wave, numpy as np
import websockets

async def test_stream():
    uri = "ws://100.107.181.45:5000/stream"
    async with websockets.connect(uri) as ws:
        # Open a 16 kHz mono WAV file
        with wave.open("test.wav", "rb") as w:
            assert w.getnchannels() == 1
            assert w.getframerate() == 16000

            raw = w.readframes(w.getnframes())
            if w.getsampwidth() == 2:          # 16-bit PCM
                samples = (
                    np.frombuffer(raw, dtype=np.int16).astype(np.float32)
                    / 32768.0
                )
            else:                               # already float32
                samples = np.frombuffer(raw, dtype=np.float32)

        # Send in 2-second chunks
        chunk_size = 32000  # 2 s × 16 kHz
        for i in range(0, len(samples), chunk_size):
            chunk = samples[i:i + chunk_size]
            frame = struct.pack("!I", i // chunk_size) + chunk.tobytes()
            await ws.send(frame)

        await ws.send(json.dumps({"type": "END"}))

        async for msg in ws:
            print(json.loads(msg))

asyncio.run(test_stream())
```

Expected output (the server echoes partial results per chunk, then the final):

```
{'type': 'partial', 'transcription': 'hello world', 'chunk_id': 0}
{'type': 'partial', 'transcription': 'hello world this is a', 'chunk_id': 1}
{'type': 'final', 'transcription': 'hello world this is a test transcription. ', 'chunk_id': 1}
```

Note: `partial` transcriptions are unnormalized per-chunk Whisper output. Only
the `final` is fully normalized through substitutions, time-format conversion,
and text normalization — identical to the `POST /transcribe` pipeline.

---

## 11. Async transcription (recommended for new clients)

```
POST {BASE_URL}/transcriptions
```

### When to use async

The synchronous `POST /transcribe` endpoint works well when the client can hold
a connection open for the duration of the transcription. However, constrained
environments — such as iOS keyboard extensions under the 48 MB Jetsam memory
cap — may be terminated by the OS mid-request. The async pattern decouples
upload from result retrieval so the client can submit audio and check back for
the result later, even after a crash and relaunch.

### Request

#### Headers

| Header | Value | Condition |
|--------|-------|-----------|
| `Content-Type` | `multipart/form-data; boundary={boundary}` | Always |
| `Idempotency-Key` | `{UUID}` | Always — see §13 for contract details |

No `Authorization` header is sent (same as `POST /transcribe`).

#### Multipart body

Identical to `POST /transcribe` — see [§2](#2-request-format). The field name is
`audio`, the filename is `audio.m4a`, and the content type is `audio/mp4`.

### Response (HTTP 202 Accepted)

```json
{
    "job_id": "3a1b2c3d-4e5f-6789-abcd-ef0123456789",
    "status_endpoint": "/jobs/3a1b2c3d-4e5f-6789-abcd-ef0123456789"
}
```

| Field | Type | Description |
|-------|------|-------------|
| `job_id` | `string` (UUID) | Unique job identifier, also used as the path component of the status endpoint |
| `status_endpoint` | `string` | Relative URL for `GET /jobs/{id}` — the client should poll this to retrieve the result |

### Idempotency

If a duplicate request with the same `Idempotency-Key` arrives within the
retention window (10 minutes), the server returns HTTP 202 with the same
`job_id` rather than re-transcribing. See [§13](#13-idempotency-key-contract)
for the full contract.

---

## 12. Job status polling

```
GET {BASE_URL}/jobs/{job_id}
```

Poll this endpoint to retrieve the transcription result after submitting via
`POST /transcriptions`. The `job_id` is obtained from the `status_endpoint`
field in the async submission response.

### Response (HTTP 200)

```json
{
    "status": "ready",
    "text": "This is the transcribed text. ",
    "revision": 3
}
```

| Field | Type | Description |
|-------|------|-------------|
| `status` | `string` | One of: `pending`, `transcribing`, `ready`, `failed` |
| `text` | `string` or `null` | The transcribed text. `null` unless `status` is `ready`. |
| `revision` | `integer` | Monotonically increasing counter bumped on every job update. Clients use this to detect stale reads — if `revision` hasn't changed, the cached response is still current. |

### Status values

| Status | Meaning |
|--------|---------|
| `pending` | Job accepted but not yet picked up by a worker |
| `transcribing` | Audio is being transcribed |
| `ready` | Transcription complete. `text` is populated. |
| `failed` | Transcription failed. `text` is `null`. |

### Polling cadence

- **While visible (UI on screen):** Poll every 500–1000 ms.
- **Stop polling** once `status` is `ready` or `failed` (terminal states).
- **Background recovery (crash relaunch):** Poll once at startup with a short
  timeout. If `status` is `ready`, retrieve the result; otherwise abandon — the
  job is likely too old or was a different session.

### Error response (HTTP 404)

```json
{ "detail": "Job not found" }
```

Returned when the `job_id` does not correspond to any known or retained job.
The client should treat this the same as an expired or never-existing job.

### Job retention

Jobs are retained for at least 10 minutes after reaching a terminal state
(`ready` or `failed`). After that, the server may evict them. The
`Idempotency-Key` retention window (see [§13](#13-idempotency-key-contract)) is
independent and may extend beyond job retention to prevent duplicate
submissions.

---

## 13. Idempotency-Key contract

The `Idempotency-Key` header provides at-least-once semantics for
`POST /transcriptions`.

### Format

A UUID string in canonical 8-4-4-4-12 lowercase hex format:

```
Idempotency-Key: 3a1b2c3d-4e5f-6789-abcd-ef0123456789
```

### Generation

The client MUST generate the idempotency key **before** starting the upload.
For Ritoras, the key is the `jobId` UUID produced by
`shared/TranscriptionInbox.swift` — the same identifier used for cross-target
delivery. This ensures that a retry after a crash reuses the same key and does
not double-transcribe.

### Retention

The server MUST retain the idempotency key for **at least 10 minutes** from the
initial request. During this window:

- A replay (same key, any identical audio) returns the **same `job_id`** as the
  original response.
- A replay with a key that has already been consumed but whose job is still
  pending or transcribing returns the same `job_id`. The server does not start
  a second transcription.
- After the retention window expires, the server MAY forget the key and treat
  the next request with that key as a new submission.

### Replay response

On key replay within the retention window, the server returns HTTP 202 with the
original `job_id` and `status_endpoint`. The response body is identical to the
original submission response — no re-transcription occurs.

### Error on duplicate with different content

If the same `Idempotency-Key` is used with **different** audio content within
the retention window, the server SHOULD return HTTP 422 Unprocessable Entity.
This signals a client bug (the key should be unique per payload), not a
transient failure.

---

## 14. Deprecation notice

### Endpoint

```
GET {BASE_URL}/dictation_result/latest
```

### What it does

The keyboard extension currently polls this endpoint as a fallback transport
when the primary app-group inbox delivery path does not produce a result in
time. The container app writes dictation results to this endpoint after
transcription completes (in both batch and stream modes), and the keyboard
reads them via polling at ~500 ms intervals.

### Response shape

```json
{
    "status": "completed",
    "text": "This is the transcribed text. ",
    "timestamp": 1712345678.0
}
```

| Field | Type | Description |
|-------|------|-------------|
| `status` | `string` | One of: `completed`, `error`, `cancelled`, `transcribing`, `recording`, `none` |
| `text` | `string` | The transcribed text (present when `status` is `completed`) |
| `timestamp` | `double` | Epoch seconds of the result. Clients use this to ignore stale results. |
| `errorMessage` | `string` or `null` | Present when `status` is `error`. |
| `detail` | `string` or `null` | Present on 404 — value is `"Not Found"`. |

If no result is available, the server returns HTTP 404 with
`{"detail": "Not Found"}`.

### Deprecation status

**DEPRECATED**

This endpoint is a polling-based transport that was introduced as a workaround
before the app-group inbox was available. It will be **removed** in a future
update (Phase 6 of the inbox migration).

### Migration path

New code must use the app-group inbox store
(`shared/TranscriptionInbox.swift`) for cross-target delivery instead of this
endpoint. The inbox provides push-style delivery without polling, works offline,
and is not subject to network latency or server availability.

### Timeline

| Phase | Action |
|-------|--------|
| Phase 5 | This deprecation notice published |
| Phase 6 | Client-side reliance on this endpoint removed. Keyboard stops polling `/dictation_result/latest`. |
| Future (TBD) | Server-side endpoint removed |

---

## 15. Migration status

The following table summarises the state of all documented server endpoints:

| Endpoint | Type | Status | Used by |
|----------|------|--------|---------|
| `POST /transcribe` | Sync | Stable — primary batch endpoint | Container app (batch mode) |
| `WS /stream` | Streaming | Stable — primary streaming endpoint | Container app (stream mode) |
| `POST /transcriptions` + `GET /jobs/{id}` | Async (request-reply) | New — recommended for constrained clients and crash recovery | Not yet adopted by iOS client (planned for Phase 7) |
| `GET /dictation_result/latest` | Sync polling | **DEPRECATED** — see §14 | Keyboard extension (fallback; to be removed in Phase 6) |

### Key design rationale

- **`POST /transcribe`** and **`WS /stream`** remain the primary endpoints for
  the container app today. They are synchronous, well-tested, and unchanged.
- **`POST /transcriptions`** + **`GET /jobs/{id}`** are optional async
  endpoints. They are not yet used by any Ritoras client. They are documented
  now so the server team can implement them in parallel. Future clients —
  especially those that may be killed by the OS mid-request — should prefer this
  pattern.
- **`GET /dictation_result/latest`** is deprecated and will be removed once the
  keyboard extension no longer relies on it (Phase 6). Do not build new
  dependencies on this endpoint.
