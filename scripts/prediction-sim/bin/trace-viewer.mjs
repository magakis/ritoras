#!/usr/bin/env node

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  completeTraceLines,
  TRACE_DECISION_TEXT_CHARACTERS,
  TRACE_LIVE_FILE_NAME,
  TRACE_REASON_CODES,
  TRACE_ROTATED_FILE_NAME,
  TRACE_SCHEMA_VERSION,
} from '../lib/keystroke-trace.mjs';

const USAGE = 'Usage: node scripts/prediction-sim/bin/trace-viewer.mjs [--summary] '
  + '<segment> [<segment> ...]';
const KEY_ACTIONS = new Set([
  'insert',
  'backspace',
  'shift',
  'mode',
  'trigger',
  'suggestionTap',
  'redacted',
]);
const STATE_ACTIONS = new Set([
  'epochBump',
  'ringCleared',
  'modelLoaded',
  'modelUnloaded',
  'segmentRolled',
]);
const META_ACTIONS = new Set([
  'schemaVersion',
  'enabled',
  'disabled',
  'sessionStarted',
  'sessionEnded',
]);
const REASON_CODES = new Set(TRACE_REASON_CODES);
const graphemeSegmenter = new Intl.Segmenter(undefined, { granularity: 'grapheme' });

function isObject(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

function requireString(value, fieldName) {
  if (typeof value !== 'string') {
    throw new TypeError(`${fieldName} must be a string`);
  }
}

function requireInteger(value, fieldName) {
  if (!Number.isInteger(value)) {
    throw new TypeError(`${fieldName} must be an integer`);
  }
}

function requireUnsignedInteger(value, fieldName) {
  requireInteger(value, fieldName);
  if (value < 0) {
    throw new TypeError(`${fieldName} must be non-negative`);
  }
}

function requireFiniteNumber(value, fieldName) {
  if (typeof value !== 'number' || !Number.isFinite(value)) {
    throw new TypeError(`${fieldName} must be a finite number`);
  }
}

function requireBoundedText(value, fieldName) {
  requireString(value, fieldName);
  if (Array.from(graphemeSegmenter.segment(value)).length > TRACE_DECISION_TEXT_CHARACTERS) {
    throw new TypeError(`${fieldName} exceeds the decision text limit`);
  }
}

function requireOptional(payload, fieldName, validate) {
  if (!Object.hasOwn(payload, fieldName) || payload[fieldName] === null) return;
  validate(payload[fieldName], `payload.${fieldName}`);
}

function requireReasonCode(value, fieldName) {
  if (!REASON_CODES.has(value)) {
    throw new TypeError(`${fieldName} is not a recognized trace reason code`);
  }
}

function validateCandidate(candidate, index) {
  const prefix = `payload.candidates[${index}]`;
  if (!isObject(candidate)) {
    throw new TypeError(`${prefix} must be an object`);
  }
  requireString(candidate.candidate, `${prefix}.candidate`);
  if (!isObject(candidate.scoreComponents)) {
    throw new TypeError(`${prefix}.scoreComponents must be an object`);
  }
  for (const [name, score] of Object.entries(candidate.scoreComponents)) {
    if (typeof score !== 'number' || !Number.isFinite(score)) {
      throw new TypeError(`${prefix}.scoreComponents.${name} must be a finite number`);
    }
  }
}

function validateEvent(event) {
  if (!isObject(event) || !isObject(event.payload)) {
    throw new TypeError('event and event.payload must be objects');
  }

  const { payload } = event;
  switch (event.type) {
    case 'key':
      if (!KEY_ACTIONS.has(payload.action)) {
        throw new TypeError('payload.action is not a recognized key action');
      }
      requireUnsignedInteger(payload.epoch, 'payload.epoch');
      requireOptional(payload, 'keyValue', requireString);
      requireOptional(payload, 'caretPosition', requireInteger);
      requireOptional(payload, 'contextBefore', requireString);
      requireOptional(payload, 'contextAfter', requireString);
      requireOptional(payload, 'deleteCount', requireInteger);
      requireOptional(payload, 'liveContextSuffix', requireString);
      return;

    case 'suggestion':
      requireString(payload.currentWord, 'payload.currentWord');
      requireString(payload.lookupWord, 'payload.lookupWord');
      requireOptional(payload, 'previousWord', requireString);
      requireOptional(payload, 'previousWord2', requireString);
      if (!Array.isArray(payload.candidates)) {
        throw new TypeError('payload.candidates must be an array');
      }
      payload.candidates.forEach(validateCandidate);
      if (!Array.isArray(payload.displayedCandidates)
          || payload.displayedCandidates.some(candidate => typeof candidate !== 'string')) {
        throw new TypeError('payload.displayedCandidates must be an array of strings');
      }
      requireUnsignedInteger(payload.epoch, 'payload.epoch');
      requireOptional(payload, 'contextToken', requireString);
      requireInteger(payload.documentContextLength, 'payload.documentContextLength');
      requireString(payload.documentContextSuffix, 'payload.documentContextSuffix');
      return;

    case 'decision':
      if (!['apply', 'skip'].includes(payload.outcome)) {
        throw new TypeError('payload.outcome must be apply or skip');
      }
      requireReasonCode(payload.reasonCode, 'payload.reasonCode');
      if (payload.outcome === 'apply') {
        requireString(payload.beforeText, 'payload.beforeText');
        requireString(payload.afterText, 'payload.afterText');
        requireInteger(payload.deleteCount, 'payload.deleteCount');
        requireInteger(payload.insertCount, 'payload.insertCount');
      } else {
        requireOptional(payload, 'candidate', requireBoundedText);
        requireOptional(payload, 'fusedScore', requireFiniteNumber);
        requireOptional(payload, 'rawLMLogProb', requireFiniteNumber);
        requireOptional(payload, 'typedLiteralRawLMLogProb', requireFiniteNumber);
        requireOptional(payload, 'typedLiteralLogProbMargin', requireFiniteNumber);
        requireOptional(payload, 'absoluteLogProbFloor', requireFiniteNumber);
        requireOptional(payload, 'checkedWord', requireBoundedText);
      }
      return;

    case 'state':
      if (!STATE_ACTIONS.has(payload.action)) {
        throw new TypeError('payload.action is not a recognized state action');
      }
      requireOptional(payload, 'epoch', requireUnsignedInteger);
      requireOptional(payload, 'reasonCode', requireReasonCode);
      requireOptional(payload, 'model', requireString);
      requireOptional(payload, 'detail', requireString);
      return;

    case 'meta':
      if (!META_ACTIONS.has(payload.action)) {
        throw new TypeError('payload.action is not a recognized metadata action');
      }
      requireOptional(payload, 'sessionID', requireString);
      if (Object.hasOwn(payload, 'attributes') && payload.attributes !== null) {
        if (!isObject(payload.attributes)
            || Object.values(payload.attributes).some(value => typeof value !== 'string')) {
          throw new TypeError('payload.attributes must be a string-valued object');
        }
      }
      return;

    default:
      throw new TypeError(`unsupported event type: ${String(event.type)}`);
  }
}

function validateRecord(record) {
  if (!isObject(record)) {
    throw new TypeError('record must be an object');
  }
  if (record.schemaVersion !== TRACE_SCHEMA_VERSION) {
    throw new TypeError(`schemaVersion must be ${TRACE_SCHEMA_VERSION}`);
  }
  requireString(record.timestamp, 'timestamp');
  validateEvent(record.event);
  return record;
}

function* completeLinesWithNumbers(bytes) {
  let offset = 0;
  let lineNumber = 1;
  for (const line of completeTraceLines(bytes)) {
    while (offset < bytes.length && bytes[offset] === 0x0a) {
      offset += 1;
      lineNumber += 1;
    }
    const currentLineNumber = lineNumber;
    offset += line.length;
    if (bytes[offset] === 0x0a) {
      offset += 1;
      lineNumber += 1;
    }
    yield { line, lineNumber: currentLineNumber };
  }
}

function orderSegmentPaths(filePaths) {
  const paths = filePaths.map(filePath => path.resolve(filePath));
  const rotatedIndex = paths.findIndex(filePath => (
    path.basename(filePath) === TRACE_ROTATED_FILE_NAME
  ));
  const liveIndex = paths.findIndex(filePath => (
    path.basename(filePath) === TRACE_LIVE_FILE_NAME
  ));

  if (rotatedIndex >= 0 && liveIndex >= 0 && rotatedIndex > liveIndex) {
    const [rotatedPath] = paths.splice(rotatedIndex, 1);
    const reorderedLiveIndex = paths.findIndex(filePath => (
      path.basename(filePath) === TRACE_LIVE_FILE_NAME
    ));
    paths.splice(reorderedLiveIndex, 0, rotatedPath);
  }
  return paths;
}

export function parseTraceFiles(filePaths) {
  if (!Array.isArray(filePaths) || filePaths.length === 0) {
    throw new TypeError('Provide at least one trace segment path');
  }

  const orderedPaths = orderSegmentPaths(filePaths);
  const records = [];
  const warnings = [];
  let malformedCount = 0;
  let incompleteTailCount = 0;

  for (const filePath of orderedPaths) {
    let bytes;
    try {
      bytes = fs.readFileSync(filePath);
    } catch (error) {
      throw new Error(`Unable to read trace segment ${filePath}: ${error.message}`, {
        cause: error,
      });
    }

    if (bytes.length > 0 && bytes.at(-1) !== 0x0a) {
      incompleteTailCount += 1;
    }

    for (const { line, lineNumber } of completeLinesWithNumbers(bytes)) {
      try {
        const record = validateRecord(JSON.parse(line.toString('utf8')));
        records.push({
          ...record,
          sourcePath: filePath,
          lineNumber,
          sequence: records.length + 1,
        });
      } catch (error) {
        malformedCount += 1;
        warnings.push(
          `Warning: ${filePath}:${lineNumber}: ${error.message}; skipped malformed trace line`
        );
      }
    }
  }

  return {
    orderedPaths,
    records,
    warnings,
    malformedCount,
    incompleteTailCount,
  };
}

function graphemes(value) {
  return Array.from(graphemeSegmenter.segment(value), part => part.segment);
}

function precedingSuggestion(records, index) {
  for (let position = index - 1; position >= 0; position -= 1) {
    if (records[position].event.type === 'suggestion') return records[position];
  }
  return null;
}

function trailingWord(text) {
  const match = text?.match(/[\p{L}\p{M}\p{N}]+(?:['’\-][\p{L}\p{M}\p{N}]+)*$/u);
  return match?.[0] ?? null;
}

function followingKey(records, index) {
  for (let position = index + 1; position < records.length; position += 1) {
    if (records[position].event.type === 'key') return records[position];
  }
  return null;
}

function findSuggestionTapSignatures(records) {
  const findings = [];

  for (let index = 0; index < records.length; index += 1) {
    const tapRecord = records[index];
    const tap = tapRecord.event;
    if (tap.type !== 'key' || tap.payload.action !== 'suggestionTap') continue;

    const suggestion = precedingSuggestion(records, index);
    const typedWord = suggestion?.event.payload.currentWord
      || trailingWord(tap.payload.contextBefore);
    const selectedWord = tap.payload.keyValue
      || suggestion?.event.payload.displayedCandidates[0];
    const deleteCount = tap.payload.deleteCount;
    if (!typedWord || !selectedWord || !Number.isInteger(deleteCount)) continue;

    const typedGraphemes = graphemes(typedWord);
    if (deleteCount < 0 || deleteCount >= typedGraphemes.length) continue;

    const insertRecord = followingKey(records, index);
    if (!insertRecord || insertRecord.event.payload.action !== 'insert') continue;

    const afterContext = insertRecord.event.payload.contextAfter;
    const remainingTypedPrefix = typedGraphemes
      .slice(0, typedGraphemes.length - deleteCount)
      .join('');
    const mergedText = `${remainingTypedPrefix}${selectedWord}`;
    if (typeof afterContext !== 'string' || !afterContext.includes(mergedText)) continue;

    findings.push({
      type: 'suggestion-tap-partial-delete',
      tapSequence: tapRecord.sequence,
      insertSequence: insertRecord.sequence,
      typedWord,
      selectedWord,
      deleteCount,
      afterContext,
    });
  }

  return findings;
}

function findDecisionAfterTrigger(records, triggerIndex) {
  for (let index = triggerIndex + 1; index < records.length; index += 1) {
    const event = records[index].event;
    if (event.type === 'key' && event.payload.action === 'trigger') return null;
    if (event.type === 'decision') return records[index];
  }
  return null;
}

function findWordOriginSignatures(records) {
  const findings = [];

  for (let triggerIndex = 0; triggerIndex < records.length; triggerIndex += 1) {
    const trigger = records[triggerIndex].event;
    if (trigger.type !== 'key' || trigger.payload.action !== 'trigger') continue;

    let tapIndex = -1;
    for (let index = triggerIndex - 1; index >= 0; index -= 1) {
      const event = records[index].event;
      if (event.type === 'key' && event.payload.action === 'suggestionTap') {
        tapIndex = index;
        break;
      }
    }
    if (tapIndex < 0) continue;

    const insertedKeyCount = records
      .slice(tapIndex + 1, triggerIndex)
      .filter(record => (
        record.event.type === 'key' && record.event.payload.action === 'insert'
      ))
      .length;
    if (insertedKeyCount === 0) continue;

    const decision = findDecisionAfterTrigger(records, triggerIndex);
    if (decision?.event.payload.outcome !== 'skip'
        || decision.event.payload.reasonCode !== 'autocorrect-origin-not-typing') {
      continue;
    }

    findings.push({
      type: 'word-origin-too-far',
      suggestionTapSequence: records[tapIndex].sequence,
      triggerSequence: records[triggerIndex].sequence,
      skipSequence: decision.sequence,
      insertedKeyCount,
    });
  }

  return findings;
}

function findEpochInvalidationSignatures(records) {
  const findings = [];
  const invalidationReasons = new Set([
    'host-text-did-change-epoch-bump',
    'host-selection-change-epoch-bump',
  ]);

  for (let decisionIndex = 0; decisionIndex < records.length; decisionIndex += 1) {
    const decision = records[decisionIndex].event;
    if (decision.type !== 'decision'
        || decision.payload.outcome !== 'skip'
        || decision.payload.reasonCode !== 'deferred-apply-epoch-changed') {
      continue;
    }

    let snapshotIndex = -1;
    for (let index = decisionIndex - 1; index >= 0; index -= 1) {
      const event = records[index].event;
      if (event.type === 'suggestion'
          || (event.type === 'key' && event.payload.action === 'trigger')) {
        snapshotIndex = index;
        break;
      }
    }
    if (snapshotIndex < 0) continue;

    let invalidationIndex = -1;
    for (let index = decisionIndex - 1; index > snapshotIndex; index -= 1) {
      const event = records[index].event;
      if (event.type === 'state' && invalidationReasons.has(event.payload.reasonCode)) {
        invalidationIndex = index;
        break;
      }
    }
    if (invalidationIndex < 0) continue;

    findings.push({
      type: 'deferred-apply-epoch-invalidated',
      snapshotSequence: records[snapshotIndex].sequence,
      invalidationSequence: records[invalidationIndex].sequence,
      applyAttemptSequence: records[decisionIndex].sequence,
      invalidationReason: records[invalidationIndex].event.payload.reasonCode,
    });
  }

  return findings;
}

export function findKnownBugSignatures(records) {
  return [
    ...findSuggestionTapSignatures(records),
    ...findWordOriginSignatures(records),
    ...findEpochInvalidationSignatures(records),
  ].sort((left, right) => (
    left.tapSequence ?? left.suggestionTapSequence ?? left.snapshotSequence
  ) - (
    right.tapSequence ?? right.suggestionTapSequence ?? right.snapshotSequence
  ));
}

export function summarizeTrace({
  records,
  malformedCount = 0,
  incompleteTailCount = 0,
}) {
  const decisions = records
    .filter(record => record.event.type === 'decision')
    .map(record => record.event.payload);
  const appliedCount = decisions.filter(decision => decision.outcome === 'apply').length;
  const skippedCount = decisions.length - appliedCount;
  const skipReasons = {};
  for (const decision of decisions) {
    if (decision.outcome !== 'skip') continue;
    skipReasons[decision.reasonCode] = (skipReasons[decision.reasonCode] ?? 0) + 1;
  }

  const suggestions = records
    .filter(record => record.event.type === 'suggestion')
    .map(record => record.event.payload.displayedCandidates[0] ?? null);
  const suggestionTransitions = Math.max(0, suggestions.length - 1);
  let changedTopSuggestionCount = 0;
  for (let index = 1; index < suggestions.length; index += 1) {
    if (suggestions[index] !== suggestions[index - 1]) changedTopSuggestionCount += 1;
  }
  const unchangedTopSuggestionCount = suggestionTransitions - changedTopSuggestionCount;

  return {
    recordCount: records.length,
    keyEventCount: records.filter(record => record.event.type === 'key').length,
    autocorrect: {
      appliedCount,
      skippedCount,
      decisionCount: decisions.length,
      fireRate: decisions.length === 0 ? null : appliedCount / decisions.length,
    },
    skipReasons: Object.fromEntries(
      Object.entries(skipReasons).sort(([left], [right]) => left.localeCompare(right))
    ),
    suggestionStability: {
      refreshCount: suggestions.length,
      transitionCount: suggestionTransitions,
      changedTopSuggestionCount,
      unchangedTopSuggestionCount,
      stabilityRate: suggestionTransitions === 0
        ? null
        : unchangedTopSuggestionCount / suggestionTransitions,
    },
    malformedCount,
    incompleteTailCount,
    bugSignatures: findKnownBugSignatures(records),
  };
}

export function analyzeTraceFiles(filePaths) {
  const parsed = parseTraceFiles(filePaths);
  return {
    ...parsed,
    summary: summarizeTrace(parsed),
  };
}

function formatRecordedText(value) {
  return value === undefined || value === null
    ? '(not recorded)'
    : JSON.stringify(value);
}

export function formatTimeline(records) {
  const lines = ['=== Keystroke Timeline ==='];
  for (const record of records) {
    const event = record.event;
    const location = `${path.basename(record.sourcePath)}:${record.lineNumber}`;
    lines.push(
      `[${String(record.sequence).padStart(4, '0')}] ${record.timestamp} `
        + `${event.type} (${location})`
    );

    if (event.type === 'key') {
      const payload = event.payload;
      const details = [
        `action=${payload.action}`,
        `key=${formatRecordedText(payload.keyValue)}`,
        `deleteCount=${payload.deleteCount ?? '(not recorded)'}`,
        `epoch=${payload.epoch}`,
      ];
      lines.push(`  ${details.join(' ')}`);
      lines.push(
        `  caret-window: before=${formatRecordedText(payload.contextBefore)} `
          + `| caret | after=${formatRecordedText(payload.contextAfter)}`
      );
      if (payload.liveContextSuffix !== undefined) {
        lines.push(`  live-context-suffix: ${JSON.stringify(payload.liveContextSuffix)}`);
      }
      if (payload.action === 'suggestionTap') {
        lines.push(`  tap before: ${formatRecordedText(payload.contextBefore)}`);
        lines.push(`  tap after: ${formatRecordedText(payload.contextAfter)}`);
      }
      continue;
    }

    if (event.type === 'decision' && event.payload.outcome === 'apply') {
      lines.push(
        `  apply: reason=${event.payload.reasonCode} `
          + `deleteCount=${event.payload.deleteCount} insertCount=${event.payload.insertCount}`
      );
      lines.push(`  beforeText: ${JSON.stringify(event.payload.beforeText)}`);
      lines.push(`  afterText: ${JSON.stringify(event.payload.afterText)}`);
      continue;
    }

    if (event.type === 'decision') {
      const payload = event.payload;
      const details = [`reason=${payload.reasonCode}`];
      if (payload.candidate != null) {
        details.push(`candidate=${JSON.stringify(payload.candidate)}`);
      }
      if (payload.fusedScore != null) details.push(`fusedScore=${payload.fusedScore}`);
      if (payload.rawLMLogProb != null) {
        details.push(`rawLMLogProb=${payload.rawLMLogProb}`);
      }
      if (payload.typedLiteralRawLMLogProb != null) {
        details.push(`typedLiteralRawLMLogProb=${payload.typedLiteralRawLMLogProb}`);
      }
      if (payload.typedLiteralLogProbMargin != null) {
        details.push(`typedLiteralLogProbMargin=${payload.typedLiteralLogProbMargin}`);
      }
      if (payload.absoluteLogProbFloor != null) {
        details.push(`absoluteLogProbFloor=${payload.absoluteLogProbFloor}`);
      }
      if (payload.checkedWord != null) {
        details.push(`checkedWord=${JSON.stringify(payload.checkedWord)}`);
      }
      lines.push(`  skip: ${details.join(' ')}`);
      continue;
    }

    if (event.type === 'suggestion') {
      lines.push(
        `  currentWord=${JSON.stringify(event.payload.currentWord)} `
          + `top=${formatRecordedText(event.payload.displayedCandidates[0])} `
          + `displayed=${JSON.stringify(event.payload.displayedCandidates)}`
      );
      continue;
    }

    lines.push(`  payload: ${JSON.stringify(event.payload)}`);
  }
  return lines.join('\n');
}

function formatPercent(value) {
  return value === null ? 'n/a' : `${(value * 100).toFixed(1)}%`;
}

export function formatSummary(summary) {
  const lines = [
    '=== Summary ===',
    `Records: ${summary.recordCount} (${summary.keyEventCount} key events)`,
    `Autocorrect fire rate: ${summary.autocorrect.appliedCount}/`
      + `${summary.autocorrect.decisionCount} applied `
      + `(${formatPercent(summary.autocorrect.fireRate)}; `
      + `${summary.autocorrect.appliedCount} applied, ${summary.autocorrect.skippedCount} skipped)`,
    'Skip reasons:',
  ];

  const reasons = Object.entries(summary.skipReasons);
  if (reasons.length === 0) {
    lines.push('  (none)');
  } else {
    for (const [reason, count] of reasons) lines.push(`  ${reason}: ${count}`);
  }

  const stability = summary.suggestionStability;
  lines.push(
    `Suggestion stability: ${formatPercent(stability.stabilityRate)} unchanged; `
      + `${stability.unchangedTopSuggestionCount}/${stability.transitionCount} stable `
      + `across ${stability.refreshCount} refreshes `
      + `(${stability.changedTopSuggestionCount} top changes)`
  );
  lines.push(`Malformed lines skipped: ${summary.malformedCount}`);
  lines.push(`Incomplete trailing lines ignored: ${summary.incompleteTailCount}`);
  lines.push('Known bug signatures:');
  if (summary.bugSignatures.length === 0) {
    lines.push('  (none)');
  } else {
    for (const finding of summary.bugSignatures) {
      lines.push(`  ${finding.type}: ${JSON.stringify(finding)}`);
    }
  }
  return lines.join('\n');
}

function parseArgs(argv) {
  const options = { summaryOnly: false, help: false, filePaths: [] };
  let positionalOnly = false;

  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    if (positionalOnly) {
      options.filePaths.push(argument);
    } else if (argument === '--') {
      positionalOnly = true;
    } else if (argument === '--summary') {
      options.summaryOnly = true;
    } else if (argument === '--help' || argument === '-h') {
      options.help = true;
    } else if (argument.startsWith('-')) {
      throw new TypeError(`Unknown option: ${argument}`);
    } else {
      options.filePaths.push(argument);
    }
  }

  if (!options.help && options.filePaths.length === 0) {
    throw new TypeError('Provide one or more trace segment paths');
  }
  return options;
}

export function main(argv = process.argv.slice(2)) {
  let options;
  try {
    options = parseArgs(argv);
    if (options.help) {
      console.log(USAGE);
      return 0;
    }
    const analysis = analyzeTraceFiles(options.filePaths);
    for (const warning of analysis.warnings) console.error(warning);
    if (!options.summaryOnly) {
      console.log(formatTimeline(analysis.records));
      console.log('');
    }
    console.log(formatSummary(analysis.summary));
    return 0;
  } catch (error) {
    console.error(error.message);
    console.error(USAGE);
    return 1;
  }
}

if (process.argv[1]
    && path.resolve(process.argv[1]) === path.resolve(fileURLToPath(import.meta.url))) {
  process.exitCode = main();
}
