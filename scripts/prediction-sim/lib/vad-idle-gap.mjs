export function findIdleGapTriggers(frames, {
  guardDb = -50,
  deltaDb = 6,
  minimumMs = 300,
  lookbackSeconds = 10,
} = {}) {
  const triggers = [];
  let time = 0;
  let idleRun = [];
  let eligibleRun = [];
  let eligibleMs = 0;
  let alreadyTriggered = false;

  const flushEligibleRun = () => {
    eligibleRun = [];
    eligibleMs = 0;
  };
  const flushIdleRun = () => {
    if (idleRun.length === 0) return;
    const idleEnd = idleRun.at(-1).end;
    const lookbackStart = Math.max(idleRun[0].start, idleEnd - lookbackSeconds);
    for (const frame of idleRun) {
      if (frame.end <= lookbackStart) continue;
      const start = Math.max(frame.start, lookbackStart);
      const durationMs = (frame.end - start) * 1000;
      if (frame.db < Math.max(frame.floorDb + deltaDb, guardDb)) {
        flushEligibleRun();
        alreadyTriggered = false;
        continue;
      }
      if (alreadyTriggered) continue;
      eligibleRun.push({ start, end: frame.end });
      eligibleMs += durationMs;
      if (eligibleMs + 1e-6 >= minimumMs) {
        const qualifyingStart = eligibleRun.at(-1).end - minimumMs / 1000;
        triggers.push({ start: qualifyingStart, end: eligibleRun.at(-1).end });
        alreadyTriggered = true;
      }
    }
    idleRun = [];
    flushEligibleRun();
    alreadyTriggered = false;
  };

  for (const frame of frames) {
    const dt = Number(frame.dt);
    const start = time;
    time += dt;
    const idle = frame.ps === 'idle' && frame.es === 'idle';
    if (!idle || !Number.isFinite(frame.fl)) {
      flushIdleRun();
      continue;
    }
    idleRun.push({ start, end: time, db: frame.db, floorDb: frame.fl });
  }
  flushIdleRun();
  return triggers;
}
