import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import {
  classifyKeyboardServicesCapability,
  decodeKeyboardServicesPinSnapshot,
  decodeSlotCatalog,
  encodeKeyboardServicesPinSnapshot,
  nextKeyboardServicesPinRevision,
  selectKeyboardServicesServers,
} from '../lib/keyboard-services-selection.mjs';

function slot(name, { enabled = true, status = 'ready', ...extra } = {}) {
  return {
    name,
    enabled,
    status,
    occupant: `${name}-occupant`,
    profile: `${name}.json`,
    ...extra,
  };
}

function makeCatalog(overrides = {}) {
  const defaults = [
    slot('asr', { status: 'legacy-active', legacy_surface: ['POST /transcribe'] }),
    slot('spelling'),
    slot('vocabulary'),
    slot('prediction', { enabled: false, status: 'disabled', engine: 'gemma' }),
    slot('grammar', { enabled: false, status: 'disabled' }),
  ];
  return decodeSlotCatalog({
    slots: defaults.map(entry => ({ ...entry, ...overrides[entry.name] })),
    future_catalog_field: true,
  });
}

function probe(server, configuredIndex, {
  statusCode = 200,
  catalog = makeCatalog(),
  roundTripTimeMilliseconds = 10,
} = {}) {
  return { server, configuredIndex, statusCode, catalog, roundTripTimeMilliseconds };
}

describe('server-v2 slot catalog decoding and capability classification', () => {
  it('decodes the five slots, optional prediction engine, and ignores unknown metadata', () => {
    const catalog = makeCatalog();

    assert.strictEqual(catalog.slots.length, 5);
    assert.strictEqual(catalog.slots.find(entry => entry.name === 'prediction').engine, 'gemma');
    assert.strictEqual(catalog.slots.find(entry => entry.name === 'asr').legacy_surface, undefined);
    assert.strictEqual(
      classifyKeyboardServicesCapability({ statusCode: 200, catalog }),
      'keyboardServices',
    );

    const noEngineCatalog = decodeSlotCatalog({
      slots: [slot('spelling'), slot('prediction', { enabled: true, status: 'ready' })],
    });
    assert.strictEqual(noEngineCatalog.slots[1].engine, undefined);
  });

  it('uses only HTTP 200 and enabled, ready spelling as the keyboard-services gate', () => {
    const readyCatalog = makeCatalog({
      asr: { enabled: false, status: 'disabled' },
      vocabulary: { enabled: false, status: 'disabled' },
      prediction: { enabled: false, status: 'disabled' },
      grammar: { enabled: true, status: 'ready' },
    });
    assert.strictEqual(
      classifyKeyboardServicesCapability({ statusCode: 200, catalog: readyCatalog }),
      'keyboardServices',
    );

    for (const statusCode of [null, 204, 401, 404, 500, 503]) {
      assert.strictEqual(
        classifyKeyboardServicesCapability({ statusCode, catalog: readyCatalog }),
        'dictationOnly',
      );
    }
    assert.strictEqual(
      classifyKeyboardServicesCapability({ statusCode: 200, catalog: null }),
      'dictationOnly',
    );
    assert.strictEqual(
      classifyKeyboardServicesCapability({ statusCode: 200, catalog: decodeSlotCatalog('{') }),
      'dictationOnly',
    );
    assert.strictEqual(
      classifyKeyboardServicesCapability({
        statusCode: 200,
        catalog: makeCatalog({ spelling: { enabled: false, status: 'ready' } }),
      }),
      'dictationOnly',
    );
    assert.strictEqual(
      classifyKeyboardServicesCapability({
        statusCode: 200,
        catalog: makeCatalog({ spelling: { enabled: true, status: 'deferred' } }),
      }),
      'dictationOnly',
    );
  });
});

describe('keyboard-services server pin selection', () => {
  it('returns no pin or fallbacks when no server is capable', () => {
    const result = selectKeyboardServicesServers([
      probe('disabled-spelling', 0, {
        catalog: makeCatalog({ spelling: { enabled: false, status: 'disabled' } }),
      }),
      probe('not-found', 1, { statusCode: 404, catalog: null }),
      probe('timeout', 2, { statusCode: null, catalog: null }),
    ]);

    assert.deepStrictEqual(result.pinnedServer, null);
    assert.deepStrictEqual(result.rankedFallbackServers, []);
  });

  it('pins a single capable server and carries non-grammar slot availability', () => {
    const result = selectKeyboardServicesServers([
      probe('dictation-only', 0, { statusCode: 404, catalog: null }),
      probe('capable', 1, {
        catalog: makeCatalog({
          vocabulary: { enabled: false, status: 'disabled' },
          prediction: { enabled: true, status: 'ready', engine: 'gemma' },
        }),
      }),
    ]);

    assert.strictEqual(result.pinnedServer, 'capable');
    assert.deepStrictEqual(result.rankedFallbackServers, ['capable']);
    assert.deepStrictEqual(result.slotAvailabilityByServer.capable, {
      spelling: true,
      vocabulary: false,
      prediction: true,
    });
  });

  it('ranks by lower /slots RTT and breaks ties by configured list order', () => {
    const result = selectKeyboardServicesServers([
      probe('tie-later', 2, { roundTripTimeMilliseconds: 12 }),
      probe('slow', 0, { roundTripTimeMilliseconds: 31 }),
      probe('tie-earlier', 1, { roundTripTimeMilliseconds: 12 }),
      probe('fast', 3, { roundTripTimeMilliseconds: 5 }),
    ]);

    assert.strictEqual(result.pinnedServer, 'fast');
    assert.deepStrictEqual(
      result.rankedFallbackServers,
      ['fast', 'tie-earlier', 'tie-later', 'slow'],
    );
  });

  it('excludes breaker-open capable servers before ranking pin and fallback candidates', () => {
    const result = selectKeyboardServicesServers([
      probe('breaker-open-fast', 0, { roundTripTimeMilliseconds: 2 }),
      probe('closed-next', 1, { roundTripTimeMilliseconds: 11 }),
      probe('closed-last', 2, { roundTripTimeMilliseconds: 19 }),
    ], { breakerOpenServers: ['breaker-open-fast'] });

    assert.strictEqual(result.pinnedServer, 'closed-next');
    assert.deepStrictEqual(result.rankedFallbackServers, ['closed-next', 'closed-last']);
  });
});

describe('keyboard-services pin snapshot mirror', () => {
  it('round-trips a versioned snapshot, tolerates extra fields, and advances revisions', () => {
    const snapshot = {
      schemaVersion: 1,
      revision: 4,
      pinnedServer: 'server-a',
      rankedFallbackServers: ['server-a', 'server-b'],
      slotAvailabilityByServer: {
        'server-a': { spelling: true, vocabulary: true, prediction: false },
      },
      future_snapshot_field: 'ignored',
    };
    const encoded = encodeKeyboardServicesPinSnapshot(snapshot);
    const decoded = decodeKeyboardServicesPinSnapshot(encoded);

    assert.deepStrictEqual(decoded, {
      schemaVersion: 1,
      revision: 4,
      pinnedServer: 'server-a',
      rankedFallbackServers: ['server-a', 'server-b'],
      slotAvailabilityByServer: {
        'server-a': { spelling: true, vocabulary: true, prediction: false },
      },
    });
    assert.strictEqual(nextKeyboardServicesPinRevision(decoded.revision), 5);
    assert.strictEqual(decodeKeyboardServicesPinSnapshot('{'), null);
    assert.strictEqual(
      decodeKeyboardServicesPinSnapshot({ ...snapshot, schemaVersion: 2 }),
      null,
    );

    const unpinned = encodeKeyboardServicesPinSnapshot({
      schemaVersion: 1,
      revision: 1,
      pinnedServer: null,
      rankedFallbackServers: [],
      slotAvailabilityByServer: {},
    });
    assert.strictEqual(Object.hasOwn(JSON.parse(unpinned), 'pinnedServer'), false);
    assert.strictEqual(decodeKeyboardServicesPinSnapshot(unpinned).pinnedServer, null);
  });
});
