// Pure-logic JS port of WhisperClient's server-probe ranking and breaker rules.
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
 * Selects the highest-ranked authenticated 2xx response. Results outside a
 * round deadline must be removed by the caller before passing them here.
 *
 * @param {{ server: string, configuredIndex: number, statusCode: number|null, modelLoaded?: boolean|null, roundTripTimeMilliseconds: number }[]} outcomes
 * @returns {object|null}
 */
export function selectServer(outcomes) {
  const authenticated = outcomes.filter(({ statusCode }) => isAuthenticated(statusCode));
  if (authenticated.length === 0) return null;

  return authenticated.reduce((winner, candidate) => (
    ranksBefore(candidate, winner) ? candidate : winner
  ));
}

/**
 * Small stateful mirror for round cutoff, breaker, and ranking persistence
 * behavior. Probe I/O and task cancellation remain owned by WhisperClient.
 */
export class ServerSelectionState {
  constructor({ failureThreshold = 3, cooldownMilliseconds = 600_000 } = {}) {
    this.failureThreshold = failureThreshold;
    this.cooldownMilliseconds = cooldownMilliseconds;
    this.breakers = new Map();
    this.persistedRanking = null;
  }

  #breaker(server) {
    let breaker = this.breakers.get(server);
    if (!breaker) {
      breaker = {
        consecutiveFailures: 0,
        openUntil: null,
        halfOpenInFlight: false,
      };
      this.breakers.set(server, breaker);
    }
    return breaker;
  }

  breakerState(server) {
    return { ...this.#breaker(server) };
  }

  beginProbe(server, now = Date.now()) {
    const breaker = this.#breaker(server);
    if (breaker.openUntil !== null && breaker.openUntil > now) {
      return { allowed: false, state: 'open', openUntil: breaker.openUntil };
    }
    if (breaker.openUntil !== null) {
      if (breaker.halfOpenInFlight) {
        return { allowed: false, state: 'half-open-in-flight', openUntil: breaker.openUntil };
      }
      breaker.halfOpenInFlight = true;
      return { allowed: true, state: 'half-open', openUntil: breaker.openUntil };
    }
    return { allowed: true, state: 'closed', openUntil: null };
  }

  recordProbeOutcome(server, completion, now = Date.now()) {
    const breaker = this.#breaker(server);
    const wasHalfOpen = breaker.halfOpenInFlight;
    breaker.halfOpenInFlight = false;

    if (completion === 'roundDeadlineCutoff' || completion === 'cancelled' || completion === 'invalidURL') {
      return null;
    }
    if (completion === 'response') {
      const recovered = breaker.consecutiveFailures > 0 || breaker.openUntil !== null;
      breaker.consecutiveFailures = 0;
      breaker.openUntil = null;
      return recovered ? 'closed' : null;
    }
    if (completion !== 'transportFailure') {
      throw new Error(`Unknown server-probe completion: ${completion}`);
    }

    if (!wasHalfOpen && breaker.openUntil !== null && breaker.openUntil > now) return null;
    breaker.consecutiveFailures += 1;
    if (wasHalfOpen || breaker.consecutiveFailures >= this.failureThreshold) {
      breaker.consecutiveFailures = Math.max(breaker.consecutiveFailures, this.failureThreshold);
      breaker.openUntil = now + this.cooldownMilliseconds;
      return wasHalfOpen ? 'reopened' : 'opened';
    }
    return null;
  }

  completeRound({ servers, outcomes, deadlineMilliseconds, now = Date.now(), cancelled = false }) {
    for (const outcome of outcomes) {
      this.recordProbeOutcome(outcome.server, outcome.completion, now);
    }

    const withinDeadline = outcomes.filter(outcome => (
      outcome.completion === 'response'
      && outcome.statusCode !== null
      && outcome.statusCode !== undefined
      && outcome.roundTripTimeMilliseconds <= deadlineMilliseconds
    ));
    const selection = selectServer(withinDeadline);
    const rankedResponders = withinDeadline
      .filter(outcome => isAuthenticated(outcome.statusCode))
      .sort(ranksBefore);
    const rankedServers = new Set(rankedResponders.map(outcome => outcome.server));
    const rankingEntries = [
      ...rankedResponders.map(({ server, modelLoaded }) => ({ server, modelLoaded })),
      ...servers
        .filter(server => !rankedServers.has(server))
        .map(server => ({
          server,
          modelLoaded: withinDeadline.find(outcome => outcome.server === server)?.modelLoaded ?? null,
        })),
    ];
    const deadlineExpired = outcomes.some(outcome => (
      outcome.completion === 'roundDeadlineCutoff'
      || outcome.roundTripTimeMilliseconds > deadlineMilliseconds
    ));

    if (cancelled) {
      return { selection: null, rankingPersisted: false, deadlineExpired };
    }

    this.persistedRanking = { timestamp: now, entries: rankingEntries };
    return { selection, rankingPersisted: true, deadlineExpired };
  }
}
