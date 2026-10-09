import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { selectServer, ServerSelectionState } from '../lib/server-selection.mjs';

function outcome(
  server,
  configuredIndex,
  statusCode,
  modelLoaded,
  roundTripTimeMilliseconds,
  completion = 'response',
) {
  return {
    server,
    configuredIndex,
    statusCode,
    modelLoaded,
    roundTripTimeMilliseconds,
    completion,
  };
}

describe('WhisperClient server selection ranking (JS port)', () => {
  it('selects the same winner regardless of probe completion order', () => {
    const configuredOutcomes = [
      outcome('server-a', 0, 200, true, 24),
      outcome('server-b', 1, 200, true, 8),
      outcome('server-c', 2, 200, true, 17),
    ];

    for (const completionOrder of [
      configuredOutcomes,
      [configuredOutcomes[2], configuredOutcomes[0], configuredOutcomes[1]],
      [configuredOutcomes[1], configuredOutcomes[2], configuredOutcomes[0]],
    ]) {
      assert.strictEqual(selectServer(completionOrder).server, 'server-b');
    }
  });

  it('ranks any authenticated 2xx above 401 and 403 responses', () => {
    const selected = selectServer([
      outcome('unauthorized', 0, 401, true, 1),
      outcome('forbidden', 1, 403, true, 2),
      outcome('accepted', 2, 200, false, 200),
    ]);

    assert.strictEqual(selected.server, 'accepted');
  });

  it('prefers a warm 2xx server over a faster cold 2xx server', () => {
    const selected = selectServer([
      outcome('cold', 0, 200, false, 1),
      outcome('warm', 1, 200, true, 100),
    ]);

    assert.strictEqual(selected.server, 'warm');
  });

  it('prefers lower RTT among equally warm authenticated servers', () => {
    const selected = selectServer([
      outcome('slow', 0, 200, true, 35),
      outcome('fast', 1, 200, true, 9),
    ]);

    assert.strictEqual(selected.server, 'fast');
  });

  it('uses configured list index as the final tie-break', () => {
    const selected = selectServer([
      outcome('later', 3, 200, true, 12),
      outcome('earlier', 1, 200, true, 12),
    ]);

    assert.strictEqual(selected.server, 'earlier');
  });

  it('returns null when no server returns an authenticated 2xx response', () => {
    const selected = selectServer([
      outcome('timed-out-first', 0, null, null, 3000),
      outcome('unauthorized-second', 1, 401, null, 10),
      outcome('forbidden-third', 2, 403, null, 5),
    ]);

    assert.strictEqual(selected, null);
  });

  it('does not select an unreachable first candidate over a later responder', () => {
    const selected = selectServer([
      outcome('timed-out-first', 0, null, null, 3000),
      outcome('responding-second', 1, 200, false, 40),
    ]);

    assert.strictEqual(selected.server, 'responding-second');
  });

  it('returns null when every probe has no HTTP response', () => {
    const selected = selectServer([
      outcome('timeout-a', 0, null, null, 3000),
      outcome('timeout-b', 1, null, null, 3000),
    ]);

    assert.strictEqual(selected, null);
  });

  it('excludes a round-deadline cutoff from ranking without counting a breaker failure', () => {
    const state = new ServerSelectionState();
    const result = state.completeRound({
      servers: ['fast-server', 'slow-server', 'cut-off-server'],
      outcomes: [
        outcome('fast-server', 0, 200, true, 30),
        outcome('slow-server', 1, 200, true, 750),
        outcome('cut-off-server', 2, null, null, 750, 'roundDeadlineCutoff'),
      ],
      deadlineMilliseconds: 500,
      now: 10_000,
    });

    assert.strictEqual(result.selection.server, 'fast-server');
    assert.deepStrictEqual(
      state.persistedRanking.entries.map(entry => entry.server),
      ['fast-server', 'slow-server', 'cut-off-server'],
    );
    assert.strictEqual(state.breakerState('slow-server').consecutiveFailures, 0);
    assert.strictEqual(state.breakerState('slow-server').openUntil, null);
    assert.strictEqual(state.breakerState('cut-off-server').consecutiveFailures, 0);
  });

  it('counts genuine transport failures and enforces cooldown and half-open transitions', () => {
    const state = new ServerSelectionState({
      failureThreshold: 3,
      cooldownMilliseconds: 1_000,
    });

    for (const now of [0, 100, 200]) {
      assert.strictEqual(state.beginProbe('optiplex', now).allowed, true);
      state.completeRound({
        servers: ['optiplex'],
        outcomes: [outcome('optiplex', 0, null, null, 50, 'transportFailure')],
        deadlineMilliseconds: 500,
        now,
      });
    }

    assert.strictEqual(state.breakerState('optiplex').consecutiveFailures, 3);
    assert.deepStrictEqual(state.beginProbe('optiplex', 1_199), {
      allowed: false,
      state: 'open',
      openUntil: 1_200,
    });
    assert.strictEqual(state.beginProbe('optiplex', 1_200).state, 'half-open');
    assert.strictEqual(state.beginProbe('optiplex', 1_200).state, 'half-open-in-flight');
    assert.strictEqual(state.recordProbeOutcome('optiplex', 'transportFailure', 1_201), 'reopened');
    assert.strictEqual(state.breakerState('optiplex').openUntil, 2_201);

    assert.strictEqual(state.beginProbe('optiplex', 2_201).state, 'half-open');
    assert.strictEqual(state.recordProbeOutcome('optiplex', 'response', 2_202), 'closed');
    assert.strictEqual(state.breakerState('optiplex').consecutiveFailures, 0);
    assert.strictEqual(state.breakerState('optiplex').openUntil, null);
  });

  it('does not persist a ranking for a cancelled round', () => {
    const state = new ServerSelectionState();
    state.completeRound({
      servers: ['existing-server'],
      outcomes: [outcome('existing-server', 0, 200, true, 20)],
      deadlineMilliseconds: 500,
      now: 1,
    });
    const previousRanking = structuredClone(state.persistedRanking);

    const result = state.completeRound({
      servers: ['cancelled-round-server'],
      outcomes: [outcome('cancelled-round-server', 0, 200, true, 15)],
      deadlineMilliseconds: 500,
      now: 2,
      cancelled: true,
    });

    assert.strictEqual(result.rankingPersisted, false);
    assert.deepStrictEqual(state.persistedRanking, previousRanking);
  });
});
