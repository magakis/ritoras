# TV-noise pause characterization: 2026-10-30 09:19:44

## Fixture contents and provenance

- `client_telemetry.json`: 674 frames; recorded `endpointSilenceMs=2000`.
- `audio.wav`: copied untrimmed from `/tmp/opencode/fixture-intake/20261030-091944/`;
  at 4.3 MB it does not justify trimming.
- `full_recording.wav`, `meta.json`, `chunks.jsonl`, and `trace.jsonl` are the
  staged originals. The real Session B (165412) was pruned from the Pi; skip its
  replay. Quiet-speech protection is covered by the synthetic matrix instead.

## Expected utterance-relative reset and decay behavior

- Speech maximum: **−21.2964 dB** at **1.29–1.40 s** (q13).
- Establishment begins with q5, the first pre-qualification strong frame while
  the endpoint is idle/onset-pending, at **0.4943125 s**. q5–q9 contribute
  **494.625 ms**; the 500 ms threshold is crossed **5.375 ms into q10**, at
  **0.9943125 s**. The frame-driven tracker first exposes its seeded reference
  at q10's end, **1.0969375 s**. q0–q4 are not strong/continuing onset evidence;
  subtracting another 70 ms from q5 would count unclassified audio. This
  reconciles the logical threshold crossing with the later telemetry frame.
- q10 is **−32.3997 dB**, below the establishing-window maximum **−25.4138 dB**
  at q9. The robust q10 seed is **−34.4536 dB**: only 108 ms of the window
  supports q9's peak, while the highest level with at least 300 ms of classified
  support is q5's −34.4536 dB. The subsequent q12–q14 sustained rise restores
  the reference to q13's **−21.2964 dB** peak; the downstream
  pause/finalize characterization is unchanged.
- Pause onset: **23.6899 s** (q237).
- **Analytic pure-ambiguous contract:** 800 ms grace + (2000 ms / 0.75) =
  **3.4667 s** after pause onset, or **27.1566 s**.
- **Observed mixed-evidence replay target:** finalize at **26.896375 s**,
  **3.2064375 s** after pause onset. Stripping starts slightly before the
  documented pause boundary, so mixed evidence reaches the threshold earlier;
  the replay test's ±300 ms window covers both values.
- Reference at finalize: **−29.2964 dB**, the 8 dB descent floor.
- After the q12–q14 raise, q15–q236 contribute **166** raw strong/continuing
  frames (**16.6575 s**) before pause onset. During the pause, q238 and q254
  contribute the only two such frames (85.3125 ms and 108 ms; **193.3125 ms**).
  The total is **168 frames / 16.8508125 s**, enough to exhaust the 8 s descent
  budget. A 301.3125 ms lower-level raise at q125–q127 lifts the reference
  temporarily to −25.1994 dB; it reaches the floor again at q188 and remains
  there through finalize.
- The global recorded TV peak, **−43.8046 dB**, is q401 at about **40.09 s**.
  It is after the first endpoint finalize, which clears that utterance's
  reference; q401 cannot be compared with the old −29.2964 dB cap. In the
  archived baseline q401 is raw strong with `speechShaped=true`, and its
  speechActive remap leaves it strong. Within the first pause strip interval the
  test's frame-end boundary (`frame.time >= pause onset`) includes q236, whose
  strong/continuing class ends exactly at pause onset. q236 at **−45.8114 dB** is
  stripped against the −29.2964 dB floor (16.515 dB gap). Restricting to frames
  whose starts are inside the pause, q254 at **−48.1451 dB** is the loudest
  stripped frame (18.85 dB gap).
- First non-stripped speech return: **41.5926 s**.

The release replay checks the enabled mixed-evidence finalize time and emitted
sample range, then checks that disabling the master switch reproduces the
recorded decisions, counters, and emitted range, with only the stop flush
finalizing the recording. q10's level is below the establishing-window maximum,
so the frame-end reporting delay does not alter the seed.
