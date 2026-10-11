import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import {
  STREAM_HEALTH_CHECK_INTERVAL_SECONDS,
  STREAM_LIVENESS_SILENCE_WINDOW_SECONDS,
  STREAM_MAX_MISSED_PONGS,
} from '../lib/transcription-timeouts.mjs';
import {
  STREAM_UPLOAD_WINDOW_MAX_AGE_SECONDS,
  STREAM_UPLOAD_WINDOW_MINIMUM_BYTES,
  StreamLivenessEvaluator,
} from '../lib/stream-liveness.mjs';

function createConnectedEvaluator(at = 0) {
  const evaluator = new StreamLivenessEvaluator();
  evaluator.markConnected({ at });
  return evaluator;
}

describe('stream liveness evaluator', () => {
  it('keeps the 17-second stalled-then-double-flush incident from timing out during upload', () => {
    const evaluator = createConnectedEvaluator();
    const opened = evaluator.frameEnqueued({ bytes: 1_291_664, at: 0 });

    assert.strictEqual(opened.opened, true);
    const stalledTick = evaluator.evaluate({ at: 17 });
    const flushedTick = evaluator.evaluate({ at: 17.003 });

    assert.strictEqual(stalledTick.secondsSinceEvidence, 0);
    assert.strictEqual(stalledTick.shouldTimeout, false);
    assert.strictEqual(flushedTick.secondsSinceEvidence, 0);
    assert.strictEqual(flushedTick.shouldTimeout, false);
    assert.strictEqual(flushedTick.windowOpen, true);
  });

  it('resumes the nominal three-by-five-second timeout after a post-drain PONG', () => {
    const evaluator = createConnectedEvaluator();
    evaluator.frameEnqueued({ bytes: 1_291_664, at: 0 });

    const drained = evaluator.pongReceived({ at: 13 });
    assert.strictEqual(drained.closed, true);
    assert.strictEqual(evaluator.evaluate({ at: 13 }).windowOpen, false);
    assert.strictEqual(
      evaluator.evaluate({ at: 13 + STREAM_LIVENESS_SILENCE_WINDOW_SECONDS - 0.001 }).shouldTimeout,
      false,
    );
    assert.strictEqual(
      evaluator.evaluate({ at: 13 + STREAM_LIVENESS_SILENCE_WINDOW_SECONDS }).shouldTimeout,
      true,
    );
  });

  it('closes a pre-END upload window on a partial result', () => {
    const evaluator = createConnectedEvaluator();
    evaluator.frameEnqueued({ bytes: 1_291_664, at: 0 });

    const partial = evaluator.partialReceived({ at: 13 });
    const status = evaluator.evaluate({ at: 13 });

    assert.strictEqual(partial.closed, true);
    assert.strictEqual(status.endSent, false);
    assert.strictEqual(status.windowOpen, false);
    assert.strictEqual(status.secondsSinceEvidence, 0);
  });

  it('times out a wedged link by the upload bound plus the normal stale threshold', () => {
    const evaluator = createConnectedEvaluator();
    evaluator.frameEnqueued({ bytes: 1_291_664, at: 0 });

    assert.strictEqual(
      evaluator.evaluate({ at: STREAM_UPLOAD_WINDOW_MAX_AGE_SECONDS - 0.001 }).shouldTimeout,
      false,
    );
    const lapsed = evaluator.evaluate({ at: STREAM_UPLOAD_WINDOW_MAX_AGE_SECONDS });
    assert.strictEqual(lapsed.windowEvents.lapsed, true);
    assert.strictEqual(lapsed.secondsSinceEvidence, 0);
    assert.strictEqual(lapsed.shouldTimeout, false);

    const beforeDeadline = evaluator.evaluate({
      at: STREAM_UPLOAD_WINDOW_MAX_AGE_SECONDS + STREAM_LIVENESS_SILENCE_WINDOW_SECONDS - 0.001,
    });
    const atDeadline = evaluator.evaluate({
      at: STREAM_UPLOAD_WINDOW_MAX_AGE_SECONDS + STREAM_LIVENESS_SILENCE_WINDOW_SECONDS,
    });
    assert.strictEqual(beforeDeadline.shouldTimeout, false);
    assert.strictEqual(atDeadline.shouldTimeout, true);
  });

  it('keeps an END behind the open chunk window covered, then restores strict PONG-only liveness', () => {
    const evaluator = createConnectedEvaluator();
    evaluator.frameEnqueued({ bytes: 1_291_664, at: 0 });
    evaluator.markEndSent({ at: 1 });

    const duringUpload = evaluator.evaluate({ at: 4 });
    assert.strictEqual(duringUpload.endSent, true);
    assert.strictEqual(duringUpload.windowOpen, true);
    assert.strictEqual(duringUpload.shouldTimeout, false);

    evaluator.partialReceived({ at: 4.5 });
    assert.strictEqual(evaluator.evaluate({ at: 4.5 }).windowOpen, true);

    const pong = evaluator.pongReceived({ at: 5 });
    assert.strictEqual(pong.closed, true);
    evaluator.partialReceived({ at: 10 });
    assert.strictEqual(evaluator.evaluate({ at: 10 }).secondsSinceEvidence, 5);
    assert.strictEqual(evaluator.evaluate({ at: 20 - 0.001 }).shouldTimeout, false);
    assert.strictEqual(evaluator.evaluate({ at: 20 }).shouldTimeout, true);
  });

  it('closes a post-END upload window on a final frame', () => {
    const evaluator = createConnectedEvaluator();
    evaluator.frameEnqueued({ bytes: 1_291_664, at: 0 });
    evaluator.markEndSent({ at: 1 });

    const final = evaluator.finalReceived({ at: 5 });

    assert.strictEqual(final.closed, true);
    assert.strictEqual(evaluator.evaluate({ at: 5 }).windowOpen, false);
  });

  it('rebases staleness when a late final closes the upload window', () => {
    const evaluator = createConnectedEvaluator();
    evaluator.frameEnqueued({ bytes: 1_291_664, at: 0 });
    evaluator.markEndSent({ at: 1 });

    const beforeFinal = evaluator.evaluate({ at: 20 });
    const final = evaluator.finalReceived({ at: 20 });
    const atFinal = evaluator.evaluate({ at: 20 });
    const afterFinal = evaluator.evaluate({ at: 20.1 });

    assert.strictEqual(beforeFinal.shouldTimeout, false);
    assert.strictEqual(beforeFinal.secondsSinceEvidence, 0);
    assert.strictEqual(final.closed, true);
    assert.strictEqual(atFinal.receivedFinal, true);
    assert.strictEqual(atFinal.secondsSinceEvidence, 0);
    assert.strictEqual(atFinal.shouldTimeout, false);
    assert.ok(Math.abs(afterFinal.secondsSinceEvidence - 0.1) < 1e-9);
    assert.strictEqual(afterFinal.shouldTimeout, false);
  });

  it('never declares timeout after a final frame, regardless of later silence', () => {
    const evaluator = createConnectedEvaluator();
    evaluator.markEndSent({ at: 1 });
    evaluator.finalReceived({ at: 5 });

    const afterLongSilence = evaluator.evaluate({ at: 180 });

    assert.strictEqual(afterLongSilence.receivedFinal, true);
    assert.strictEqual(afterLongSilence.secondsSinceEvidence, 175);
    assert.strictEqual(afterLongSilence.shouldTimeout, false);
  });

  it('blocks enqueue-only window renewal until new inbound evidence arrives', () => {
    const evaluator = createConnectedEvaluator();
    evaluator.frameEnqueued({ bytes: STREAM_UPLOAD_WINDOW_MINIMUM_BYTES, at: 0 });
    let firstTimeoutAt = null;
    let sawLapse = false;

    for (let at = 5; at <= 180; at += STREAM_HEALTH_CHECK_INTERVAL_SECONDS) {
      if (at % STREAM_UPLOAD_WINDOW_MAX_AGE_SECONDS === 0) {
        const renewal = evaluator.frameEnqueued({
          bytes: STREAM_UPLOAD_WINDOW_MINIMUM_BYTES,
          at,
        });
        assert.strictEqual(renewal.opened, false);
        if (at === STREAM_UPLOAD_WINDOW_MAX_AGE_SECONDS) {
          sawLapse = renewal.lapsed;
        }
      }

      const status = evaluator.evaluate({ at });
      if (status.shouldTimeout && firstTimeoutAt === null) {
        firstTimeoutAt = at;
      }
    }

    assert.strictEqual(sawLapse, true);
    assert.strictEqual(firstTimeoutAt, STREAM_UPLOAD_WINDOW_MAX_AGE_SECONDS
      + STREAM_LIVENESS_SILENCE_WINDOW_SECONDS);
    assert.strictEqual(evaluator.evaluate({ at: 180 }).windowOpen, false);
  });

  it('requires post-lapse evidence from the current liveness tier before re-arming', () => {
    const midStream = createConnectedEvaluator();
    midStream.frameEnqueued({ bytes: STREAM_UPLOAD_WINDOW_MINIMUM_BYTES, at: 0 });
    assert.strictEqual(midStream.evaluate({ at: 30 }).windowEvents.lapsed, true);
    assert.strictEqual(midStream.frameEnqueued({
      bytes: STREAM_UPLOAD_WINDOW_MINIMUM_BYTES,
      at: 31,
    }).opened, false);
    midStream.partialReceived({ at: 32 });
    assert.strictEqual(midStream.frameEnqueued({
      bytes: STREAM_UPLOAD_WINDOW_MINIMUM_BYTES,
      at: 33,
    }).opened, true);

    const postEnd = createConnectedEvaluator();
    postEnd.frameEnqueued({ bytes: STREAM_UPLOAD_WINDOW_MINIMUM_BYTES, at: 0 });
    postEnd.markEndSent({ at: 1 });
    assert.strictEqual(postEnd.evaluate({ at: 30 }).windowEvents.lapsed, true);
    postEnd.partialReceived({ at: 31 });
    assert.strictEqual(postEnd.frameEnqueued({
      bytes: STREAM_UPLOAD_WINDOW_MINIMUM_BYTES,
      at: 32,
    }).opened, false);
    postEnd.pongReceived({ at: 33 });
    assert.strictEqual(postEnd.frameEnqueued({
      bytes: STREAM_UPLOAD_WINDOW_MINIMUM_BYTES,
      at: 34,
    }).opened, true);
  });

  it('re-arms large-frame windows on regular healthy-server PONGs', () => {
    const evaluator = createConnectedEvaluator();
    let openedWindows = 0;
    const initial = evaluator.frameEnqueued({
      bytes: STREAM_UPLOAD_WINDOW_MINIMUM_BYTES,
      at: 0,
    });
    openedWindows += Number(initial.opened);

    for (let at = 5; at <= 180; at += STREAM_HEALTH_CHECK_INTERVAL_SECONDS) {
      evaluator.pongReceived({ at });
      if (at % STREAM_UPLOAD_WINDOW_MAX_AGE_SECONDS === 0) {
        const opened = evaluator.frameEnqueued({
          bytes: STREAM_UPLOAD_WINDOW_MINIMUM_BYTES,
          at,
        });
        assert.strictEqual(opened.opened, true);
        openedWindows += Number(opened.opened);
      }
      assert.strictEqual(evaluator.evaluate({ at }).shouldTimeout, false);
    }

    assert.strictEqual(openedWindows, 7);
    assert.strictEqual(evaluator.evaluate({ at: 180 }).windowOpen, true);
  });

  it('opens only at the frame-size threshold and never extends an open window', () => {
    const evaluator = createConnectedEvaluator();
    const smallFrame = evaluator.frameEnqueued({
      bytes: STREAM_UPLOAD_WINDOW_MINIMUM_BYTES - 1,
      at: 0,
    });
    assert.strictEqual(smallFrame.opened, false);
    assert.strictEqual(evaluator.evaluate({ at: 0 }).windowOpen, false);

    const opened = evaluator.frameEnqueued({
      bytes: STREAM_UPLOAD_WINDOW_MINIMUM_BYTES,
      at: 1,
    });
    assert.strictEqual(opened.opened, true);
    const laterEnqueue = evaluator.frameEnqueued({
      bytes: STREAM_UPLOAD_WINDOW_MINIMUM_BYTES + 100,
      at: 20,
    });
    assert.strictEqual(laterEnqueue.opened, false);

    assert.strictEqual(evaluator.evaluate({ at: 30 }).secondsSinceEvidence, 1);
    const afterOriginalDeadline = evaluator.evaluate({ at: 35 });
    assert.strictEqual(afterOriginalDeadline.windowEvents.lapsed, true);
    assert.strictEqual(afterOriginalDeadline.secondsSinceEvidence, 5);
  });

  it('mirrors the existing two-tier cadence constants', () => {
    assert.strictEqual(STREAM_HEALTH_CHECK_INTERVAL_SECONDS, 5);
    assert.strictEqual(STREAM_MAX_MISSED_PONGS, 3);
    assert.strictEqual(STREAM_LIVENESS_SILENCE_WINDOW_SECONDS, 15);
  });
});
