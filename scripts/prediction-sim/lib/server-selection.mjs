// Pure-logic JS port of WhisperClient's server-probe ranking.
// Kept in sync per AGENTS.md -> Test policy.

function isAuthenticated(statusCode) {
  return Number.isInteger(statusCode) && statusCode >= 200 && statusCode < 300;
}

function ranksBefore(left, right) {
  const leftIsAuthenticated = isAuthenticated(left.statusCode);
  const rightIsAuthenticated = isAuthenticated(right.statusCode);
  if (leftIsAuthenticated !== rightIsAuthenticated) return leftIsAuthenticated;
  if (!leftIsAuthenticated) return left.configuredIndex < right.configuredIndex;

  const leftIsWarm = left.modelLoaded === true;
  const rightIsWarm = right.modelLoaded === true;
  if (leftIsWarm !== rightIsWarm) return leftIsWarm;
  if (left.roundTripTimeMilliseconds !== right.roundTripTimeMilliseconds) {
    return left.roundTripTimeMilliseconds < right.roundTripTimeMilliseconds;
  }
  return left.configuredIndex < right.configuredIndex;
}

/**
 * Selects the highest-ranked HTTP responder, ignoring unreachable probes.
 * Returns null when no server returned an HTTP response. Outcomes carry their
 * original configured list index, so completion order does not affect the winner.
 *
 * @param {{ server: string, configuredIndex: number, statusCode: number|null, modelLoaded?: boolean|null, roundTripTimeMilliseconds: number }[]} outcomes
 * @returns {object|null}
 */
export function selectServer(outcomes) {
  const responders = outcomes.filter(({ statusCode }) => (
    statusCode !== null && statusCode !== undefined
  ));
  if (responders.length === 0) return null;

  return responders.reduce((winner, candidate) => (
    ranksBefore(candidate, winner) ? candidate : winner
  ));
}
