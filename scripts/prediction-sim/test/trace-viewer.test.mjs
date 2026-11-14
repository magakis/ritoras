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
        beforeText: 'I saw thier yesterday',
        afterText: 'I saw their yesterday',
        deleteCount: 5,
        insertCount: 5,
      }),
    ]);

    const analysis = analyzeTraceFiles([tracePath]);
    const timeline = formatTimeline(analysis.records);

    assert.match(timeline, /caret-window: before="I saw thier" \| caret \| after=" yesterday"/);
    assert.match(timeline, /tap before: "I saw thier"/);
    assert.match(timeline, /tap after: " yesterday"/);
    assert.match(timeline, /beforeText: "I saw thier yesterday"/);
    assert.match(timeline, /afterText: "I saw their yesterday"/);
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
    assert.match(renderedSummary, /Autocorrect fire rate: 1\/3 applied \(33\.3%/);
    assert.match(renderedSummary, /autocorrect-score-below-threshold: 2/);
    assert.match(renderedSummary, /Suggestion stability: 50\.0% unchanged/);
    assert.match(renderedSummary, /Malformed lines skipped: 0/);
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
