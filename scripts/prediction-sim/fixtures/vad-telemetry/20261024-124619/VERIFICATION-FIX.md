# Phase 2 fixed-logic verification runbook

Run from the repository root. The fixture's captured session config contains
the old 500 ms endpoint pre-roll, so the replay explicitly overrides only that
field to the new 900 ms default. Keep the captured `endpointSilenceMs=1900`
override unchanged; do not change `silenceMs` or add other `--set` values.

## 1. Replay the fixed logic

```sh
node scripts/prediction-sim/bin/replay-vad.mjs \
  scripts/prediction-sim/fixtures/vad-telemetry/20261024-124619/session.jsonl \
  --set endpointPreRollMs=900 \
  --json /tmp/opencode/20261024-124619-vad-replay-fixed.json
```

## 2. Extract the same boundaries and parity report as Phase 1

```sh
node --input-type=module -e '
import fs from "node:fs";
const replay = JSON.parse(fs.readFileSync("/tmp/opencode/20261024-124619-vad-replay-fixed.json", "utf8"));
const frameTime = frame => ({
  q: frame.q,
  startMs: (frame.time - frame.dt) * 1000,
  endMs: frame.time * 1000,
  e: frame.e,
  es: frame.es,
  d: frame.d,
  db: frame.db,
  ll: frame.ll,
});
console.log(JSON.stringify({
  config: {
    endpointSilenceMs: replay.config.endpointSilenceMs,
    silenceMs: replay.config.silenceMs,
    endpointPreRollMs: replay.config.endpointPreRollMs,
  },
  parity: replay.divergence,
  starts: replay.frames.filter(frame => frame.d === "start_utterance").map(frameTime),
  finalizations: replay.frames.filter(frame => frame.d === "finalize_endpoint").map(frameTime),
  emits: replay.events.filter(event => event.k === "emit").map(event => ({
    id: event.id,
    s0: event.s0,
    s1: event.s1,
    decisionTimeMs: event.time * 1000,
  })),
  stopFlush: replay.events.filter(event => event.k === "stop_flush").map(event => ({
    reason: event.r,
    samples: event.n,
  })),
}, null, 2));
'
```

The baseline parity comparison is expected to diverge where the fixed logic
changes the onset; it is diagnostic, not a PASS gate for this fixed replay.

**Fixed replay PASS requires all of the following:**

- `endpointSilenceMs=1900`, `silenceMs=1900`, and
  `endpointPreRollMs=900` in the replay config.
- Exactly two `start_utterance` frames and exactly two emitted chunks. There
  must be no start on frames 42–49 and no start frame whose start time is
  within 4200–4950 ms. This directly guards against the observed q=45 false
  start.
- The first emitted chunk remains `s0=0`, `s1` approximately `2679.5 ms`
  (within ±100 ms), and the first `finalize_endpoint` remains frame `q=41`
  (frame start approximately `4087.4 ms`, within ±100 ms of 4100 ms).
- The second start is on a soft/latched frame `q=50..52`, with replay evidence
  `e="continuing"` and decision `d="start_utterance"`. Its frame start is
  approximately `4987..5150 ms`; allow one recorded-frame tolerance (100 ms)
  for the 300 ms streak crossing. The expected 300 ms crossing is frame 52,
  whose recorded frame start is about `5184.6 ms`.
- The `fl` values on frames 50–52 are non-increasing from frame 50. The 1.2 s
  idle floor-rise hold has about 211 ms remaining at frame 52's start
  (5184.625 ms, 989.25 ms after frame 41 ends at 4195.375 ms), so the new
  no-upward-floor-rise latch gate must not delay the target onset.
- The quiet latch requires a rising edge at least as large as the existing
  5 dB flat-spread threshold. The target q49→q50 edge is +6.271 dB, while the
  no-latch q56–58 and q97–99 streaks rise by at most +2.567 dB and +3.189 dB.
  Frames 50–52 then accumulate the required 301.3125 ms qualified streak.
- The post-finalize soft-latch blackout is 700 ms: it suppresses continuing /
  ambiguous promotion only. Normal `.strong` frames must still be eligible to
  start an utterance during the blackout.
- The second emit has `s0 <= 4950 ms` and `s0` no later than the first soft
  onset frame's start. Its `s1` is after frame 55's end, proving the soft
  onset ramp is inside the emitted chunk.
- The final stop flush remains `reason="empty"` with zero samples.

## 3. Run the full pure-logic suite

```sh
node --test 'scripts/prediction-sim/test/**/*.{js,cjs,mjs}'
```

PASS requires a successful exit with every test passing. This includes the
`vad-never-onset-study` negative controls, the fixture's 4200–4950 ms
no-start regression, and the normal-strong-onset blackout bypass test.
Intentional pins are the 900 ms shipping pre-roll / 14,400-sample endpoint
default, the two stable-floor latch timings of 300–310 ms, and the interrupted
pre-latch streak of 29 × 10 ms (290 ms). Keep the no-latch evidence counts and
pre-baseline no-start guard unchanged; do not update unrelated expectations to
make the suite pass.

## 4. Run the mandatory Swift syntax gate

```sh
node scripts/parse-check.mjs
```

PASS requires every tracked Swift file to parse successfully. Type checking
and the iOS build remain CI-only on this Linux host.
