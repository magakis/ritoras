// Pure mirror of the keyboard's post-render merge and pin failover policies.

const MAXIMUM_DISPLAYED_CANDIDATES = 3;
const MAXIMUM_SERVER_COUNT = 64;
const MAXIMUM_SERVER_URL_BYTES = 512;
const MAXIMUM_FAILURES = 255;
const CONSUMED_ENDPOINTS = ['spelling', 'vocabulary', 'prediction'];

function normalizeServer(server) {
  return server.replace(/^\/+|\/+$/g, '');
}

function uniqueServers(servers) {
  const seen = new Set();
  return servers.flatMap(server => {
    const normalized = normalizeServer(server);
    if (!normalized || seen.has(normalized)) return [];
    seen.add(normalized);
    return [normalized];
  });
}

function serverURLIsBounded(server) {
  return new TextEncoder().encode(server).length <= MAXIMUM_SERVER_URL_BYTES;
}

function isAvailable(availability, endpoint) {
  return availability?.[endpoint] === true;
}

function sameAvailability(left, right) {
  const leftServers = Object.keys(left).sort();
  const rightServers = Object.keys(right).sort();
  return leftServers.length === rightServers.length
    && leftServers.every((server, index) => (
      server === rightServers[index]
      && CONSUMED_ENDPOINTS.every(endpoint => (
        left[server][endpoint] === right[server][endpoint]
      ))
    ));
}

function cloneState(state) {
  return {
    revision: state.revision,
    pinnedServer: state.pinnedServer,
    fallbackServers: [...state.fallbackServers],
    activeFallbackIndex: state.activeFallbackIndex,
    consecutiveFailuresByServer: { ...state.consecutiveFailuresByServer },
    slotAvailabilityByServer: { ...state.slotAvailabilityByServer },
    disabledEndpointsByServer: Object.fromEntries(
      Object.entries(state.disabledEndpointsByServer).map(([server, endpoints]) => [
        server,
        new Set(endpoints),
      ]),
    ),
    skippedServers: new Set(state.skippedServers),
    unauthorizedServers: new Set(state.unauthorizedServers),
    failureThreshold: state.failureThreshold,
  };
}

/** Creates the process-local failover state mirrored by KeyboardServicesSuggestionFailover. */
export function createSuggestionFailoverState(failureThreshold = 3) {
  return {
    revision: null,
    pinnedServer: null,
    fallbackServers: [],
    activeFallbackIndex: 0,
    consecutiveFailuresByServer: {},
    slotAvailabilityByServer: {},
    disabledEndpointsByServer: {},
    skippedServers: new Set(),
    unauthorizedServers: new Set(),
    failureThreshold,
  };
}

/** Applies a passive snapshot; a pin outside the current server list fails closed. */
export function updateSuggestionFailoverSnapshot(state, snapshot, configuredServers) {
  const next = cloneState(state);
  const oldRevision = next.revision;
  const oldPinnedServer = next.pinnedServer;
  const oldFallbackServers = [...next.fallbackServers];
  const oldAvailability = next.slotAvailabilityByServer;
  const oldActiveServer = next.fallbackServers[next.activeFallbackIndex] ?? null;
  const configured = new Set(
    uniqueServers(configuredServers.slice(0, MAXIMUM_SERVER_COUNT))
      .filter(server => serverURLIsBounded(server)),
  );
  const nextRevision = snapshot?.revision ?? null;
  const revisionChanged = nextRevision !== null && nextRevision !== next.revision;

  if (revisionChanged) {
    next.activeFallbackIndex = 0;
    next.consecutiveFailuresByServer = {};
    next.disabledEndpointsByServer = {};
    next.skippedServers.clear();
    next.unauthorizedServers.clear();
  }
  next.revision = nextRevision;

  const pin = typeof snapshot?.pinnedServer === 'string'
    ? normalizeServer(snapshot.pinnedServer)
    : null;
  if (snapshot === null
    || snapshot?.schemaVersion !== 1
    || !Number.isSafeInteger(snapshot?.revision)
    || snapshot.revision <= 0
    || !pin
    || !serverURLIsBounded(pin)
    || !configured.has(pin)
    || !Array.isArray(snapshot.rankedFallbackServers)
    || snapshot.rankedFallbackServers.length > MAXIMUM_SERVER_COUNT
    || snapshot.rankedFallbackServers.some(server => !serverURLIsBounded(server))
    || Object.keys(snapshot.slotAvailabilityByServer ?? {}).length > MAXIMUM_SERVER_COUNT
    || Object.keys(snapshot.slotAvailabilityByServer ?? {}).some(
      server => !serverURLIsBounded(server),
    )) {
    next.pinnedServer = null;
    next.fallbackServers = [];
    next.slotAvailabilityByServer = {};
    next.activeFallbackIndex = 0;
    return {
      state: next,
      changed: revisionChanged
        || oldPinnedServer !== null
        || oldFallbackServers.length > 0
        || Object.keys(oldAvailability).length > 0,
    };
  }

  const normalizedFallbacks = uniqueServers(snapshot.rankedFallbackServers);
  if (normalizedFallbacks[0] !== pin) {
    next.pinnedServer = null;
    next.fallbackServers = [];
    next.slotAvailabilityByServer = {};
    next.activeFallbackIndex = 0;
    return {
      state: next,
      changed: revisionChanged
        || oldPinnedServer !== null
        || oldFallbackServers.length > 0
        || Object.keys(oldAvailability).length > 0,
    };
  }

  const fallbackServers = normalizedFallbacks.filter(server => configured.has(server));
  if (fallbackServers[0] !== pin) {
    next.pinnedServer = null;
    next.fallbackServers = [];
    next.slotAvailabilityByServer = {};
    next.activeFallbackIndex = 0;
    return {
      state: next,
      changed: revisionChanged
        || oldPinnedServer !== null
        || oldFallbackServers.length > 0
        || Object.keys(oldAvailability).length > 0,
    };
  }

  const availability = {};
  for (const [server, flags] of Object.entries(snapshot.slotAvailabilityByServer ?? {})) {
    const normalizedServer = normalizeServer(server);
    if (!configured.has(normalizedServer)) continue;
    availability[normalizedServer] = Object.fromEntries(
      CONSUMED_ENDPOINTS.map(endpoint => [endpoint, flags?.[endpoint] === true]),
    );
  }

  if (!revisionChanged) {
    const newActiveIndex = fallbackServers.indexOf(oldActiveServer);
    next.activeFallbackIndex = newActiveIndex >= 0
      ? newActiveIndex
      : Math.min(next.activeFallbackIndex, fallbackServers.length);
  }
  next.pinnedServer = pin;
  next.fallbackServers = fallbackServers;
  next.slotAvailabilityByServer = availability;

  const availabilityChanged = !sameAvailability(oldAvailability, availability);
  return {
    state: next,
    changed: revisionChanged
      || oldRevision !== next.revision
      || oldPinnedServer !== next.pinnedServer
      || oldFallbackServers.length !== fallbackServers.length
      || oldFallbackServers.some((server, index) => server !== fallbackServers[index])
      || availabilityChanged,
  };
}

/** Selects the earliest available endpoint server at or after the active fallback index. */
export function suggestionServerForEndpoint(state, endpoint) {
  for (const server of state.fallbackServers.slice(state.activeFallbackIndex)) {
    if (state.skippedServers.has(server)
      || state.unauthorizedServers.has(server)
      || state.disabledEndpointsByServer[server]?.has(endpoint)
      || !isAvailable(state.slotAvailabilityByServer[server], endpoint)) {
      continue;
    }
    return server;
  }
  return null;
}

/** Applies one response while returning the matching App Group telemetry update. */
export function applySuggestionRequestOutcome(state, { server, endpoint, outcome }) {
  const next = cloneState(state);
  const normalizedServer = normalizeServer(server);
  let telemetryUpdate = null;
  let consecutiveFailures = next.consecutiveFailuresByServer[normalizedServer] ?? 0;
  let didReachThreshold = false;
  let shouldClearAugmentation = false;

  if (outcome === 'success') {
    next.consecutiveFailuresByServer[normalizedServer] = 0;
    next.skippedServers.delete(normalizedServer);
    telemetryUpdate = { server: normalizedServer, outcome: 'success', consecutiveFailures: 0 };
  } else if (outcome === 'failure' || outcome === 'unauthorized') {
    consecutiveFailures = Math.min(consecutiveFailures + 1, MAXIMUM_FAILURES);
    next.consecutiveFailuresByServer[normalizedServer] = consecutiveFailures;
    telemetryUpdate = {
      server: normalizedServer,
      outcome: 'failure',
      consecutiveFailures,
    };
    if (outcome === 'unauthorized') {
      next.unauthorizedServers.add(normalizedServer);
      advancePastServer(next, normalizedServer);
      shouldClearAugmentation = true;
    } else {
      didReachThreshold = consecutiveFailures >= next.failureThreshold
        && !next.skippedServers.has(normalizedServer);
      if (consecutiveFailures >= next.failureThreshold) {
        next.skippedServers.add(normalizedServer);
        advancePastServer(next, normalizedServer);
        shouldClearAugmentation = true;
      }
    }
  } else if (outcome === 'disabled') {
    next.disabledEndpointsByServer[normalizedServer] ??= new Set();
    next.disabledEndpointsByServer[normalizedServer].add(endpoint);
    shouldClearAugmentation = true;
  }

  return {
    state: next,
    telemetryUpdate,
    consecutiveFailures,
    didReachThreshold,
    shouldClearAugmentation,
  };
}

function advancePastServer(state, server) {
  const index = state.fallbackServers.indexOf(server);
  if (index === state.activeFallbackIndex) state.activeFallbackIndex = index + 1;
}

/** Mirrors a render using server results only when their revision and context still match. */
export function mergeSuggestionsForDisplay({
  localCandidates,
  spellingCandidates = [],
  vocabularyCandidates = [],
  predictionCandidates = [],
  localContextToken,
  serverContextToken,
  serverRevisionMatches,
  isEmptyPrefix = false,
}) {
  if (!serverRevisionMatches
    || localContextToken === 0
    || serverContextToken !== localContextToken) {
    return localCandidates.slice(0, MAXIMUM_DISPLAYED_CANDIDATES);
  }

  const localSet = new Set(localCandidates.map(candidate => candidate.toLowerCase()));
  const orderedCandidates = isEmptyPrefix
    ? [
      ...predictionCandidates.filter(candidate => localSet.has(candidate.toLowerCase())),
      ...localCandidates,
    ]
    : [...spellingCandidates, ...vocabularyCandidates, ...localCandidates];
  const seen = new Set();
  return orderedCandidates.filter(candidate => {
    const normalized = candidate.toLowerCase();
    if (seen.has(normalized)) return false;
    seen.add(normalized);
    return true;
  }).slice(0, MAXIMUM_DISPLAYED_CANDIDATES);
}
