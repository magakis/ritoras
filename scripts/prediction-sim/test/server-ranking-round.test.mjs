import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import {
  acceptKeyboardServicesFailureTelemetry,
  integrateServerRankingRound,
  mergePersistedServerSlotsCatalog,
  selectSlotProbeTargets,
} from '../lib/server-ranking-round.mjs';
import { ServerSelectionState } from '../lib/server-selection.mjs';
import {
  applySuggestionRequestOutcome,
  createSuggestionFailoverState,
} from '../lib/suggestion-augmentation.mjs';

function makeCatalog(overrides = {}) {
  const defaults = [
    { name: 'spelling', enabled: true, status: 'ready' },
    { name: 'vocabulary', enabled: true, status: 'ready' },
    { name: 'prediction', enabled: false, status: 'disabled' },
    { name: 'grammar', enabled: true, status: 'ready' },
    { name: 'asr', enabled: false, status: 'legacy-active' },
  ];
  return {
    slots: defaults.map(slot => ({ ...slot, ...overrides[slot.name] })),
  };
}

function statusOutcome(server, configuredIndex, {
  statusCode = 200,
  modelLoaded = true,
  roundTripTimeMilliseconds = 10,
  completion = 'response',
} = {}) {
  return {
    server,
    configuredIndex,
    statusCode,
    modelLoaded,
    roundTripTimeMilliseconds,
    completion,
  };
}

function slotOutcome(server, configuredIndex, {
  statusCode = 200,
  catalog = makeCatalog(),
  roundTripTimeMilliseconds = 10,
  completion = 'response',
} = {}) {
  return {
    server,
    configuredIndex,
    statusCode,
    catalog,
    roundTripTimeMilliseconds,
    completion,
  };
}

function telemetry(revision, consecutiveFailuresByServer) {
  return { schemaVersion: 1, revision, consecutiveFailuresByServer };
}

function integrate(overrides = {}) {
  return integrateServerRankingRound({
    configuredServers: ['server-a', 'server-b'],
    breakerEligibleServers: ['server-a', 'server-b'],
    statusOutcomes: [
      statusOutcome('server-a', 0, { roundTripTimeMilliseconds: 15 }),
      statusOutcome('server-b', 1, { roundTripTimeMilliseconds: 30 }),
    ],
    slotOutcomes: [
      slotOutcome('server-a', 0, { roundTripTimeMilliseconds: 5 }),
      slotOutcome('server-b', 1, { roundTripTimeMilliseconds: 12 }),
    ],
    timestamp: 100,
    ...overrides,
  });
}

describe('shared server-ranking round integration', () => {
  it('selects /slots targets from the same breaker-approved server set in configured order', () => {
    assert.deepStrictEqual(
      selectSlotProbeTargets(
        ['//server-a/', 'server-b', 'server-c', 'server-a'],
        ['server-c', 'server-a'],
      ),
      ['server-a', 'server-c'],
    );
  });

  it('keeps dictation selection independent of /slots failures and round cutoffs', () => {
    const state = new ServerSelectionState();
    const statuses = [
      statusOutcome('server-a', 0, { roundTripTimeMilliseconds: 15 }),
      statusOutcome('server-b', 1, { roundTripTimeMilliseconds: 30 }),
    ];
    const baseline = integrate({ statusOutcomes: statuses, slotOutcomes: [] });
    const failedSlots = integrate({
      statusOutcomes: statuses,
      slotOutcomes: [
        slotOutcome('server-a', 0, {
          statusCode: null,
          catalog: null,
          roundTripTimeMilliseconds: 80,
          completion: 'transportFailure',
        }),
        slotOutcome('server-b', 1, {
          statusCode: null,
          catalog: null,
          roundTripTimeMilliseconds: 800,
          completion: 'roundDeadlineCutoff',
        }),
      ],
    });

    state.completeRound({
      servers: ['server-a', 'server-b'],
      outcomes: statuses,
      deadlineMilliseconds: 500,
      now: 1,
    });
    assert.strictEqual(failedSlots.dictationSelection.server, baseline.dictationSelection.server);
    assert.strictEqual(failedSlots.dictationSelection.server, 'server-a');
    assert.strictEqual(failedSlots.snapshot.pinnedServer, null);
    assert.strictEqual(state.breakerState('server-a').consecutiveFailures, 0);
    assert.strictEqual(state.breakerState('server-b').consecutiveFailures, 0);
  });

  it('demotes threshold telemetry behind healthy candidates while keeping availability', () => {
    const flaggedTelemetry = telemetry(4, { 'server-a': 3 });
    const demoted = integrate({ failureTelemetry: flaggedTelemetry });
    const emptyStore = integrate({
      failureTelemetry: telemetry(5, {}),
    });
    const absentStore = integrate({ failureTelemetry: null });
    const staleStore = integrate({
      previousFailureTelemetry: telemetry(8, { 'server-a': 3 }),
      failureTelemetry: telemetry(7, {}),
    });

    assert.strictEqual(demoted.snapshot.pinnedServer, 'server-b');
    assert.deepStrictEqual(demoted.snapshot.rankedFallbackServers, ['server-b', 'server-a']);
    assert.deepStrictEqual(demoted.snapshot.slotAvailabilityByServer['server-a'], {
      spelling: true,
      vocabulary: true,
      prediction: false,
    });
    assert.strictEqual(emptyStore.snapshot.pinnedServer, 'server-a');
    assert.strictEqual(absentStore.snapshot.pinnedServer, 'server-a');
    assert.strictEqual(staleStore.snapshot.pinnedServer, 'server-b');
    assert.deepStrictEqual(staleStore.snapshot.rankedFallbackServers, ['server-b', 'server-a']);
    assert.strictEqual(integrate({
      failureTelemetry: telemetry(6, { 'server-a': 2 }),
    }).snapshot.pinnedServer, 'server-a');
  });

  it('keeps the sole telemetry-flagged capable server pinned and available as fallback', () => {
    const onlyFlagged = integrate({
      configuredServers: ['server-a'],
      breakerEligibleServers: ['server-a'],
      statusOutcomes: [statusOutcome('server-a', 0)],
      slotOutcomes: [slotOutcome('server-a', 0)],
      failureTelemetry: telemetry(4, { 'server-a': 3 }),
    });

    assert.strictEqual(onlyFlagged.snapshot.pinnedServer, 'server-a');
    assert.deepStrictEqual(onlyFlagged.snapshot.rankedFallbackServers, ['server-a']);
  });

  it('restores normal pin priority after extension recordSuccess reports zero failures', () => {
    const flaggedTelemetry = telemetry(4, { 'server-a': 3 });
    const extensionState = createSuggestionFailoverState();
    extensionState.consecutiveFailuresByServer['server-a'] = 3;
    const success = applySuggestionRequestOutcome(extensionState, {
      server: 'server-a',
      endpoint: 'spelling',
      outcome: 'success',
    });
    const recoveredTelemetry = telemetry(5, {
      [success.telemetryUpdate.server]: success.telemetryUpdate.consecutiveFailures,
    });
    const recovered = integrate({
      previousFailureTelemetry: flaggedTelemetry,
      failureTelemetry: recoveredTelemetry,
    });

    assert.strictEqual(success.state.consecutiveFailuresByServer['server-a'], 0);
    assert.strictEqual(recovered.snapshot.pinnedServer, 'server-a');
    assert.deepStrictEqual(recovered.snapshot.rankedFallbackServers, ['server-a', 'server-b']);
  });

  it('accepts only valid monotonic telemetry revisions and treats absent data as no effect', () => {
    const current = telemetry(7, { 'server-a': 3 });
    assert.deepStrictEqual(
      acceptKeyboardServicesFailureTelemetry(current, telemetry(6, {})),
      current,
    );
    assert.deepStrictEqual(
      acceptKeyboardServicesFailureTelemetry(current, telemetry(8, {})),
      telemetry(8, {}),
    );
    assert.strictEqual(acceptKeyboardServicesFailureTelemetry(current, null), null);
    assert.strictEqual(
      acceptKeyboardServicesFailureTelemetry(current, telemetry(0, { 'server-a': 3 })),
      null,
    );
  });

  it('publishes only on pin, fallback, availability, or configured-list changes', () => {
    const first = integrate();
    const unchanged = integrate({
      previousSnapshot: first.snapshot,
      previousCatalog: first.catalog,
      timestamp: 200,
    });
    const changedAvailability = integrate({
      previousSnapshot: first.snapshot,
      previousCatalog: first.catalog,
      slotOutcomes: [
        slotOutcome('server-a', 0, {
          catalog: makeCatalog({ vocabulary: { enabled: false, status: 'disabled' } }),
          roundTripTimeMilliseconds: 5,
        }),
        slotOutcome('server-b', 1, { roundTripTimeMilliseconds: 12 }),
      ],
    });
    const changedPin = integrate({
      previousSnapshot: first.snapshot,
      previousCatalog: first.catalog,
      slotOutcomes: [
        slotOutcome('server-a', 0, { roundTripTimeMilliseconds: 20 }),
        slotOutcome('server-b', 1, { roundTripTimeMilliseconds: 5 }),
      ],
    });
    const reorderedServers = integrate({
      configuredServers: ['server-b', 'server-a'],
      breakerEligibleServers: ['server-a', 'server-b'],
      previousSnapshot: first.snapshot,
      previousCatalog: first.catalog,
    });

    assert.strictEqual(first.snapshotChanged, true);
    assert.strictEqual(unchanged.snapshotChanged, false);
    assert.strictEqual(changedAvailability.snapshotChanged, true);
    assert.strictEqual(changedPin.snapshotChanged, true);
    assert.strictEqual(changedPin.snapshot.pinnedServer, 'server-b');
    assert.strictEqual(reorderedServers.snapshotChanged, true);
  });

  it('compares server membership without order when no prior catalog is available', () => {
    const first = integrate();
    const reorderedServers = integrate({
      configuredServers: ['server-b', 'server-a'],
      breakerEligibleServers: ['server-a', 'server-b'],
      previousSnapshot: first.snapshot,
      previousCatalog: null,
      timestamp: 200,
    });

    assert.strictEqual(reorderedServers.snapshotChanged, false);
  });

  it('retains last-known catalogs on failures and drops servers removed from configuration', () => {
    const previousCatalog = {
      schemaVersion: 1,
      timestamp: 50,
      entries: [
        {
          server: 'server-a',
          catalog: makeCatalog({ vocabulary: { enabled: false, status: 'disabled' } }),
          catalogTimestamp: 40,
          lastProbeTimestamp: 45,
        },
        {
          server: 'removed-server',
          catalog: makeCatalog(),
          catalogTimestamp: 35,
          lastProbeTimestamp: 45,
        },
      ],
    };
    const merged = mergePersistedServerSlotsCatalog({
      configuredServers: ['server-a', 'server-b'],
      outcomes: [
        slotOutcome('server-a', 0, {
          statusCode: 503,
          catalog: null,
          roundTripTimeMilliseconds: 20,
        }),
        slotOutcome('server-b', 1, {
          catalog: makeCatalog({ prediction: { enabled: true, status: 'ready' } }),
          roundTripTimeMilliseconds: 12,
        }),
      ],
      previousCatalog,
      timestamp: 100,
    });

    assert.deepStrictEqual(merged.entries.map(entry => entry.server), ['server-a', 'server-b']);
    assert.strictEqual(merged.entries[0].catalogTimestamp, 40);
    assert.strictEqual(merged.entries[0].lastProbeTimestamp, 100);
    assert.strictEqual(merged.entries[0].catalog.slots[1].enabled, false);
    assert.strictEqual(merged.entries[1].catalogTimestamp, 100);
    assert.strictEqual(merged.entries[1].catalog.slots[2].enabled, true);
  });
});
