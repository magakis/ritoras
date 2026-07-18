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
