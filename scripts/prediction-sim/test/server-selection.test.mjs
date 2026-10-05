import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { selectServer } from '../lib/server-selection.mjs';

function outcome(server, configuredIndex, statusCode, modelLoaded, roundTripTimeMilliseconds) {
  return {
    server,
    configuredIndex,
    statusCode,
    modelLoaded,
    roundTripTimeMilliseconds,
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

  it('chooses the first configured responder when no server returns 2xx', () => {
    const selected = selectServer([
      outcome('timed-out-first', 0, null, null, 3000),
      outcome('unauthorized-second', 1, 401, null, 10),
      outcome('forbidden-third', 2, 403, null, 5),
    ]);

    assert.strictEqual(selected.server, 'unauthorized-second');
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
});
