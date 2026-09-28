#!/usr/bin/env node

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  DEFAULT_SESSION_CONFIG,
  parseSession,
  replaySession,
} from './replay-vad.mjs';

const G1_EDGE_TOLERANCE_MS = 150;
const G2_MIN_QUALIFIED_SHARE = 0.8;
const STRONG_FRACTION_THRESHOLD = 0.8;

function intervalUnion(intervals) {
  const sorted = intervals
    .filter(interval => Number.isFinite(interval.start) && Number.isFinite(interval.end)
      && interval.end > interval.start)
    .map(interval => ({ start: interval.start, end: interval.end }))
    .sort((left, right) => left.start - right.start || left.end - right.end);
  const merged = [];
  for (const interval of sorted) {
    const previous = merged.at(-1);
    if (previous && interval.start <= previous.end) {
      previous.end = Math.max(previous.end, interval.end);
    } else {
      merged.push(interval);
    }
  }
  return merged;
}

function duration(intervals) {
  return intervals.reduce((total, interval) => total + interval.end - interval.start, 0);
}

function openIntervalsFromEvents(events, durationSeconds) {
  const starts = events.filter(event => event.k === 'start_utterance');
  const closes = events.filter(event => event.k === 'emit'
    || event.k === 'discard'
    || (event.k === 'stop_flush' && event.r === 'below_minimums'));
  const usedCloses = new Set();
  return starts.flatMap(startEvent => {
    const closeIndex = closes.findIndex((event, index) => event.time >= startEvent.time && !usedCloses.has(index));
    const close = closeIndex < 0 ? null : closes[closeIndex];
    if (close) usedCloses.add(closeIndex);
    const start = Math.max(0, startEvent.time - (Number.isFinite(startEvent.n) ? startEvent.n / 16000 : 0));
    const end = close?.time ?? durationSeconds;
    return end >= start ? [{ start, end }] : [];
  });
}

function differenceIntervals(left, right) {
  const cuts = intervalUnion(right);
  const result = [];
  for (const interval of intervalUnion(left)) {
    let cursor = interval.start;
    for (const cut of cuts) {
      if (cut.end <= cursor) continue;
      if (cut.start >= interval.end) break;
      if (cut.start > cursor) result.push({ start: cursor, end: Math.min(cut.start, interval.end) });
      cursor = Math.max(cursor, cut.end);
      if (cursor >= interval.end) break;
    }
    if (cursor < interval.end) result.push({ start: cursor, end: interval.end });
  }
  return result.filter(interval => interval.end > interval.start);
}

export function gateG1CoverageMonotonicity(baselineEmitIntervals, candidateOpenIntervals, toleranceMs = G1_EDGE_TOLERANCE_MS) {
  const candidate = intervalUnion(candidateOpenIntervals);
  const tolerance = toleranceMs / 1000;
  const missing = baselineEmitIntervals.filter(interval => !candidate.some(open => (
    open.start <= interval.start + tolerance
      && open.end >= interval.end - tolerance
      && open.end > interval.start
      && open.start < interval.end
  )));
  return { pass: missing.length === 0, missingIntervals: missing.length, toleranceMs };
}

export function gateG2EvidenceBoundedGrowth(candidateOpenIntervals, baselineOpenIntervals, frames) {
  const growth = differenceIntervals(candidateOpenIntervals, baselineOpenIntervals);
  const growthSeconds = duration(growth);
  let qualifiedSeconds = 0;
  let pureSilenceSeconds = 0;
  for (const interval of growth) {
    for (const frame of frames) {
      const overlap = Math.max(0, Math.min(interval.end, frame.end) - Math.max(interval.start, frame.start));
      if (overlap === 0) continue;
      const qualifies = frame.evidence === 'continuing'
        || (frame.evidence === 'ambiguous'
          && Number.isFinite(frame.db)
          && Number.isFinite(frame.floorDb)
          && frame.db >= frame.floorDb + 2);
      if (qualifies) qualifiedSeconds += overlap;
      if (frame.evidence === 'silence') pureSilenceSeconds += overlap;
    }
  }
  const growthQualifiedShare = growthSeconds === 0 ? 1 : qualifiedSeconds / growthSeconds;
  const pureSilenceLimitSeconds = Math.max(0.2, growthSeconds * 0.05);
  return {
    pass: growthQualifiedShare + 1e-9 >= G2_MIN_QUALIFIED_SHARE
      && pureSilenceSeconds <= pureSilenceLimitSeconds + 1e-9,
    growthSeconds,
    growthQualifiedShare,
    qualifiedGrowthSeconds: qualifiedSeconds,
    pureSilenceGrowthSeconds: pureSilenceSeconds,
    pureSilenceLimitSeconds,
  };
}

export function gateG3NormalVoiceInvariance(baselineEmitIntervals, candidateEmitIntervals, strongFraction, theta = STRONG_FRACTION_THRESHOLD) {
  const applicable = strongFraction >= theta;
  const same = baselineEmitIntervals.length === candidateEmitIntervals.length
    && baselineEmitIntervals.every((interval, index) => (
      interval.s0 === candidateEmitIntervals[index].s0
        && interval.s1 === candidateEmitIntervals[index].s1
    ));
  return { pass: !applicable || same, applicable, same, strongFraction, theta };
}

function listTelemetryFiles(input) {
  const resolved = path.resolve(input);
  const stat = fs.statSync(resolved);
  if (stat.isFile()) {
    return resolved.endsWith('-vad.jsonl') ? [resolved] : [];
  }
  return fs.readdirSync(resolved, { withFileTypes: true }).flatMap(entry => {
    const child = path.join(resolved, entry.name);
    if (entry.isDirectory()) return listTelemetryFiles(child);
    return entry.isFile() && entry.name.endsWith('-vad.jsonl') ? [child] : [];
  });
}

function readTelemetry(filePath) {
  const text = fs.readFileSync(filePath, 'utf8');
  const records = text.split(/\r?\n/).filter(Boolean).map(line => JSON.parse(line));
  const session = parseSession(text);
  const meta = records.find(record => record.t === 'meta') ?? {};
  const id = meta.jobId ?? path.basename(filePath, '-vad.jsonl');
  const framesBySequence = new Map();
  const timedEvents = [];
  let elapsed = 0;
  for (const record of records) {
    if (record.t === 'f') {
      const frameDuration = Number.isFinite(record.dt) ? record.dt : 0;
      const end = elapsed + frameDuration;
      framesBySequence.set(record.q, {
        sequence: record.q,
        start: elapsed,
        end,
        dt: frameDuration,
        evidence: record.e,
        db: record.db,
        floorDb: record.fl,
        record,
      });
      elapsed = end;
    } else if (record.t === 'ev') {
      timedEvents.push({ ...record, time: elapsed });
    }
  }
  const frames = [...framesBySequence.values()].sort((left, right) => left.sequence - right.sequence);
  const sessionStartConfig = records.find(record => record.t === 'ev'
    && record.k === 'session_start')?.c ?? {};
  const deviceEmitIntervals = timedEvents.filter(event => event.k === 'emit'
    && Number.isFinite(event.s0) && Number.isFinite(event.s1))
    .map(event => ({ s0: event.s0, s1: event.s1 }));
  const deviceOpenIntervals = openIntervalsFromEvents(timedEvents, elapsed);
  const durationSeconds = frames.reduce((total, frame) => total + frame.dt, 0);
  const strongSeconds = frames.reduce((total, frame) => (
    total + (frame.evidence === 'strong' ? frame.dt : 0)
  ), 0);
  return {
    id,
    filePath,
    session,
    sessionStartConfig,
    meta,
    frames,
    events: timedEvents,
    durationSeconds,
    strongFraction: durationSeconds > 0 ? strongSeconds / durationSeconds : 0,
    deviceEmitIntervals,
    deviceOpenIntervals,
  };
}

function emittedIntervals(events) {
  return events.filter(event => event.k === 'emit'
    && Number.isFinite(event.s0) && Number.isFinite(event.s1))
    .map(({ s0, s1 }) => ({ s0, s1 }));
}

function compareEmitIntervals(expected, actual) {
  return expected.length === actual.length && expected.every((interval, index) => (
    interval.s0 === actual[index].s0 && interval.s1 === actual[index].s1
  ));
}

function embeddedConfig(item, overrides = {}) {
  const config = { ...item.session.config, ...overrides };
  if (item.sessionStartConfig.loudRegimeEnabled === undefined) {
    config.loudRegimeEnabled = false;
  }
  if (item.session.configIsTelemetry && Number.isFinite(config.staleFloorSeconds)
    && Number.isFinite(config.riseMultiplier)) {
    config.staleFloorSeconds *= config.riseMultiplier;
  }
  return config;
}

function mirrorFidelity(item) {
  const replay = replaySession(item.session, embeddedConfig(item), { compare: true });
  const frameMismatchCount = replay.divergence?.mismatchCount ?? 0;
  const emitsMatch = compareEmitIntervals(item.deviceEmitIntervals, emittedIntervals(replay.events));
  return {
    id: item.id,
    frameCount: item.frames.length,
    frameMismatchCount,
    fieldMismatchCount: replay.divergence?.fieldMismatchCount ?? 0,
    firstDivergence: replay.divergence?.firstDivergence ?? null,
    deviceChunkCount: item.deviceEmitIntervals.length,
    replayChunkCount: emittedIntervals(replay.events).length,
    emitsMatch,
    pass: frameMismatchCount === 0 && emitsMatch,
  };
}

function countLatchDiscardChurn(events) {
  const starts = events.filter(event => event.k === 'start_utterance');
  const closes = events.filter(event => event.k === 'emit' || event.k === 'discard'
    || (event.k === 'stop_flush' && event.r === 'below_minimums'));
  const used = new Set();
  let count = 0;
  for (const start of starts) {
    const closeIndex = closes.findIndex((event, index) => event.time >= start.time && !used.has(index));
    if (closeIndex < 0) continue;
    used.add(closeIndex);
    if (start.softOnset === true && closes[closeIndex].k === 'discard') count += 1;
  }
  return count;
}

function evaluateSession(item, override = {}, theta = STRONG_FRACTION_THRESHOLD) {
  const config = embeddedConfig(item, override);
  const replay = replaySession(item.session, config, { compare: false });
  const candidateEmits = emittedIntervals(replay.events);
  const candidateOpenSeconds = openIntervalsFromEvents(replay.events, item.durationSeconds);
  const baselineOpenSeconds = item.deviceOpenIntervals;
  const g1 = gateG1CoverageMonotonicity(
    item.deviceEmitIntervals.map(interval => ({ start: interval.s0 / 1000, end: interval.s1 / 1000 })),
    candidateOpenSeconds,
  );
  const g2 = gateG2EvidenceBoundedGrowth(candidateOpenSeconds, baselineOpenSeconds, item.frames);
  const g3 = gateG3NormalVoiceInvariance(item.deviceEmitIntervals, candidateEmits, item.strongFraction, theta);
  return {
    id: item.id,
    durationSeconds: item.durationSeconds,
    strongFraction: item.strongFraction,
    growthSeconds: g2.growthSeconds,
    growthQualifiedShare: g2.growthQualifiedShare,
    pureSilenceGrowthSeconds: g2.pureSilenceGrowthSeconds,
    softOnsetCount: replay.events.filter(event => event.k === 'start_utterance'
      && event.softOnset === true).length,
    candidateEmitIntervals: candidateEmits,
    latchOriginatedThenDiscardedChurn: countLatchDiscardChurn(replay.events),
    gates: { G1: g1, G2: g2, G3: g3 },
    pass: g1.pass && g2.pass && g3.pass,
  };
}

function parseArguments(argv) {
  const inputs = [];
  const overrides = {};
  let theta = STRONG_FRACTION_THRESHOLD;
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === '--theta') {
      theta = Number(argv[++index]);
      if (!Number.isFinite(theta) || theta < 0 || theta > 1) {
        throw new Error('--theta must be between 0 and 1');
      }
    } else if (arg === '--set') {
      const assignment = argv[++index];
      if (!assignment || !assignment.includes('=')) throw new Error('--set requires key=value');
      const [key, raw] = assignment.split('=', 2);
      const defaults = DEFAULT_SESSION_CONFIG;
      if (!Object.hasOwn(defaults, key)) throw new Error(`unknown config key: ${key}`);
      overrides[key] = raw === 'true' ? true : raw === 'false' ? false : Number(raw);
      if (typeof overrides[key] === 'number' && !Number.isFinite(overrides[key])) {
        throw new Error(`invalid numeric config value: ${assignment}`);
      }
    } else if (arg.startsWith('--')) {
      throw new Error(`unknown option: ${arg}`);
    } else {
      inputs.push(arg);
    }
  }
  if (inputs.length === 0) {
    throw new Error('usage: sweep-vad-quiet.mjs <telemetry-dir|session.jsonl>... [--theta 0.8] [--set key=value]');
  }
  return { inputs, overrides, theta };
}

export function runQuietSweep(inputs, { overrides = {}, theta = STRONG_FRACTION_THRESHOLD, cache = null } = {}) {
  const files = inputs.flatMap(listTelemetryFiles).sort();
  const sessions = files.map(file => {
    if (!cache) return readTelemetry(file);
    if (!cache.sessions.has(file)) cache.sessions.set(file, readTelemetry(file));
    return cache.sessions.get(file);
  });
  const fidelity = sessions.map(item => {
    if (!cache) return mirrorFidelity(item);
    if (!cache.fidelity.has(item.filePath)) cache.fidelity.set(item.filePath, mirrorFidelity(item));
    return cache.fidelity.get(item.filePath);
  });
  const evaluations = sessions.map(item => evaluateSession(item, overrides, theta));
  const sortedStrongFractions = evaluations.map(item => item.strongFraction).sort((a, b) => a - b);
  const quantile = p => sortedStrongFractions.length === 0
    ? null
    : sortedStrongFractions[Math.min(sortedStrongFractions.length - 1,
      Math.floor(p * (sortedStrongFractions.length - 1)))];
  return {
    sessionCount: sessions.length,
    theta,
    overrides,
    fidelity: {
      passed: fidelity.filter(item => item.pass).length,
      total: fidelity.length,
      pass: fidelity.every(item => item.pass),
      sessions: fidelity,
    },
    deviceBaseline: sessions.map(item => ({
      id: item.id,
      emittedIntervals: item.deviceEmitIntervals,
      frames: item.frames.map(frame => ({
        sequence: frame.sequence,
        start: frame.start,
        end: frame.end,
        dt: frame.dt,
        evidence: frame.evidence,
        db: frame.db,
        floorDb: frame.floorDb ?? null,
      })),
    })),
    acceptanceGates: {
      G1: evaluations.filter(item => item.gates.G1.pass).length,
      G2: evaluations.filter(item => item.gates.G2.pass).length,
      G3: evaluations.filter(item => item.gates.G3.pass).length,
      total: evaluations.length,
      pass: evaluations.every(item => item.pass),
    },
    strongFractionDistribution: {
      sorted: sortedStrongFractions,
      min: sortedStrongFractions[0] ?? null,
      p25: quantile(0.25),
      median: quantile(0.5),
      p75: quantile(0.75),
      max: sortedStrongFractions.at(-1) ?? null,
      atOrAboveTheta: evaluations.filter(item => item.strongFraction >= theta).length,
    },
    sessions: evaluations,
  };
}

function markdown(report) {
  const rows = report.sessions.map(session => (
    `| ${session.id} | ${session.strongFraction.toFixed(3)} | ${session.growthSeconds.toFixed(3)} | ${session.growthQualifiedShare.toFixed(3)} | ${session.softOnsetCount} | ${session.latchOriginatedThenDiscardedChurn} | ${session.gates.G1.pass} | ${session.gates.G2.pass} | ${session.gates.G3.pass} |`
  ));
  const sorted = report.strongFractionDistribution.sorted.map(value => value.toFixed(4)).join(', ');
  return [
    '# Quiet-path VAD telemetry sweep',
    '',
    `Sessions: ${report.sessionCount}; mirror fidelity: ${report.fidelity.passed}/${report.fidelity.total}; theta: ${report.theta}`,
    `Gates: G1 ${report.acceptanceGates.G1}/${report.acceptanceGates.total}, G2 ${report.acceptanceGates.G2}/${report.acceptanceGates.total}, G3 ${report.acceptanceGates.G3}/${report.acceptanceGates.total}`,
    '',
    `Strong-fraction distribution: min=${report.strongFractionDistribution.min?.toFixed(4) ?? 'n/a'}, p25=${report.strongFractionDistribution.p25?.toFixed(4) ?? 'n/a'}, median=${report.strongFractionDistribution.median?.toFixed(4) ?? 'n/a'}, p75=${report.strongFractionDistribution.p75?.toFixed(4) ?? 'n/a'}, max=${report.strongFractionDistribution.max?.toFixed(4) ?? 'n/a'}, >=theta=${report.strongFractionDistribution.atOrAboveTheta}/${report.sessionCount}`,
    `Sorted strong fractions: ${sorted}`,
    '',
    '| Session | strong fraction | growth s | qualified share | soft onsets | latch-discard churn | G1 | G2 | G3 |',
    '| --- | ---: | ---: | ---: | ---: | ---: | --- | --- | --- |',
    ...rows,
    '',
    'All interval matching uses per-frame telemetry durations; G1 edge tolerance is 150 ms.',
  ].join('\n');
}

export function main(argv = process.argv.slice(2)) {
  const { inputs, overrides, theta } = parseArguments(argv);
  const report = runQuietSweep(inputs, { overrides, theta });
  const outputDir = '/tmp/opencode';
  fs.mkdirSync(outputDir, { recursive: true });
  const stamp = new Date().toISOString().replaceAll(':', '').replaceAll('.', '');
  const jsonPath = path.join(outputDir, `vad-quiet-sweep-${stamp}.json`);
  const mdPath = path.join(outputDir, `vad-quiet-sweep-${stamp}.md`);
  fs.writeFileSync(jsonPath, `${JSON.stringify(report, null, 2)}\n`);
  fs.writeFileSync(mdPath, `${markdown(report)}\n`);
  console.log(`${jsonPath}\n${mdPath}`);
  if (!report.fidelity.pass || !report.acceptanceGates.pass) process.exitCode = 1;
}

if (process.argv[1] && path.resolve(process.argv[1]) === path.resolve(fileURLToPath(import.meta.url))) {
  try {
    main();
  } catch (error) {
    console.error(error instanceof Error ? error.message : error);
    process.exitCode = 1;
  }
}
