import fs from 'node:fs';
import path from 'node:path';
import { DEFAULT_SESSION_CONFIG } from '../bin/replay-vad.mjs';

function configFromTelemetry(payload) {
  return payload.vad_config
    ?? payload.events?.find(event => event.k === 'session_start' && event.c)?.c
    ?? payload.frames?.[0]?.c
    ?? {};
}

export function adaptClientTelemetry(payload, sessionId = 'unknown') {
  if (!Array.isArray(payload.frames)) {
    throw new Error(`${sessionId}: client telemetry has no frames array`);
  }
  const frames = payload.frames.map((frame, index) => {
    const dt = Number(frame.dt);
    const db = Number(frame.db);
    if (!Number.isFinite(dt) || dt <= 0 || !Number.isFinite(db)) {
      throw new Error(`${sessionId}: invalid db/dt in frame ${index}`);
    }
    return { t: 'f', q: frame.q ?? index, dt, db };
  });
  const events = Array.isArray(payload.events) ? payload.events : [];
  const recordedFrames = payload.frames.map(frame => ({
    q: frame.q,
    dt: frame.dt,
    e: frame.e,
    es: frame.es,
    d: frame.d,
    ll: frame.ll,
    ls: frame.ls,
    lr: frame.lr,
    dy: frame.dy,
    fc: frame.fc,
  }));
  const rawConfig = configFromTelemetry(payload);
  return {
    id: sessionId,
    frames,
    recordedFrames,
    events,
    config: { ...DEFAULT_SESSION_CONFIG, ...rawConfig },
    configIsTelemetry: true,
  };
}

export function readClientTelemetry(filePath, sessionId = path.basename(path.dirname(filePath))) {
  let payload;
  try {
    payload = JSON.parse(fs.readFileSync(filePath, 'utf8'));
  } catch (error) {
    throw new Error(`cannot read telemetry for ${sessionId}: ${error.message}`, { cause: error });
  }
  return adaptClientTelemetry(payload, sessionId);
}

export function discoverClientTelemetry(corpusPath) {
  const roots = [path.join(corpusPath, 'ritoras'), corpusPath];
  const sessions = new Map();
  for (const root of roots) {
    if (!fs.existsSync(root)) continue;
    for (const entry of fs.readdirSync(root, { withFileTypes: true })) {
      if (!entry.isDirectory() || sessions.has(entry.name)) continue;
      const telemetryPath = path.join(root, entry.name, 'client_telemetry.json');
      if (!fs.existsSync(telemetryPath)) continue;
      sessions.set(entry.name, readClientTelemetry(telemetryPath, entry.name));
    }
  }
  return [...sessions.values()].sort((left, right) => left.id.localeCompare(right.id));
}

export function recordedEmissionMap(session) {
  return session.events
    .filter(event => event.k === 'emit')
    .map(event => ({
      start: Number.isFinite(event.s0) ? event.s0 / 1000 : null,
      end: Number.isFinite(event.s1) ? event.s1 / 1000 : null,
      duration: Number.isFinite(event.tm) ? event.tm / 1000 : null,
      id: event.id ?? null,
    }));
}
