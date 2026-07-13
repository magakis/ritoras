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
| Stream endpoint | WebSocket `/stream` (real-time, not used by Ritoras) |

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

The client is at `keyboard/Sources/WhisperClient.swift`. Key design decisions:

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
