import assert from 'node:assert/strict';
import {
  mkdtempSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { describe, it } from 'node:test';
import {
  encodeTraceRecord,
  makeDecisionEvent,
  makeKeyEvent,
  makeStateEvent,
  makeSuggestionEvent,
  TRACE_LIVE_FILE_NAME,
  TRACE_ROTATED_FILE_NAME,
} from '../lib/keystroke-trace.mjs';
import {
  analyzeTraceFiles,
  formatSummary,
  formatTimeline,
} from '../bin/trace-viewer.mjs';

const timestamp = '2026-11-14T12:00:00.000Z';

function temporaryDirectory(testContext) {
  const directory = mkdtempSync(path.join(os.tmpdir(), 'ritoras-trace-viewer-'));
  testContext.after(() => rmSync(directory, { recursive: true, force: true }));
  return directory;
}

function encodedEvents(events) {
  return Buffer.concat(events.map(event => encodeTraceRecord(event, timestamp)));
}

function writeEvents(filePath, events, trailingText = '') {
  writeFileSync(filePath, Buffer.concat([
    encodedEvents(events),
    Buffer.from(trailingText, 'utf8'),
  ]));
}

function suggestion(currentWord, displayedCandidates) {
  return makeSuggestionEvent({
    currentWord,
    lookupWord: currentWord,
    candidates: displayedCandidates.map(candidate => ({
      candidate,
      scoreComponents: { apple: 1 },
    })),
    displayedCandidates,
    epoch: 1,
    documentContextLength: currentWord.length,
    documentContextSuffix: currentWord,
  });
}

describe('offline keystroke trace viewer', () => {
  it('reads rotated then live segments, skips torn tails, and counts malformed lines', (testContext) => {
    const directory = temporaryDirectory(testContext);
    const rotatedPath = path.join(directory, TRACE_ROTATED_FILE_NAME);
    const livePath = path.join(directory, TRACE_LIVE_FILE_NAME);
    writeEvents(rotatedPath, [
      makeKeyEvent({
        action: 'insert',
        keyValue: 'a',
        epoch: 1,
        contextBefore: '',
        contextAfter: 'a',
      }),
    ], '{"schemaVersion":');
    writeEvents(livePath, [
      makeKeyEvent({
        action: 'insert',
        keyValue: 'b',
        epoch: 1,
        contextBefore: 'a',
        contextAfter: 'ab',
      }),
      makeKeyEvent({
        action: 'insert',
        contextBefore: 'ab',
        contextAfter: 'abc',
      }),
    ], 'not-json\n');

    const analysis = analyzeTraceFiles([livePath, rotatedPath]);

    assert.deepStrictEqual(analysis.orderedPaths, [rotatedPath, livePath]);
    assert.deepStrictEqual(
      analysis.records.map(record => record.event.payload.keyValue),
      ['a', 'b']
    );
    assert.strictEqual(analysis.malformedCount, 2);
    assert.strictEqual(analysis.incompleteTailCount, 1);
    assert.strictEqual(analysis.warnings.length, 2);
    assert.strictEqual(analysis.summary.malformedCount, 2);
    assert.strictEqual(analysis.summary.incompleteTailCount, 1);
  });

  it('prints every key caret window and complete correction and tap text', (testContext) => {
    const directory = temporaryDirectory(testContext);
    const tracePath = path.join(directory, 'trace.ndjson');
    writeEvents(tracePath, [
      makeKeyEvent({
        action: 'suggestionTap',
        keyValue: 'their',
        epoch: 3,
        contextBefore: 'I saw thier',
        contextAfter: ' yesterday',
        deleteCount: 5,
        liveContextSuffix: 'I saw their yesterday',
      }),
      makeDecisionEvent({
        outcome: 'apply',
        reasonCode: 'autocorrect-applied',
        rawLMLogProb: -7.5,
        beforeText: 'I saw thier yesterday',
        afterText: 'I saw their yesterday',
        deleteCount: 5,
        insertCount: 5,
      }),
      makeDecisionEvent({
        outcome: 'apply',
        reasonCode: 'autocorrect-applied',
        path: 'inline',
        rawLMLogProb: -8.1254,
        conditionalLMLogProb: -6.1254,
        typedLiteralRawLMLogProb: -10.0004,
        beforeText: 'I saw wiyh yesterday',
        afterText: 'I saw with yesterday',
        deleteCount: 4,
        insertCount: 4,
      }),
      makeDecisionEvent({
        outcome: 'queued',
        reasonCode: 'autocorrect-retro-queued',
        checkedWord: 'wiyh',
        candidate: 'with',
      }),
      makeDecisionEvent({
        outcome: 'skip',
        reasonCode: 'autocorrect-language-model-floor',
        path: 'inline',
        rawLMLogProb: -10.125,
        conditionalLMLogProb: -8.625,
      }),
      makeDecisionEvent({
        outcome: 'skip',
        reasonCode: 'autocorrect-language-model-floor',
        path: 'retro',
        candidate: 'with',
        fusedScore: 1,
        rawLMLogProb: -9.125,
        typedLiteralRawLMLogProb: -10,
        typedLiteralLogProbMargin: 2,
        absoluteLogProbFloor: -8,
        checkedWord: 'wiyh',
      }),
      makeDecisionEvent({
        outcome: 'skip',
        reasonCode: 'autocorrect-apply-target-mismatch',
        path: 'retro',
        checkedWord: 'their',
        expectedWindow: 'their',
        foundWindow: 'their',
      }),
    ]);

    const analysis = analyzeTraceFiles([tracePath]);
    const timeline = formatTimeline(analysis.records);
    const decisions = analysis.records.filter(record => record.event.type === 'decision');
    assert.deepEqual(decisions.slice(0, 5).map(record => record.event.payload.conditionalLMLogProb),
      [undefined, -6.125, undefined, -8.625, undefined]);

    assert.match(timeline, /caret-window: before="I saw thier" \| caret \| after=" yesterday"/);
    assert.match(timeline, /tap before: "I saw thier"/);
    assert.match(timeline, /tap after: " yesterday"/);
    assert.match(timeline, /beforeText: "I saw thier yesterday"/);
    assert.match(timeline, /afterText: "I saw their yesterday"/);
    assert.ok(timeline.includes(
      '  apply: reason=autocorrect-applied path=inline rawLMLogProb=-8.125 '
        + 'conditionalLMLogProb=-6.125 (floor operand) '
        + 'typedLiteralRawLMLogProb=-10 deleteCount=4 insertCount=4'
    ));
    assert.match(timeline, /rawLMLogProb=-7\.5 floor operand=rawLMLogProb \(older rule: combined score\)/);
    assert.match(timeline, /rawLMLogProb=-10\.125 conditionalLMLogProb=-8\.625 \(floor operand\)/);
    assert.ok(timeline.includes(
      '  queued: reason=autocorrect-retro-queued checkedWord="wiyh" '
        + 'candidate="with"'
    ));
    assert.ok(timeline.includes(
      '  skip: reason=autocorrect-language-model-floor path=retro candidate="with" '
        + 'fusedScore=1 rawLMLogProb=-9.125 floor operand=rawLMLogProb (older rule: combined score)'
    ));
    assert.match(
      timeline,
      /typedLiteralRawLMLogProb=-10 typedLiteralLogProbMargin=2 absoluteLogProbFloor=-8 checkedWord="wiyh"/
    );
    assert.ok(timeline.includes(
      '  skip: reason=autocorrect-apply-target-mismatch path=retro '
        + 'checkedWord="their" expectedWindow="their" foundWindow="their"'
    ));
  });

  it('summarizes autocorrect outcomes, skip reasons, and consecutive suggestion stability', (testContext) => {
    const directory = temporaryDirectory(testContext);
    const tracePath = path.join(directory, 'trace.ndjson');
    writeEvents(tracePath, [
      makeDecisionEvent({
        outcome: 'apply',
        reasonCode: 'autocorrect-applied',
        beforeText: 'teh',
        afterText: 'the',
        deleteCount: 3,
        insertCount: 3,
      }),
      makeDecisionEvent({
        outcome: 'skip',
        reasonCode: 'autocorrect-score-below-threshold',
      }),
      makeDecisionEvent({
        outcome: 'queued',
        reasonCode: 'autocorrect-retro-queued',
        checkedWord: 'thier',
        candidate: 'their',
      }),
      makeDecisionEvent({
        outcome: 'skip',
        reasonCode: 'autocorrect-score-below-threshold',
      }),
      suggestion('teh', ['the', 'ten']),
      suggestion('teh', ['the']),
      suggestion('teh', ['then']),
    ]);

    const analysis = analyzeTraceFiles([tracePath]);
    const summary = analysis.summary;
    const renderedSummary = formatSummary(summary);

    assert.deepStrictEqual(summary.autocorrect, {
      appliedCount: 1,
      skippedCount: 2,
      queuedCount: 1,
      decisionCount: 3,
      fireRate: 1 / 3,
    });
    assert.deepStrictEqual(summary.skipReasons, {
      'autocorrect-score-below-threshold': 2,
    });
    assert.deepStrictEqual(summary.suggestionStability, {
      refreshCount: 3,
      transitionCount: 2,
      changedTopSuggestionCount: 1,
      unchangedTopSuggestionCount: 1,
      stabilityRate: 0.5,
    });
    assert.match(
      renderedSummary,
      /Autocorrect fire rate: 1\/3 applied \(33\.3%; 1 applied, 2 skipped, 1 queued\)/
    );
    assert.match(renderedSummary, /autocorrect-score-below-threshold: 2/);
    assert.match(renderedSummary, /Suggestion stability: 50\.0% unchanged/);
    assert.match(renderedSummary, /Malformed lines skipped: 0/);
  });

  it('validates optional apply operands and bounded queue words', (testContext) => {
    const directory = temporaryDirectory(testContext);
    const tracePath = path.join(directory, 'trace.ndjson');
    const invalidRecords = [
      {
        schemaVersion: 1,
        timestamp,
        event: {
          type: 'decision',
          payload: {
            outcome: 'apply',
            reasonCode: 'autocorrect-applied',
            path: 'other',
            beforeText: 'wiyh',
            afterText: 'with',
            deleteCount: 4,
            insertCount: 4,
          },
        },
      },
      {
        schemaVersion: 1,
        timestamp,
        event: {
          type: 'decision',
          payload: {
            outcome: 'queued',
            reasonCode: 'autocorrect-retro-queued',
            checkedWord: 'wiyh',
            candidate: 'x'.repeat(65),
          },
        },
      },
    ];
    writeFileSync(
      tracePath,
      `${invalidRecords.map(record => JSON.stringify(record)).join('\n')}\n`
    );

    const analysis = analyzeTraceFiles([tracePath]);

    assert.strictEqual(analysis.records.length, 0);
    assert.strictEqual(analysis.malformedCount, 2);
    assert.match(analysis.warnings[0], /path must be inline or retro/);
    assert.match(analysis.warnings[1], /exceeds the decision text limit/);
  });

  it('distinguishes suggestion-tap partial deletion from the merged inserted context', (testContext) => {
    const directory = temporaryDirectory(testContext);
    const tracePath = path.join(directory, 'trace.ndjson');
    writeEvents(tracePath, [
      suggestion('thier', ['their']),
      makeKeyEvent({
        action: 'suggestionTap',
        keyValue: 'their',
        epoch: 1,
        contextBefore: 'I typed thier',
        contextAfter: ' tomorrow',
        deleteCount: 0,
      }),
      makeKeyEvent({
        action: 'insert',
        keyValue: ' ',
        epoch: 1,
        contextBefore: 'I typed thier',
        contextAfter: 'thiertheir tomorrow',
        deleteCount: 0,
      }),
    ]);

    const findings = analyzeTraceFiles([tracePath]).summary.bugSignatures;

    assert.deepStrictEqual(findings.map(finding => finding.type), [
      'suggestion-tap-partial-delete',
    ]);
    assert.strictEqual(findings[0].deleteCount, 0);
    assert.strictEqual(findings[0].afterContext, 'thiertheir tomorrow');
  });

  it('distinguishes an origin-not-typing skip after typing the word following a suggestion tap', (testContext) => {
    const directory = temporaryDirectory(testContext);
    const tracePath = path.join(directory, 'trace.ndjson');
    writeEvents(tracePath, [
      makeKeyEvent({
        action: 'suggestionTap',
        keyValue: 'their',
        epoch: 1,
        contextBefore: 'I saw thier',
        contextAfter: ' ',
        deleteCount: 5,
      }),
      makeKeyEvent({
        action: 'insert',
        keyValue: 'n',
        epoch: 1,
        contextBefore: 'I saw their n',
        contextAfter: 'ext',
        deleteCount: 0,
      }),
      makeKeyEvent({
        action: 'trigger',
        epoch: 1,
        contextBefore: 'I saw their next',
        contextAfter: '',
      }),
      makeDecisionEvent({
        outcome: 'skip',
        reasonCode: 'autocorrect-origin-not-typing',
      }),
    ]);

    const findings = analyzeTraceFiles([tracePath]).summary.bugSignatures;

    assert.deepStrictEqual(findings.map(finding => finding.type), [
      'word-origin-too-far',
    ]);
    assert.strictEqual(findings[0].insertedKeyCount, 1);
  });

  it('distinguishes an epoch-invalidated deferred correction from ordinary skips', (testContext) => {
    const directory = temporaryDirectory(testContext);
    const tracePath = path.join(directory, 'trace.ndjson');
    writeEvents(tracePath, [
      makeKeyEvent({
        action: 'trigger',
        epoch: 1,
        contextBefore: 'teh',
        contextAfter: '',
      }),
      makeStateEvent({
        action: 'epochBump',
        epoch: 2,
        reasonCode: 'host-text-did-change-epoch-bump',
      }),
      makeDecisionEvent({
        outcome: 'skip',
        reasonCode: 'deferred-apply-epoch-changed',
      }),
    ]);

    const findings = analyzeTraceFiles([tracePath]).summary.bugSignatures;

    assert.deepStrictEqual(findings.map(finding => finding.type), [
      'deferred-apply-epoch-invalidated',
    ]);
    assert.strictEqual(
      findings[0].invalidationReason,
      'host-text-did-change-epoch-bump'
    );
  });
});
