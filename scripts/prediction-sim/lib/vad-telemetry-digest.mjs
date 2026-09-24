import fs from 'node:fs';
import path from 'node:path';
import { parseSession } from '../bin/replay-vad.mjs';

export const DEFAULT_BUDGET = 96 * 1024;
const TIMELINE_INTERVAL_SECONDS = 0.25;
const MAX_CHUNK_ROWS = 12;
const JOB_ID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

const PARAMETER_NAMES = Object.freeze({
  endpointOnsetMs: 'onset',
  endpointEndEvidenceMs: 'endEvidence',
  endpointSilenceMs: 'endpointSilence',
  endpointResumeMs: 'resume',
  endpointAmbiguousRescueMs: 'rescue',
  endpointPreRollMs: 'preRoll',
  strongDeltaDb: 'strongDelta',
  continuationDeltaDb: 'continuationDelta',
  silenceDeltaDb: 'silenceDelta',
  dynamicsSpreadDb: 'dynamicsSpread',
  flatSpreadDb: 'flatSpread',
  riseMultiplier: 'adaptationSpeed',
});
const PARAMETER_ORDER = [
  'endpointOnsetMs',
  'endpointEndEvidenceMs',
  'endpointSilenceMs',
  'endpointResumeMs',
  'endpointAmbiguousRescueMs',
  'endpointPreRollMs',
  'minSpeechMs',
  'minChunkMs',
];

export function summarizeRecording({ filename, records, session = null, modifiedAt = null }) {
  const fallbackJobId = jobIdFromFilename(filename);
  if (!fallbackJobId) return null;

  const meta = records.find(record => record.t === 'meta') ?? null;
  const metaJobId = typeof meta?.jobId === 'string' && JOB_ID_PATTERN.test(meta.jobId)
    ? meta.jobId
    : null;
  const jobId = metaJobId ?? fallbackJobId;
  const parsedStartDate = parseDate(meta?.startedAt);
  const frames = session?.frames ?? records.filter(record => record.t === 'f');
  const events = session?.events ?? records.filter(record => record.t === 'ev');

  let durationSeconds = 0;
  let foundFrameDuration = false;
  let missingFrameDuration = false;
  let timelineTime = 0;
  let nextTimelineTime = 0;
  let speechFrames = 0;
  const floors = [];
  const timeline = [];
  const decisionTallies = { emit: 0, resume: 0, rescue: 0 };

  for (const frame of frames) {
    const frameDuration = finiteNumber(frame.dt);
    if (frameDuration !== null && frameDuration >= 0) {
      durationSeconds += frameDuration;
      foundFrameDuration = true;
    } else {
      missingFrameDuration = true;
    }
    const floorDb = finiteNumber(frame.fl);
    if (floorDb !== null) floors.push(floorDb);
    const isSpeech = frame.sp === true;
    if (isSpeech) speechFrames += 1;

    if (typeof frame.d === 'string' && frame.d.startsWith('finalize_')) {
      decisionTallies.emit += 1;
    }
    if (frame.ps === 'endPending' && frame.es === 'speechActive') {
      if (frame.e === 'strong' || frame.e === 'continuing') decisionTallies.resume += 1;
      else if (frame.e === 'ambiguous') decisionTallies.rescue += 1;
    }

    const frameDb = finiteNumber(frame.db);
    if (timelineTime + 1e-9 >= nextTimelineTime && frameDb !== null) {
      timeline.push({
        time: timelineTime,
        frameDb,
        floorDb,
        isSpeech,
      });
      while (nextTimelineTime <= timelineTime + 1e-9) {
        nextTimelineTime += TIMELINE_INTERVAL_SECONDS;
      }
    }
    timelineTime += frameDuration !== null && frameDuration >= 0 ? frameDuration : 0;
  }

  if (!foundFrameDuration || missingFrameDuration || durationSeconds === 0) {
    const sequence = frames.findLast(frame => finiteNumber(frame.q) !== null);
    const frameDuration = frames.findLast(frame => finiteNumber(frame.dt) !== null);
    const lastSequence = finiteNumber(sequence?.q);
    const lastFrameDuration = finiteNumber(frameDuration?.dt);
    if (lastSequence !== null && lastFrameDuration !== null
      && lastSequence >= 0 && lastFrameDuration >= 0) {
      durationSeconds = lastSequence * lastFrameDuration;
    }
  }

  const startEvent = events.find(event => event.k === 'session_start');
  const parameters = startEvent && startEvent.c && typeof startEvent.c === 'object'
    && !Array.isArray(startEvent.c)
    ? startEvent.c
    : null;
  const outcomeEvent = events.findLast(event => event.k === 'outcome');
  const outcome = typeof outcomeEvent?.r === 'string' ? outcomeEvent.r : 'unknown';
  const emittedEvents = events.filter(event => event.k === 'emit');
  const emittedSpeechSeconds = emittedEvents.reduce(
    (total, event) => total + (finiteNumber(event.sm) ?? 0) / 1000,
    0,
  );
  const emittedChunkSeconds = emittedEvents.reduce(
    (total, event) => total + (finiteNumber(event.tm) ?? 0) / 1000,
    0,
  );
  const receivedById = new Map();
  for (const event of events) {
    if (event.k === 'chunk_received' && Number.isSafeInteger(event.id)) {
      receivedById.set(event.id, event);
    }
  }
  const chunkRecords = emittedEvents.map(event => {
    const received = Number.isSafeInteger(event.id) ? receivedById.get(event.id) ?? null : null;
    return {
      id: Number.isSafeInteger(event.id) ? event.id : null,
      reason: typeof event.r === 'string' ? event.r : null,
      startMs: finiteNumber(event.s0),
      endMs: finiteNumber(event.s1),
      durationMs: finiteNumber(event.tm),
      speechMs: finiteNumber(event.sm),
      endpointState: typeof event.es === 'string' ? event.es : null,
      hasReceivedResponse: received !== null,
      recvLatencyMs: finiteNumber(received?.lat),
      recvChars: finiteNumber(received?.ch),
    };
  }).sort((left, right) => (left.id ?? Number.MAX_SAFE_INTEGER) - (right.id ?? Number.MAX_SAFE_INTEGER));
  const chunkDurations = chunkRecords.map(chunk => chunk.durationMs).filter(value => value !== null);
  const receiveLatencies = chunkRecords.map(chunk => chunk.recvLatencyMs).filter(value => value !== null);
  const receivedChunkCount = emittedEvents.reduce((count, event) => (
    Number.isSafeInteger(event.id) && receivedById.has(event.id) ? count + 1 : count
  ), 0);
  const mean = values => values.length === 0
    ? null
    : values.reduce((total, value) => total + value, 0) / values.length;
  const floorsSorted = [...floors].sort((left, right) => left - right);

  return {
    jobId,
    startedAt: parsedStartDate ? formatUtc(parsedStartDate) : 'unknown',
    durationSeconds,
    outcome,
    parameters,
    frameCount: frames.length,
    speechPercent: frames.length === 0
      ? null
      : Math.round((speechFrames / frames.length) * 100),
    decisionTallies,
    chunkCount: emittedEvents.length,
    emittedSpeechSeconds,
    emittedChunkSeconds,
    chunkRecords,
    chunksPerMinute: durationSeconds > 0 ? emittedEvents.length / (durationSeconds / 60) : null,
    meanChunkMs: mean(chunkDurations),
    meanRecvLatencyMs: mean(receiveLatencies),
    receivedChunkCount,
    floorFirst: floors[0] ?? null,
    floorMinimum: floorsSorted[0] ?? null,
    floorMaximum: floorsSorted.at(-1) ?? null,
    floorLast: floors.at(-1) ?? null,
    timeline,
    orderingDate: parsedStartDate ?? parseDate(modifiedAt),
  };
}

export function buildText({
  files = [],
  globalSettings = [],
  budget = DEFAULT_BUDGET,
  exportedAt = new Date(),
} = {}) {
  const summaries = files.flatMap((filename, sourceOrder) => {
    const filePath = typeof filename === 'string' ? filename : filename.pathname;
    const basename = path.basename(filePath);
    if (!jobIdFromFilename(basename)) return [];

    let text;
    let modifiedAt = null;
    try {
      text = fs.readFileSync(filePath, 'utf8');
      modifiedAt = fs.statSync(filePath).mtime;
    } catch {
      return [];
    }

    const { records, session } = parseTelemetryText(text);
    const summary = summarizeRecording({ filename: basename, records, session, modifiedAt });
    return summary ? [{ summary, sourceOrder }] : [];
  }).sort((left, right) => {
    const leftDate = left.summary.orderingDate;
    const rightDate = right.summary.orderingDate;
    if (leftDate && rightDate && leftDate.getTime() !== rightDate.getTime()) {
      return rightDate - leftDate;
    }
    if (leftDate && !rightDate) return -1;
    if (!leftDate && rightDate) return 1;
    return left.sourceOrder - right.sourceOrder;
  }).map(({ summary }) => summary);

  return renderText({
    summaries,
    globalSettings,
    budget: Math.max(0, budget),
    exportedAt: parseDate(exportedAt) ?? new Date(),
  });
}

function parseTelemetryText(text) {
  const records = [];
  const validLines = [];
  for (const line of text.split(/\r?\n/)) {
    if (!line.trim()) continue;
    try {
      const record = JSON.parse(line);
      if (!record || typeof record !== 'object' || Array.isArray(record)) continue;
      records.push(record);
      validLines.push(line);
    } catch {
      continue;
    }
  }
  return { records, session: parseSession(validLines.join('\n')) };
}

function renderText({ summaries, globalSettings, budget, exportedAt }) {
  let timelineStride = 1;
  let chunkStride = 1;
  while (summaries.some(summary => Math.ceil(summary.chunkRecords.length / chunkStride) > MAX_CHUNK_ROWS)) {
    chunkStride *= 2;
  }
  const removedTimelines = new Set();
  let text = render({
    summaries,
    globalSettings,
    budget,
    exportedAt,
    timelineStride,
    chunkStride,
    removedTimelines,
  });

  while (Buffer.byteLength(text, 'utf8') > budget
    && summaries.some(summary => (summary.timeline.length > 1
      && Math.floor(summary.timeline.length / (timelineStride * 2)) > 0)
      || (summary.chunkRecords.length > 1
      && Math.floor(summary.chunkRecords.length / (chunkStride * 2)) > 0))) {
    timelineStride *= 2;
    chunkStride *= 2;
    text = render({
      summaries,
      globalSettings,
      budget,
      exportedAt,
      timelineStride,
      chunkStride,
      removedTimelines,
    });
  }

  if (Buffer.byteLength(text, 'utf8') > budget) {
    for (let index = summaries.length - 1; index >= 0; index -= 1) {
      if (summaries[index].timeline.length === 0) continue;
      removedTimelines.add(index);
      text = render({
        summaries,
        globalSettings,
        budget,
        exportedAt,
        timelineStride,
        chunkStride,
        removedTimelines,
      });
      if (Buffer.byteLength(text, 'utf8') <= budget) break;
    }
  }
  return text;
}

function render({ summaries, globalSettings, budget, exportedAt, timelineStride, chunkStride, removedTimelines }) {
  const telemetryValue = globalSettings.find(([key]) => key === 'telemetryEnabled')?.[1] ?? 'ON';
  const budgetKilobytes = Math.ceil(budget / 1024);
  const lines = [
    `Ritoras VAD digest v1 — exported ${formatUtc(exportedAt)}`,
    `recordings: ${summaries.length} retained (telemetry toggle currently ${telemetryValue}) | budget: ${budgetKilobytes} KB`,
    '',
    '== Current global VAD settings ==',
    globalSettings.map(([key, value]) => `${key}=${value}`).join(' '),
    '',
  ];

  summaries.forEach((summary, index) => {
    const newestLabel = index === 0 ? ' (newest)' : '';
    lines.push(`== Recording ${index + 1}/${summaries.length}${newestLabel} ==`);
    lines.push(`job=${summary.jobId} started=${summary.startedAt} dur=${fixed(summary.durationSeconds, 1)}s outcome=${summary.outcome}`);
    lines.push(`chunks=${summary.chunkCount} emitted speech=${fixed(summary.emittedSpeechSeconds, 1)}s/${fixed(summary.emittedChunkSeconds, 1)}s`);
    lines.push(formatChunks(summary, chunkStride));
    lines.push(formatParameters(summary.parameters));
    lines.push(`floorDb first/min/max/last=${optionalFixed(summary.floorFirst)}/${optionalFixed(summary.floorMinimum)}/${optionalFixed(summary.floorMaximum)}/${optionalFixed(summary.floorLast)}`);
    const speechPercent = summary.speechPercent === null ? 'n/a' : String(summary.speechPercent);
    const decisions = ['emit', 'resume', 'rescue']
      .map(key => `${key}=${summary.decisionTallies[key] ?? 0}`)
      .join(',');
    lines.push(`frames n=${summary.frameCount} speech%=${speechPercent} decisions{${decisions}}`);
    lines.push(formatTimeline(
      summary.timeline,
      timelineStride,
      removedTimelines.has(index),
    ));
    lines.push('');
  });

  return lines.join('\n').replace(/^\n+|\n+$/g, '');
}

function formatParameters(parameters) {
  if (parameters === null) return 'params=unknown';
  const hasStaleFloorBreakdown = finiteNumber(parameters.staleFloorSeconds) !== null
    && finiteNumber(parameters.staleFloorSecondsRaw) !== null
    && finiteNumber(parameters.riseSpeedMultiplier) !== null;
  const values = Object.keys(parameters).sort(parameterKeyComesFirst).map(key => {
    if (hasStaleFloorBreakdown && (key === 'staleFloorSecondsRaw' || key === 'riseSpeedMultiplier')) {
      return null;
    }
    const name = PARAMETER_NAMES[key] ?? key;
    if (key === 'staleFloorSeconds' && hasStaleFloorBreakdown) {
      return `staleFloor=eff=${fixed(parameters.staleFloorSeconds, 2)}s (raw=${fixed(parameters.staleFloorSecondsRaw, 1)}s ÷ ×${fixed(parameters.riseSpeedMultiplier, 1)})`;
    }
    return `${name}=${parameterValue(parameters[key], key)}`;
  }).filter(value => value !== null);
  return `params(${values.join(' ')})`;
}

function parameterKeyComesFirst(left, right) {
  if (left === 'mode') return 1;
  if (right === 'mode') return -1;
  const leftOrder = PARAMETER_ORDER.indexOf(left);
  const rightOrder = PARAMETER_ORDER.indexOf(right);
  const normalizedLeftOrder = leftOrder < 0 ? Number.MAX_SAFE_INTEGER : leftOrder;
  const normalizedRightOrder = rightOrder < 0 ? Number.MAX_SAFE_INTEGER : rightOrder;
  if (normalizedLeftOrder !== normalizedRightOrder) return normalizedLeftOrder - normalizedRightOrder;
  return left < right ? -1 : left > right ? 1 : 0;
}

function parameterValue(value, key) {
  if (typeof value === 'string') return value;
  if (typeof value === 'boolean') return value ? 'true' : 'false';
  if (typeof value === 'number' && Number.isFinite(value)) {
    if (key.endsWith('Ms')) return `${compact(value)}ms`;
    if (key.endsWith('Db') || key.endsWith('SpreadDb')) return `${fixed(value, 1)}dB`;
    if (key.endsWith('Seconds') || key.endsWith('Sec')) return `${fixed(value, 1)}s`;
    if (key.endsWith('Hz')) return `${compact(value)}Hz`;
    return compact(value);
  }
  return String(value);
}

function formatTimeline(points, stride, truncated) {
  const selected = points.filter((_, index) => index % stride === 0);
  const didTruncate = truncated || selected.length < points.length;
  const values = selected.map(point => {
    const floor = point.floorDb === null ? 'n/a' : fixed(point.floorDb, 1);
    const speech = point.isSpeech ? 'S' : '-';
    return `${timelineTime(point.time)}:${fixed(point.frameDb, 1)}:${floor}:${speech}`;
  });
  if (didTruncate) values.push('…truncated');
  return `timeline(250ms decimated): ${values.length === 0 ? 'n/a' : values.join(' ')}`;
}

function formatChunks(summary, stride) {
  const meanDuration = summary.meanChunkMs === null ? 'n/a' : `${fixed(summary.meanChunkMs / 1000, 2)}s`;
  const rate = summary.chunksPerMinute === null ? 'n/a/min' : `${fixed(summary.chunksPerMinute, 1)}/min`;
  const meanReceive = summary.meanRecvLatencyMs === null ? 'n/a' : fixed(summary.meanRecvLatencyMs / 1000, 1);
  const selected = summary.chunkRecords.filter((_, index) => index % stride === 0);
  const lines = [`chunk table mean ${meanDuration}; ${rate}; recv ${meanReceive}/${summary.receivedChunkCount}`];
  for (const chunk of selected) {
    const id = chunk.id === null ? 'n/a' : String(chunk.id);
    const start = chunk.startMs === null ? 'n/a' : fixed(chunk.startMs / 1000, 2);
    const end = chunk.endMs === null ? 'n/a' : fixed(chunk.endMs / 1000, 2);
    const duration = chunk.durationMs === null ? 'n/a' : `${fixed(chunk.durationMs / 1000, 2)}s`;
    const speech = chunk.speechMs === null ? 'n/a' : `${fixed(chunk.speechMs / 1000, 2)}s`;
    const endpoint = chunk.endpointState ?? 'n/a';
    const receive = chunk.hasReceivedResponse
      ? `recv=${chunk.recvLatencyMs === null ? 'n/a' : `${compact(chunk.recvLatencyMs)}ms`} ${chunk.recvChars === null ? 'n/a' : `${compact(chunk.recvChars)}ch`}`
      : 'recv=—';
    lines.push(` #${id} ${start}->${end}s dur=${duration} sp=${speech} endpoint=${endpoint} reason=${chunk.reason ?? 'n/a'} ${receive}`);
  }
  if (selected.length < summary.chunkRecords.length) lines.push('…truncated');
  return lines.join('\n');
}

function jobIdFromFilename(filename) {
  if (!filename.endsWith('-vad.jsonl')) return null;
  const jobId = filename.slice(0, -'-vad.jsonl'.length);
  return JOB_ID_PATTERN.test(jobId) ? jobId : null;
}

function finiteNumber(value) {
  return typeof value === 'number' && Number.isFinite(value) ? value : null;
}

function parseDate(value) {
  if (value instanceof Date) return Number.isFinite(value.getTime()) ? value : null;
  if (typeof value !== 'string') return null;
  const date = new Date(value);
  return Number.isFinite(date.getTime()) ? date : null;
}

function formatUtc(date) {
  return date.toISOString().replace(/\.\d{3}Z$/, 'Z');
}

function fixed(value, digits) {
  return Number(value).toFixed(digits);
}

function optionalFixed(value) {
  return value === null ? 'n/a' : fixed(value, 1);
}

function compact(value) {
  return Number.isInteger(value) ? String(value) : fixed(value, 1);
}

function timelineTime(value) {
  let compacted = fixed(value, 2).replace(/0+$/, '');
  if (compacted.endsWith('.')) compacted += '0';
  return compacted;
}
