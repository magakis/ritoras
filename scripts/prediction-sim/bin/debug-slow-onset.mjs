#!/usr/bin/env node

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { readClientTelemetry } from '../lib/client-telemetry.mjs';
import { expandLevelSegments, makeFaultTraceHarness } from '../lib/vad-never-onset-fault-trace.mjs';
import { replaySession } from './replay-vad.mjs';

const FIXTURE_PATH = new URL('../fixtures/vad-never-onset/incident-signature.json', import.meta.url);
const DEFAULT_CORPUS_PATH = '/home/michael/vad-corpus';
const REAL_SESSION_ID = '20261021-175330';
const LOST_WINDOW = { start: 7.379, end: 8.579 };

function parseArgs(argv) {
  const options = { corpusPath: DEFAULT_CORPUS_PATH };
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    if (argument === '--corpus') {
      const value = argv[++index];
      if (!value || value.startsWith('--')) throw new Error('--corpus requires a path');
      options.corpusPath = path.resolve(value);
    } else if (argument === '--help' || argument === '-h') {
      options.help = true;
    } else {
      throw new Error(`unknown option: ${argument}`);
    }
  }
  return options;
}

function formatNumber(value, digits = 3) {
  return Number.isFinite(value) ? value.toFixed(digits) : 'n/a';
}

function formatFrameTable(rows) {
  const headings = [
    'i', 't(s)', 'db', 'floor', 'floor+Δ', 'guard', 'threshold', 'qual',
    'evidence ms', 'window ms', 'chunk ms', 'endpoint', 'decision', 'reason',
  ];
  const values = rows.map(({ frameIndex, time, db, diagnostic }) => [
    String(frameIndex),
    formatNumber(time),
    formatNumber(db),
    formatNumber(diagnostic.floorDb),
    formatNumber(diagnostic.floorThresholdDb),
    formatNumber(diagnostic.guardThresholdDb),
    formatNumber(diagnostic.thresholdDb),
    diagnostic.qualifies ? 'yes' : 'no',
    `${formatNumber(diagnostic.evidenceBeforeMs, 1)}→${formatNumber(diagnostic.evidenceAfterMs, 1)}`,
    formatNumber(diagnostic.windowOccupancyMs, 1),
    `${formatNumber(diagnostic.accumulatorBeforeMs, 1)}→${formatNumber(diagnostic.accumulatorAfterMs, 1)}`,
    `${diagnostic.endpointStateBefore}→${diagnostic.endpointStateAfter}`,
    diagnostic.decision,
    diagnostic.reason,
  ]);
  const widths = headings.map((heading, index) => Math.max(
    heading.length,
    ...values.map(row => row[index].length),
  ));
  const render = row => row.map((value, index) => value.padEnd(widths[index])).join(' | ');
  process.stdout.write(`${render(headings)}\n`);
  process.stdout.write(`${widths.map(width => '-'.repeat(width)).join('-+-')}\n`);
  for (const row of values) process.stdout.write(`${render(row)}\n`);
}

function summarizePath(label, rows, events) {
  const emitted = events.filter(event => event.k === 'emit');
  const slowTriggers = events.filter(event => event.k === 'slow_onset');
  const utteranceStarts = events.filter(event => event.k === 'start_utterance');
  const lastGrowth = rows.filter(row => row.diagnostic.evidenceAfterMs
    > row.diagnostic.evidenceBeforeMs).at(-1) ?? null;
  const triggered = rows.find(row => row.diagnostic.triggered) ?? null;
  const firstNonIdle = rows.find(row => row.diagnostic.endpointStateBefore !== 'idle');
  let reason;
  if (slowTriggers.length > 0 && triggered?.diagnostic.decision === 'startUtterance') {
    reason = `slow tier triggered and endpoint accepted startUtterance; ${utteranceStarts.length} start event(s)`;
  } else if (slowTriggers.length > 0) {
    reason = `slow tier emitted ${slowTriggers.length} trigger event(s); endpoint decision was ${triggered?.diagnostic.decision ?? 'not observed'}`;
  } else if (firstNonIdle) {
    reason = `no slow trigger; endpoint was already ${firstNonIdle.diagnostic.endpointStateBefore} at frame ${firstNonIdle.frameIndex}; ${emitted.length} flush emission(s) came from the existing path`;
  } else if (rows.some(row => row.diagnostic.enabled)) {
    reason = `no slow trigger; last per-frame reason=${rows.at(-1)?.diagnostic.reason ?? 'unavailable'}`;
  } else {
    reason = `tier was disabled; ${emitted.length} emission(s) came from the existing path`;
  }
  process.stdout.write(`\n${label} summary\n`);
  process.stdout.write(`slow tier enabled: ${rows[0]?.diagnostic.enabled ?? false}\n`);
  process.stdout.write(`slow tier trigger count: ${slowTriggers.length}\n`);
  process.stdout.write(`utterance start count: ${utteranceStarts.length}\n`);
  process.stdout.write(`final emission count: ${emitted.length}\n`);
  process.stdout.write(`frame where evidence last grew: ${lastGrowth?.frameIndex ?? 'none'}\n`);
  process.stdout.write(`last evidence occupancy: ${formatNumber(rows.at(-1)?.diagnostic.windowOccupancyMs, 1)} ms\n`);
  process.stdout.write(`qualification/endpoint result: ${reason}\n`);
}

function replaySyntheticFixture() {
  const fixture = JSON.parse(fs.readFileSync(FIXTURE_PATH, 'utf8'));
  const frames = expandLevelSegments(fixture.segments);
  const rows = [];
  const events = [];
  const harness = makeFaultTraceHarness({
    slowOnsetEnabled: true,
    onEvent: event => events.push(event),
  });

  frames.forEach((frame, frameIndex) => {
    const result = harness.drive(frame.db, frame.dt);
    rows.push({
      frameIndex,
      time: harness.sessionElapsedSamples / 16000,
      db: frame.db,
      diagnostic: result.slowOnsetDiagnostic,
    });
  });
  harness.flush();
  harness.end();
  process.stdout.write('=== Synthetic fault-injection trace ===\n');
  formatFrameTable(rows);
  summarizePath('Synthetic trace', rows, events);
  return { rows, events };
}

function replayRealIncident(corpusPath) {
  const telemetryPath = path.join(corpusPath, 'ritoras', REAL_SESSION_ID, 'client_telemetry.json');
  const session = readClientTelemetry(telemetryPath, REAL_SESSION_ID);
  const baseReplay = replaySession(session);
  const config = {
    ...baseReplay.config,
    slowOnsetEnabled: true,
    slowOnsetDeltaDb: 5,
    slowOnsetEvidenceMs: 300,
    slowOnsetWindowSeconds: 2.5,
  };
  const rows = [];
  const replay = replaySession(session, config, {
    compare: false,
    onFrameDiagnostic: diagnostic => rows.push({
      frameIndex: diagnostic.frameIndex,
      time: diagnostic.time,
      db: diagnostic.frame.db,
      dt: diagnostic.frame.dt,
      diagnostic: diagnostic.diagnostic,
    }),
  });
  const visibleRows = rows.filter(row => row.time >= 6.5 && row.time <= 10.0);
  const qualifiedMsInWindow = visibleRows.reduce((total, row) => {
    const start = row.time - row.dt;
    const overlap = Math.max(0, Math.min(row.time, LOST_WINDOW.end) - Math.max(start, LOST_WINDOW.start));
    return total + (Number.isFinite(row.diagnostic.thresholdDb)
      && row.db >= row.diagnostic.thresholdDb ? overlap * 1000 : 0);
  }, 0);
  process.stdout.write('\n=== Real incident trace (6.5–10.0 s) ===\n');
  formatFrameTable(visibleRows);
  process.stdout.write(`\nreal-window cumulative level-above-threshold evidence inside ${LOST_WINDOW.start}–${LOST_WINDOW.end} s: ${formatNumber(qualifiedMsInWindow, 1)} ms\n`);
  summarizePath('Real incident window', visibleRows, replay.events);
}

function usage() {
  return 'Usage: node scripts/prediction-sim/bin/debug-slow-onset.mjs [--corpus PATH]';
}

export function main(argv = process.argv.slice(2)) {
  const options = parseArgs(argv);
  if (options.help) {
    process.stdout.write(`${usage()}\n`);
    return;
  }
  replaySyntheticFixture();
  replayRealIncident(options.corpusPath);
}

if (process.argv[1] && path.resolve(process.argv[1]) === path.resolve(fileURLToPath(import.meta.url))) {
  try {
    main();
  } catch (error) {
    process.stderr.write(`${error instanceof Error ? error.message : error}\n`);
    process.exitCode = 1;
  }
}
