# Ritoras ↔ Whisper-compatible transcription server contract

> Current client/server request and response contracts, with the streaming wire
> protocol explicitly versioned. Protocol v1 records existing behavior;
> Protocol v2 specifies additive format negotiation.

---

## 1. Purpose and scope

Ritoras communicates with a **Whisper-compatible transcription server** for
batch and streaming dictation. The client contract covers the request shapes,
WebSocket frames, response types, and client-side lifecycle described below.

The client does not assume a specific ASR engine, model, quantization, or
language limitation. Where behavior depends on the server deployment rather
than on the Ritoras client, this document says so explicitly. Deployment-
specific behavior is summarized in §9.

---

## 2. Server URL and endpoints

The base URL is configured in Ritoras settings. The client uses these paths
relative to that base URL:

| Operation | Endpoint |
|-----------|----------|
| Batch transcription | `POST {BASE_URL}/transcribe` |
| Streaming transcription | WebSocket `{BASE_URL}/stream` |

The WebSocket endpoint uses the URL scheme corresponding to the configured base
URL (`ws` for `http`, or `wss` for `https`).

---

## 3. Batch transcription

### Request

Ritoras sends a `multipart/form-data` request to `POST /transcribe` with the
audio part and, when available, optional language and LLM-cleanup form fields:

```text
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
| Multipart field name | `audio` |
| Filename | `audio.m4a` |
| Content-Type | `audio/mp4` |
| Optional form field | `language` |
| Optional form field | `cleanup_styling` (string; `casual`, `semi-casual`, `semi-formal`, `formal`) |
| Optional form field | `cleanup_structure` (string; `prose`, `lists`) |
| Optional form field | `cleanup_context` (string; `general`, `email`) |

The field name is **`audio`**, not `file`. The optional `language` field is a
client-provided value; how the deployment interprets it is deployment-specific.
Each LLM-cleanup field is optional; omitting it lets the server apply its
profile default. An invalid cleanup value receives HTTP 422 with a JSON body of
`{"detail":"<field> must be one of: <choices>"}`, where `<choices>` is the
allowed-value list for that field above.

### Authentication

When a non-empty API key is configured, Ritoras sends it as
`Authorization: Bearer <key>`. The scheme is case-insensitive, and the header
contains the scheme and key as two whitespace-separated parts. The same key is
used for every configured server. Set the key in Settings → API Key.

The server applies this authentication to all HTTP endpoints, including
`/transcribe`, `/transcriptions`, `/jobs/{job_id}`, `/dictation_result`,
`/dictation_result/latest`, `/warmup`, `/health`, and any other route. A missing
or invalid key receives HTTP 401 with
`{"detail": "Invalid or missing API key"}` and `WWW-Authenticate: Bearer`.
Ritoras treats HTTP 401 as terminal, surfaces it as an API-key error, and does
not retry it.

When no key is configured, Ritoras omits the `Authorization` header. This works
with servers configured not to enforce authentication; enforcement and key
validity are deployment-specific.

### Response

On a successful JSON response, the client expects a `transcription` field:

```json
{
    "success": true,
    "transcription": "The transcribed text."
}
```

For a JSON response, the client accepts the transcription only when the
response indicates success. If JSON decoding fails, the client also accepts a
non-empty plain-text response. A non-200 HTTP response is surfaced as an error.
The server's choice of error body and any text processing applied to the
returned transcription are deployment-specific.

### Async job API

The Ritoras client can submit an asynchronous batch transcription to
`POST /transcriptions`. This endpoint is implemented by the referenced
server-v2 source; availability and behavior on any particular deployment are
not guaranteed by this client contract.

The request is `multipart/form-data` with the required `audio` file part, the
optional LLM-cleanup form fields described above, and an optional
`Idempotency-Key` HTTP header. The cleanup fields are strings with these allowed
values: `cleanup_styling` (`casual`, `semi-casual`, `semi-formal`, `formal`),
`cleanup_structure` (`prose`, `lists`), and `cleanup_context` (`general`,
`email`). Omit a field to let the server apply its profile default. An invalid
cleanup value receives HTTP 422 with a JSON body of
`{"detail":"<field> must be one of: <choices>"}`, using that field's allowed
values for `<choices>`.

The server hashes the raw uploaded audio bytes with SHA-256, and normalized
cleanup preferences are part of the request content identity. While the key
remains indexed, repeating the same key with the same audio and cleanup
preferences returns HTTP 202 and the existing `job_id` and `status_endpoint`;
reusing the key with different audio or cleanup preferences returns HTTP 422.
A newly accepted job uses the idempotency key as its `job_id`, or a generated
UUID when no key is supplied. The optional `language` field is currently ignored
by this server implementation; this is a source-confirmed property of that
implementation, not a promise about other compatible servers.

The 202 response has this shape:

```json
{
    "job_id": "<job-id>",
    "status_endpoint": "/jobs/<job-id>"
}
```

Poll `GET /jobs/{job_id}` for an object containing `status`, `text`,
`revision`, and `error`. Status values are `pending`, `transcribing`, `ready`,
and `failed`; `text` and `error` may be null until applicable. A 404 means that
the job is not present in the server's current job store. It does not establish
that the job was specifically evicted: the id may be unknown, belong to a
different server, have expired, or have been lost on server restart.

For the referenced implementation, terminal job records are retained for 600
seconds from `terminal_at`; idempotency entries are retained for 600 seconds
from `created_at`. A background cleanup loop checks for expired entries every
60 seconds, so these are retention limits rather than exact deletion times.
Both stores are process-local and in-memory, safe only for a single worker.
They are not restored after restart; an accepted job is not guaranteed to
survive a process restart, and the job store is not shared across workers.
These details describe the source implementation and must not be read as
confirmation of a deployed server's configuration or runtime behavior.

The client's existing async timeout path retries with the same idempotency key
up to two times, then falls back to synchronous `POST /transcribe`. That
synchronous fallback is not deduplicated against an already accepted async
job, so both paths may perform transcription. The async job contract does not
promise indefinite background execution or immediate wake/resumption of a
suspended client; retention windows likewise do not guarantee that a job can
be recovered after process loss or expiry.

### Audio upload and timeout

The client uploads AAC/MPEG-4 audio. Accepted formats and server-side decoding
are deployment-specific; the client does not require or assert a particular
server conversion pipeline.

The configured base timeout is `SharedConfig.timeoutSeconds`, whose default is
**20 seconds**. For an async batch transcription, the `POST /transcriptions`
submit timeout is the greater of this setting and **0.1 seconds per recorded
second** (for example, 120 seconds for a 20-minute recording). The async
poll-loop deadline is the greater of
**600 seconds** and **2 seconds per recorded second** (2,400 seconds for a
20-minute recording). A sync `POST /transcribe` fallback receives at least that
same poll-deadline budget. Short recordings therefore retain the existing
20-second submit and 600-second poll defaults. Streaming partial and final
response waits use their separate streaming timeouts.

---

## 4. Streaming lifecycle

Streaming recording begins **immediately**. The microphone starts before server
selection and WebSocket connection complete. Server selection and connection
attempts run in the background while the user dictates.

The background connection loop:

1. Tries all configured servers, putting the probe-selected server first when a
   probe result is available.
2. Waits with an increasing backoff between failed rounds, starting at 1 second
   and doubling up to an 8-second cap.
3. Continues trying for the duration of the dictation session.

The WebSocket `/stream` upgrade request sends the same Bearer authorization
header. A rejected handshake is closed with code `1008` and reason
`Invalid or missing API key`.

Audio chunks produced while disconnected are held in a FIFO queue. Nothing is
dropped because the WebSocket is not connected. A late successful connection is
wired into the active session exactly once. A bounded reconnect can create a
replacement WebSocket for the same dictation after a transport failure.

---

## 5. Streaming wire protocols

### Protocol v1 (frozen)

Protocol v1 is the existing `/stream` wire contract. A client that sends no
`CONFIG` uses this protocol; v2 servers continue to accept it without changing
its binary layout.

#### Client → server

| Frame | Shape | Purpose |
|-------|-------|---------|
| Binary | `[4-byte BE uint32 chunk_id][float32 LE PCM @ 16 kHz mono]` | One audio chunk |
| Text JSON | `{"type":"END"}` | Signals that no more audio chunks will follow |
| Text JSON | `{"type":"PING"}` | Keepalive and connection probe |
| Text JSON | `{"type":"CONTEXT","text":"..."}` | Context; supported by the referenced server, not sent by the current Ritoras client |
| Text JSON | `{"type":"CANCEL"}` | Cancels recording; supported by the referenced server, not sent by the current Ritoras client |
| Text JSON | `{"type":"TELEMETRY", ...}` | Client diagnostics; the current Ritoras client sends this before `END` when telemetry is available |

The binary frame layout is:

| Offset | Size | Field |
|--------|------|-------|
| 0 | 4 bytes | `chunk_id`, unsigned 32-bit integer, big-endian |
| 4 | N × 4 bytes | Float32 PCM samples, little-endian, 16 kHz mono |

Ritoras starts a connection with a `PING`/`PONG` handshake. A `PONG` confirms
that the WebSocket connection is usable. The referenced server echoes
`ping_seq` in its `PONG` when that optional field is present in a client's
`PING`.

The referenced server-v2 implementation accepts `CANCEL` during the receive
loop, discards queued audio, waits for any in-flight chunk, sends no `final`,
and closes the WebSocket. The current Ritoras client does not send `CANCEL`.

`TELEMETRY` is a JSON object with a `type` field; the current client uses this
text-frame pattern for chunk-splitter diagnostics. The referenced server-v2
implementation accepts frames up to 1 MiB of UTF-8 JSON, keeps the last
accepted frame before `END`, and writes it as `client_telemetry.json` with the
captured recording. It checks the JSON object and `type`, but does not validate
a telemetry payload schema. Send it before `END`: after `END`, the server only
handles `PING` while waiting to send the final response, so later telemetry is
ignored. The client bounds its telemetry send wait and continues to `END` if
that send fails or times out.

#### `?format=` query

The referenced server-v2 implementation selects a connection-wide v1 audio
format from `?format=`. An absent or empty query value defaults to `pcm`; the
server lowercases and trims non-empty values before lookup. Accepted values
are `pcm`, `wav`, `wave`, `m4a`, `mp4`,
`aac`, `mp3`, `ogg`, `opus`, and `flac`. `wave` aliases `wav`; `mp4` aliases
`m4a`. `pcm` means the Float32 layout above. For every other accepted value,
bytes after the four-byte chunk ID are container/compressed-audio bytes decoded
by the server to 16 kHz mono Float32; the decoder content-sniffs the payload,
and the mapped suffix is not currently used as a format hint. An unsupported
query value produces `{"type":"error","message":"unsupported format: <value>"}`
and closes the WebSocket with code `1003`.
The current Ritoras client does not append this query; its Protocol v1 mode is
the referenced server's default `pcm`.

#### Server → client

| Type | Shape | Meaning |
|------|-------|---------|
| `partial` | `{"type":"partial","transcription":"...","chunk_id":N}` | Result associated with one audio chunk |
| `final` | `{"type":"final","transcription":"...","chunk_id":N}` | Terminal result after `END` and drain |
| `PONG` | `{"type":"PONG"}` | Response to `PING`; echoes `ping_seq` when supplied |
| `error` | `{"type":"error","message":"..."}` | Server-reported failure; the current client treats it as terminal outside v2 negotiation |

Two independent client timers send PINGs after connection setup: the liveness
monitor sends every **5 seconds**, and the application keepalive sends every
**25 seconds**. Both cadences are active; they are not alternatives. The
liveness monitor times out after **three consecutive 5-second intervals**
without qualifying activity (nominally about **15 seconds**, with bounded
upload-window pause credit). This corrects the earlier 60-second summary: the
configured threshold is three intervals, not 60 seconds. A `PONG` or `partial`
is qualifying activity while recording; after `END`, only a `PONG` qualifies.

### Protocol v2 (additive)

Protocol v2 adds per-connection audio-format negotiation and optional
LLM-cleanup preference delivery on the same `/stream` endpoint. It adds JSON
text control frames and preserves the four-byte chunk ID prefix. `CONFIG`
follows the existing JSON text-frame precedent used by `TELEMETRY` in v1; it
does not add another endpoint or transport. The existing `END`, `PING`,
`partial`, `final`, and ordinary error behavior remains unchanged after
negotiation.

#### Negotiation and CONFIG

For an unpinned session with AAC enabled (on by default), the client completes
the existing `PING`/`PONG` probe, sends one `CONFIG` before any binary frame, and
waits for `CONFIG_ACK`. When AAC is disabled but at least one cleanup preference
is non-default, it sends `CONFIG` requesting `f32le` and waits for the same ACK.
With AAC disabled and all cleanup preferences at the server default, it sends
no `CONFIG` and retains the Protocol v1 Float32 behavior. Legacy-pinned sessions
also omit `CONFIG`, including when cleanup choices are non-default. The ACK wait
is bounded inside the existing **32-second** `streamWsConnectTimeout`
connection-setup budget; it does not add another 32-second timeout. When
required, the client sends only one `CONFIG` text frame per WebSocket
connection.

The client sends this JSON text frame (with `sampleRate` set to the active
source rate):

```json
{"type":"CONFIG","format":"aac-m4a","sampleRate":16000,"channels":1,"bitrate":64000,"protocol":2}
```

`sampleRate` is `16000` or `48000`. Field meanings and server use:

| Field | Value | Meaning |
|-------|-------|---------|
| `type` | `"CONFIG"` | Identifies the text frame. |
| `format` | `"aac-m4a"` | The only field that selects the audio decode path; it is load-bearing. |
| `sampleRate` | `16000` or `48000` | Advisory declaration of the client's configured AAC source rate. |
| `channels` | `1` | Advisory channel count. |
| `bitrate` | `64000` | Advisory bitrate in bits per second. |
| `protocol` | `2` | Protocol version marker; it does not select the audio decode path. |
| `cleanup_styling` | Optional: `casual`, `semi-casual`, `semi-formal`, or `formal` | Explicit cleanup style; omitted for the server default. |
| `cleanup_structure` | Optional: `prose` or `lists` | Explicit output structure; omitted for the server default. |
| `cleanup_context` | Optional: `general` or `email` | Explicit cleanup context; omitted for the server default. |

The cleanup fields are sent in this same first `CONFIG` frame, only for axes
whose values are non-default. For example, a custom AAC request may include:

```json
{"type":"CONFIG","format":"aac-m4a","sampleRate":16000,"channels":1,"bitrate":64000,"protocol":2,"cleanup_styling":"formal","cleanup_context":"email"}
```

No empty values or separate cleanup frames are sent. If AAC is disabled, a
cleanup-only request uses `f32le` and omits the AAC-specific fields:

```json
{"type":"CONFIG","format":"f32le","protocol":2,"cleanup_structure":"lists"}
```

`type` and `protocol` identify the message and version. Of the audio-format
fields, `format` alone selects the decode path. `sampleRate`, `channels`, and
`bitrate` are advisory; the server content-sniffs the selected container and
decodes to 16 kHz mono Float32 regardless of the declared source rate. Both
16 kHz and 48 kHz are valid (`16000` is the client setting's default). The
decoded PCM is transcribed and appended to `audio.wav`; the capture does not
store the incoming m4a payload. The client encodes AAC-LC, mono, at 64 kbps in
a self-contained m4a container for each chunk, using the batch recorder's high
encoder-quality setting. The server does not guess between PCM and container
formats; `format` selects the decode branch. In 16 kHz mode the client encodes
the chunk PCM directly. In 48 kHz mode it must explicitly convert the 16 kHz
chunk PCM to 48 kHz before encoding; writing a buffer does not implicitly
resample it.

The format enum is extensible:

| Format | Status and meaning |
|--------|--------------------|
| `f32le` | Supported alias for legacy `pcm` Float32; default with no `CONFIG`. An explicit request is ACKed as `f32le`. |
| `aac-m4a` | Supported by v2; one complete m4a container per binary message. |
| `pcm16` | Reserved; not implemented. |

On an accepted request, the server replies with a JSON text frame. In this
schema, `<accepted>` is replaced by the negotiated enum value:

```json
{"type":"CONFIG_ACK","format":"<accepted>","protocol":2}
```

For the Ritoras AAC request, the ACK is:

```json
{"type":"CONFIG_ACK","format":"aac-m4a","protocol":2}
```

For a request with cleanup fields, the `CONFIG_ACK` echoes the accepted,
normalized cleanup values, for example:

```json
{"type":"CONFIG_ACK","format":"aac-m4a","protocol":2,"cleanup_styling":"formal","cleanup_context":"email"}
```

The ACK's `format` is the format accepted for that connection. The client treats
only a parseable `CONFIG_ACK` with protocol `2` and the requested format as
success: `aac-m4a` when AAC is enabled, or `f32le` for a cleanup-only request
when AAC is disabled. Other text frames do not authorize the requested format;
an unrecognized or non-matching ACK leaves the bounded wait running until it
succeeds or times out. The client does not require the echoed cleanup values to
authorize the format.

#### Server negotiation policy

- The first `CONFIG` received before any binary frame wins, including an
  unsupported-format request. Only this first `CONFIG` is accepted; later
  `CONFIG` frames do not renegotiate that connection. The client sends its
  `CONFIG` after the initial `PING`/`PONG` probe and before the first binary
  audio frame.
- Only a JSON object with `type: "CONFIG"` and `protocol: 2` is a v2 request.
  A server that does not recognize the type or protocol version ignores it as
  an unknown text frame; the client then reaches its bounded ACK timeout.
- A `CONFIG` received after any binary frame is ignored with a server warning
  and no ACK; the connection keeps the format already selected for it.
- An invalid cleanup preference value produces an `error` frame and cancels
  the WebSocket session without a `CONFIG_ACK`. The client sends values from
  the shared cleanup-preference model's supported options and omits defaults.
- An accepted `CONFIG` overrides the `?format=` query for that connection only.
  It does not change the query or any other connection's format.
- An unknown or unimplemented format, including reserved `pcm16`, produces a
  requester-safe `{"type":"error","message":"unsupported format: <value>"}`
  frame without closing the WebSocket. The connection remains in `pcm` mode,
  so the client can fall back to Float32 in place. This differs from an
  unsupported `?format=` query, which closes with code `1003` as specified
  above.
- A connection with no `CONFIG` retains Protocol v1 behavior, including its
  `?format=` selection.

#### Client outcome matrix

| Outcome | Connection | Client and wire behavior |
|---------|------------|--------------------------|
| Matching `CONFIG_ACK` | Open | Pin to `aac-m4a`; use one complete m4a payload per audio message. |
| Matching `f32le` `CONFIG_ACK` for cleanup-only request | Open | Use Float32 PCM and retain the accepted cleanup preferences for this connection. |
| ACK timeout | Client closes | Pin session to `f32le`; bounded reconnect without `CONFIG`, then send v1 Float32. Later reconnects also omit `CONFIG`. |
| Unsupported-format `error` frame | Still open | Use `f32le` in place and pin session legacy. Server stays `pcm`; later reconnects omit `CONFIG`. |
| WebSocket close | Closed | Connection failure, not in-place fallback; an unpinned session re-runs negotiation on the replacement socket. |
| Invalid cleanup preference value | Server cancels session | No `CONFIG_ACK`; the client pins the session to legacy Float32, and a replacement connection omits `CONFIG`. |
| AAC setting off; cleanup preferences at server defaults | Open | Never send `CONFIG`; use the unchanged Protocol v1 Float32 format. |
| AAC setting off; at least one cleanup preference non-default | Open after matching ACK | Send `CONFIG` with `format: "f32le"` and only the selected cleanup fields; use Float32 PCM. |

Protocol v1 cannot carry cleanup preferences. If a v1 server ignores a v2
`CONFIG`, the client's bounded ACK timeout closes and pins that session to
legacy Float32; subsequent legacy-pinned connections send no `CONFIG`, so the
stream cleanup choices are not applied by that server. AAC-disabled sessions
with only default cleanup choices continue to omit `CONFIG` entirely.

A server-side close during negotiation is handled by client lifecycle, not by
an on-wire fallback. The existing bounded reconnect repeats `PING`/`PONG` and
re-runs `CONFIG`/`CONFIG_ACK` unless the session was already legacy-pinned by a
prior timeout or error frame. The client also closes after an ACK timeout:
because the server may have committed `aac-m4a` before a delayed ACK, continuing
with Float32 on that socket is unsafe. That close pins legacy before reconnect,
so the replacement socket and any later reconnect omit `CONFIG`. If reconnect
fails, streaming enters the existing terminal-failure path and preserves
`.stream.wav` for saved-audio retry (see §8).

The AAC toggle, source rate, and cleanup preferences are captured once at
session start; changes take effect on the next session. A connection uses one
audio format only: PCM and AAC frames never mix, and there is no mid-connection
renegotiation. On reconnect, AAC negotiation runs again unless a timeout or
error frame has pinned the session to legacy Float32; a legacy-pinned session
omits `CONFIG` on every replacement connection. The send queue keeps PCM samples
as its source of truth and prepares each retry for the format selected on that
connection.

#### Protocol v2 binary frame

The chunk ID prefix is unchanged; only the payload changes after a successful
AAC ACK:

| Offset | Size | Field |
|--------|------|-------|
| 0 | 4 bytes | `chunk_id`, unsigned 32-bit integer, big-endian |
| 4 | Remaining message | One complete, self-contained m4a container for this chunk |

Each WebSocket binary message contains exactly one complete m4a payload after
the prefix. Do not send ADTS, add another length prefix, or split one container
across messages. The declared source rate may be 16 kHz or 48 kHz; server
decoding normalizes either to 16 kHz mono Float32.

---

## 6. Result semantics and stop behavior

- `partial` responses are **raw per-chunk outputs**. They are display-only in
  the app and are not accepted as the terminal transcription.
- The `final` response is the accepted streaming result.
- A **non-empty** `final` is accepted even when the session produced zero
  partial responses.

When the user stops recording, the client:

1. Allows up to **2 seconds** for a connection to arrive late.
2. Waits for the chunk-consumer task to complete. The stream is considered
   drained only when the FIFO queue is empty and no chunk is in flight.
3. Sends `{"type":"END"}` after the drain completes.
4. Awaits the `final` response, bounded by
   `SharedConfig.Defaults.streamFinalTimeout` (**120 seconds**).

---

## 7. Client-side Chunk Splitter

Streaming uses an energy-based RMS voice-activity detector with DC-corrected RMS
and an adaptive noise floor. The endpoint machine owns chunk boundaries. A
chunk is emitted only when one of these events occurs:

- a real speech-to-silence transition accumulates the endpoint silence
  threshold, whose default is **700 ms** (`SharedConfig.streamVadEndpointSilenceMs`,
  or **11,200 samples** at 16 kHz); or
- recording ends and the stop flush finalizes the in-flight utterance.

The minimum speech and total chunk durations below determine whether the
accumulated utterance is eligible for emission; they do not create another
boundary. On the adaptive path, silence accrues only for level-quiet,
non-speech-shaped energy: gradually modulated soft speech remains speech
evidence even below the current silence threshold, while abrupt gusts and flat
ambient noise remain eligible to bank silence. The static mode retains its
fixed RMS classification. On the adaptive path, the noise floor is frozen while
an utterance is in flight and rises only while the endpoint machine is idle.
Floor convergence therefore cannot create a mid-utterance chunk boundary. A legacy
consecutive-silence fallback remains behind the disabled-by-default
`streamEndpointMachineEnabled` kill switch and uses the `streamVadSpeechRms`,
`streamVadSilenceMs`, and `streamVadMaxNoiseSec` settings.

Cold-start refinement-window convergence is deliberately not idle-gated; this is the
one intentional exception to the rule that the floor rises only while idle.

The endpoint-machine defaults are:

| Parameter | Default | Meaning |
|-----------|---------|---------|
| `onsetSamples` | `1,120 samples` (**70 ms**) | Strong speech evidence required to start an utterance |
| `endEvidenceSamples` | `1,600 samples` (**100 ms**) | Silence evidence required to enter endpoint-pending state |
| `endpointSilenceSamples` | `11,200 samples` (**700 ms**) | Silence accumulation required to emit after a speech-to-silence transition |
| `resumeSamples` | `1,920 samples` (**120 ms**) | Speech evidence required to resume a pending utterance |
| `ambiguousRescueSamples` | `5,120 samples` (**320 ms**) | Ambiguous evidence required to rescue a pending endpoint |
| `streamVadMinSpeechMs` | `300 ms` | Minimum detected speech in an emitted chunk or stop flush |
| `streamVadMinChunkMs` | `300 ms` | Minimum total audio in an emitted chunk |

The chunking semantics described here do not change the wire format or protocol.

There is **no maximum chunk length** and no forced-finalization timer based on
chunk duration. Unbounded continuous speech therefore produces one unbounded
chunk; clients must treat chunk size as unbounded.

Telemetry retains the existing `maxChunkMs`, `splitSearchWindowMs`, and
`minSilenceAtSplitMs` configuration keys for capture compatibility, with the
numeric value `0` indicating that no duration cap or split search is active.
These metadata values do not limit the `/stream` audio payload.

---

## 8. Failure and retry

Connection attempts continue throughout the streaming session. While recording,
queued streaming chunk sends retry without a fixed attempt limit, using the
client's backoff between attempts. A dead active transport gets one bounded
reconnect per session; if it fails, the existing terminal-failure path
preserves the `.stream.wav` for saved-audio retry.

If streaming cannot complete, the continuous WAV recording is preserved for a
later retry. The user-facing failure messages are:

- `Server unreachable — recording preserved for retry` when no streaming
  connection becomes available;
- `stream send failed — recording preserved for retry` when a connection exists
  but queued audio cannot be completed.

The **25-second** application keepalive PING runs in addition to the
**5-second** liveness PING described in §5. The WebSocket connection-setup budget is
`streamWsConnectTimeout`, **32.0 seconds**; Protocol v2 ACK negotiation shares
that budget.

HTTP 401 responses are non-retryable. The app surfaces them as
`WhisperError.unauthorized` with an API-key error; the keyboard's job-poll path
shows a prompt terminal API-key error rather than treating the response as a
timeout.

---

## 9. Deployment-specific behavior

The following are properties of a particular server deployment, not assumptions
made by the Ritoras client contract:

- ASR engine and model choice;
- server-side VAD, segmentation, silence trimming, and other preprocessing;
- cross-chunk context behavior;
- supported languages and the interpretation of the optional `language` field;
- whether authentication enforcement is enabled and which key value is valid
  (the header format is specified in §3);
- accepted batch audio formats and server-side audio decoding;
- normalization, punctuation, substitutions, casing, and other result
  post-processing;
- performance, latency, concurrency, and resource behavior.
