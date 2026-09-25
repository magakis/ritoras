import { after, describe, it } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { buildText } from '../lib/vad-telemetry-digest.mjs';

const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'ritoras-vad-digest-'));
const globalSettings = [
  ['telemetryEnabled', 'ON'],
  ['mode', 'adaptive'],
  ['pause', 'balanced'],
];

after(() => fs.rmSync(directory, { recursive: true, force: true }));

function frame(q, overrides = {}) {
  return {
    t: 'f',
    q,
    dt: 0.1,
    db: -50,
    e: 'silence',
    sp: false,
    fl: -52,
    ps: 'idle',
    es: 'idle',
    d: 'none',
    ...overrides,
  };
}

function recordingFile(name, records) {
  const filePath = path.join(directory, name);
  fs.writeFileSync(filePath, records.map(record => JSON.stringify(record)).join('\n'));
  return filePath;
}

function digest(files, options = {}) {
  return buildText({
    files,
    globalSettings,
    exportedAt: new Date('2026-09-23T14:02:11.000Z'),
    ...options,
  });
}

describe('VAD telemetry digest', () => {
  it('reduces metadata, session config, frames, events, and session end records', () => {
    const jobId = '12345678-1234-1234-1234-123456789abc';
    const file = recordingFile(`${jobId}-vad.jsonl`, [
      { t: 'meta', jobId, startedAt: '2026-09-23T13:58:02Z', appVersion: '1.2' },
      {
        t: 'ev',
        k: 'session_start',
        c: { mode: 'adaptive', endpointOnsetMs: 70, endpointSilenceMs: 700 },
      },
      frame(0, { sp: true, fl: -52 }),
      frame(1, { q: 1, sp: true, fl: -55, d: 'finalize_endpoint', ps: 'speechActive', es: 'idle' }),
      frame(2, { q: 2, fl: -44, ps: 'endPending', es: 'speechActive', e: 'strong' }),
      frame(3, { q: 3, fl: -44, ps: 'endPending', es: 'speechActive', e: 'ambiguous' }),
      { t: 'ev', k: 'emit', sm: 120, tm: 200 },
      { t: 'ev', k: 'outcome', r: 'success' },
      { t: 'ev', k: 'session_end' },
    ]);

    const text = digest([file]);
    assert.match(text, /^Ritoras VAD digest v1 — exported 2026-09-23T14:02:11Z/m);
    assert.match(text, /job=12345678-1234-1234-1234-123456789abc started=2026-09-23T13:58:02Z dur=0\.4s outcome=success/);
    assert.match(text, /chunks=1 emitted speech=0\.1s\/0\.2s/);
    assert.match(text, /params\(onset=70ms endpointSilence=700ms mode=adaptive\)/);
    assert.match(text, /floorDb first\/min\/max\/last=-52\.0\/-55\.0\/-44\.0\/-44\.0/);
    assert.match(text, /frames n=4 speech%=50 decisions\{emit=1,resume=1,rescue=1\}/);
    assert.match(text, /== Recording 1\/1 \(newest\) ==/);
    assert.match(text, /telemetryEnabled=ON mode=adaptive pause=balanced/);
  });

  it('renders chunk timing and receive correlation from full telemetry events', () => {
    const jobId = '14345678-1234-1234-1234-123456789abc';
    const file = recordingFile(`${jobId}-vad.jsonl`, [
      { t: 'meta', jobId, startedAt: '2026-09-23T13:58:02Z' },
      ...Array.from({ length: 120 }, (_, index) => frame(index)),
      { t: 'ev', k: 'emit', id: 1, n: 3200, r: 'stop', sm: 800, tm: 950, s0: 3100, s1: 4050, es: 'idle' },
      { t: 'ev', k: 'emit', id: 0, n: 4000, r: 'endpoint', sm: 1100, tm: 1250, s0: 1200, s1: 2450, es: 'speechActive' },
      { t: 'ev', k: 'chunk_received', id: 1, lat: 1990, ch: 18 },
      { t: 'ev', k: 'chunk_received', id: 0, lat: 210, ch: 42 },
    ]);

    const text = digest([file]);
    assert.match(text, /chunks=2 emitted speech=1\.9s\/2\.2s/);
    assert.match(text, /chunk table mean 1\.10s; 10\.0\/min; recv 1\.1\/2/);
    assert.match(text, / #0 1\.20->2\.45s dur=1\.25s sp=1\.10s endpoint=speechActive reason=endpoint recv=210ms 42ch/);
    assert.match(text, / #1 3\.10->4\.05s dur=0\.95s sp=0\.80s endpoint=idle reason=stop recv=1990ms 18ch/);
  });

  it('renders n/a for omitted legacy chunk fields without changing the emitted count', () => {
    const jobId = '15345678-1234-1234-1234-123456789abc';
    const file = recordingFile(`${jobId}-vad.jsonl`, [
      { t: 'meta', jobId, startedAt: '2026-09-23T13:58:02Z' },
      { t: 'ev', k: 'emit', id: 0, n: 3200, r: 'legacy', sm: 100, tm: 200 },
    ]);

    const text = digest([file]);
    assert.match(text, /chunks=1 emitted speech=0\.1s\/0\.2s/);
    assert.match(text, /chunk table mean 0\.20s; n\/a\/min; recv n\/a\/0/);
    assert.match(text, / #0 n\/a->n\/as dur=0\.20s sp=0\.10s endpoint=n\/a reason=legacy recv=—/);
  });

  it('caps chunk rows with even-stride selection and a truncation marker', () => {
    const jobId = '16345678-1234-1234-1234-123456789abc';
    const file = recordingFile(`${jobId}-vad.jsonl`, [
      { t: 'meta', jobId, startedAt: '2026-09-23T13:58:02Z' },
      ...Array.from({ length: 25 }, (_, id) => ({
        t: 'ev', k: 'emit', id, r: 'endpoint', sm: 100, tm: 200, s0: id * 200, s1: id * 200 + 200,
      })),
    ]);

    const text = digest([file]);
    const chunkRows = text.split('\n').filter(line => /^ #\d+ /.test(line));
    assert.match(text, /chunk table[^\n]*\n(?: #\d+ [^\n]*\n){7}…truncated/);
    assert.equal(chunkRows.length, 7);
    assert.match(text, /chunks=25 emitted speech=2\.5s\/5\.0s/);
  });

  it('renders effective and raw stale-floor values when the telemetry keys are present', () => {
    const jobId = '13345678-1234-1234-1234-123456789abc';
    const file = recordingFile(`${jobId}-vad.jsonl`, [
      { t: 'meta', jobId, startedAt: '2026-09-23T13:58:02Z' },
      {
        t: 'ev',
        k: 'session_start',
        c: {
          mode: 'adaptive',
          staleFloorSeconds: 0.375,
          staleFloorSecondsRaw: 1.5,
          riseSpeedMultiplier: 4,
        },
      },
    ]);

    const text = digest([file]);
    assert.match(text, /staleFloor=eff=0\.38s \(raw=1\.5s ÷ ×4\.0\)/);
    assert.doesNotMatch(text, /staleFloorSecondsRaw|riseSpeedMultiplier=/);
  });

  it('keeps the single-value stale-floor rendering for legacy telemetry records', () => {
    const jobId = '23345678-1234-1234-1234-123456789abc';
    const file = recordingFile(`${jobId}-vad.jsonl`, [
      { t: 'meta', jobId, startedAt: '2026-09-23T13:58:02Z' },
      { t: 'ev', k: 'session_start', c: { mode: 'adaptive', staleFloorSeconds: 0.4 } },
    ]);

    const text = digest([file]);
    assert.match(text, /staleFloorSeconds=0\.4s/);
    assert.doesNotMatch(text, /staleFloor=eff=/);
  });

  it('uses unknown outcome and params when events are absent and skips corrupt lines', () => {
    const jobId = '22345678-1234-1234-1234-123456789abc';
    const filePath = path.join(directory, `${jobId}-vad.jsonl`);
    fs.writeFileSync(filePath, `not-json\n${JSON.stringify({ t: 'f', q: 0, dt: 0.25, db: -51, sp: false })}\n`);

    const text = digest([filePath]);
    assert.match(text, /outcome=unknown/);
    assert.match(text, /params=unknown/);
    assert.match(text, /frames n=1/);
  });

  it('sorts recordings newest-first using metadata start time', () => {
    const olderId = '32345678-1234-1234-1234-123456789abc';
    const newerId = '42345678-1234-1234-1234-123456789abc';
    const older = recordingFile(`${olderId}-vad.jsonl`, [
      { t: 'meta', jobId: olderId, startedAt: '2026-09-23T10:00:00Z' },
    ]);
    const newer = recordingFile(`${newerId}-vad.jsonl`, [
      { t: 'meta', jobId: newerId, startedAt: '2026-09-23T11:00:00Z' },
    ]);

    const text = digest([older, newer]);
    assert.ok(text.indexOf(`job=${newerId}`) < text.indexOf(`job=${olderId}`));
    assert.match(text, new RegExp(`== Recording 1/2 \\(newest\\) ==\\njob=${newerId}`));
    assert.match(text, new RegExp(`== Recording 2/2 ==\\njob=${olderId}`));
  });

  it('falls back to last sequence times frame duration when frame durations are incomplete', () => {
    const jobId = '52345678-1234-1234-1234-123456789abc';
    const file = recordingFile(`${jobId}-vad.jsonl`, [
      { t: 'f', q: 0, db: -50, sp: false },
      { t: 'f', q: 1, db: -50, sp: false },
      { t: 'f', q: 2, dt: 0.1, db: -50, sp: false },
    ]);

    const text = digest([file]);
    assert.match(text, /dur=0\.2s/);
  });

  it('decimates then truncates timelines while preserving count and recording statistics', () => {
    const jobId = '62345678-1234-1234-1234-123456789abc';
    const records = [
      { t: 'meta', jobId, startedAt: '2026-09-23T12:00:00Z' },
      { t: 'ev', k: 'session_start', c: { mode: 'adaptive' } },
      ...Array.from({ length: 4000 }, (_, index) => frame(index, {
        q: index,
        db: -50 + (index % 2),
      })),
    ];
    const file = recordingFile(`${jobId}-vad.jsonl`, records);
    const text = digest([file], { budget: 2048 });

    assert.ok(Buffer.byteLength(text, 'utf8') <= 2048);
    assert.match(text, /…truncated/);
    assert.match(text, /frames n=4000/);
    assert.match(text, /job=62345678-1234-1234-1234-123456789abc/);
  });

  it('decimates an oversized chunk table without decimating a long timeline', () => {
    const jobId = '72345678-1234-1234-1234-123456789abc';
    const file = recordingFile(`${jobId}-vad.jsonl`, [
      { t: 'meta', jobId, startedAt: '2026-09-23T12:00:00Z' },
      ...Array.from({ length: 60 }, (_, index) => frame(index, { q: index })),
      ...Array.from({ length: 300 }, (_, id) => ({
        t: 'ev',
        k: 'emit',
        id,
        n: 3200,
        r: `endpoint-${'x'.repeat(100)}`,
        sm: 100,
        tm: 200,
        s0: id * 200,
        s1: id * 200 + 200,
      })),
    ]);

    const text = digest([file], { budget: 2048 });
    const timelineLine = text.split('\n').find(line => line.startsWith('timeline(250ms decimated): '));
    const timelinePoints = timelineLine?.slice('timeline(250ms decimated): '.length).split(' ') ?? [];
    const chunkRows = text.split('\n').filter(line => /^ #\d+ /.test(line));

    assert.ok(Buffer.byteLength(text, 'utf8') <= 2048);
    assert.equal(timelinePoints.length, 24);
    assert.equal(chunkRows.length, 5);
  });

  it('skips files whose filename prefix is not a UUID', () => {
    const file = recordingFile('not-a-uuid-vad.jsonl', [
      { t: 'meta', jobId: '72345678-1234-1234-1234-123456789abc', startedAt: '2026-09-23T12:00:00Z' },
    ]);

    const text = digest([file]);
    assert.match(text, /recordings: 0 retained/);
    assert.doesNotMatch(text, /job=72345678/);
  });
});
