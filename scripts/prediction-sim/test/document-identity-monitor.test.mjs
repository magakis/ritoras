import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { DocumentIdentityMonitor } from '../lib/document-identity-monitor.mjs';

describe('DocumentIdentityMonitor (JS port)', () => {
  it('2 distinct non-nil ids 100 ms apart -> defensive', () => {
    const m = new DocumentIdentityMonitor();
    assert.strictEqual(m.observe('A', 0.0), false);
    assert.strictEqual(m.observe('B', 0.1), true);
    assert.strictEqual(m.isDefensive, true);
  });

  it('device scenario: 3 ids incl. a nil round-trip within 10 ms -> defensive', () => {
    const m = new DocumentIdentityMonitor();
    assert.strictEqual(m.observe('A', 0.000), false);
    assert.strictEqual(m.observe(null, 0.003), false);
    assert.strictEqual(m.observe('B', 0.006), true);
  });

  it('same id every 50 ms for 5 s -> never defensive', () => {
    const m = new DocumentIdentityMonitor();
    for (let t = 0; t <= 5.0; t += 0.05) {
      assert.strictEqual(m.observe('A', t), false, `t=${t}`);
    }
    assert.strictEqual(m.isDefensive, false);
  });

  it('2 nil<->non-nil transitions within the window -> defensive', () => {
    const m = new DocumentIdentityMonitor();
    assert.strictEqual(m.observe('A', 0.0), false);
    assert.strictEqual(m.observe(null, 0.01), false);
    assert.strictEqual(m.observe('A', 0.02), true);
  });

  it('2 distinct ids 600 ms apart -> not defensive (outside 0.5 s window)', () => {
    const m = new DocumentIdentityMonitor();
    m.observe('A', 0.0);
    assert.strictEqual(m.observe('B', 0.6), false);
  });

  it('cooldown expiry: exits at the next observe >=2 s after the last flap', () => {
    const m = new DocumentIdentityMonitor();
    m.observe('A', 0.0);
    assert.strictEqual(m.observe('B', 0.1), true); // flap at 0.1
    assert.strictEqual(m.observe(null, 0.61), true); // 0.51 s after flap, still defensive
    assert.strictEqual(m.observe(null, 1.0), true); // 0.9 s after flap, still defensive
    assert.strictEqual(m.observe(null, 2.11), false); // 2.01 s after flap -> cooldown expired
  });

  it('stability early-exit: exits after 0.5 s of one stable non-nil id while within cooldown', () => {
    const m = new DocumentIdentityMonitor();
    m.observe('A', 0.0);
    assert.strictEqual(m.observe('B', 0.1), true); // flap at 0.1
    assert.strictEqual(m.observe('B', 0.2), true); // still defensive
    assert.strictEqual(m.observe('B', 0.61), false); // B held 0.51 s >= 0.5 -> stability exit
  });

  it('re-flap during defensive mode extends the cooldown', () => {
    const m = new DocumentIdentityMonitor();
    m.observe('A', 0.0);
    assert.strictEqual(m.observe('B', 0.1), true); // flap at 0.1
    assert.strictEqual(m.observe('C', 0.3), true); // re-flap at 0.3 -> lastFlapAt = 0.3
    // 2.01 s after the FIRST flap but only 1.81 s after the re-flap: still
    // defensive, proving the window was extended.
    assert.strictEqual(m.observe(null, 2.11), true);
    assert.strictEqual(m.observe(null, 2.31), false); // 2.01 s after re-flap -> expired
  });

  it('window boundary: entry exactly flapWindow old counts; strictly older does not', () => {
    // Exactly flapWindow (0.5 s) apart -> the first id is still visible -> flap.
    const exactly = new DocumentIdentityMonitor();
    exactly.observe('A', 0.0);
    assert.strictEqual(exactly.observe('B', 0.5), true);

    // Strictly older than flapWindow (0.51 s) -> the first id is invisible -> no flap.
    const older = new DocumentIdentityMonitor();
    older.observe('A', 0.0);
    assert.strictEqual(older.observe('B', 0.51), false);
  });

  it('nils alone never cause a flap', () => {
    const m = new DocumentIdentityMonitor();
    for (const t of [0.0, 0.01, 0.02, 0.05, 0.1, 0.5, 1.0]) {
      assert.strictEqual(m.observe(null, t), false, `t=${t}`);
    }
    assert.strictEqual(m.isDefensive, false);
  });
});
