# Phase 1 verification runbook

Run these commands from the repository root. Do not add `--set` or `--sweep`:
the CLI enables baseline comparison only when both are absent.

## 1. Replay the recorded session with its captured config

```sh
node scripts/prediction-sim/bin/replay-vad.mjs \
  scripts/prediction-sim/fixtures/vad-telemetry/20261024-124619/session.jsonl \
  --json /tmp/opencode/20261024-124619-vad-replay.json
```

The stdout report includes `Per-frame e/es/d parity: <matched>/<compared>
(<percent>)` and the divergence count. The JSON report has normalized config,
the full replay `frames` and `events`, and `divergence.mismatches` with each
mismatching frame number, differing fields, recorded values, and replayed
values. `endpointSilenceMs` and its `silenceMs` alias must both be 1900.

## 2. Extract the exact replay boundaries and parity details

```sh
node --input-type=module -e '
import fs from "node:fs";
const replay = JSON.parse(fs.readFileSync("/tmp/opencode/20261024-124619-vad-replay.json", "utf8"));
const frameTime = frame => ({
  q: frame.q,
  startMs: (frame.time - frame.dt) * 1000,
  endMs: frame.time * 1000,
  e: frame.e,
  es: frame.es,
  d: frame.d,
  db: frame.db,
});
console.log(JSON.stringify({
  config: {
    endpointSilenceMs: replay.config.endpointSilenceMs,
    silenceMs: replay.config.silenceMs,
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

The JSON `frames` store `time` at frame end and `dt` as the frame duration;
the extraction therefore prints both frame-start and frame-end milliseconds.
The recorded onset marker is at the start of its tagged frame, while the
replay's generated event timestamp may be at that frame's end (within one
recorded frame). Emission `s0`/`s1` are already milliseconds.

**Baseline replay PASS** requires all of the following:

- Captured `endpointSilenceMs=1900` (and `silenceMs=1900`) in replay config.
- First `emit`: `s0=0`, `s1` approximately `2679.5 ms`.
- Second `start_utterance` frame: `q=56`, frame start approximately `5594 ms`
  (within one frame, ±100 ms).
- Second `emit`: `s0` approximately `5093.9 ms` (within one frame, ±100 ms).
- First `finalize_endpoint` frame: `q=41`, frame start approximately
  `4100 ms` (within one frame, ±100 ms).
- `parity.comparedFrameCount=119`, `parity.matchedFrameCount=119`,
  `parity.matchRate=1`, and no entries in `parity.mismatches`. The comparison
  covers every frame's `e`, `es`, and `d`. If a mismatch occurs, report each
  listed frame and its expected/actual values; do not call parity a pass.
- Final `stop_flush` remains `reason="empty"`, with zero samples.

## 3. Run the full pure-logic suite

```sh
node --test 'scripts/prediction-sim/test/**/*.{js,cjs,mjs}'
```

PASS requires the command to exit successfully with all tests passing. This
runbook records expected output only; Phase 1 implementation did not execute
the replay or tests.
