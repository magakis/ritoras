# Whisper recognition findings — 2026-10-27

**Status:** upstream findings handoff; no server experiment or ASR call was run.
**Decision owner:** the user, who owns `server-v2` on the Pi.

## Summary

Phase 4a reviewed 18 sessions and 50 emitted chunks. Fourteen chunks had blank
ASR results. The available evidence identifies several *emitted-unrecognized
candidates*: their audio was sample-aligned, valid AAC, and VAD-active, but
the server returned empty text. This label does not establish that the audio
contained intelligible words; the user-listen gate remains pending.

The server trace is consistent across the set: Parakeet v2
(`nemo-parakeet-tdt-0.6b-v2`), int8, CPU, 16 kHz, with server-side VAD disabled.
It records a loaded worker and per-chunk timings, but omits language, decoder
beam/temperature, server version, and load metrics. The configured
`cleanup_temperature=0` and `s1-mini` refer to post-ASR cleanup, not ASR decoder
temperature.

The strongest recognition-side case is session `20261027-083653`'s final
20.604 s chunk: its start residual is 0 samples, its anchor correlation is
0.978, it has 140 `sp` frames (85 strong), and the source RMS p50/p90 are
−55.5/−44.5 dBFS. ASR returned empty after 8.90 s. This supports investigating
quiet-input handling, but does not prove that gain or decoding changes will
recover intelligible speech.

There is no overload signature in the supplied set: blank chunks average
6.02 s (median 4.48 s) and 2.45 s ASR latency; nonblank chunks average 10.22 s
and 2.23 s latency. Ten of the fourteen blanks are final chunks, so final
position correlates weakly, but blanks are not limited to short tails: examples
include 13.308 s in `20261027-003838` and 20.604 s in `20261027-083653`.

## Evidence table

| Session / chunk | Duration | Alignment proof | VAD activity | Level evidence | ASR outcome / latency |
|---|---:|---|---|---|---|
| `20261027-083653` / final | 20.604 s | Start residual 0 samples; anchor r=0.978 | 140 `sp`, 85 strong | Source RMS p50/p90 −55.5/−44.5 dBFS | Empty after 8.90 s |
| `20261027-001210` / `empty2` | 5.82 s | Sample-aligned; valid AAC | 16 `sp` | `db_max` −49.2 dBFS | Blank; per-chunk latency not supplied |
| `20261027-001745` / `empty1` | 4.028 s | Sample-aligned; valid AAC | 7 `sp` | Onset db −69.5 dBFS | Blank; per-chunk latency not supplied |
| `20261027-005252` / `empty1` | 5.948 s | Sample-aligned; valid AAC | 11 `sp` | p99 −47.7 dBFS | Blank; per-chunk latency not supplied |
| `20261027-002045` / `empty3` | Not supplied | Sample-aligned; valid AAC | VAD-active; speech-vs-noise unresolved | Not supplied | Blank; per-chunk latency not supplied |
| `20261027-003542` / `empty1` | Not supplied | Sample-aligned; valid AAC | VAD-active; speech-vs-noise unresolved | Not supplied | Blank; per-chunk latency not supplied |
| `20261027-003838` / `empty1` | 13.308 s | Sample-aligned; valid AAC | VAD-active; speech-vs-noise unresolved | Not supplied | Blank; per-chunk latency not supplied |
| `20261027-003958` / `empty1` | Not supplied | Sample-aligned; valid AAC | VAD-active; speech-vs-noise unresolved | Not supplied | Blank; per-chunk latency not supplied |
| `20261027-010408` / `empty1` guard | Not supplied | Not supplied | Zero `sp` frames | Not supplied | Non-speech guard; not a speech-recognition failure |

The four unresolved cases are candidates for disposition, not confirmed speech
loss. Words and intelligibility remain unverified for every candidate until
the user-listen gate.

## Findings

1. **The client delivered the cited candidate chunks.** Their sample alignment,
   valid AAC, and VAD activity provide no evidence that pre-roll, AAC bitrate,
   or endpoint-boundary changes would recover missing samples from these
   already-emitted chunks.
2. **Final position is common but not the only disposition.** Ten of fourteen
   blanks are final chunks, and blank chunks include long examples such as
   003838 and 083653. The blank group is shorter on average than the nonblank
   group; latencies are similar (2.45 s versus 2.23 s), with no observed
   overload signature.
3. **Quiet input is a lead, not a conclusion.** The 083653 final chunk is
   quiet by the supplied RMS figures. Server-side normalization/pre-gain or
   whisper-oriented decoding could help, but no A/B was run and no ASR calls
   were authorized.
4. **Current traces cannot isolate the recognition stage.** The engine and
   worker are identified, but the trace lacks several decoder/runtime fields
   needed to attribute empty results to language configuration, decoding, or
   resource conditions. `cleanup_temperature=0`/`s1-mini` are post-ASR cleanup
   settings and should not be treated as ASR decoder settings.

## Recommended server-side experiments

These are proposals for the server owner, not approved or executed changes.

1. **Add per-chunk trace fields before changing the model path.** Record server
   build/version, selected language, ASR decoder parameters (including beam and
   temperature), and contemporaneous worker/load metrics alongside each chunk's
   timing and outcome. **Acceptance metric:** all fields are present and
   correlated for a matched session/chunk set; trace data distinguishes ASR
   output from post-ASR cleanup without including audio or response bodies.
2. **Run a paired quiet-input normalization A/B.** Use the 083653 final chunk
   and the other sample-aligned blank candidates, with nonblank chunks and the
   010408 zero-`sp` guard as controls. **Acceptance metric:** report per-chunk
   empty/nonempty outcomes and latency/resource changes; any nonempty recovery
   must pass the user-listen gate, and the non-speech guard must not gain
   hallucinated text.
3. **Run a paired whisper-decoding configuration A/B.** First expose and record
   the actual language/beam/temperature settings, then vary only server-approved
   whisper-oriented decode settings on the same aligned inputs. **Acceptance
   metric:** report per-case recovery, guard-control output, and latency/load
   deltas; intelligibility remains user-verified rather than inferred from
   nonempty text.
4. **Evaluate a one-shot retry-on-empty only after the first two experiments.**
   Retry only an empty result with an explicitly approved alternate decode
   configuration. **Acceptance metric:** document recovered candidate cases,
   false nonempty results on controls, and added latency/load before proposing
   deployment.

## Client fixes and telemetry for future triage

- **Phase 3 fixed the evidenced client retention fault** in `20261027-000217`:
  VAD-accepted evidence in a pending endpoint accumulator now prevents its
  adjacent retained gap from being treated as entirely voiceless. The
  six-second backstop remains active for gaps without qualifying evidence.
- **Phase 2 sample-true telemetry** records frame and event source coordinates,
  witness fields, effective session parameters/build identity, and timestamped
  discards. Future full recordings can be compared to emitted/discarded spans
  without relying on compressed legacy millisecond coordinates.
- **Full-recording upload-gate telemetry** records the resolved enable flag,
  token presence as a Boolean, final-text nonempty state, WAV presence, stage
  outcome, and upload completion/status or error domain. It never records the
  token or response body; this should make a recurrence of missing
  `full_recording.wav` explainable from the on-device JSONL record.

## Open questions

- What language value was actually passed to Parakeet for each blank chunk?
- What ASR beam/temperature and other decoder options were active? The trace
  does not record them; cleanup temperature is a separate post-ASR setting.
- Which exact server build/version handled each session?
- What were worker CPU, memory, queue, and concurrent-load metrics at the time?
- For the unresolved 002045, 003542, 003838, and 003958 candidates, was the
  emitted audio speech-bearing or non-speech? Waveform/listening evidence is
  needed before classifying them.
- For each empty response, did Parakeet itself return empty text, or did a later
  post-ASR stage produce the empty final? The supplied summary does not resolve
  this stage boundary.

## Ownership and approval boundary

The user owns `server-v2` on the Pi and is the decision owner for server-side
experiments. Any gain/normalization change, model or quantization change, decode
parameter change, or retry-on-empty behavior requires the user's explicit
approval and belongs in the server repository. This Ritoras memo makes no
server changes and performs no ASR calls.
