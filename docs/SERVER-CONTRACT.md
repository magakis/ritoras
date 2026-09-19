# Ritoras ↔ Whisper-compatible transcription server contract

> Current client/server request, response, and streaming wire contract. This
> document describes only behavior that the Ritoras client sends or observes.

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
audio part and, when available, an optional language form field:

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

The field name is **`audio`**, not `file`. The optional `language` field is a
client-provided value; how the deployment interprets it is deployment-specific.

Ritoras sends no `Authorization` header. That describes the client request,
not whether a particular deployment requires or supports authentication.

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

### Audio upload and timeout

The client uploads AAC/MPEG-4 audio. Accepted formats and server-side decoding
are deployment-specific; the client does not require or assert a particular
server conversion pipeline.

The client-side timeout setting is `SharedConfig.timeoutSeconds`, whose default
is **20 seconds**.

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

Audio chunks produced while disconnected are held in a FIFO queue. Nothing is
dropped because the WebSocket is not connected. A late successful connection is
wired into the active session exactly once, and one WebSocket session spans one
dictation.

---

## 5. Streaming wire protocol

### Client → server

| Frame | Shape | Purpose |
|-------|-------|---------|
| Binary | `[4-byte BE uint32 chunk_id][float32 LE PCM @ 16 kHz mono]` | One audio chunk |
| Text JSON | `{"type":"END"}` | Signals that no more audio chunks will follow |
| Text JSON | `{"type":"PING"}` | Keepalive and connection probe |
| Text JSON | `{"type":"CONTEXT","text":"..."}` | Defined protocol frame; unused by the Ritoras client |

The binary frame layout is:

| Offset | Size | Field |
|--------|------|-------|
| 0 | 4 bytes | `chunk_id`, unsigned 32-bit integer, big-endian |
| 4 | N × 4 bytes | Float32 PCM samples, little-endian, 16 kHz mono |

Ritoras starts a connection with a PING/PONG handshake. A PONG confirms that
the WebSocket connection is usable.

### Server → client

The client handles these text JSON response types:

| Type | Shape | Meaning |
|------|-------|---------|
| `partial` | `{"type":"partial","transcription":"...","chunk_id":N}` | Result associated with one audio chunk |
| `final` | `{"type":"final","transcription":"...","chunk_id":N}` | Terminal result after END and drain |
| `PONG` | `{"type":"PONG"}` | Response to PING |

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
   `SharedConfig.Defaults.streamFinalTimeout` (**30 seconds**).

---

## 7. Client-side VAD

Streaming uses an energy-based RMS voice-activity detector with DC-corrected RMS
and an adaptive noise floor. The endpoint machine owns chunk boundaries. A
chunk is emitted only when one of these events occurs:

- a real speech-to-silence transition accumulates the endpoint silence
  threshold, whose default is **700 ms** (`SharedConfig.streamVadEndpointSilenceMs`,
  or **11,200 samples** at 16 kHz); or
- recording ends and the stop flush finalizes the in-flight utterance.

The minimum speech and total chunk durations below determine whether the
accumulated utterance is eligible for emission; they do not create another
boundary. On the adaptive path, the noise floor is frozen while an utterance is
in flight and rises only while the endpoint machine is idle. Floor convergence
therefore cannot create a mid-utterance chunk boundary. A legacy
consecutive-silence fallback remains behind the disabled-by-default
`streamEndpointMachineEnabled` kill switch and uses the `streamVadSpeechRms`,
`streamVadSilenceMs`, and `streamVadMaxNoiseSec` settings.

The endpoint-machine defaults are:

| Parameter | Default | Meaning |
|-----------|---------|---------|
| `onsetSamples` | `1,120 samples` (**70 ms**) | Strong speech evidence required to start an utterance |
| `endEvidenceSamples` | `1,600 samples` (**100 ms**) | Silence evidence required to enter endpoint-pending state |
| `endpointSilenceSamples` | `11,200 samples` (**700 ms**) | Silence accumulation required to emit after a speech-to-silence transition |
| `resumeSamples` | `1,920 samples` (**120 ms**) | Speech evidence required to resume a pending utterance |
| `ambiguousRescueSamples` | `5,120 samples` (**320 ms**) | Ambiguous evidence required to rescue a pending endpoint |
| `preRollSamples` | `4,000 samples` (**250 ms**) | Audio retained before onset |
| `streamVadMinSpeechMs` | `300 ms` | Minimum detected speech in an emitted chunk or stop flush |
| `streamVadMinChunkMs` | `300 ms` | Minimum total audio in an emitted chunk |

The chunking semantics described here do not change the wire format or protocol.

There is **no maximum chunk length** and no forced-finalization timer based on
chunk duration. Unbounded continuous speech therefore produces one unbounded
chunk; clients must treat chunk size as unbounded.

---

## 8. Failure and retry

Connection retries continue throughout the streaming session. While recording,
queued streaming chunk sends retry without a fixed attempt limit, using the
client's backoff between attempts.

If streaming cannot complete, the continuous WAV recording is preserved for a
later retry. The user-facing failure messages are:

- `Server unreachable — recording preserved for retry` when no streaming
  connection becomes available;
- `stream send failed — recording preserved for retry` when a connection exists
  but queued audio cannot be completed.

The client sends a keepalive PING every **25 seconds**. The WebSocket connection
attempt timeout is `streamWsConnectTimeout`, **8.0 seconds**.

---

## 9. Deployment-specific behavior

The following are properties of a particular server deployment, not assumptions
made by the Ritoras client contract:

- ASR engine and model choice;
- server-side VAD, segmentation, silence trimming, and other preprocessing;
- cross-chunk context behavior;
- supported languages and the interpretation of the optional `language` field;
- authentication requirements and authorization policy;
- accepted batch audio formats and server-side audio decoding;
- normalization, punctuation, substitutions, casing, and other result
  post-processing;
- performance, latency, concurrency, and resource behavior.
