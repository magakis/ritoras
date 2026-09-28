#!/usr/bin/env node

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  DEFAULT_SESSION_CONFIG,
  SHIPPING_SESSION_CONFIG,
  decodeWav,
  expandSweep,
  parseLabels,
  parseSession,
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

function intervalsEqual(left, right) {
  return left.length === right.length && left.every((interval, index) =>
    interval.s0 === right[index].s0 && interval.s1 === right[index].s1);
}

function intersection(left, right) {
  const output = [];
  for (const a of left) {
    for (const b of right) {
      const start = Math.max(a.start, b.start);
      const end = Math.min(a.end, b.end);
      if (end > start) output.push({ start, end });
    }
  }
  return output.sort((a, b) => a.start - b.start);
}

function levelQualifiedGapRecovery(candidateIntervals, baselineGaps, baselineFrames, marginDb) {
  const regions = intersection(candidateIntervals, baselineGaps);
  const recoveredIntervals = [];
  let opportunitySeconds = 0;
  let recoveredSeconds = 0;
  for (const frame of baselineFrames) {
    const frameStart = frame.time - frame.dt;
    const frameEnd = frame.time;
    const frameInterval = { start: frameStart, end: frameEnd };
    const gapCoverage = intersection([frameInterval], baselineGaps);
    const qualified = Number.isFinite(frame.fl) && frame.db >= frame.fl + marginDb;
    if (qualified) opportunitySeconds += gapCoverage.reduce((total, part) => total + part.end - part.start, 0);
    if (!qualified) continue;
    for (const part of intersection([frameInterval], regions)) {
      recoveredSeconds += part.end - part.start;
      const previous = recoveredIntervals.at(-1);
      if (previous && Math.abs(previous.end - part.start) < 1e-6) {
        previous.end = part.end;
        previous.seconds = previous.end - previous.start;
      } else {
        recoveredIntervals.push({ start: part.start, end: part.end, seconds: part.end - part.start });
      }
    }
  }
  return { opportunitySeconds, recoveredSeconds, candidateGapSeconds: regions.reduce((sum, x) => sum + x.end - x.start, 0), recoveredIntervals };
}

export function loadSession(input) {
  const resolved = path.resolve(input);
  const isDirectory = fs.statSync(resolved).isDirectory();
  const telemetryPath = isDirectory
    ? fs.readdirSync(resolved).map(name => path.join(resolved, name))
      .find(candidate => candidate.endsWith('.jsonl'))
    : resolved.endsWith('.jsonl') ? resolved : null;
  const wavPath = isDirectory ? path.join(resolved, 'audio.wav') : null;
  const fixtureDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../fixtures/vad-labels');
  if (telemetryPath) {
    const text = fs.readFileSync(telemetryPath, 'utf8');
    const records = text.split(/\r?\n/).filter(Boolean).map(line => JSON.parse(line));
    const meta = records.find(record => record.t === 'meta') ?? {};
    const sessionStartConfig = records.find(record => record.t === 'ev'
      && record.k === 'session_start')?.c ?? null;
    const session = parseSession(text);
    const shortId = meta.jobId?.slice(0, 8) ?? path.basename(telemetryPath, '.jsonl').slice(0, 8);
    const id = `20260928-${shortId}`;
    const labelPath = path.join(fixtureDir, `${id}.txt`);
    const labels = fs.existsSync(labelPath) ? parseLabels(fs.readFileSync(labelPath, 'utf8').trim()) : [];
    return {
      id,
      directory: path.dirname(telemetryPath),
      telemetryPath,
      meta,
      sessionStartConfig,
      labels,
      session,
      source: 'telemetry',
    };
  }
  if (!wavPath || !fs.existsSync(wavPath)) {
    throw new Error(`session input must be a telemetry JSONL or a directory containing audio.wav: ${input}`);
  }
  const wav = decodeWav(fs.readFileSync(wavPath));
  const meta = JSON.parse(fs.readFileSync(path.join(resolved, 'meta.json'), 'utf8'));
  const id = path.basename(resolved);
  const labelPath = path.join(fixtureDir, `${id}.txt`);
  const labels = fs.existsSync(labelPath) ? parseLabels(fs.readFileSync(labelPath, 'utf8').trim()) : [];
  return {
    id, directory: resolved, wav, meta, labels, source: 'wav',
    session: { frames: [], events: [], config: { ...DEFAULT_SESSION_CONFIG }, configIsTelemetry: false },
  };
}

function emittedIntervals(replay) {
  return replay.events.filter(event => event.k === 'emit').map(({ s0, s1 }) => ({ s0, s1 }));
}

function sessionWithConfig(session, config) {
  const configured = { ...session, config };
  Object.defineProperty(configured, 'configIsTelemetry', {
    value: Boolean(session.configIsTelemetry),
  });
  return configured;
}

export function runSweep(directories, sets = [], sweeps = []) {
  const sessions = directories.map(loadSession);
  const baseline = new Map(sessions.map(item => {
    const config = item.source === 'telemetry'
      ? {
        ...item.session.config,
        // Older telemetry predates this master flag; reproduce the recorded
        // path instead of inheriting today's enabled shipping default.
        loudRegimeEnabled: item.sessionStartConfig?.loudRegimeEnabled ?? false,
      }
      : SHIPPING_SESSION_CONFIG;
    const baselineSession = sessionWithConfig(item.session, config);
    return [item.id, replaySession(baselineSession, baselineSession.config, {
      fromWav: item.wav ?? null,
      labels: item.labels,
      compare: false,
    })];
  }));
  const setOverrides = Object.fromEntries(sets.map(item => [item.key, item.value]));
  const configs = expandSweep({}, sweeps).map(config => ({ ...config, ...setOverrides }));
  const runs = configs.map((overrides, index) => {
    const replayed = sessions.map(item => {
      const config = { ...item.session.config, ...overrides };
      const replay = replaySession(item.session, config, {
        fromWav: item.wav ?? null,
        labels: item.labels,
        compare: false,
      });
      const baselineReplay = baseline.get(item.id);
      const baselineChunkIntervals = emittedIntervals(baselineReplay).map(interval => ({
        start: interval.s0 / 1000,
        end: interval.s1 / 1000,
      }));
      const baselineGaps = baselineChunkIntervals.slice(1).flatMap((interval, index) => {
        const start = baselineChunkIntervals[index].end;
        return interval.start > start ? [{ start, end: interval.start }] : [];
      });
      const gapPlus3 = levelQualifiedGapRecovery(
        replay.openIntervals,
        baselineGaps,
        baselineReplay.frames,
        3,
      );
      const gapPlus6 = levelQualifiedGapRecovery(
        replay.openIntervals,
        baselineGaps,
        baselineReplay.frames,
        6,
      );
      const terminatorEvents = replay.events.filter(event =>
        event.k === 'flat_terminate' || event.k === 'loud_flat_terminate');
      const overlapSpeech = terminatorEvents.filter(event => item.labels.some(label =>
        event.time >= label.start && (event.startTime ?? event.time) < label.end)).length;
      return {
        id: item.id,
        source: item.source,
        sessionDurationSeconds: replay.metrics.sessionDurationSeconds,
        metrics: replay.metrics,
        gapSecondsRecovered: gapPlus3.recoveredSeconds,
        gapOpportunitySeconds: gapPlus3.opportunitySeconds,
        gapSecondsRecoveredAtFloorPlus6: gapPlus6.recoveredSeconds,
        gapOpportunityAtFloorPlus6Seconds: gapPlus6.opportunitySeconds,
        candidateOpenGapSeconds: gapPlus3.candidateGapSeconds,
        recoveredGapIntervals: gapPlus3.recoveredIntervals,
        recoveredGapIntervalsAtFloorPlus6: gapPlus6.recoveredIntervals,
        discardCount: replay.events.filter(event => event.k === 'discard').length,
        baselineDiscardCount: baselineReplay.events.filter(event => event.k === 'discard').length,
        terminatorActivationCount: terminatorEvents.length,
        terminatorSpeechOverlapCount: overlapSpeech,
        latchMissingDynamicsWitnessCount: replay.metrics.latchMissingDynamicsWitnessCount,
        quietBoundaryIdentity: item.labels.length === 0
          ? intervalsEqual(emittedIntervals(replay), emittedIntervals(baselineReplay)) : null,
        quietUtteranceIdentity: item.labels.length === 0
          ? replay.metrics.utteranceCount === baselineReplay.metrics.utteranceCount : null,
        emittedIntervals: emittedIntervals(replay),
        openIntervals: replay.openIntervals,
      };
    });
    return {
      index,
      config: overrides,
      aggregate: replayed.reduce((sum, item) => {
        for (const key of ['utteranceCount', 'missedSpeechSeconds', 'falseOpenSeconds']) {
          sum[key] += item.metrics[key];
        }
        for (const key of ['gapSecondsRecovered', 'gapOpportunitySeconds',
          'gapSecondsRecoveredAtFloorPlus6', 'gapOpportunityAtFloorPlus6Seconds',
          'candidateOpenGapSeconds', 'discardCount', 'terminatorActivationCount',
          'terminatorSpeechOverlapCount', 'latchMissingDynamicsWitnessCount']) sum[key] += item[key];
        return sum;
      }, {
        utteranceCount: 0, missedSpeechSeconds: 0, falseOpenSeconds: 0,
        gapSecondsRecovered: 0, gapOpportunitySeconds: 0,
        gapSecondsRecoveredAtFloorPlus6: 0, gapOpportunityAtFloorPlus6Seconds: 0,
        candidateOpenGapSeconds: 0, discardCount: 0, terminatorActivationCount: 0,
        terminatorSpeechOverlapCount: 0, latchMissingDynamicsWitnessCount: 0,
      }),
      quietBoundaryIdentity: replayed.filter(item => item.quietBoundaryIdentity !== null)
        .every(item => item.quietBoundaryIdentity),
      quietUtteranceIdentity: replayed.filter(item => item.quietUtteranceIdentity !== null)
        .every(item => item.quietUtteranceIdentity),
      quietHardPass: replayed.filter(item => item.quietBoundaryIdentity !== null).every(item =>
        item.quietBoundaryIdentity && item.quietUtteranceIdentity && item.terminatorActivationCount === 0),
      sessions: replayed,
    };
  });
  return {
    sessions: sessions.map(item => ({ id: item.id, source: item.source, labels: item.labels, meta: item.meta })),
    baseline: [...baseline].map(([id, replay]) => ({
      id,
      metrics: replay.metrics,
      discardCount: replay.events.filter(event => event.k === 'discard').length,
      openIntervals: replay.openIntervals,
      emittedIntervals: emittedIntervals(replay),
    })),
    runs,
  };
}

function markdown(report) {
  const headers = ['#', 'utterances', 'missed (s)', 'false (s)', 'gap ≥floor+3 (s)', 'opportunity (s)', 'discards', 'terminators', 'speech overlap', 'latch witness rejects', 'quiet identity'];
  const rows = report.runs.map(run => [run.index, run.aggregate.utteranceCount,
    run.aggregate.missedSpeechSeconds.toFixed(2), run.aggregate.falseOpenSeconds.toFixed(2),
    run.aggregate.gapSecondsRecovered.toFixed(2), run.aggregate.gapOpportunitySeconds.toFixed(2),
    run.aggregate.discardCount,
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
