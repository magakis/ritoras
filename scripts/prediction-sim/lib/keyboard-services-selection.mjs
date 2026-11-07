// Pure-logic mirror of the /slots capability and keyboard-services pin rules.

const SNAPSHOT_SCHEMA_VERSION = 1;
const CONSUMED_SLOTS = ['spelling', 'vocabulary', 'prediction'];

function isRecord(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

function optionalString(value, key, target) {
  if (!(key in value) || value[key] === null) return true;
  if (typeof value[key] !== 'string') return false;
  target[key] = value[key];
  return true;
}

function isReady(catalog, slotName) {
  const slot = catalog?.slots?.find(candidate => candidate.name === slotName);
  return slot?.enabled === true && slot.status === 'ready';
}

/**
 * Decodes the server-v2 slots envelope, ignoring unknown fields like Swift Codable.
 * Malformed entries return null instead of yielding partial capability state.
 *
 * @param {string|object} value JSON response text or its parsed value.
 * @returns {{slots: object[]}|null}
 */
export function decodeSlotCatalog(value) {
  let parsed = value;
  if (typeof parsed === 'string') {
    try {
      parsed = JSON.parse(parsed);
    } catch {
      return null;
    }
  }
  if (!isRecord(parsed) || !Array.isArray(parsed.slots)) return null;

  const slots = [];
  for (const rawSlot of parsed.slots) {
    if (!isRecord(rawSlot)
      || typeof rawSlot.name !== 'string'
      || typeof rawSlot.enabled !== 'boolean'
      || typeof rawSlot.status !== 'string') {
      return null;
    }
    const slot = {
      name: rawSlot.name,
      enabled: rawSlot.enabled,
      status: rawSlot.status,
    };
    if (!optionalString(rawSlot, 'occupant', slot)
      || !optionalString(rawSlot, 'profile', slot)
      || !optionalString(rawSlot, 'engine', slot)) {
      return null;
    }
    slots.push(slot);
  }
  return { slots };
}

/**
 * Classifies only HTTP 200 catalogs with enabled, ready spelling as keyboard-capable.
 *
 * @param {{statusCode: number|null, catalog: object|null}} outcome
 * @returns {'keyboardServices'|'dictationOnly'}
 */
export function classifyKeyboardServicesCapability({ statusCode, catalog }) {
  return statusCode === 200 && isReady(catalog, 'spelling')
    ? 'keyboardServices'
    : 'dictationOnly';
}

function slotAvailability(outcome) {
  const catalog = outcome.statusCode === 200 ? outcome.catalog : null;
  return Object.fromEntries(
    CONSUMED_SLOTS.map(slotName => [slotName, isReady(catalog, slotName)]),
  );
}

/**
 * Ranks capable servers by /slots RTT and configured order, excluding open breakers.
 * Returns the pin, ordered fallbacks, and service-slot flags for probed servers.
 *
 * @param {object[]} outcomes Probe results with server, configuredIndex, statusCode,
 *   catalog, and roundTripTimeMilliseconds.
 * @param {{breakerOpenServers?: Iterable<string>}} options
 * @returns {{pinnedServer: string|null, rankedFallbackServers: string[], slotAvailabilityByServer: object}}
 */
export function selectKeyboardServicesServers(outcomes, { breakerOpenServers = [] } = {}) {
  const openServers = new Set(breakerOpenServers);
  const ranked = outcomes
    .filter(outcome => (
      !openServers.has(outcome.server)
      && classifyKeyboardServicesCapability(outcome) === 'keyboardServices'
    ))
    .sort((left, right) => (
      left.roundTripTimeMilliseconds - right.roundTripTimeMilliseconds
      || left.configuredIndex - right.configuredIndex
    ));
  const slotAvailabilityByServer = Object.fromEntries(
    outcomes.map(outcome => [outcome.server, slotAvailability(outcome)]),
  );
  const rankedFallbackServers = ranked.map(outcome => outcome.server);

  return {
    pinnedServer: rankedFallbackServers[0] ?? null,
    rankedFallbackServers,
    slotAvailabilityByServer,
  };
}

/** Returns the next positive revision without wrapping at the JS safe-integer limit. */
export function nextKeyboardServicesPinRevision(currentRevision = 0) {
  if (!Number.isSafeInteger(currentRevision) || currentRevision < 0
    || currentRevision === Number.MAX_SAFE_INTEGER) {
    throw new RangeError('Invalid or exhausted keyboard-services pin revision');
  }
  return currentRevision + 1;
}

function normalizeSnapshot(snapshot) {
  if (!isRecord(snapshot)
    || snapshot.schemaVersion !== SNAPSHOT_SCHEMA_VERSION
    || !Number.isSafeInteger(snapshot.revision)
    || snapshot.revision < 1
    || !(snapshot.pinnedServer === null
      || snapshot.pinnedServer === undefined
      || typeof snapshot.pinnedServer === 'string')
    || !Array.isArray(snapshot.rankedFallbackServers)
    || snapshot.rankedFallbackServers.some(server => typeof server !== 'string')
    || !isRecord(snapshot.slotAvailabilityByServer)) {
    return null;
  }

  const availabilityEntries = [];
  for (const [server, availability] of Object.entries(snapshot.slotAvailabilityByServer)) {
    if (!isRecord(availability)
      || CONSUMED_SLOTS.some(slotName => typeof availability[slotName] !== 'boolean')) {
      return null;
    }
    availabilityEntries.push([
      server,
      Object.fromEntries(CONSUMED_SLOTS.map(slotName => [slotName, availability[slotName]])),
    ]);
  }

  return {
    schemaVersion: SNAPSHOT_SCHEMA_VERSION,
    revision: snapshot.revision,
    // Swift's synthesized Codable decodes the optional with decodeIfPresent,
    // so an absent key yields nil — mirrored here as null, never undefined.
    pinnedServer: snapshot.pinnedServer ?? null,
    rankedFallbackServers: [...snapshot.rankedFallbackServers],
    slotAvailabilityByServer: Object.fromEntries(availabilityEntries),
  };
}

/** Encodes the supported snapshot fields, omitting unknown fields as the Swift schema does. */
export function encodeKeyboardServicesPinSnapshot(snapshot) {
  const normalized = normalizeSnapshot(snapshot);
  if (!normalized) throw new TypeError('Invalid keyboard-services pin snapshot');
  if (normalized.pinnedServer === null) delete normalized.pinnedServer;
  return JSON.stringify(normalized);
}

/** Decodes a supported pin snapshot or returns null for malformed/unsupported data. */
export function decodeKeyboardServicesPinSnapshot(value) {
  let parsed = value;
  if (typeof parsed === 'string') {
    try {
      parsed = JSON.parse(parsed);
    } catch {
      return null;
    }
  }
  return normalizeSnapshot(parsed);
}
