#!/usr/bin/env node

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  DEFAULT_SESSION_CONFIG,
  SHIPPING_SESSION_CONFIG,
  decodeWav,
  expandSweep,
  intervalDifferenceDuration,
  parseLabels,
  replaySession,
} from './replay-vad.mjs';

function argumentsFor(argv) {
  const dirs = [];
  const sets = [];
  const sweeps = [];
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === '--set' || arg === '--sweep') {
      const value = argv[++i];
      if (!value) throw new Error(`${arg} requires key=value`);
      const [key, raw] = value.split('=', 2);
      if (!key || raw === undefined) throw new Error(`expected key=value, got ${value}`);
      const values = raw.split(',').map(item => item === 'true' ? true : item === 'false' ? false
        : Number.isFinite(Number(item)) ? Number(item) : item);
      if (arg === '--set') sets.push({ key, value: values[0] });
      else sweeps.push({ key, values });
    } else if (arg.startsWith('--')) throw new Error(`unknown option: ${arg}`);
    else dirs.push(arg);
  }
  if (dirs.length === 0) throw new Error('usage: sweep-vad-loud.mjs <session-dir>... [--set key=value] [--sweep key=v1,v2]');
  return { dirs, sets, sweeps };
}

function apply(config, assignments) {
  return assignments.reduce((result, assignment) => ({ ...result, [assignment.key]: assignment.value }), config);
}

function intervalsEqual(left, right) {
  return left.length === right.length && left.every((interval, index) =>
    interval.s0 === right[index].s0 && interval.s1 === right[index].s1);
}

function loadSession(directory) {
  const wav = decodeWav(fs.readFileSync(path.join(directory, 'audio.wav')));
  const meta = JSON.parse(fs.readFileSync(path.join(directory, 'meta.json'), 'utf8'));
  const labelPath = path.join(path.dirname(fileURLToPath(import.meta.url)), '../fixtures/vad-labels', `${path.basename(directory)}.txt`);
  const labels = fs.existsSync(labelPath) ? parseLabels(fs.readFileSync(labelPath, 'utf8').trim()) : [];
  return {
    id: path.basename(directory), directory, wav, meta, labels,
    session: { frames: [], events: [], config: { ...DEFAULT_SESSION_CONFIG }, configIsTelemetry: false },
  };
}

function emittedIntervals(replay) {
  return replay.events.filter(event => event.k === 'emit').map(({ s0, s1 }) => ({ s0, s1 }));
}

export function runSweep(directories, sets = [], sweeps = []) {
  const sessions = directories.map(loadSession);
  const baseline = new Map(sessions.map(item => [item.id,
    replaySession(item.session, SHIPPING_SESSION_CONFIG, { fromWav: item.wav, labels: item.labels, compare: false })]));
  const baseConfig = apply(SHIPPING_SESSION_CONFIG, sets);
  const configs = expandSweep(baseConfig, sweeps);
  const runs = configs.map((config, index) => {
    const replayed = sessions.map(item => {
      const replay = replaySession(item.session, config, { fromWav: item.wav, labels: item.labels, compare: false });
      const baselineReplay = baseline.get(item.id);
      const gapRecovered = intervalDifferenceDuration(replay.openIntervals, baselineReplay.openIntervals);
      const terminatorEvents = replay.events.filter(event => event.k === 'loud_flat_terminate');
      const overlapSpeech = terminatorEvents.filter(event => item.labels.some(label =>
        event.time >= label.start && (event.startTime ?? event.time) < label.end)).length;
      return {
        id: item.id,
        metrics: replay.metrics,
        gapSecondsRecovered: gapRecovered,
        discardCount: replay.events.filter(event => event.k === 'discard').length,
        terminatorActivationCount: terminatorEvents.length,
        terminatorSpeechOverlapCount: overlapSpeech,
        latchMissingDynamicsWitnessCount: replay.metrics.latchMissingDynamicsWitnessCount,
        quietBoundaryIdentity: item.labels.length === 0
          ? intervalsEqual(emittedIntervals(replay), emittedIntervals(baselineReplay)) : null,
        emittedIntervals: emittedIntervals(replay),
        openIntervals: replay.openIntervals,
      };
    });
    return {
      index,
      config,
      aggregate: replayed.reduce((sum, item) => {
        for (const key of ['utteranceCount', 'missedSpeechSeconds', 'falseOpenSeconds']) {
          sum[key] += item.metrics[key];
        }
        for (const key of ['gapSecondsRecovered', 'discardCount', 'terminatorActivationCount',
          'terminatorSpeechOverlapCount', 'latchMissingDynamicsWitnessCount']) sum[key] += item[key];
        return sum;
      }, {
        utteranceCount: 0, missedSpeechSeconds: 0, falseOpenSeconds: 0,
        gapSecondsRecovered: 0, discardCount: 0, terminatorActivationCount: 0,
        terminatorSpeechOverlapCount: 0, latchMissingDynamicsWitnessCount: 0,
      }),
      quietBoundaryIdentity: replayed.filter(item => item.quietBoundaryIdentity !== null)
        .every(item => item.quietBoundaryIdentity),
      sessions: replayed,
    };
  });
  return { sessions: sessions.map(item => ({ id: item.id, labels: item.labels, meta: item.meta })), baseline: [...baseline].map(([id, replay]) => ({ id, metrics: replay.metrics, openIntervals: replay.openIntervals, emittedIntervals: emittedIntervals(replay) })), runs };
}

function markdown(report) {
  const headers = ['#', 'utterances', 'missed (s)', 'false (s)', 'gap recovered (s)', 'discards', 'terminators', 'speech overlap', 'latch witness rejects', 'quiet identity'];
  const rows = report.runs.map(run => [run.index, run.aggregate.utteranceCount,
    run.aggregate.missedSpeechSeconds.toFixed(2), run.aggregate.falseOpenSeconds.toFixed(2),
    run.aggregate.gapSecondsRecovered.toFixed(2), run.aggregate.discardCount,
    run.aggregate.terminatorActivationCount, run.aggregate.terminatorSpeechOverlapCount,
    run.aggregate.latchMissingDynamicsWitnessCount, run.quietBoundaryIdentity]);
  return [
    '# Loud-regime VAD sweep', '', `Sessions: ${report.sessions.map(item => item.id).join(', ')}`, '',
    `| ${headers.join(' | ')} |`, `| ${headers.map(() => '---').join(' | ')} |`,
    ...rows.map(row => `| ${row.join(' | ')} |`), '',
    'False-open seconds are reported, not gated. A speech-overlap terminator count above zero fails the safety gate.',
  ].join('\n');
}

export function main(argv = process.argv.slice(2)) {
  const { dirs, sets, sweeps } = argumentsFor(argv);
  const report = runSweep(dirs, sets, sweeps);
  const stamp = new Date().toISOString().replaceAll(':', '').replaceAll('.', '');
  const outputDir = '/tmp/opencode';
  fs.mkdirSync(outputDir, { recursive: true });
  const jsonPath = path.join(outputDir, `vad-loud-sweep-${stamp}.json`);
  const mdPath = path.join(outputDir, `vad-loud-sweep-${stamp}.md`);
  fs.writeFileSync(jsonPath, `${JSON.stringify(report, null, 2)}\n`);
  fs.writeFileSync(mdPath, `${markdown(report)}\n`);
  console.log(`${jsonPath}\n${mdPath}`);
}

if (process.argv[1] && path.resolve(process.argv[1]) === path.resolve(fileURLToPath(import.meta.url))) {
  try { main(); } catch (error) {
    console.error(error instanceof Error ? error.message : error);
    process.exitCode = 1;
  }
}
