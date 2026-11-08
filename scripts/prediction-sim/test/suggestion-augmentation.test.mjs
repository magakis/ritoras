import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import {
  applySuggestionRequestOutcome,
  createSuggestionFailoverState,
  fallbackSuggestionsForDisplay,
  mergeSuggestionsForDisplay,
  suggestionServerForEndpoint,
  updateSuggestionFailoverSnapshot,
} from '../lib/suggestion-augmentation.mjs';

function snapshot({
  revision = 1,
  pinnedServer = 'server-a',
  rankedFallbackServers = ['server-a', 'server-b'],
  availability = {
    'server-a': { spelling: true, vocabulary: true, prediction: true },
    'server-b': { spelling: true, vocabulary: true, prediction: true },
  },
} = {}) {
  return {
    schemaVersion: 1,
    revision,
    pinnedServer,
    rankedFallbackServers,
    slotAvailabilityByServer: availability,
  };
}

function configured(state = createSuggestionFailoverState(), next = snapshot(), servers = [
  'server-a',
  'server-b',
]) {
  return updateSuggestionFailoverSnapshot(state, next, servers).state;
}

describe('server suggestion display merge', () => {
  it('orders spelling before vocabulary and local candidates, then de-duplicates and caps the bar', () => {
    const displayed = mergeSuggestionsForDisplay({
      localCandidates: ['local', 'typo', 'another'],
      spellingCandidates: ['fixed', 'local'],
      vocabularyCandidates: ['alias', 'fixed'],
      localContextToken: 4,
      serverContextToken: 4,
      serverRevisionMatches: true,
    });

    assert.deepStrictEqual(displayed, ['fixed', 'local', 'alias']);
  });

  it('reorders only on-device next-word candidates and never suppresses empty-prefix defaults', () => {
    const ranked = mergeSuggestionsForDisplay({
      localCandidates: ['the', 'I', 'and'],
      predictionCandidates: ['and', 'unrequested'],
      localContextToken: 7,
      serverContextToken: 7,
      serverRevisionMatches: true,
      isEmptyPrefix: true,
    });
    const fallback = mergeSuggestionsForDisplay({
      localCandidates: ['the', 'I', 'and'],
      localContextToken: 7,
      serverContextToken: 7,
      serverRevisionMatches: true,
      isEmptyPrefix: true,
    });

    assert.deepStrictEqual(ranked, ['and', 'the', 'I']);
    assert.deepStrictEqual(fallback, ['the', 'I', 'and']);
  });

  it('keeps an applied augmentation across a later same-context local render', () => {
    const displayed = mergeSuggestionsForDisplay({
      localCandidates: ['new local', 'old local', 'third local'],
      spellingCandidates: ['server result', 'second server result'],
      localContextToken: 12,
      serverContextToken: 12,
      serverRevisionMatches: true,
    });
    const stale = mergeSuggestionsForDisplay({
      localCandidates: ['new local', 'old local'],
      spellingCandidates: ['server result'],
      localContextToken: 13,
      serverContextToken: 12,
      serverRevisionMatches: true,
    });

    assert.deepStrictEqual(displayed, ['server result', 'second server result', 'new local']);
    assert.deepStrictEqual(stale, ['new local', 'old local']);
  });

  it('uses server candidates when the local bar is empty without changing empty-prefix defaults on failure', () => {
    const filled = mergeSuggestionsForDisplay({
      localCandidates: [],
      spellingCandidates: ['server-only', 'another'],
      localContextToken: 2,
      serverContextToken: 2,
      serverRevisionMatches: true,
    });
    const unchanged = mergeSuggestionsForDisplay({
      localCandidates: ['the', 'I', 'and'],
      localContextToken: 2,
      serverContextToken: 2,
      serverRevisionMatches: true,
      isEmptyPrefix: true,
    });

    assert.deepStrictEqual(filled, ['server-only', 'another']);
    assert.deepStrictEqual(unchanged, ['the', 'I', 'and']);
  });

  it('strict remote-only displays only server candidates for mid-word context', () => {
    const displayed = mergeSuggestionsForDisplay({
      localCandidates: ['local typo', 'local completion'],
      spellingCandidates: ['server correction'],
      vocabularyCandidates: ['server term'],
      localContextToken: 20,
      serverContextToken: 20,
      serverRevisionMatches: true,
      localEpoch: 1,
      serverEpoch: 1,
      strictRemoteOnly: true,
    });

    assert.deepStrictEqual(displayed, ['server correction', 'server term']);
  });

  it('strict remote-only preserves the server-ranked next-word order', () => {
    // Prediction rank only reorders the client-supplied pool; overlap is
    // expected. Filtering it would empty every word-boundary bar and mislead diagnosis.
    const displayed = mergeSuggestionsForDisplay({
      localCandidates: ['the', 'I', 'and'],
      predictionCandidates: ['and', 'the'],
      localContextToken: 21,
      serverContextToken: 21,
      serverRevisionMatches: true,
      isEmptyPrefix: true,
      localEpoch: 1,
      serverEpoch: 1,
      strictRemoteOnly: true,
    });

    assert.deepStrictEqual(displayed, ['and', 'the']);
  });

  it('strict remote-only leaves the bar empty when the current context has no server result', () => {
    const midWord = mergeSuggestionsForDisplay({
      localCandidates: ['local suggestion'],
      localContextToken: 22,
      serverContextToken: 22,
      serverRevisionMatches: true,
      strictRemoteOnly: true,
    });
    const nextWord = mergeSuggestionsForDisplay({
      localCandidates: ['the', 'I', 'and'],
      localContextToken: 22,
      serverContextToken: 22,
      serverRevisionMatches: true,
      isEmptyPrefix: true,
      strictRemoteOnly: true,
    });

    assert.deepStrictEqual(midWord, []);
    assert.deepStrictEqual(nextWord, []);
  });

  it('strict remote-only suppresses the local cached fallback path', () => {
    const strictFallback = fallbackSuggestionsForDisplay({
      localCandidates: ['cached local', 'another local'],
      strictRemoteOnly: true,
    });
    const normalFallback = fallbackSuggestionsForDisplay({
      localCandidates: ['cached local', 'another local'],
      strictRemoteOnly: false,
    });

    assert.deepStrictEqual(strictFallback, []);
    assert.deepStrictEqual(normalFallback, ['cached local', 'another local']);
  });

  it('strict remote-only is opt-in and strict-off output stays merged', () => {
    const displayed = mergeSuggestionsForDisplay({
      localCandidates: ['local suggestion', 'another local'],
      spellingCandidates: ['server correction'],
      localContextToken: 23,
      serverContextToken: 23,
      serverRevisionMatches: true,
      strictRemoteOnly: false,
    });

    assert.deepStrictEqual(displayed, ['server correction', 'local suggestion', 'another local']);
  });

  it('strict remote-only keeps server results across a later same-context local render', () => {
    const displayed = mergeSuggestionsForDisplay({
      localCandidates: ['new local', 'old local'],
      spellingCandidates: ['server result'],
      localContextToken: 24,
      serverContextToken: 24,
      serverRevisionMatches: true,
      localEpoch: 2,
      serverEpoch: 2,
      strictRemoteOnly: true,
    });
    const stale = mergeSuggestionsForDisplay({
      localCandidates: ['new local', 'old local'],
      spellingCandidates: ['server result'],
      localContextToken: 24,
      serverContextToken: 24,
      serverRevisionMatches: true,
      localEpoch: 3,
      serverEpoch: 2,
      strictRemoteOnly: true,
    });

    assert.deepStrictEqual(displayed, ['server result']);
    assert.deepStrictEqual(stale, []);
  });
});

describe('keyboard-services failover and latches', () => {
  it('treats a pin outside the current server list as on-device-only', () => {
    const state = configured(
      createSuggestionFailoverState(),
      snapshot(),
      ['server-b'],
    );

    assert.strictEqual(state.pinnedServer, null);
    assert.strictEqual(suggestionServerForEndpoint(state, 'spelling'), null);
  });

  it('selects the first fallback that advertises an optional endpoint', () => {
    const state = configured(
      createSuggestionFailoverState(),
      snapshot({
        availability: {
          'server-a': { spelling: true, vocabulary: false, prediction: false },
          'server-b': { spelling: true, vocabulary: true, prediction: true },
        },
      }),
    );

    assert.strictEqual(suggestionServerForEndpoint(state, 'spelling'), 'server-a');
    assert.strictEqual(suggestionServerForEndpoint(state, 'vocabulary'), 'server-b');
  });

  it('advances after three consecutive failures and emits failure telemetry updates', () => {
    let state = configured();
    const telemetry = [];
    for (let count = 1; count <= 3; count += 1) {
      const result = applySuggestionRequestOutcome(state, {
        server: 'server-a',
        endpoint: 'spelling',
        outcome: 'failure',
      });
      state = result.state;
      telemetry.push(result.telemetryUpdate);
      assert.strictEqual(result.consecutiveFailures, count);
      assert.strictEqual(result.didReachThreshold, count === 3);
      assert.strictEqual(result.shouldClearAugmentation, count === 3);
    }

    assert.strictEqual(suggestionServerForEndpoint(state, 'spelling'), 'server-b');
    assert.deepStrictEqual(telemetry.map(report => report.consecutiveFailures), [1, 2, 3]);
  });

  it('latches disabled endpoints until revision change and tolerates 422 without telemetry', () => {
    let state = configured();
    let result = applySuggestionRequestOutcome(state, {
      server: 'server-a',
      endpoint: 'spelling',
      outcome: 'disabled',
    });
    state = result.state;
    assert.strictEqual(result.telemetryUpdate, null);
    assert.strictEqual(result.shouldClearAugmentation, true);
    assert.strictEqual(suggestionServerForEndpoint(state, 'spelling'), 'server-b');
    assert.strictEqual(suggestionServerForEndpoint(state, 'vocabulary'), 'server-a');

    result = applySuggestionRequestOutcome(state, {
      server: 'server-b',
      endpoint: 'spelling',
      outcome: 'tolerated',
    });
    assert.strictEqual(result.telemetryUpdate, null);
    assert.strictEqual(result.shouldClearAugmentation, false);
    assert.strictEqual(suggestionServerForEndpoint(result.state, 'spelling'), 'server-b');

    const refreshed = configured(state, snapshot({ revision: 2 }));
    assert.strictEqual(suggestionServerForEndpoint(refreshed, 'spelling'), 'server-a');
  });

  it('skips 401 servers until a new revision and records later recovery as zero', () => {
    let state = configured();
    let result = applySuggestionRequestOutcome(state, {
      server: 'server-a',
      endpoint: 'spelling',
      outcome: 'unauthorized',
    });
    state = result.state;
    assert.strictEqual(result.telemetryUpdate.consecutiveFailures, 1);
    assert.strictEqual(result.shouldClearAugmentation, true);
    assert.strictEqual(suggestionServerForEndpoint(state, 'spelling'), 'server-b');
    assert.strictEqual(
      suggestionServerForEndpoint(configured(state, snapshot()), 'spelling'),
      'server-b',
    );

    state = configured(state, snapshot({ revision: 2 }));
    assert.strictEqual(suggestionServerForEndpoint(state, 'spelling'), 'server-a');

    result = applySuggestionRequestOutcome(state, {
      server: 'server-a',
      endpoint: 'spelling',
      outcome: 'success',
    });
    assert.strictEqual(result.state.consecutiveFailuresByServer['server-a'], 0);
    assert.deepStrictEqual(result.telemetryUpdate, {
      server: 'server-a',
      outcome: 'success',
      consecutiveFailures: 0,
    });
    assert.strictEqual(result.shouldClearAugmentation, false);
  });

  it('exhausts the ordered list after each server reaches the failure threshold', () => {
    let state = configured();
    for (const server of ['server-a', 'server-b']) {
      for (let count = 0; count < 3; count += 1) {
        state = applySuggestionRequestOutcome(state, {
          server,
          endpoint: 'spelling',
          outcome: 'failure',
        }).state;
      }
    }

    assert.strictEqual(state.activeFallbackIndex, 2);
    assert.strictEqual(suggestionServerForEndpoint(state, 'spelling'), null);
    const refreshed = configured(state, snapshot({ revision: 2 }));
    assert.strictEqual(suggestionServerForEndpoint(refreshed, 'spelling'), 'server-a');
  });
});
