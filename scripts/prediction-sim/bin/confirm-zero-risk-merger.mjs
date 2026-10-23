#!/usr/bin/env node

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  ZERO_RISK_MERGER_CONFIG,
  evaluateChunkFinalSeam,
  mergeChunkFinal,
  mergeChunkFinalV1,
} from '../lib/chunk-final-merge.mjs';

const DEFAULT_CORPUS_PATH = '/home/michael/vad-corpus';
const DEFAULT_REPORT_PATH = path.join(DEFAULT_CORPUS_PATH, 'ZERO-RISK-CONFIRMATION.md');
const CONTINUATION = 'continuation';
const NEW_SENTENCE = 'new-sentence';
const UNCLEAR = 'unclear';
const LABELS = [CONTINUATION, NEW_SENTENCE, UNCLEAR];
const REGIME_ORDER = [
  'below-range/floor-clamped',
  'measurement-mode-like',
  'voice-isolation-like',
  'above-range',
  'standard-like',
  'borderline between bands',
  'missing-telemetry',
];
const SEAM_TYPE_ORDER = ['endpoint-close', '30s-hard-split', 'stop-flush', 'unknown'];
const EXPECTED_CONTINUATION_REPAIRS = 5;

function parseArgs(argv) {
  const options = { corpusPath: DEFAULT_CORPUS_PATH, reportPath: DEFAULT_REPORT_PATH };
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
  return options;
}

function readJson(filePath) {
  try {
    return JSON.parse(fs.readFileSync(filePath, 'utf8'));
  } catch (error) {
    throw new Error(`cannot read ${filePath}: ${error.message}`, { cause: error });
  }
}

function loadSeams(corpusPath) {
  const inventory = readJson(path.join(corpusPath, 'SEAM-INVENTORY.json'));
  if (!Array.isArray(inventory.seams)) {
    throw new Error('SEAM-INVENTORY.json has no seams array');
  }
  for (const seam of inventory.seams) {
    if (!LABELS.includes(seam.provisionalLabel)) {
      throw new Error(`${seam.session} ${seam.leftChunkId}→${seam.rightChunkId}: unknown label`);
    }
    if (typeof seam.leftTailText !== 'string' || typeof seam.rightHeadText !== 'string') {
      throw new Error(`${seam.session} ${seam.leftChunkId}→${seam.rightChunkId}: missing text`);
    }
  }
  return { inventory, seams: inventory.seams };
}

function wordMatches(text) {
  return [...text.matchAll(/[\p{L}]+/gu)];
}

function terminalPunctuation(text) {
  const match = text.match(/[.!?](?=["'”’)]*\s*$)/u);
  return match ? { index: match.index, value: match[0] } : null;
}

function firstWord(text) {
  return wordMatches(text)[0] ?? null;
}

function isCapitalized(word) {
  return word[0] === word[0].toUpperCase() && word[0] !== word[0].toLowerCase();
}

function continuationMissReason(outcome) {
  const head = firstWord(outcome.seam.rightHeadText.trim())?.[0] ?? '';
  const isV1LowercaseHead = head.length > 0
    && head[0] === head[0].toLowerCase()
    && head[0] !== head[0].toUpperCase();
  if (outcome.v1Joined && isV1LowercaseHead && !outcome.ruleA && !outcome.ruleB) {
    return `V1's lowercase-head fallback joins this, but Rule A requires a listed v1 connector and “${head.toLowerCase()}” is not on that list; Rule B does not match.`;
  }
  return 'Neither configured rule matches this seam.';
}

function ruleAForSeam(seam, leftText, rightText) {
  const punctuation = terminalPunctuation(leftText);
  const rightHead = firstWord(rightText)?.[0];
  const head = rightHead?.toLowerCase();
  const continuationWords = new Set(
    ZERO_RISK_MERGER_CONFIG.ruleA.continuationWords.map(word => word.toLowerCase()),
  );
  const acceptedHead = head !== undefined
    && ((ZERO_RISK_MERGER_CONFIG.ruleA.acceptLowercaseHead
      && rightHead[0] === rightHead[0].toLowerCase()
      && rightHead[0] !== rightHead[0].toUpperCase())
      || continuationWords.has(head));
  return punctuation !== null
    && acceptedHead
    && seam.gapMs <= ZERO_RISK_MERGER_CONFIG.ruleA.maxGapMs;
}

function ruleBForSeam(seam, leftText, rightText) {
  const leftWords = wordMatches(leftText);
  const head = firstWord(rightText)?.[0].toLowerCase();
  if (leftWords.length < 2 || head === undefined) return false;
  const auxiliary = leftWords.at(-2)[0].toLowerCase();
  const adverb = leftWords.at(-1)[0].toLowerCase();
  const auxiliaryWords = new Set(
    ZERO_RISK_MERGER_CONFIG.ruleB.auxiliaryWords.map(word => word.toLowerCase()),
  );
  const hangingClauseAdverbs = new Set(
    ZERO_RISK_MERGER_CONFIG.ruleB.hangingClauseAdverbs.map(word => word.toLowerCase()),
  );
  const hasConfiguredTail = auxiliaryWords.has(auxiliary)
    && hangingClauseAdverbs.has(adverb);
  const hasGerundHead = head.endsWith(ZERO_RISK_MERGER_CONFIG.ruleB.rightHeadGerundSuffix);
  return hasConfiguredTail
    && hasGerundHead
    && seam.gapMs > ZERO_RISK_MERGER_CONFIG.ruleA.maxGapMs
    && seam.gapMs > ZERO_RISK_MERGER_CONFIG.ruleB.minGapExclusiveMs
    && seam.gapMs <= ZERO_RISK_MERGER_CONFIG.ruleB.maxGapMs;
}

function expectedMergedText(leftText, rightText, rule) {
  const punctuation = terminalPunctuation(leftText);
  const head = firstWord(rightText);
  if (!head || !rule) return null;
  const lowerHead = rule === 'B'
    ? isCapitalized(head[0])
    : isCapitalized(head[0])
      && ZERO_RISK_MERGER_CONFIG.ruleA.continuationWords
        .some(word => word.toLowerCase() === head[0].toLowerCase());
  const editedRight = lowerHead
    ? rightText.slice(0, head.index) + head[0][0].toLowerCase() + head[0].slice(1)
      + rightText.slice(head.index + head[0].length)
    : rightText;

  if (rule === 'A') {
    if (!punctuation) return null;
    return `${leftText.slice(0, punctuation.index)} ${editedRight.slice(head.index)}`;
  }

  const editedLeft = punctuation
    ? leftText.slice(0, punctuation.index)
      + leftText.slice(punctuation.index + punctuation.value.length)
    : leftText;
  return `${editedLeft} ${editedRight}`;
}

function seamKey(seam) {
  return `${seam.session}:${seam.leftChunkId}->${seam.rightChunkId}`;
}

function formatGap(value) {
  return Number.isFinite(value) ? `${Number(value).toFixed(2)} ms` : 'n/a';
}

function escapeCell(value) {
  return String(value ?? '').replaceAll('|', '\\|').replaceAll('\n', ' ');
}

function evaluateSeam(seam) {
  const leftText = seam.leftTailText.trim();
  const rightText = seam.rightHeadText.trim();
  const beforeText = `${leftText} ${rightText}`;
  if (!Number.isFinite(seam.gapMs)) {
    return {
      seam,
      evaluated: false,
      ruleA: false,
      ruleB: false,
      union: false,
      joined: false,
      rule: null,
      v1Joined: false,
      beforeText,
      afterText: beforeText,
      editCorrect: true,
      decisionMatchesUnion: true,
    };
  }

  const ruleA = ruleAForSeam(seam, leftText, rightText);
  const ruleB = ruleBForSeam(seam, leftText, rightText);
  const union = ruleA || ruleB;
  const segments = [
    { chunkLocalText: leftText, startMs: 0, endMs: 0 },
    { chunkLocalText: rightText, startMs: seam.gapMs, endMs: seam.gapMs },
  ];
  const v1AfterText = mergeChunkFinalV1(
    beforeText,
    segments,
    ZERO_RISK_MERGER_CONFIG.ruleA.maxGapMs,
  );
  const decision = evaluateChunkFinalSeam(
    leftText,
    rightText,
    seam.gapMs,
    ZERO_RISK_MERGER_CONFIG,
  );
  const afterText = mergeChunkFinal(
    beforeText,
    segments,
    ZERO_RISK_MERGER_CONFIG,
  );
  const joined = afterText !== beforeText;
  const expectedRule = ruleA ? 'A' : ruleB ? 'B' : null;
  const expectedText = joined ? expectedMergedText(leftText, rightText, decision.rule) : beforeText;
  return {
    seam,
    evaluated: true,
    ruleA,
    ruleB,
    union,
    joined,
    rule: decision.rule,
    v1Joined: v1AfterText !== beforeText,
    beforeText,
    afterText,
    editCorrect: !joined || (expectedText !== null && afterText === expectedText),
    decisionMatchesUnion: decision.shouldMerge === union && decision.rule === expectedRule,
  };
}

function orderedValues(values, preferredOrder) {
  const distinct = [...new Set(values.filter(value => typeof value === 'string'))];
  return [
    ...preferredOrder.filter(value => distinct.includes(value)),
    ...distinct.filter(value => !preferredOrder.includes(value)).sort(),
  ];
}

function markdownStrataTable(seams, outcomes, field, order) {
  const values = orderedValues(seams.map(seam => seam[field]), order);
  const rows = values.map(value => {
    const strataSeams = seams.filter(seam => seam[field] === value);
    const outcomesInStratum = outcomes.filter(outcome => outcome.seam[field] === value);
    const count = label => strataSeams.filter(seam => (
      Number.isFinite(seam.gapMs) && seam.provisionalLabel === label
    )).length;
    const joins = label => outcomesInStratum.filter(outcome => (
      outcome.seam.provisionalLabel === label && outcome.joined
    )).length;
    const n = outcomesInStratum.length;
    return `| ${escapeCell(value)} | ${n} | ${joins(CONTINUATION)}/${count(CONTINUATION)} | ${joins(NEW_SENTENCE)}/${count(NEW_SENTENCE)} | ${joins(UNCLEAR)}/${count(UNCLEAR)} | ${outcomesInStratum.filter(outcome => outcome.ruleA).length} | ${outcomesInStratum.filter(outcome => outcome.ruleB).length} |`;
  });
  return [
    `| ${field === 'regime' ? 'Regime' : 'Seam type'} | Gap-known n | Continuation joins | New-sentence joins | Unclear joins | Rule A | Rule B |`,
    '|---|---:|---:|---:|---:|---:|---:|',
    ...rows,
  ].join('\n');
}

function markdownJoinTable(outcomes, label, noRowsText) {
  const rows = outcomes.filter(outcome => outcome.seam.provisionalLabel === label && outcome.joined);
  const tableRows = rows.map(outcome => (
    `| ${outcome.seam.session} ${outcome.seam.leftChunkId}→${outcome.seam.rightChunkId} | ${formatGap(outcome.seam.gapMs)} | ${escapeCell(outcome.seam.regime)} | ${outcome.v1Joined ? 'joined' : 'not joined'} | Rule ${outcome.rule} | ${escapeCell(`${outcome.seam.leftTailText} | ${outcome.seam.rightHeadText}`)} | ${escapeCell(outcome.afterText)} |`
  ));
  return [
    '| Session / chunks | Gap | Regime | V1 baseline | Rule | Before (boundary marked) | Merged output |',
    '|---|---:|---|---|---|---|---|',
    ...(tableRows.length ? tableRows : [noRowsText]),
  ].join('\n');
}

function markdownUnclearTable(seams, outcomes) {
  const rows = seams.filter(seam => seam.provisionalLabel === UNCLEAR).map(seam => {
    const result = Number.isFinite(seam.gapMs)
      ? outcomes.find(outcome => seamKey(outcome.seam) === seamKey(seam))
      : null;
    const outcome = result ? (result.joined ? `joined under Rule ${result.rule}` : 'not joined')
      : 'not evaluated (null gap)';
    const after = result?.joined ? result.afterText : `${seam.leftTailText} | ${seam.rightHeadText}`;
    return `| ${seam.session} ${seam.leftChunkId}→${seam.rightChunkId} | ${escapeCell(seam.regime)} | ${escapeCell(seam.seamType)} | ${formatGap(seam.gapMs)} | ${outcome} | ${escapeCell(`${seam.leftTailText} | ${seam.rightHeadText}`)} | ${escapeCell(after)} |`;
  });
  return [
    '| Session / chunks | Regime | Seam type | Gap | Outcome | Before (boundary marked) | After / retained split |',
    '|---|---|---|---:|---|---|---|',
    ...rows,
  ].join('\n');
}

function markdownUnionAudit({ ruleAKeys, ruleBKeys, unionKeys, actualKeys, violations }) {
  const overlap = [...ruleAKeys].filter(key => ruleBKeys.has(key));
  const missing = [...unionKeys].filter(key => !actualKeys.has(key));
  const unexpected = [...actualKeys].filter(key => !unionKeys.has(key));
  const violationRows = violations.map(violation => (
    `| ${violation.key} | ${escapeCell(violation.reason)} |`
  ));
  return {
    overlapCount: overlap.length,
    missing,
    unexpected,
    table: [
      `- Rule A joins: ${ruleAKeys.size}.`,
      `- Rule B joins: ${ruleBKeys.size}.`,
      `- Rule A ∩ Rule B: ${overlap.length}.`,
      `- Rule A ∪ Rule B: ${unionKeys.size}. Actual configuration joins: ${actualKeys.size}.`,
      `- Missing from actual: ${missing.length}; actual joins outside the union: ${unexpected.length}.`,
      '',
      '| Seam | Union check detail |',
      '|---|---|',
      ...(violationRows.length ? violationRows : ['| none | No union violations. |']),
    ].join('\n'),
  };
}

function zeroRiskMarkdown({
  inventory,
  reportPath,
  seams,
  outcomes,
  checks,
  ruleAKeys,
  ruleBKeys,
  unionKeys,
  actualKeys,
  violations,
}) {
  const continuationCount = seams.filter(seam => Number.isFinite(seam.gapMs)
    && seam.provisionalLabel === CONTINUATION).length;
  const repairs = outcomes.filter(outcome => outcome.seam.provisionalLabel === CONTINUATION
    && outcome.joined);
  const newSentenceCount = seams.filter(seam => Number.isFinite(seam.gapMs)
    && seam.provisionalLabel === NEW_SENTENCE).length;
  const falseMerges = outcomes.filter(outcome => outcome.seam.provisionalLabel === NEW_SENTENCE
    && outcome.joined);
  const unclearCount = seams.filter(seam => seam.provisionalLabel === UNCLEAR).length;
  const unclearEvaluable = outcomes.filter(outcome => outcome.seam.provisionalLabel === UNCLEAR);
  const unclearJoined = unclearEvaluable.filter(outcome => outcome.joined);
  const editErrors = outcomes.filter(outcome => outcome.joined && !outcome.editCorrect);
  const ruleMismatches = outcomes.filter(outcome => !outcome.decisionMatchesUnion);
  const nullGapCount = seams.filter(seam => !Number.isFinite(seam.gapMs)).length;
  const v1ContinuationJoins = outcomes.filter(outcome => (
    outcome.seam.provisionalLabel === CONTINUATION && outcome.v1Joined
  ));
  const ruleAContinuationJoins = outcomes.filter(outcome => (
    outcome.seam.provisionalLabel === CONTINUATION && outcome.ruleA
  ));
  const ruleAUnclearJoins = outcomes.filter(outcome => (
    outcome.seam.provisionalLabel === UNCLEAR && outcome.ruleA
  ));
  const v1OnlyContinuationMisses = outcomes.filter(outcome => (
    outcome.seam.provisionalLabel === CONTINUATION
    && outcome.v1Joined
    && !outcome.joined
  ));
  const gatePassed = falseMerges.length === 0
    && repairs.length >= EXPECTED_CONTINUATION_REPAIRS
    && editErrors.length === 0
    && violations.length === 0
    && ruleMismatches.length === 0;
  const falseMergeTable = markdownJoinTable(
    outcomes,
    NEW_SENTENCE,
    '| none | — | — | — | — | No new-sentence-labeled seam was joined. | — |',
  );
  const continuationTable = markdownJoinTable(
    outcomes,
    CONTINUATION,
    '| none | — | — | — | — | No continuation-labeled seam was joined. | — |',
  );
  const editErrorRows = editErrors.map(outcome => (
    `| ${outcome.seam.session} ${outcome.seam.leftChunkId}→${outcome.seam.rightChunkId} | Rule ${outcome.rule} | ${escapeCell(outcome.beforeText)} | ${escapeCell(outcome.afterText)} |`
  ));
  const v1OnlyMissRows = v1OnlyContinuationMisses.map(outcome => {
    return `| ${outcome.seam.session} ${outcome.seam.leftChunkId}→${outcome.seam.rightChunkId} | ${formatGap(outcome.seam.gapMs)} | ${escapeCell(`${outcome.seam.leftTailText} | ${outcome.seam.rightHeadText}`)} | V1 joins; zero-risk does not | ${escapeCell(continuationMissReason(outcome))} |`;
  });
  const blockerSection = repairs.length < EXPECTED_CONTINUATION_REPAIRS
    ? [
      `BLOCKED: only ${repairs.length} of the expected ${EXPECTED_CONTINUATION_REPAIRS} continuation seams were joined. The V1 baseline joins ${v1ContinuationJoins.length}/24 continuation labels; Rule A admits ${ruleAContinuationJoins.length} continuation-labeled joins plus ${ruleAUnclearJoins.length} unclear-labeled join(s), and Rule B admits ${outcomes.filter(outcome => outcome.seam.provisionalLabel === CONTINUATION && outcome.ruleB).length} continuation join(s).`,
      v1OnlyMissRows.length
        ? 'The following V1 continuation join(s) are absent from the shipping config. Reconcile Rule A with this legacy lowercase-head behavior or amend the approved continuation list, then rerun the false-merge gate before porting:'
        : 'The remaining shortfall is not a V1-only lowercase-head case; inspect the missed continuation rows above and update the named rules only after a user-approved decision.',
      '',
      '| Session / chunks | Gap | Before (boundary marked) | Baseline comparison | Specific rule mismatch |',
      '|---|---:|---|---|---|',
      ...(v1OnlyMissRows.length ? v1OnlyMissRows : ['| none | — | — | — | No V1-only continuation misses. |']),
    ]
    : ['No blocker: the continuation-repair threshold was met.'];
  const unionAudit = markdownUnionAudit({
    ruleAKeys,
    ruleBKeys,
    unionKeys,
    actualKeys,
    violations,
  });
  const status = gatePassed ? 'PASS' : 'BLOCKED';
  const checkRows = checks.map(check => (
    `| ${check.name} | ${check.passed ? 'PASS' : 'FAIL'} | ${escapeCell(check.detail)} |`
  ));
  const continuationBlockerRows = repairs.length < EXPECTED_CONTINUATION_REPAIRS
    ? [
      `The shortfall is specific: V1 joins ${v1ContinuationJoins.length}/24 continuation labels, while the zero-risk config joins ${repairs.length}/24. Rule A joins ${ruleAContinuationJoins.length} continuation-labeled seam(s) and ${ruleAUnclearJoins.length} unclear-labeled seam(s); Rule B adds ${outcomes.filter(outcome => outcome.seam.provisionalLabel === CONTINUATION && outcome.ruleB).length} continuation seam(s).`,
      v1OnlyMissRows.length
        ? 'At least one expected V1-class continuation is lost because the shipping Rule A list is narrower than the actual V1 lowercase-head behavior. The exact V1-only join(s) are:'
        : 'The missed continuation is not explained by a V1-only lowercase-head path; the named rules need a user-approved adjustment.',
      '',
      '| Session / chunks | Gap | Before (boundary marked) | Baseline comparison | Specific rule mismatch |',
      '|---|---:|---|---|---|',
      ...(v1OnlyMissRows.length ? v1OnlyMissRows : ['| none | — | — | — | No V1-only continuation misses. |']),
      '',
      'Needed next: reconcile Rule A with the legacy lowercase-head behavior (or add the missing lowercase head to its approved continuation list), then rerun this confirmation and the new-sentence false-merge check. No config or library change was made in this verification task.',
    ]
    : ['No continuation shortfall blocker.'];
  return [
    '# Zero-risk merger confirmation',
    '',
    `Generated: ${new Date().toISOString()}`,
    `Corpus: \`${inventory.sourceInventory ?? 'SEAM-INVENTORY.json'}\` · ${seams.length} seams · ${outcomes.length} finite-gap seams evaluated.`,
    '',
    `**${status} — ${repairs.length}/${continuationCount} gap-evaluable continuation seams joined; ${falseMerges.length}/${newSentenceCount} new-sentence false merges; ${editErrors.length} edit errors; ${violations.length} union violations.**`,
    '',
    '## Named shipping configuration',
    '',
    `\`${ZERO_RISK_MERGER_CONFIG.name}\` is the configuration imported directly from \`ZERO_RISK_MERGER_CONFIG\` in \`chunk-final-merge.mjs\`.`,
    '',
    '```json',
    JSON.stringify(ZERO_RISK_MERGER_CONFIG, null, 2),
    '```',
    '',
    `- **Rule A:** left ends in terminal punctuation; the first right-hand word matches the case-insensitive v1 list or is lowercase when \`acceptLowercaseHead\` is true; gap ≤ ${ZERO_RISK_MERGER_CONFIG.ruleA.maxGapMs} ms.`,
    `- **Rule B:** the left tail is an immediately adjacent auxiliary + configured hanging-clause adverb; the first right-hand word ends in \`${ZERO_RISK_MERGER_CONFIG.ruleB.rightHeadGerundSuffix}\`; ${ZERO_RISK_MERGER_CONFIG.ruleB.minGapExclusiveMs} ms < gap ≤ ${ZERO_RISK_MERGER_CONFIG.ruleB.maxGapMs} ms.`,
    '',
    '## Check results',
    '',
    '| Check | Result | Evidence |',
    '|---|---|---|',
    ...checkRows,
    '',
    '## Continuation shortfall blocker',
    '',
    ...continuationBlockerRows,
    '',
    '## Continuation repairs',
    '',
    `Observed ${repairs.length}/${continuationCount}; the expected confirmation count was at least ${EXPECTED_CONTINUATION_REPAIRS}. Each joined seam is shown verbatim.`,
    '',
    continuationTable,
    '',
    '### Missed continuation-labeled seams',
    '',
    '| Session / chunks | Regime | Seam type | Gap |',
    '|---|---|---|---:|',
    ...outcomes.filter(outcome => outcome.seam.provisionalLabel === CONTINUATION && !outcome.joined)
      .map(outcome => `| ${outcome.seam.session} ${outcome.seam.leftChunkId}→${outcome.seam.rightChunkId} | ${escapeCell(outcome.seam.regime)} | ${escapeCell(outcome.seam.seamType)} | ${formatGap(outcome.seam.gapMs)} |`),
    '',
    '## New-sentence false merges',
    '',
    `Observed ${falseMerges.length}/${newSentenceCount}. The table is empty when no such boundary is joined.`,
    '',
    falseMergeTable,
    '',
    '## Unclear seams',
    '',
    `Unclear labels do not pass or fail a gate. There are ${unclearJoined.length} joins among ${unclearEvaluable.length} finite-gap unclear seams; the remaining ${unclearCount - unclearEvaluable.length} have null gaps.`,
    '',
    markdownUnclearTable(seams, outcomes),
    '',
    '## Edit integrity',
    '',
    `Every joined output was compared with the exact permitted edit for its rule: Rule A removes the left terminal-punctuation-to-head span and lowercases a capitalized v1 connector; Rule B removes only left terminal punctuation and lowercases a capitalized gerund head. Mismatches: ${editErrors.length}.`,
    '',
    '| Session / chunks | Rule | Before | Actual output |',
    '|---|---|---|---|',
    ...(editErrorRows.length ? editErrorRows : ['| none | — | — | No edit-integrity errors. |']),
    '',
    '## Outcomes by regime',
    '',
    markdownStrataTable(seams, outcomes, 'regime', REGIME_ORDER),
    '',
    '## Outcomes by seam type',
    '',
    markdownStrataTable(seams, outcomes, 'seamType', SEAM_TYPE_ORDER),
    '',
    '## Rule A ∪ Rule B verification',
    '',
    'Rule A and Rule B were independently evaluated against their named config fields. The joined set is compared with their set union; this does not rely only on the final merged text.',
    '',
    unionAudit.table,
    '',
    `There are ${nullGapCount} null-gap seams; they are listed in the source inventory but are not gap-evaluable and are not included in the six-check counts.`,
    '',
    `Report path: \`${reportPath}\``,
    '',
  ].join('\n');
}

export function runZeroRiskConfirmation({
  corpusPath = DEFAULT_CORPUS_PATH,
  reportPath = DEFAULT_REPORT_PATH,
} = {}) {
  const { inventory, seams } = loadSeams(corpusPath);
  const evaluableSeams = seams.filter(seam => Number.isFinite(seam.gapMs));
  const outcomes = evaluableSeams.map(evaluateSeam);
  const ruleAKeys = new Set(outcomes.filter(outcome => outcome.ruleA).map(outcome => seamKey(outcome.seam)));
  const ruleBKeys = new Set(outcomes.filter(outcome => outcome.ruleB).map(outcome => seamKey(outcome.seam)));
  const unionKeys = new Set([...ruleAKeys, ...ruleBKeys]);
  const actualKeys = new Set(outcomes.filter(outcome => outcome.joined).map(outcome => seamKey(outcome.seam)));
  const violations = [];
  for (const outcome of outcomes) {
    const key = seamKey(outcome.seam);
    if (outcome.union !== outcome.joined) {
      violations.push({ key, reason: `independent Rule A/Rule B union=${outcome.union}, merger joined=${outcome.joined}` });
    }
    if (!outcome.decisionMatchesUnion) {
      violations.push({ key, reason: `decision rule ${outcome.rule ?? 'none'} disagrees with the independently evaluated sub-rules` });
    }
  }
  const falseMerges = outcomes.filter(outcome => outcome.seam.provisionalLabel === NEW_SENTENCE
    && outcome.joined);
  const repairs = outcomes.filter(outcome => outcome.seam.provisionalLabel === CONTINUATION
    && outcome.joined);
  const v1ContinuationJoinCount = outcomes.filter(outcome => (
    outcome.seam.provisionalLabel === CONTINUATION && outcome.v1Joined
  )).length;
  const ruleAContinuationJoinCount = outcomes.filter(outcome => (
    outcome.seam.provisionalLabel === CONTINUATION && outcome.ruleA
  )).length;
  const ruleAUnclearJoinCount = outcomes.filter(outcome => (
    outcome.seam.provisionalLabel === UNCLEAR && outcome.ruleA
  )).length;
  const editErrors = outcomes.filter(outcome => outcome.joined && !outcome.editCorrect);
  const unionEqual = violations.length === 0
    && unionKeys.size === actualKeys.size
    && [...unionKeys].every(key => actualKeys.has(key));
  const regimeTable = markdownStrataTable(seams, outcomes, 'regime', REGIME_ORDER);
  const seamTypeTable = markdownStrataTable(seams, outcomes, 'seamType', SEAM_TYPE_ORDER);
  const checks = [
    {
      name: 'Continuation repairs',
      passed: repairs.length >= EXPECTED_CONTINUATION_REPAIRS,
      detail: `${repairs.length}/${outcomes.filter(outcome => outcome.seam.provisionalLabel === CONTINUATION).length} zero-risk joins; expected at least ${EXPECTED_CONTINUATION_REPAIRS}. V1 joins ${v1ContinuationJoinCount}; Rule A joins ${ruleAContinuationJoinCount} continuation labels plus ${ruleAUnclearJoinCount} unclear label(s).`,
    },
    {
      name: 'New-sentence false merges',
      passed: falseMerges.length === 0,
      detail: `${falseMerges.length} joins among ${outcomes.filter(outcome => outcome.seam.provisionalLabel === NEW_SENTENCE).length} gap-evaluable new-sentence labels.`,
    },
    {
      name: 'Unclear outcomes',
      passed: true,
      detail: `${outcomes.filter(outcome => outcome.seam.provisionalLabel === UNCLEAR && outcome.joined).length} joined; all unclear finite-gap outcomes are listed below.`,
    },
    {
      name: 'Edit integrity',
      passed: editErrors.length === 0,
      detail: `${editErrors.length} joined outputs differ from the rule-specific punctuation/head-case edit.`,
    },
    {
      name: 'Regime and seam-type breakdowns',
      passed: regimeTable.length > 0 && seamTypeTable.length > 0,
      detail: 'Every outcome table includes gap-known sample sizes by regime and seam type.',
    },
    {
      name: 'Rule A ∪ Rule B equals actual join set',
      passed: unionEqual,
      detail: `${unionKeys.size} union members; ${actualKeys.size} actual joins; ${violations.length} decision/set discrepancies.`,
    },
  ];
  const markdown = zeroRiskMarkdown({
    inventory,
    reportPath,
    seams,
    outcomes,
    checks,
    ruleAKeys,
    ruleBKeys,
    unionKeys,
    actualKeys,
    violations,
  });
  fs.writeFileSync(reportPath, markdown);
  const status = checks.every(check => check.passed) ? 'COMPLETE' : 'BLOCKED';
  return {
    status,
    reportPath,
    seamCount: seams.length,
    evaluatedSeams: outcomes.length,
    nullGapSeams: seams.length - outcomes.length,
    ruleAJoins: ruleAKeys.size,
    ruleBJoins: ruleBKeys.size,
    ruleAUnionRuleB: unionKeys.size,
    actualJoins: actualKeys.size,
    continuationRepairs: repairs.length,
    continuationCount: outcomes.filter(outcome => outcome.seam.provisionalLabel === CONTINUATION).length,
    falseMerges: falseMerges.length,
    newSentenceCount: outcomes.filter(outcome => outcome.seam.provisionalLabel === NEW_SENTENCE).length,
    unclearJoins: outcomes.filter(outcome => outcome.seam.provisionalLabel === UNCLEAR && outcome.joined).length,
    editErrors: editErrors.length,
    unionViolations: violations.length,
    checks,
  };
}

function parseArgs(argv) {
  const options = { corpusPath: DEFAULT_CORPUS_PATH, reportPath: DEFAULT_REPORT_PATH };
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
  return options;
}

function printHelp() {
  console.log('Usage: node scripts/prediction-sim/bin/confirm-zero-risk-merger.mjs [--corpus PATH] [--report PATH]');
}

const invokedPath = process.argv[1] ? path.resolve(process.argv[1]) : null;
if (invokedPath === fileURLToPath(import.meta.url)) {
  try {
    const options = parseArgs(process.argv.slice(2));
    if (options.help) printHelp();
    else console.log(JSON.stringify(runZeroRiskConfirmation(options), null, 2));
  } catch (error) {
    console.error(error.stack ?? error.message);
    process.exitCode = 1;
  }
}
