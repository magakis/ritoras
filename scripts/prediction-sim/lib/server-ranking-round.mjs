// Pure mirror of the app's same-round dictation and keyboard-services integration.

import { selectKeyboardServicesServers } from './keyboard-services-selection.mjs';
import { selectServer } from './server-selection.mjs';

const TELEMETRY_SCHEMA_VERSION = 1;
const TELEMETRY_MAXIMUM_SERVER_COUNT = 64;
const TELEMETRY_MAXIMUM_FAILURES = 255;
const DEFAULT_FAILURE_THRESHOLD = 3;
const CONSUMED_SLOTS = ['spelling', 'vocabulary', 'prediction'];

function normalizeUniqueServers(servers) {
  const seen = new Set();
  return servers.flatMap(server => {
    const normalized = server.replace(/^\/+|\/+$/g, '');
    if (!normalized || seen.has(normalized)) return [];
    seen.add(normalized);
    return [normalized];
  });
}

function validFailureTelemetry(telemetry) {
  if (telemetry === null || typeof telemetry !== 'object'
    || telemetry.schemaVersion !== TELEMETRY_SCHEMA_VERSION
    || !Number.isSafeInteger(telemetry.revision)
    || telemetry.revision < 1
    || telemetry.consecutiveFailuresByServer === null
    || typeof telemetry.consecutiveFailuresByServer !== 'object'
    || Array.isArray(telemetry.consecutiveFailuresByServer)) {
    return false;
  }
  const entries = Object.entries(telemetry.consecutiveFailuresByServer);
  return entries.length <= TELEMETRY_MAXIMUM_SERVER_COUNT
    && entries.every(([server, failures]) => (
      server.length > 0
      && Number.isInteger(failures)
      && failures >= 0
      && failures <= TELEMETRY_MAXIMUM_FAILURES
    ));
}

function completedWithinRound(outcome, deadlineMilliseconds) {
  return outcome.completion !== 'roundDeadlineCutoff'
    && outcome.completion !== 'cancelled'
    && outcome.roundTripTimeMilliseconds <= deadlineMilliseconds;
}

function slotAvailability(outcome) {
  const catalog = outcome?.statusCode === 200 ? outcome.catalog : null;
  const slots = catalog?.slots ?? [];
  const availability = {};
  for (const name of CONSUMED_SLOTS) {
    const slot = slots.find(candidate => candidate.name === name);
    availability[name] = slot?.enabled === true && slot.status === 'ready';
  }
  return availability;
}

function sameArray(left, right) {
  return left.length === right.length && left.every((value, index) => value === right[index]);
}

function sameSet(left, right) {
  const leftSet = new Set(left);
  const rightSet = new Set(right);
  return leftSet.size === rightSet.size
    && [...leftSet].every(value => rightSet.has(value));
}

function sameAvailability(left, right) {
  const leftServers = Object.keys(left).sort();
  const rightServers = Object.keys(right).sort();
  return sameArray(leftServers, rightServers)
    && leftServers.every(server => CONSUMED_SLOTS.every(slot => (
      left[server][slot] === right[server][slot]
    )));
}

/**
 * Returns configured servers eligible for a /slots request, in configured order.
 * The caller supplies the breaker-approved set from the shared status round.
 */
export function selectSlotProbeTargets(configuredServers, breakerEligibleServers) {
  const eligible = new Set(normalizeUniqueServers(breakerEligibleServers));
  return normalizeUniqueServers(configuredServers).filter(server => eligible.has(server));
}

/**
 * Keeps telemetry revisions monotonic in-process; an absent or invalid store is a no-op.
 */
export function acceptKeyboardServicesFailureTelemetry(previous, incoming) {
  if (!validFailureTelemetry(incoming)) return null;
  if (validFailureTelemetry(previous) && previous.revision >= incoming.revision) {
    return previous;
  }
  return incoming;
}

/**
 * Merges current probe observations into the app-local, last-known catalog.
 * Failed or missing probes retain the last decoded catalog for still-configured servers.
 */
export function mergePersistedServerSlotsCatalog({
  configuredServers,
  outcomes,
  previousCatalog = null,
  timestamp,
}) {
  const servers = normalizeUniqueServers(configuredServers);
  const previousEntries = new Map(
    (previousCatalog?.entries ?? []).map(entry => [entry.server, entry]),
  );
  const outcomesByServer = new Map(outcomes.map(outcome => [outcome.server, outcome]));

  return {
    schemaVersion: 1,
    timestamp,
    entries: servers.map(server => {
      const previous = previousEntries.get(server);
      const outcome = outcomesByServer.get(server);
      const successfulCatalog = outcome?.statusCode === 200 && outcome.catalog
        ? outcome.catalog
        : null;
      return {
        server,
        catalog: successfulCatalog ?? previous?.catalog ?? null,
        catalogTimestamp: successfulCatalog ? timestamp : previous?.catalogTimestamp ?? null,
        lastProbeTimestamp: outcome ? timestamp : previous?.lastProbeTimestamp ?? null,
      };
    }),
  };
}

/**
 * Mirrors a completed shared round. /status input alone determines dictation;
 * only timely, breaker-eligible /slots results can affect the keyboard pin.
 */
export function integrateServerRankingRound({
  configuredServers,
  breakerEligibleServers,
  breakerOpenServers = [],
  statusOutcomes,
  slotOutcomes,
  failureTelemetry = null,
  previousFailureTelemetry = null,
  failureThreshold = DEFAULT_FAILURE_THRESHOLD,
  previousSnapshot = null,
  previousCatalog = null,
  deadlineMilliseconds = 500,
  timestamp,
}) {
  const servers = normalizeUniqueServers(configuredServers);
  const breakerOpen = new Set(normalizeUniqueServers(breakerOpenServers));
  const probeTargets = new Set(selectSlotProbeTargets(servers, breakerEligibleServers));
  const timelyStatusOutcomes = statusOutcomes.filter(outcome => (
    outcome.completion === 'response'
    && outcome.roundTripTimeMilliseconds <= deadlineMilliseconds
  ));
  const dictationSelection = selectServer(timelyStatusOutcomes);
  const configuredIndexByServer = new Map(servers.map((server, index) => [server, index]));
  const timelySlotOutcomes = slotOutcomes
    .filter(outcome => (
      probeTargets.has(outcome.server)
      && completedWithinRound(outcome, deadlineMilliseconds)
    ))
    .map(outcome => ({
      ...outcome,
      configuredIndex: configuredIndexByServer.get(outcome.server),
    }));
  const outcomesByServer = new Map(timelySlotOutcomes.map(outcome => [outcome.server, outcome]));
  const acceptedFailureTelemetry = acceptKeyboardServicesFailureTelemetry(
    previousFailureTelemetry,
    failureTelemetry,
  );
  const telemetryIsValid = validFailureTelemetry(acceptedFailureTelemetry);
  const telemetryFailures = telemetryIsValid
    ? acceptedFailureTelemetry.consecutiveFailuresByServer
    : {};
  const pinSelection = selectKeyboardServicesServers(timelySlotOutcomes, {
    breakerOpenServers: breakerOpen,
  });
  const preferredFallbackServers = pinSelection.rankedFallbackServers.filter(server => (
    (telemetryFailures[server] ?? 0) < failureThreshold
  ));
  const telemetryDemotedServers = pinSelection.rankedFallbackServers.filter(server => (
    (telemetryFailures[server] ?? 0) >= failureThreshold
  ));
  const rankedFallbackServers = [...preferredFallbackServers, ...telemetryDemotedServers];
  const pinnedServer = preferredFallbackServers[0]
    ?? telemetryDemotedServers[0]
    ?? null;
  const slotAvailabilityByServer = Object.fromEntries(
    servers.map(server => [server, slotAvailability(outcomesByServer.get(server))]),
  );
  const snapshot = {
    schemaVersion: 1,
    revision: previousSnapshot?.revision ?? 0,
    pinnedServer,
    rankedFallbackServers,
    slotAvailabilityByServer,
  };
  const catalog = mergePersistedServerSlotsCatalog({
    configuredServers: servers,
    outcomes: timelySlotOutcomes,
    previousCatalog,
    timestamp,
  });
  const previousServers = previousCatalog
    ? previousCatalog.entries.map(entry => entry.server)
    : Object.keys(previousSnapshot?.slotAvailabilityByServer ?? {});
  const serverListChanged = previousCatalog
    ? !sameArray(previousServers, servers)
    : !sameSet(previousServers, servers);
  const snapshotChanged = previousSnapshot === null
    || serverListChanged
    || previousSnapshot.pinnedServer !== snapshot.pinnedServer
    || !sameArray(
      previousSnapshot.rankedFallbackServers,
      snapshot.rankedFallbackServers,
    )
    || !sameAvailability(
      previousSnapshot.slotAvailabilityByServer,
      snapshot.slotAvailabilityByServer,
    );

  return {
    dictationSelection,
    slotProbeTargets: [...probeTargets],
    timelySlotOutcomes,
    snapshot,
    snapshotChanged,
    catalog,
  };
}
