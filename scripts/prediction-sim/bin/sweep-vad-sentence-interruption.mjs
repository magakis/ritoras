#!/usr/bin/env node

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { adaptClientTelemetry, recordedEmissionMap } from '../lib/client-telemetry.mjs';
import { ChunkResultKind, ChunkResultStore } from '../lib/chunk-result-store.mjs';
import { mergeChunkFinal } from '../lib/chunk-final-merge.mjs';
import { makeRecorderHarness } from '../lib/recorder-sim.mjs';
import { makeStreamingEndpointConfig } from '../lib/streaming-endpoint.mjs';
import { normalizeConfig, replaySession } from './replay-vad.mjs';

const DEFAULT_CORPUS_PATH = '/home/michael/vad-corpus';
const DEFAULT_REPORT_PATH = path.join(DEFAULT_CORPUS_PATH, 'BEFORE-AFTER-2026-10-23.md');
const HEALTHY_FINALIZE_TOLERANCE_MS = 100;
const FINALIZE_TIME_MATCH_EPSILON_SECONDS = 1e-6;
const MERGER_MAX_GAP_MS = 2500;
const USER_ENDPOINT_SILENCE_MS = 1300;
const LEGACY_RESUME_MS = 120;
const LEGACY_RESCUE_MS = 320;
const RESUME_COARSE_VALUES = steppedValues(0.02, 0.50, 0.02);
const RESCUE_COARSE_VALUES = steppedValues(0.05, 1.00, 0.025);
const CONTINUATION_WORDS = new Set([
  'for', 'and', 'but', 'or', 'nor', 'so', 'yet', 'which', 'that', 'because',
  'with', 'also', 'to', 'from', 'when', 'while', 'since', 'although', 'however', 'plus',
]);
const WORD_PATTERN = /[\p{L}\p{N}]+(?:['’][\p{L}\p{N}]+)*/gu;

function steppedValues(start, end, step) {
  const values = [];
  for (let value = start; value <= end + Number.EPSILON; value += step) {
    values.push(Number(value.toFixed(3)));
  }
  return values;
}

function parseArgs(argv) {
  const options = { corpusPath: DEFAULT_CORPUS_PATH, reportPath: null };
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    if (argument === '--corpus' || argument === '--report') {
      const value = argv[++index];
      if (!value || value.startsWith('--')) throw new Error(`${argument} requires a path`);
      if (argument === '--corpus') options.corpusPath = path.resolve(value);
      else options.reportPath = path.resolve(value);
    } else if (argument === '--help' || argument === '-h') {
      options.help = true;
    } else {
      throw new Error(`unknown option: ${argument}`);
    }
  }
  options.reportPath ??= path.join(options.corpusPath, path.basename(DEFAULT_REPORT_PATH));
  return options;
}

function telemetryConfig(session) {
  const config = { ...session.config };
  if (Number.isFinite(config.staleFloorSeconds) && Number.isFinite(config.riseMultiplier)) {
    config.staleFloorSeconds *= config.riseMultiplier;
  }
  return config;
}

function readJsonLines(filePath) {
  return fs.readFileSync(filePath, 'utf8')
    .split('\n')
    .filter(line => line.trim().length > 0)
    .map((line, index) => {
      try {
        return JSON.parse(line);
      } catch (error) {
        throw new Error(`${filePath}: invalid JSON on line ${index + 1}: ${error.message}`);
      }
    });
}

function recordedFinalizeDecisions(payload) {
  let time = 0;
  const decisions = [];
  for (const [index, frame] of (payload.frames ?? []).entries()) {
    const duration = Number(frame.dt);
    if (!Number.isFinite(duration) || duration <= 0) continue;
    time += duration;
    if (typeof frame.d === 'string' && frame.d.startsWith('finalize_')) {
      decisions.push({ time, frame: frame.q ?? index, decision: frame.d });
    }
  }
  return decisions;
}

function recordedEmissionDetails(payload) {
  const emissions = recordedEmissionMap({ events: payload.events });
  const emitEvents = payload.events.filter(event => event.k === 'emit');
  const finalizeDecisions = recordedFinalizeDecisions(payload);
  let lastMatchedDecisionTime = -Infinity;
  return emissions.map((emission, index) => {
    const reason = emitEvents[index]?.r ?? null;
    const expectedDecision = reason ? `finalize_${reason}` : null;
    const decision = expectedDecision
      ? finalizeDecisions.find(candidate => candidate.decision === expectedDecision
        && candidate.time > lastMatchedDecisionTime
        && candidate.time + FINALIZE_TIME_MATCH_EPSILON_SECONDS >= (emission.start ?? 0)
        && candidate.time + FINALIZE_TIME_MATCH_EPSILON_SECONDS >= (emission.end ?? 0))
      : null;
    if (decision) lastMatchedDecisionTime = decision.time;
    return {
      ...emission,
      reason,
      finalizeTime: decision?.time ?? null,
      finalizeFrame: decision?.frame ?? null,
    };
  });
}

function summarizeReplayEvents(events) {
  return events
    .filter(event => event.k === 'emit' || event.k === 'start_utterance')
    .map(event => ({
      kind: event.k,
      id: event.id ?? null,
      reason: event.r ?? null,
      start: Number.isFinite(event.s0) ? event.s0 : null,
      end: Number.isFinite(event.s1) ? event.s1 : null,
      time: event.time,
    }));
}

function assertReplayWrapperMatches(session, normalized, replay) {
  const wrapped = runRecorderReplay(session, normalized, null, false);
  const expected = JSON.stringify(summarizeReplayEvents(replay.events));
  const actual = JSON.stringify(summarizeReplayEvents(wrapped.events));
  if (expected !== actual) {
    throw new Error(`${session.id}: ratio replay wrapper differs from replaySession before applying ratios`);
  }
}

function runRecorderReplay(session, normalized, ratios, captureFrames = false) {
  const endpointConfig = { ...normalized.endpoint.configuration };
  if (ratios) {
    delete endpointConfig.resumeMs;
    delete endpointConfig.ambiguousRescueMs;
    endpointConfig.resumeToEndpointSilenceRatio = ratios.resume;
    endpointConfig.ambiguousRescueToEndpointSilenceRatio = ratios.rescue;
  }

  const events = [];
  const frames = [];
  let time = 0;
  let eventTime = 0;
  const harness = makeRecorderHarness({
    gateConfig: normalized.gateConfig,
    endpointConfig,
    endpointSilenceMs: normalized.config.endpointSilenceMs,
    endpointMachineEnabled: normalized.config.endpointMachineEnabled,
    minSpeechSamples: normalized.minSpeechSamples,
    minChunkSamples: normalized.minChunkSamples,
    maxNoiseSamples: normalized.maxNoiseSamples,
    recorderConfig: normalized.recorderConfig,
    onFrame: captureFrames
      ? record => frames.push({
        time: eventTime,
        evidence: record.e,
        endpointState: record.es,
        decision: record.d,
      })
      : undefined,
    onEvent: event => events.push({ ...event, time: event.time ?? eventTime }),
  });

  for (const source of session.frames) {
    const duration = Number(source.dt);
    eventTime = time + duration;
    harness.drive(Number(source.db), duration);
    time = eventTime;
  }
  if (session.events.some(event => event.k === 'stop_flush')) {
    eventTime = time;
    harness.flush();
  }
  eventTime = time;
  harness.end();

  return {
    events,
    frames,
    endpointConfiguration: harness.endpoint.configuration,
  };
}

function loadCorpus(corpusPath) {
  const inventoryPath = path.join(corpusPath, 'INVENTORY.json');
  const inventory = JSON.parse(fs.readFileSync(inventoryPath, 'utf8'));
  if (!Array.isArray(inventory.sessions)) throw new Error('INVENTORY.json has no sessions array');

  const sessions = inventory.sessions
    .map(entry => {
      if (entry.status !== 'fidelity-ok') return { entry, excluded: true };
      const directory = path.join(corpusPath, entry.path);
      const telemetryPath = path.join(directory, 'client_telemetry.json');
      const payload = JSON.parse(fs.readFileSync(telemetryPath, 'utf8'));
      const session = adaptClientTelemetry(payload, entry.id);
      const normalized = normalizeConfig(telemetryConfig(session));
      const ambiguousResetReplay = replaySession(session, session.config, { compare: false });
      assertReplayWrapperMatches(session, normalized, ambiguousResetReplay);
      return {
        entry,
        directory,
        payload,
        session,
        normalized,
        recorded: recordedEmissionDetails(payload),
        ambiguousResetReplay,
      };
    })
    .sort((left, right) => left.entry.id.localeCompare(right.entry.id));
  return { inventory, sessions };
}

function emissionEvents(replay) {
  return replay.events.filter(event => event.k === 'emit');
}

function resumesBeforeFinalize(split, recorded, replay) {
  const prior = recorded.find(event => event.id === split.emissionId);
  const priorStartMs = Number.isFinite(prior?.start) ? prior.start * 1000 : 0;
  const resumedAtMs = split.resumedAt * 1000;
  return emissionEvents(replay).some(event => (
    Number.isFinite(event.s0)
    && Number.isFinite(event.s1)
    && event.s0 <= priorStartMs + 150
    && event.s1 >= resumedAtMs
  ));
}

function controlTiming(recorded, candidate) {
  const recordedEndpoints = recorded.filter(event => event.reason === 'endpoint');
  const candidateEndpoints = candidate.filter(event => event.r === 'endpoint');
  if (recordedEndpoints.length !== candidateEndpoints.length) {
    return {
      maxAbsDeltaMs: null,
      worstDeltaMs: null,
      endpointCountDelta: candidateEndpoints.length - recordedEndpoints.length,
    };
  }
  const deltas = recordedEndpoints.map((event, index) => {
    const baselineTime = event.finalizeTime;
    const candidateTime = candidateEndpoints[index].time;
    return Number.isFinite(baselineTime) && Number.isFinite(candidateTime)
      ? (candidateTime - baselineTime) * 1000
      : null;
  });
  if (deltas.some(delta => delta === null)) {
    return { maxAbsDeltaMs: null, endpointCountDelta: 0 };
  }
  const worstDeltaMs = deltas.length > 0
    ? deltas.reduce((worst, delta) => Math.abs(delta) > Math.abs(worst) ? delta : worst, deltas[0])
    : 0;
  return {
    maxAbsDeltaMs: deltas.length > 0 ? Math.max(...deltas.map(Math.abs)) : 0,
    worstDeltaMs,
    endpointCountDelta: 0,
  };
}

function isHealthyControl(session) {
  return (session.entry.splitSignatures ?? []).length === 0;
}

function evaluateCandidate(sessions, ratios) {
  let resumedCount = 0;
  let controlPass = true;
  let maximumHealthyDeltaMs = 0;
  let addedHealthyEmissions = 0;
  let changedHealthyEmissionCounts = 0;

  for (const session of sessions) {
    const replay = runRecorderReplay(session.session, session.normalized, ratios);
    const emitted = emissionEvents(replay);
    for (const split of session.entry.splitSignatures ?? []) {
      if (resumesBeforeFinalize(split, session.recorded, replay)) resumedCount += 1;
    }

    if (!isHealthyControl(session)) continue;
    const timing = controlTiming(session.recorded, emitted);
    const added = Math.max(0, emitted.length - session.recorded.length);
    addedHealthyEmissions += added;
    if (emitted.length !== session.recorded.length) changedHealthyEmissionCounts += 1;
    if (timing.maxAbsDeltaMs === null) {
      controlPass = false;
    } else {
      maximumHealthyDeltaMs = Math.max(maximumHealthyDeltaMs, timing.maxAbsDeltaMs);
      if (timing.maxAbsDeltaMs > HEALTHY_FINALIZE_TOLERANCE_MS) controlPass = false;
    }
    if (timing.endpointCountDelta !== 0 || added > 0 || emitted.length !== session.recorded.length) {
      controlPass = false;
    }
  }

  return {
    resumeRatio: ratios.resume,
    rescueRatio: ratios.rescue,
    resumedCount,
    controlPass,
    maximumHealthyDeltaMs,
    addedHealthyEmissions,
    changedHealthyEmissionCounts,
  };
}

function candidateKey(resume, rescue) {
  return `${resume.toFixed(3)}:${rescue.toFixed(3)}`;
}

function addRefinementGrid(candidates, center) {
  const resumeValues = steppedValues(
    Math.max(0.005, center.resumeRatio - 0.02),
    center.resumeRatio + 0.02,
    0.005,
  );
  const rescueValues = steppedValues(
    Math.max(0.005, center.rescueRatio - 0.025),
    center.rescueRatio + 0.025,
    0.005,
  );
  for (const resume of resumeValues) {
    for (const rescue of rescueValues) {
      candidates.add(candidateKey(resume, rescue));
    }
  }
}

function widensLegacyWindowsAtUserSetting(candidate) {
  return candidate.resumeRatio * USER_ENDPOINT_SILENCE_MS > LEGACY_RESUME_MS
    && candidate.rescueRatio * USER_ENDPOINT_SILENCE_MS > LEGACY_RESCUE_MS;
}

function sweepCandidates(sessions) {
  const keys = new Set();
  for (const resume of RESUME_COARSE_VALUES) {
    for (const rescue of RESCUE_COARSE_VALUES) keys.add(candidateKey(resume, rescue));
  }

  const results = new Map();
  const evaluate = key => {
    if (results.has(key)) return results.get(key);
    const [resume, rescue] = key.split(':').map(Number);
    const result = evaluateCandidate(sessions, { resume, rescue });
    results.set(key, result);
    return result;
  };

  for (const key of keys) evaluate(key);
  const safeCoarse = [...results.values()].filter(candidate => candidate.controlPass);
  if (safeCoarse.length > 0) {
    const safeWidenedCoarse = safeCoarse.filter(widensLegacyWindowsAtUserSetting);
    const refinementFrontier = safeWidenedCoarse.length > 0 ? safeWidenedCoarse : safeCoarse;
    refinementFrontier.sort(compareCandidatePreference);
    addRefinementGrid(keys, refinementFrontier[0]);
    for (const key of keys) evaluate(key);
  }
  return [...results.values()].sort(compareCandidatePreference);
}

function compareCandidatePreference(left, right) {
  if (left.controlPass !== right.controlPass) return left.controlPass ? -1 : 1;
  if (left.resumedCount !== right.resumedCount) return right.resumedCount - left.resumedCount;
  const leftMagnitude = left.resumeRatio + left.rescueRatio;
  const rightMagnitude = right.resumeRatio + right.rescueRatio;
  if (leftMagnitude !== rightMagnitude) return leftMagnitude - rightMagnitude;
  if (left.resumeRatio !== right.resumeRatio) return left.resumeRatio - right.resumeRatio;
  return left.rescueRatio - right.rescueRatio;
}

function tokenize(text) {
  return [...text.matchAll(WORD_PATTERN)].map(match => ({
    text: match[0],
    normalized: match[0].toLocaleLowerCase('en-US'),
    start: match.index,
    end: match.index + match[0].length,
  }));
}

function alignChunkTranscriptsToFinal(rows, finalText) {
  const source = rows.flatMap((row, rowIndex) => tokenize(row.text ?? '')
    .map(token => ({ ...token, rowIndex })));
  const target = tokenize(finalText);
  const width = target.length + 1;
  const table = new Uint16Array((source.length + 1) * width);

  for (let sourceIndex = source.length - 1; sourceIndex >= 0; sourceIndex -= 1) {
    for (let targetIndex = target.length - 1; targetIndex >= 0; targetIndex -= 1) {
      const offset = sourceIndex * width + targetIndex;
      table[offset] = source[sourceIndex].normalized === target[targetIndex].normalized
        ? table[(sourceIndex + 1) * width + targetIndex + 1] + 1
        : Math.max(
          table[(sourceIndex + 1) * width + targetIndex],
          table[sourceIndex * width + targetIndex + 1],
        );
    }
  }

  const matchesByRow = rows.map(() => []);
  let sourceIndex = 0;
  let targetIndex = 0;
  while (sourceIndex < source.length && targetIndex < target.length) {
    if (source[sourceIndex].normalized === target[targetIndex].normalized) {
      matchesByRow[source[sourceIndex].rowIndex].push(targetIndex);
      sourceIndex += 1;
      targetIndex += 1;
    } else if (table[(sourceIndex + 1) * width + targetIndex]
      >= table[sourceIndex * width + targetIndex + 1]) {
      sourceIndex += 1;
    } else {
      targetIndex += 1;
    }
  }

  const alignedRows = rows.flatMap((row, rowIndex) => (
    matchesByRow[rowIndex].length > 0
      ? [{ rowIndex, firstTargetIndex: matchesByRow[rowIndex][0], matchCount: matchesByRow[rowIndex].length }]
      : []
  ));
  const spans = new Map();
  for (let index = 0; index < alignedRows.length; index += 1) {
    const aligned = alignedRows[index];
    const start = index === 0 ? 0 : target[aligned.firstTargetIndex].start;
    const next = alignedRows[index + 1];
    const end = next ? target[next.firstTargetIndex].start : finalText.length;
    const sourceTokenCount = tokenize(rows[aligned.rowIndex].text ?? '').length;
    spans.set(aligned.rowIndex, {
      text: finalText.slice(start, end).trim(),
      coverage: sourceTokenCount > 0 ? aligned.matchCount / sourceTokenCount : 0,
    });
  }

  return rows.map((row, rowIndex) => ({
    rowIndex,
    chunkId: row.chunk_id,
    partialText: (row.text ?? '').trim(),
    finalText: spans.get(rowIndex)?.text ?? '',
    alignmentCoverage: spans.get(rowIndex)?.coverage ?? 0,
  }));
}

function continuationWord(text) {
  const firstWord = text.match(/[\p{L}]+/u)?.[0] ?? '';
  if (!firstWord) return false;
  return (firstWord[0] === firstWord[0].toLowerCase()
      && firstWord[0] !== firstWord[0].toUpperCase())
    || CONTINUATION_WORDS.has(firstWord.toLowerCase());
}

function mergerEdit(finalText, left, right) {
  if (!left.chunkLocalText || !right.chunkLocalText) return null;
  const leftStart = finalText.indexOf(left.chunkLocalText.slice(0, 24));
  if (leftStart < 0 || !finalText.startsWith(left.chunkLocalText, leftStart)) return null;
  const leftEnd = leftStart + left.chunkLocalText.length;
  const rightStart = finalText.indexOf(right.chunkLocalText.slice(0, 24), leftEnd);
  if (rightStart < 0 || !finalText.startsWith(right.chunkLocalText, rightStart)) return null;
  const punctuation = left.chunkLocalText.match(/[.!?](?=["'”’)]*\s*$)/u);
  const firstWord = right.chunkLocalText.match(/[\p{L}]+/u);
  if (!punctuation || !firstWord || right.startMs - left.endMs > MERGER_MAX_GAP_MS) return null;
  const word = firstWord[0];
  if (!continuationWord(word)) return null;

  const punctuationAt = leftStart + punctuation.index;
  const wordAt = rightStart + firstWord.index;
  const removable = finalText.slice(punctuationAt, wordAt)
    .replace(/[.!?]["'”’)]*/gu, '')
    .trim();
  const replaceWord = CONTINUATION_WORDS.has(word.toLowerCase())
    && word[0] === word[0].toUpperCase()
    ? word[0].toLowerCase() + word.slice(1)
    : word;
  return {
    punctuationAt,
    wordAt,
    falseMerge: /[\p{L}\p{N}]/u.test(removable),
    capitalizedContinuation: replaceWord !== word,
  };
}

function isMergerEligible(left, right) {
  return Boolean(left?.chunkLocalText
    && right?.chunkLocalText
    && Number.isFinite(left.endMs)
    && Number.isFinite(right.startMs)
    && right.startMs - left.endMs <= MERGER_MAX_GAP_MS
    && left.chunkLocalText.match(/[.!?](?=["'”’)]*\s*$)/u)
    && continuationWord(right.chunkLocalText));
}

function createStoreSegments(aligned, emissions, useKindAwareStore) {
  const store = useKindAwareStore ? new ChunkResultStore() : new Map();
  for (const segment of aligned) {
    const partialText = segment.partialText;
    const finalText = segment.finalText;
    if (partialText.length > 0) {
      if (useKindAwareStore) {
        store.store(segment.chunkId, ChunkResultKind.partial, partialText);
      } else if (!store.has(segment.chunkId)) {
        store.set(segment.chunkId, { kind: ChunkResultKind.partial, text: partialText });
      }
    }
    if (finalText.length > 0) {
      if (useKindAwareStore) {
        store.store(segment.chunkId, ChunkResultKind.final, finalText);
      } else if (!store.has(segment.chunkId)) {
        store.set(segment.chunkId, { kind: ChunkResultKind.final, text: finalText });
      }
    }
  }

  return aligned.map(segment => {
    const result = store.get(segment.chunkId);
    const emission = emissions.get(segment.chunkId);
    return {
      chunkId: segment.chunkId,
      startMs: Number.isFinite(emission?.s0) ? emission.s0 : null,
      endMs: Number.isFinite(emission?.s1) ? emission.s1 : null,
      chunkLocalText: result?.text ?? '',
      alignmentCoverage: segment.alignmentCoverage,
    };
  });
}

function mergerRefusalReason(left, right, edit) {
  if (!left || !right) return 'no adjacent transcript-bearing chunks';
  if (!left.chunkLocalText) return `chunk ${left.chunkId} has no stored transcript`;
  if (!right.chunkLocalText) return `chunk ${right.chunkId} has no stored transcript`;
  if (!Number.isFinite(left.startMs) || !Number.isFinite(left.endMs)
    || !Number.isFinite(right.startMs)) return 'telemetry emission timing is unavailable';
  const gapMs = right.startMs - left.endMs;
  if (gapMs > MERGER_MAX_GAP_MS) return `audio gap ${gapMs.toFixed(0)} ms exceeds the ${MERGER_MAX_GAP_MS} ms merger limit`;
  if (!left.chunkLocalText.match(/[.!?](?=["'”’)]*\s*$)/u)) {
    return 'left transcript does not end in sentence punctuation';
  }
  if (!continuationWord(right.chunkLocalText)) {
    return 'right transcript does not begin with a lowercase or continuation word';
  }
  if (!edit) return 'stored chunk text does not anchor in the terminal transcript';
  if (edit.falseMerge) return 'joining would remove intervening transcript words';
  return 'merger did not produce a safe edit';
}

function buildMergerSimulation(session) {
  const rows = readJsonLines(path.join(session.directory, 'chunks.jsonl'))
    .sort((left, right) => left.chunk_id - right.chunk_id);
  const finalText = fs.readFileSync(path.join(session.directory, 'transcription.txt'), 'utf8').trim();
  const partialText = fs.readFileSync(path.join(session.directory, 'partial.txt'), 'utf8').trim();
  const emissions = new Map(session.payload.events
    .filter(event => event.k === 'emit')
    .map(event => [event.id, event]));
  const aligned = alignChunkTranscriptsToFinal(rows, finalText);
  const baselineSegments = createStoreSegments(aligned, emissions, false);
  const fixedSegments = createStoreSegments(aligned, emissions, true);
  const baselineOutput = mergeChunkFinal(finalText, baselineSegments);
  const fixedOutput = mergeChunkFinal(finalText, fixedSegments);
  const nonempty = fixedSegments.filter(segment => segment.chunkLocalText.length > 0);
  const seams = [];

  for (let index = 0; index < nonempty.length - 1; index += 1) {
    const left = nonempty[index];
    const right = nonempty[index + 1];
    const baselineLeft = baselineSegments.find(segment => segment.chunkId === left.chunkId);
    const baselineRight = baselineSegments.find(segment => segment.chunkId === right.chunkId);
    const baselinePairOutput = mergeChunkFinal(finalText, [baselineLeft, baselineRight]);
    const fixedPairOutput = mergeChunkFinal(finalText, [left, right]);
    const edit = mergerEdit(finalText, left, right);
    const fixedJoined = fixedPairOutput !== finalText && Boolean(edit) && !edit.falseMerge;
    const eligible = isMergerEligible(left, right);
    const leftText = left.chunkLocalText;
    const rightText = right.chunkLocalText;
    const firstWord = rightText.match(/[\p{L}]+/u)?.[0] ?? '';
    seams.push({
      sessionId: session.entry.id,
      leftChunkId: left.chunkId,
      rightChunkId: right.chunkId,
      gapMs: left.endMs !== null && right.startMs !== null ? right.startMs - left.endMs : null,
      leftText,
      rightText,
      baselineJoined: baselinePairOutput !== finalText,
      fixedJoined,
      eligible,
      falseMerge: fixedPairOutput !== finalText && (!edit || Boolean(edit.falseMerge)),
      refusalReason: fixedJoined ? null : mergerRefusalReason(left, right, edit),
      capitalizedContinuation: edit?.capitalizedContinuation ?? false,
      transcriptAssessment: assessTranscriptJoin(leftText, rightText, firstWord),
      beforeSnippet: transcriptSnippet(leftText, rightText, false),
      afterSnippet: transcriptSnippet(leftText, rightText, true),
      alignmentCoverage: Math.min(left.alignmentCoverage, right.alignmentCoverage),
    });
  }

  const joinedByFullResult = fixedOutput !== finalText;
  const fixedJoinedCount = seams.filter(seam => seam.fixedJoined).length;
  const eligibleSeams = seams.filter(seam => seam.eligible);
  const missedEligible = eligibleSeams.filter(seam => !seam.fixedJoined);
  const falseMerges = seams.filter(seam => seam.falseMerge);
  const fullResultConsistent = joinedByFullResult === (fixedJoinedCount > 0);
  const chunkText = rows.map(row => (row.text ?? '').trim()).filter(Boolean).join(' ');
  return {
    finalText,
    rows,
    baselineSegments,
    fixedSegments,
    baselineOutput,
    fixedOutput,
    seams,
    fixedJoinedCount,
    baselineJoinedCount: seams.filter(seam => seam.baselineJoined).length,
    eligibleSeamCount: eligibleSeams.length,
    missedEligible,
    falseMerges,
    fullResultConsistent,
    unalignedChunks: aligned.filter(segment => segment.partialText && !segment.finalText).length,
    partialMatchesChunkRows: normalizeWhitespace(partialText) === normalizeWhitespace(chunkText),
  };
}

function normalizeWhitespace(text) {
  return text.split(/\s+/).filter(Boolean).join(' ');
}

function assessTranscriptJoin(leftText, rightText, firstWord) {
  const leftTail = leftText.split(/\s+/).slice(-10).join(' ');
  const rightHead = rightText.split(/\s+/).slice(0, 10).join(' ');
  if (/\bor not[.!?]*$/i.test(leftText.trim()) && /^\s*or\s+worse\b/i.test(rightText)) {
    return 'possibly less natural/redundant; user judgment';
  }
  const continuation = continuationWord(firstWord);
  const clauseLike = /[,;:]$/.test(leftTail) || /\b(?:and|or|but|because|which|that|when|while)$/i.test(leftTail);
  if (continuation && clauseLike) return 'reads more smoothly as one thought';
  if (continuation) return 'plausible continuation; context-dependent';
  return `not a continuation candidate (${rightHead.split(/\s+/)[0] ?? 'empty'})`;
}

function transcriptSnippet(leftText, rightText, merged) {
  let left = leftText.split(/\s+/).slice(-11).join(' ');
  const rightWords = rightText.split(/\s+/).slice(0, 11);
  if (merged) left = left.replace(/[.!?]["'”’)]*$/u, '');
  const first = rightWords[0] ?? '';
  if (merged && first && CONTINUATION_WORDS.has(first.toLowerCase())
    && first[0] === first[0].toUpperCase()) {
    rightWords[0] = first[0].toLowerCase() + first.slice(1);
  }
  const combined = `${left}${merged ? ' ' : ' | '}${rightWords.join(' ')}`;
  return combined.length > 190 ? `${combined.slice(0, 187)}…` : combined;
}

function findCrossingMergerSeam(split, merger) {
  return (merger?.seams ?? []).find(seam => seam.leftChunkId <= split.emissionId
    && seam.rightChunkId > split.emissionId) ?? null;
}

function evidenceCounts(frames, fromTime, toTime) {
  const counts = new Map();
  for (const frame of frames) {
    if (frame.time <= fromTime || frame.time > toTime) continue;
    const key = frame.evidence ?? 'unknown';
    counts.set(key, (counts.get(key) ?? 0) + 1);
  }
  return [...counts].map(([evidence, count]) => `${evidence} ${count}`).join(', ') || 'no frames';
}

function splitRootCause(split, replay, mergerSeam) {
  const emitted = emissionEvents(replay);
  const resumeTime = split.resumedAt;
  const prior = emitted.filter(event => event.time <= resumeTime).at(-1);
  const mergerCause = mergerSeam?.fixedJoined
    ? null
    : mergerSeam?.refusalReason ?? 'no matching transcript seam was captured';
  let vadCause = 'candidate replay did not carry the earlier audio segment through the resumed-start';

  if (prior && Number.isFinite(prior.time)) {
    const counts = evidenceCounts(replay.frames, prior.time, resumeTime);
    const firstResumeSignal = replay.frames.find(frame => frame.time > prior.time
      && frame.time <= resumeTime
      && ['strong', 'continuing', 'ambiguous'].includes(frame.evidence));
    vadCause = firstResumeSignal
      ? `candidate finalized at ${prior.time.toFixed(3)} s; later resume evidence arrived ${((firstResumeSignal.time - prior.time) * 1000).toFixed(0)} ms afterward (${counts})`
      : `candidate finalized at ${prior.time.toFixed(3)} s; only ${counts} followed before the recorded restart, so no resume evidence reached the endpoint in time`;
  }
  return mergerCause ? `${vadCause}; text merger refused: ${mergerCause}` : vadCause;
}

function buildSplitOutcomes(sessions, candidateReplays, mergers) {
  const outcomes = [];
  for (const session of sessions) {
    for (const split of session.entry.splitSignatures ?? []) {
      const candidateReplay = candidateReplays.get(session.entry.id);
      const resetOnly = resumesBeforeFinalize(split, session.recorded, session.ambiguousResetReplay);
      const preFinalized = resumesBeforeFinalize(split, session.recorded, candidateReplay);
      const mergerSeam = findCrossingMergerSeam(split, mergers.get(session.entry.id));
      const outcome = preFinalized
        ? 'resumed pre-finalize'
        : mergerSeam?.fixedJoined
          ? 'still split, then merged'
          : 'not fixed';
      outcomes.push({
        sessionId: session.entry.id,
        emissionId: split.emissionId,
        closeAt: split.closeAt,
        resumedAt: split.resumedAt,
        resumeAfterMs: split.resumeAfterSeconds * 1000,
        resetOnly,
        preFinalized,
        outcome,
        mergerSeam,
        rootCause: preFinalized || mergerSeam?.fixedJoined
          ? null
          : splitRootCause(split, candidateReplay, mergerSeam),
      });
    }
  }
  return outcomes;
}

function formatSeconds(value) {
  return Number.isFinite(value) ? `${value.toFixed(3)}s` : 'n/a';
}

function formatEmissionMap(emissions) {
  if (emissions.length === 0) return 'none';
  return emissions.map(event => {
    const id = event.id ?? '?';
    const reason = event.r ?? event.reason ?? 'unknown';
    const start = Number.isFinite(event.s0) ? event.s0 / 1000 : event.start;
    const end = Number.isFinite(event.s1) ? event.s1 / 1000 : event.end;
    const time = Number.isFinite(event.time) ? event.time : event.finalizeTime;
    return `#${id}/${reason} ${formatSeconds(start)}–${formatSeconds(end)} @${formatSeconds(time)}`;
  }).join('; ');
}

function sessionEmissionMaps(sessions, candidateReplays, resetOnlyReplays) {
  return sessions.map(session => ({
    id: session.entry.id,
    recorded: formatEmissionMap(session.recorded),
    ambiguousReset: formatEmissionMap(emissionEvents(resetOnlyReplays.get(session.entry.id))),
    candidate: formatEmissionMap(emissionEvents(candidateReplays.get(session.entry.id))),
  }));
}

function healthyControlRows(sessions, candidateReplays) {
  return sessions.filter(isHealthyControl).map(session => {
    const candidate = emissionEvents(candidateReplays.get(session.entry.id));
    const timing = controlTiming(session.recorded, candidate);
    const added = Math.max(0, candidate.length - session.recorded.length);
    return {
      id: session.entry.id,
      baselineEmissionCount: session.recorded.length,
      candidateEmissionCount: candidate.length,
      emissionCountDelta: candidate.length - session.recorded.length,
      addedEmissions: added,
      maxAbsFinalizeDeltaMs: timing.maxAbsDeltaMs,
      worstFinalizeDeltaMs: timing.worstDeltaMs ?? null,
      pass: timing.maxAbsDeltaMs !== null
        && timing.maxAbsDeltaMs <= HEALTHY_FINALIZE_TOLERANCE_MS
        && timing.endpointCountDelta === 0
        && added === 0
        && candidate.length === session.recorded.length,
    };
  });
}

function selectedCandidateReplays(sessions, ratios) {
  return new Map(sessions.map(session => [
    session.entry.id,
    runRecorderReplay(session.session, session.normalized, ratios, true),
  ]));
}

function summarizeCorpusSettings(sessions) {
  const values = sessions.map(session => session.normalized.config.endpointSilenceMs).sort((a, b) => a - b);
  return {
    minimum: Math.min(...values),
    median: values[Math.floor(values.length / 2)],
    maximum: Math.max(...values),
  };
}

function calculateGateSummary({ splitOutcomes, healthyRows, mergers, candidate }) {
  const allSplitCasesClassified = splitOutcomes.every(outcome => (
    outcome.preFinalized
    || outcome.mergerSeam?.fixedJoined
    || (outcome.outcome === 'not fixed' && outcome.rootCause)
  ));
  const healthyControlsPass = healthyRows.length > 0 && healthyRows.every(row => row.pass);
  const mergerFalseMerges = [...mergers.values()].reduce((total, result) => total + result.falseMerges.length, 0);
  const missedContinuationSeams = [...mergers.values()].reduce((total, result) => total + result.missedEligible.length, 0);
  const fullResultInconsistencies = [...mergers.values()].filter(result => !result.fullResultConsistent).length;
  const ratioWideningPass = widensLegacyWindowsAtUserSetting(candidate);
  const mergerPass = mergerFalseMerges === 0
    && missedContinuationSeams === 0
    && fullResultInconsistencies === 0
    && [...mergers.values()].some(result => result.fixedJoinedCount > 0)
    && [...mergers.values()].some(result => result.eligibleSeamCount > 0);
  return {
    allSplitCasesClassified,
    healthyControlsPass,
    mergerPass,
    mergerFalseMerges,
    missedContinuationSeams,
    fullResultInconsistencies,
    ratioWideningPass,
    candidateLocked: allSplitCasesClassified && healthyControlsPass && mergerPass && ratioWideningPass,
    resumeRatio: candidate.resumeRatio,
    rescueRatio: candidate.rescueRatio,
  };
}

function markdownReport({ inventory, sessions, candidates, selected, candidateReplays, mergers, reportPath }) {
  const fidelitySessions = sessions.filter(session => !session.excluded);
  const excludedSessions = sessions.filter(session => session.excluded);
  const splitOutcomes = buildSplitOutcomes(fidelitySessions, candidateReplays, mergers);
  const controls = healthyControlRows(fidelitySessions, candidateReplays);
  const gate = calculateGateSummary({ splitOutcomes, healthyRows: controls, mergers, candidate: selected });
  const emissionMaps = sessionEmissionMaps(
    fidelitySessions,
    candidateReplays,
    new Map(fidelitySessions.map(session => [session.entry.id, session.ambiguousResetReplay])),
  );
  const allSeams = [...mergers.values()].flatMap(result => result.seams);
  const joinedSeams = allSeams.filter(seam => seam.fixedJoined);
  const baselineJoinedSeams = allSeams.filter(seam => seam.baselineJoined);
  const potentiallyWorseJoins = joinedSeams.filter(seam => (
    seam.transcriptAssessment.startsWith('possibly less natural')
  ));
  const safeCandidates = candidates.filter(candidate => (
    candidate.controlPass && widensLegacyWindowsAtUserSetting(candidate)
  ));
  const settings = summarizeCorpusSettings(fidelitySessions);
  const defaultSettingRows = [450, 1300, 5000].map(endpointSilenceMs => {
    const config = makeStreamingEndpointConfig({
      endpointSilenceMs,
      resumeToEndpointSilenceRatio: selected.resumeRatio,
      ambiguousRescueToEndpointSilenceRatio: selected.rescueRatio,
    });
    return {
      endpointSilenceMs,
      resumeMs: config.resumeSamples / 16,
      rescueMs: config.ambiguousRescueSamples / 16,
    };
  });
  const resumeRange = [defaultSettingRows[0].resumeMs, defaultSettingRows[2].resumeMs];
  const rescueRange = [defaultSettingRows[0].rescueMs, defaultSettingRows[2].rescueMs];
  const phase4ClampNote = resumeRange[0] < 50 || resumeRange[1] > 500
    || rescueRange[0] < 100 || rescueRange[1] > 1000;
  const allRecordedEmissionCount = fidelitySessions.reduce((sum, session) => sum + session.recorded.length, 0);
  const allCandidateEmissionCount = fidelitySessions.reduce((sum, session) => (
    sum + emissionEvents(candidateReplays.get(session.entry.id)).length
  ), 0);
  const resetOnlyFixed = splitOutcomes.filter(outcome => outcome.resetOnly).length;
  const candidateFixed = splitOutcomes.filter(outcome => outcome.preFinalized).length;
  const stillSplitMerged = splitOutcomes.filter(outcome => outcome.outcome === 'still split, then merged').length;
  const notFixed = splitOutcomes.filter(outcome => outcome.outcome === 'not fixed').length;
  const additionalByRatios = splitOutcomes.filter(outcome => outcome.preFinalized && !outcome.resetOnly).length;
  const healthyMaximum = controls.reduce((max, row) => Math.max(max, row.maxAbsFinalizeDeltaMs ?? Infinity), 0);
  const healthyAddedEmissions = controls.reduce((sum, row) => sum + row.addedEmissions, 0);
  const mergerFalseMerges = [...mergers.values()].reduce((total, result) => total + result.falseMerges.length, 0);
  const mergerMisses = [...mergers.values()].reduce((total, result) => total + result.missedEligible.length, 0);
  const excludedList = excludedSessions.map(session => `| ${session.entry.id} | ${session.entry.exclusionReason ?? 'not fidelity-validated'} |`).join('\n');
  const splitRows = splitOutcomes.map(outcome => {
    const seam = outcome.mergerSeam;
    const merger = seam
      ? `${seam.baselineJoined ? 'yes' : 'no'} → ${seam.fixedJoined ? 'yes' : 'no'} (${seam.leftChunkId}→${seam.rightChunkId})`
      : 'no transcript seam';
    const cause = outcome.preFinalized || seam?.fixedJoined ? '—' : outcome.rootCause;
    return `| ${outcome.sessionId} #${outcome.emissionId} | ${outcome.resumeAfterMs.toFixed(0)} ms | ${outcome.resetOnly ? 'resumed' : 'split'} | ${outcome.preFinalized ? 'resumed pre-finalize' : outcome.outcome} | ${merger} | ${escapeCell(cause ?? '—')} |`;
  }).join('\n');
  const healthyRows = controls.map(row => (
    `| ${row.id} | ${row.baselineEmissionCount} | ${row.candidateEmissionCount} (${formatSigned(row.emissionCountDelta)}) | ${row.addedEmissions} | ${formatSigned(row.worstFinalizeDeltaMs)} (max ${formatSigned(row.maxAbsFinalizeDeltaMs)}) | ${row.pass ? 'PASS' : 'FAIL'} |`
  )).join('\n');
  const emissionMapRows = emissionMaps.map(row => (
    `| ${row.id} | ${escapeCell(row.recorded)} | ${escapeCell(row.ambiguousReset)} | ${escapeCell(row.candidate)} |`
  )).join('\n');
  const mergerRows = allSeams.map(seam => (
    `| ${seam.sessionId} ${seam.leftChunkId}→${seam.rightChunkId} | ${formatSigned(seam.gapMs)} | ${seam.baselineJoined ? 'yes' : 'no'} | ${seam.fixedJoined ? 'yes' : 'no'} | ${seam.falseMerge ? 'YES' : 'no'} | ${escapeCell(seam.transcriptAssessment)} | ${escapeCell(seam.beforeSnippet)} | ${escapeCell(seam.afterSnippet)} |`
  )).join('\n');
  const topCandidates = [...safeCandidates]
    .sort(compareCandidatePreference)
    .slice(0, 12)
    .map(candidate => `| ${candidate.resumeRatio.toFixed(3)} | ${candidate.rescueRatio.toFixed(3)} | ${candidate.resumedCount}/${splitOutcomes.length} | ${candidate.maximumHealthyDeltaMs.toFixed(0)} ms | ${candidate.addedHealthyEmissions} |`)
    .join('\n');
  const settingsRows = defaultSettingRows.map(row => (
    `| ${row.endpointSilenceMs} ms | ${row.resumeMs.toFixed(1)} ms | ${row.rescueMs.toFixed(1)} ms |`
  )).join('\n');
  const incidentSessions = fidelitySessions
    .filter(session => Number(session.entry.id.slice(9, 11)) >= 18)
    .map(session => session.entry.id);
  const reportStatus = gate.candidateLocked ? 'PASS — candidate locked for user approval' : 'NO-GO — no candidate satisfies every gate';
  const partialArtifactMatches = [...mergers.values()].filter(result => result.partialMatchesChunkRows).length;
  const unalignedTranscriptChunks = [...mergers.values()].reduce((total, result) => total + result.unalignedChunks, 0);
  const totalChunkRows = [...mergers.values()].reduce((total, result) => total + result.rows.length, 0);
  const nonemptyChunkRows = [...mergers.values()].reduce((total, result) => (
    total + result.rows.filter(row => typeof row.text === 'string' && row.text.trim()).length
  ), 0);
  const lines = [
    '# VAD sentence-interruption Phase 3 replay · 2026-10-23',
    '',
    `Generated: ${new Date().toISOString()}`,
    `Corpus: \`${inventory.corpusPath ?? DEFAULT_CORPUS_PATH}\` · baseline semantics: \`${inventory.baseline?.mirrorRevision ?? 'unknown'}\``,
    '',
    '## Gate summary',
    '',
    `**${reportStatus}.** The ratio sweep selected resume=${selected.resumeRatio.toFixed(3)} and ambiguous-rescue=${selected.rescueRatio.toFixed(3)} of \`endpointSilenceMs\` for this comparison. This is a candidate for approval, not authorization to begin Phase 4.`,
    '',
    `- Corpus: ${inventory.sessions.length} sessions; ${fidelitySessions.length} fidelity-validated; ${excludedSessions.length} excluded. There are ${splitOutcomes.length} split signatures across ${new Set(splitOutcomes.map(outcome => outcome.sessionId)).size} sessions, and ${controls.length} healthy controls.`,
    `- Split contribution: ambiguous-reset alone resumes ${resetOnlyFixed}/26 cases pre-finalize; the selected ratio pair resumes ${candidateFixed}/26 pre-finalize (${additionalByRatios} more than reset-only), leaves ${stillSplitMerged} as separate audio chunks that the fixed transcript merger joins, and leaves ${notFixed} not fixed with a documented root cause.`,
    `- Healthy controls: maximum absolute endpoint-finalize delta ${Number.isFinite(healthyMaximum) ? `${healthyMaximum.toFixed(0)} ms` : 'unavailable'} (tolerance ±${HEALTHY_FINALIZE_TOLERANCE_MS} ms); added emissions ${healthyAddedEmissions}; controls passing ${controls.filter(row => row.pass).length}/${controls.length}.`,
    `- Merger: ${baselineJoinedSeams.length} seams join with first-result storage → ${joinedSeams.length} with kind-aware storage (${mergers.size} sessions simulated); ${mergerFalseMerges} false merges; ${mergerMisses} eligible continuation seams missed.`,
    `- Candidate total emission count across fidelity sessions: ${allRecordedEmissionCount} recorded → ${allCandidateEmissionCount} replayed. This total is descriptive; healthy-control gates are evaluated per session below.`,
    '',
    '### Safety gates',
    '',
    `1. **Every split case classified:** ${gate.allSplitCasesClassified ? 'PASS' : 'FAIL'} — each case is resumed pre-finalize, still split but merged in text, or not fixed with a telemetry/transcript root cause.`,
    `2. **Healthy stop behavior:** ${gate.healthyControlsPass ? 'PASS' : 'FAIL'} — every control has the same emission count, zero added emissions, and endpoint-finalize timing within ±${HEALTHY_FINALIZE_TOLERANCE_MS} ms.`,
    `3. **Real transcript merger:** ${gate.mergerPass ? 'PASS' : 'FAIL'} — ${mergerFalseMerges} false merges; ${mergerMisses} eligible continuation seams missed; ${[...mergers.values()].filter(result => !result.fullResultConsistent).length} session outputs inconsistent with pairwise seam outcomes.`,
    `4. **Widened proportional windows:** ${gate.ratioWideningPass ? 'PASS' : 'FAIL'} — both selected ratios exceed the legacy 120/320 ms windows at the user's ${USER_ENDPOINT_SILENCE_MS} ms setting.`,
    '',
    '## Candidate parameters and sweep',
    '',
    `- **Resume ratio:** ${selected.resumeRatio.toFixed(3)} × endpoint silence (${(selected.resumeRatio * 100).toFixed(1)}%).`,
    `- **Ambiguous-rescue ratio:** ${selected.rescueRatio.toFixed(3)} × endpoint silence (${(selected.rescueRatio * 100).toFixed(1)}%).`,
    `- Corpus endpoint-silence settings: min ${settings.minimum} ms, median ${settings.median} ms, max ${settings.maximum} ms. Captured sessions were replayed with their recorded settings; the following projection shows how the candidate scales over the configured 450–5000 ms range.`,
    '',
    '| endpointSilenceMs | resume window | ambiguous-rescue window |',
    '|---:|---:|---:|',
    settingsRows,
    '',
    `The candidate sweep evaluated ${candidates.length} ratio pairs (resume 0.02–0.50 and rescue 0.05–1.00 on the coarse grid, plus local 0.005 refinements). Among pairs that widen both legacy windows at ${USER_ENDPOINT_SILENCE_MS} ms and pass the healthy-control gate, candidates are ordered by pre-finalize resumes, then smallest ratio sum. Healthy-stop tolerance was fixed at one 100 ms telemetry frame, stricter than the 600 ms baseline emission-map matching tolerance.`,
    '',
    '| Safe widened resume ratio | Safe widened rescue ratio | Pre-finalize resumes | Max healthy delta | Added healthy emissions |',
    '|---:|---:|---:|---:|---:|',
    topCandidates || '| none | none | — | — | — |',
    '',
    phase4ClampNote
      ? `**Phase 4 config note:** the selected proportional semantics need the Swift resume/rescue clamps revisited before porting. The projected ${resumeRange[0].toFixed(1)}–${resumeRange[1].toFixed(1)} ms resume and ${rescueRange[0].toFixed(1)}–${rescueRange[1].toFixed(1)} ms rescue ranges do not fit the current 50–500 ms / 100–1000 ms bounds at every supported setting; preserving the ratios requires changing those bounds rather than silently clipping the values.`
      : 'The projected ratio windows fit the current numeric config bounds, but proportional semantics still need to be preserved by the Phase 4 config reader.',
    '',
    '### Replay method and transcript evaluation',
    '',
    '- The recorded emission map is the baseline. “Ambiguous-reset alone” replays the fidelity-validated telemetry through the Phase 2 mirror with legacy 120/320 ms resume/rescue defaults. Ratio candidates inject the Phase 2 `resumeToEndpointSilenceRatio` and `ambiguousRescueToEndpointSilenceRatio` settings into the same recorder harness; no endpoint-silence threshold or post-finalize grace was changed.',
    '- Corpus replay uses only `fidelity-ok` sessions from `INVENTORY.json`; excluded or missing-telemetry sessions are not silently included. The replay wrapper is checked against `replaySession` before applying ratios.',
    `- \`chunks.jsonl\` has one row per audio \`chunk_id\` with a per-chunk \`text\` field when transcription is non-empty (${totalChunkRows} rows total; ${nonemptyChunkRows} non-empty here). Its \`payload_kind: pcm\` describes the audio payload, not a partial/final message kind. The capture does not preserve per-message kinds. The fallback treats the captured chunk text as the first partial and aligns ordered chunk words to \`transcription.txt\` to synthesize terminal per-chunk final spans; telemetry \`s0\`/\`s1\` supplies audio boundaries. \`partial.txt\` agrees with the whitespace-joined chunk rows in ${partialArtifactMatches}/${mergers.size} sessions; ${unalignedTranscriptChunks} non-empty chunk rows could not be aligned to a terminal span. The fixed \`ChunkResultStore\` replaces each partial with its final span; the baseline simulation keeps the first result.`,
    '- The user’s evaluation rule is applied: “what you see in the transcriptions might not actually represent the reality of what is said. So if you get a different transcription from the one that was transcribed at the time of the recording, don\'t necessarily take it as wrong, but evaluate the result and see if it looks better or not. Or worse.” The merger changes punctuation/capitalization only; changed surface text is not automatically scored as an error. The snippet assessment below is about flow, not ground-truth accuracy.',
    '',
    '## Split-signature outcomes',
    '',
    '| Session / emission | Recorded restart gap | Reset-only | Selected candidate | Store merger baseline → fixed | Residual root cause |',
    '|---|---:|---|---|---|---|',
    splitRows,
    '',
    '## Healthy controls: true-stop timing',
    '',
    `Tolerance: ±${HEALTHY_FINALIZE_TOLERANCE_MS} ms from the recorded endpoint-finalize frame. “Emission delta” is candidate total emissions minus recorded total; added emissions must be zero, and this gate also requires no removed emissions.`,
    '',
    '| Session | Recorded emits | Candidate emits (delta) | Added | Worst signed endpoint-finalize delta (max abs) | Gate |',
    '|---|---:|---:|---:|---:|---|',
    healthyRows,
    '',
    '## Merger simulation on real transcript seams',
    '',
    `| All ${allSeams.length} adjacent transcript-bearing seams are included. “Fixed” is the kind-aware store result; joins require the existing merger punctuation/continuation rules and a gap ≤${MERGER_MAX_GAP_MS} ms. A false merge means the edit would remove intervening lexical content.`,
    '',
    '| Session / chunks | Audio gap | First-result store joins | Kind-aware store joins | False merge | Surface read | Before | After |',
    '|---|---:|---|---|---|---|---|---|',
    mergerRows || '| — | — | — | — | — | no transcript seams | — | — |',
    '',
    `Surface read: ${joinedSeams.length - potentiallyWorseJoins.length} joined seams look like plausible smoother continuations; ${potentiallyWorseJoins.length} may read less naturally after joining (${potentiallyWorseJoins.map(seam => `${seam.sessionId} ${seam.leftChunkId}→${seam.rightChunkId}`).join(', ') || 'none'}). In particular, “better or not. Or worse.” → “better or not or worse.” can sound redundant. This is not a ground-truth verdict: the audio was not re-evaluated, and the user's stated rule means a changed transcript is not automatically wrong. The table keeps the wording visible for the approval gate.`,
    '',
    '## Per-session emission maps',
    '',
    'Intervals are emitted audio boundaries in seconds; `@` is the endpoint/finalize time when available. The three columns separate the recorded baseline, ambiguous-reset-only contribution, and selected ratio candidate.',
    '',
    '| Session | Recorded baseline | Ambiguous-reset only | Selected ratio candidate |',
    '|---|---|---|---|',
    emissionMapRows,
    '',
    '## Exclusions and scope',
    '',
    '| Session | Exclusion reason |',
    '|---|---|',
    excludedList || '| none | — |',
    '',
    `Evening incident-candidate sessions in the fidelity-validated corpus: ${incidentSessions.join(', ') || 'none'}. No Pi access or live system interaction was used. No Swift or Phase 4 changes were made.`,
    '',
    `Report path: \`${reportPath}\``,
    '',
  ];
  return { markdown: lines.join('\n'), splitOutcomes, controls, gate, joinedSeams };
}

function formatSigned(value) {
  if (!Number.isFinite(value)) return 'n/a';
  return `${value > 0 ? '+' : ''}${value.toFixed(0)} ms`;
}

function escapeCell(value) {
  return String(value ?? '').replaceAll('|', '\\|').replaceAll('\n', ' ');
}

function readMergerResults(sessions) {
  return new Map(sessions.map(session => [session.entry.id, buildMergerSimulation(session)]));
}

export function runSweep({ corpusPath = DEFAULT_CORPUS_PATH, reportPath = DEFAULT_REPORT_PATH } = {}) {
  const { inventory, sessions: allSessions } = loadCorpus(corpusPath);
  const fidelitySessions = allSessions.filter(session => !session.excluded);
  const mergers = readMergerResults(fidelitySessions);
  const candidates = sweepCandidates(fidelitySessions);
  const safeCandidates = candidates.filter(candidate => candidate.controlPass);
  const safeWidenedCandidates = safeCandidates.filter(widensLegacyWindowsAtUserSetting);
  const selected = (safeWidenedCandidates.length > 0
    ? safeWidenedCandidates
    : safeCandidates.length > 0
      ? safeCandidates
      : candidates)[0];
  const candidateReplays = selectedCandidateReplays(fidelitySessions, {
    resume: selected.resumeRatio,
    rescue: selected.rescueRatio,
  });
  const report = markdownReport({
    inventory,
    sessions: allSessions,
    candidates,
    selected,
    candidateReplays,
    mergers,
    reportPath,
  });
  fs.writeFileSync(reportPath, report.markdown);
  return {
    candidate: selected,
    gate: report.gate,
    sessions: fidelitySessions.length,
    exclusions: allSessions.length - fidelitySessions.length,
    splitCases: report.splitOutcomes.length,
    preFinalize: report.splitOutcomes.filter(outcome => outcome.preFinalized).length,
    stillSplitThenMerged: report.splitOutcomes.filter(outcome => outcome.outcome === 'still split, then merged').length,
    notFixed: report.splitOutcomes.filter(outcome => outcome.outcome === 'not fixed').length,
    healthyControls: report.controls.length,
    healthyControlsPassed: report.controls.filter(row => row.pass).length,
    maxHealthyDeltaMs: Math.max(...report.controls.map(row => row.maxAbsFinalizeDeltaMs ?? Infinity)),
    addedHealthyEmissions: report.controls.reduce((sum, row) => sum + row.addedEmissions, 0),
    mergedSeams: report.joinedSeams.length,
    falseMerges: [...mergers.values()].reduce((sum, result) => sum + result.falseMerges.length, 0),
    mergerPass: report.gate.mergerPass,
    reportPath,
  };
}

function usage() {
  return 'Usage: node scripts/prediction-sim/bin/sweep-vad-sentence-interruption.mjs [--corpus PATH] [--report PATH]';
}

export function main(argv = process.argv.slice(2)) {
  const options = parseArgs(argv);
  if (options.help) {
    process.stdout.write(`${usage()}\n`);
    return;
  }
  const result = runSweep(options);
  process.stdout.write(`Sweep: ${result.sessions} fidelity sessions; ${result.splitCases} split cases; ${result.preFinalize} resumed before finalize; ${result.stillSplitThenMerged} text-merged; ${result.notFixed} residual\n`);
  process.stdout.write(`Candidate: resume=${result.candidate.resumeRatio.toFixed(3)} × silence; rescue=${result.candidate.rescueRatio.toFixed(3)} × silence\n`);
  process.stdout.write(`Healthy controls: ${result.healthyControlsPassed}/${result.healthyControls}; max delta ${result.maxHealthyDeltaMs.toFixed(0)} ms; added emissions ${result.addedHealthyEmissions}\n`);
  process.stdout.write(`Merger: ${result.mergedSeams} joined seams; ${result.falseMerges} false merges; gate ${result.mergerPass ? 'PASS' : 'FAIL'}\n`);
  process.stdout.write(`Report: ${result.reportPath}\n`);
  process.stdout.write(`Safety gates: ${result.gate.candidateLocked ? 'PASS' : 'NO-GO'}\n`);
}

if (process.argv[1] && path.resolve(process.argv[1]) === path.resolve(fileURLToPath(import.meta.url))) {
  try {
    main();
  } catch (error) {
    process.stderr.write(`${error instanceof Error ? error.message : error}\n`);
    process.exitCode = 1;
  }
}
