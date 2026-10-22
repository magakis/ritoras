#!/usr/bin/env node

import { createQuietProfileEvaluationFixture } from '../lib/quiet-profile-evaluation-fixture.mjs';
import { replaySession } from './replay-vad.mjs';

function format(value, digits = 2) {
  return Number.isFinite(value) ? value.toFixed(digits) : 'n/a';
}

function frameDescription(frame, replay) {
  const strongDelta = Number.isFinite(frame.th) && Number.isFinite(frame.fl)
    ? frame.th - frame.fl
    : null;
  const continuationDelta = Number.isFinite(frame.ct) && Number.isFinite(frame.fl)
    ? frame.ct - frame.fl
    : null;
  const frameEvents = replay.events.filter(event => event.time === frame.time)
    .map(event => event.k);
  return [
    `floor=${format(frame.fl)}`,
    `strong=${format(frame.th)}(floor+${format(strongDelta)})`,
    `continuation=${format(frame.ct)}(floor+${format(continuationDelta)})`,
    `evidence=${frame.e}`,
    `endpoint=${frame.es}`,
    `decision=${frame.d}`,
    `events=${frameEvents.join(',') || 'none'}`,
  ].join(' ');
}

function maximumStrongStreakMs(frames) {
  let currentMs = 0;
  let maximumMs = 0;
  for (const frame of frames) {
    if (frame.e === 'strong') {
      currentMs += frame.dt * 1000;
      maximumMs = Math.max(maximumMs, currentMs);
    } else {
      currentMs = 0;
    }
  }
  return maximumMs;
}

function eventsFor(replay, kind) {
  return replay.events.filter(event => event.k === kind);
}

function summarize(label, replay) {
  const starts = eventsFor(replay, 'start_utterance');
  const emissions = eventsFor(replay, 'emit');
  process.stdout.write(`\n${label} summary\n`);
  process.stdout.write(
    `effective configured deltas: strong=${replay.config.strongDeltaDb} continuation=${replay.config.continuationDeltaDb}\n`,
  );
  process.stdout.write(`strong-classified frames: ${replay.frames.filter(frame => frame.e === 'strong').length}\n`);
  process.stdout.write(
    `longest uninterrupted strong streak: ${format(maximumStrongStreakMs(replay.frames), 1)} ms (onset requires ${replay.config.endpointOnsetMs} ms)\n`,
  );
  process.stdout.write(`latched continuing frames: ${replay.frames.filter(frame => frame.ll).length}\n`);
  process.stdout.write(`utterance starts: ${starts.map(event => format(event.time, 3)).join(', ') || 'none'}\n`);
  process.stdout.write(
    `emissions (${emissions.length}): ${emissions.map(event => `${format(event.s0 / 1000, 3)}–${format(event.s1 / 1000, 3)}s`).join(', ') || 'none'}\n`,
  );
  if (starts.length === 0) {
    const longestStrongMs = maximumStrongStreakMs(replay.frames);
    const latchedFrames = replay.frames.filter(frame => frame.ll).length;
    const lastFrame = replay.frames.at(-1);
    const reason = longestStrongMs < replay.config.endpointOnsetMs
      ? `no continuous strong run reached the endpoint onset requirement (${format(longestStrongMs, 1)} < ${replay.config.endpointOnsetMs} ms)`
      : latchedFrames === 0
        ? 'strong evidence met the onset duration, but no continuation latch was recorded; inspect the per-frame endpoint decisions above'
        : `no start event despite ${latchedFrames} latched frames; final endpoint state=${lastFrame?.es ?? 'unavailable'}, decision=${lastFrame?.d ?? 'unavailable'}`;
    process.stdout.write(`why no onset: ${reason}\n`);
  }
}

const { session, baselineConfig, evaluationConfig } = createQuietProfileEvaluationFixture();
const baseline = replaySession(session, baselineConfig, { compare: false });
const evaluation = replaySession(session, evaluationConfig, { compare: false });
process.stdout.write(
  `Effective configs: baseline strong=${baseline.config.strongDeltaDb}/continuation=${baseline.config.continuationDeltaDb}; quiet strong=${evaluation.config.strongDeltaDb}/continuation=${evaluation.config.continuationDeltaDb}\n`,
);
process.stdout.write('Frame-by-frame replay (threshold deltas in parentheses are actual threshold minus floor):\n');
process.stdout.write('frame | t(s) | db | baseline | quiet evaluation\n');
for (let index = 0; index < Math.max(baseline.frames.length, evaluation.frames.length); index += 1) {
  const baselineFrame = baseline.frames[index];
  const evaluationFrame = evaluation.frames[index];
  const frame = baselineFrame ?? evaluationFrame;
  process.stdout.write(`${index} | ${format(frame.time, 3)} | ${format(frame.db)} | ${baselineFrame ? frameDescription(baselineFrame, baseline) : 'no frame'} | ${evaluationFrame ? frameDescription(evaluationFrame, evaluation) : 'no frame'}\n`);
}

const divergenceIndex = baseline.frames.findIndex((frame, index) => {
  const candidate = evaluation.frames[index];
  return !candidate || ['e', 'es', 'd', 'th', 'ct', 'fl', 'll']
    .some(field => frame[field] !== candidate[field]);
});
process.stdout.write(`\nFirst replay divergence: ${divergenceIndex < 0 ? 'none' : `frame ${divergenceIndex} at ${format(baseline.frames[divergenceIndex].time, 3)}s`}\n`);
summarize('Baseline', baseline);
summarize('Quiet evaluation', evaluation);
