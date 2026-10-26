import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import {
  configMessage,
  decisionForServerMessage,
  initialMode,
  shouldSendConfig,
  STREAM_AUDIO_FORMAT,
  STREAM_AUDIO_MODE,
  STREAM_NEGOTIATION_DECISION,
  timeoutDecision,
} from '../lib/stream-format-negotiation.mjs';

describe('stream format negotiation', () => {
  it('builds the v2 CONFIG with the configured 16 kHz source rate', () => {
    assert.strictEqual(
      configMessage(16_000),
      '{"type":"CONFIG","format":"aac-m4a","sampleRate":16000,"channels":1,"bitrate":64000,"protocol":2}',
    );
  });

  it('declares the configured 48 kHz source rate and rejects unsupported rates', () => {
    assert.deepStrictEqual(JSON.parse(configMessage(48_000)), {
      type: 'CONFIG',
      format: STREAM_AUDIO_FORMAT.AAC_M4A,
      sampleRate: 48_000,
      channels: 1,
      bitrate: 64_000,
      protocol: 2,
    });
    assert.strictEqual(configMessage(44_100), null);
  });

  it('starts AAC requests pending and the disabled toggle directly selects legacy PCM', () => {
    assert.strictEqual(initialMode(true), null);
    assert.strictEqual(initialMode(false), STREAM_AUDIO_MODE.FLOAT32_PCM);
    assert.strictEqual(shouldSendConfig(false, false), false);
    assert.strictEqual(shouldSendConfig(true, false), true);
    assert.deepStrictEqual(
      decisionForServerMessage('{"type":"CONFIG_ACK","format":"aac-m4a","protocol":2}', false),
      { kind: STREAM_NEGOTIATION_DECISION.SELECT, mode: STREAM_AUDIO_MODE.FLOAT32_PCM },
    );
  });

  it('accepts only a matching v2 AAC CONFIG_ACK', () => {
    assert.deepStrictEqual(
      decisionForServerMessage('{"type":"CONFIG_ACK","format":"aac-m4a","protocol":2}', true),
      { kind: STREAM_NEGOTIATION_DECISION.SELECT, mode: STREAM_AUDIO_MODE.AAC_M4A },
    );
    assert.deepStrictEqual(
      decisionForServerMessage('{"type":"CONFIG_ACK","format":"f32le","protocol":2}', true),
      { kind: STREAM_NEGOTIATION_DECISION.WAIT },
    );
    assert.deepStrictEqual(
      decisionForServerMessage('{"type":"CONFIG_ACK","format":"aac-m4a","protocol":1}', true),
      { kind: STREAM_NEGOTIATION_DECISION.WAIT },
    );
  });

  it('falls back in place and pins the session on server error frames', () => {
    const errorDecision = decisionForServerMessage(
      '{"type":"error","message":"unsupported format"}',
      true,
      true,
    );
    assert.deepStrictEqual(
      errorDecision,
      {
        kind: STREAM_NEGOTIATION_DECISION.FALLBACK_IN_PLACE_AND_PIN_LEGACY,
        mode: STREAM_AUDIO_MODE.FLOAT32_PCM,
        pinsSessionLegacy: true,
      },
    );
    assert.strictEqual(shouldSendConfig(true, errorDecision.pinsSessionLegacy), false);
  });

  it('closes and pins legacy when the ACK is late after the server has accepted AAC', () => {
    const serverCommittedMode = STREAM_AUDIO_FORMAT.AAC_M4A;
    const lateAckDecision = decisionForServerMessage(
      '{"type":"CONFIG_ACK","format":"aac-m4a","protocol":2}',
      true,
      true,
    );

    assert.strictEqual(serverCommittedMode, STREAM_AUDIO_FORMAT.AAC_M4A);
    assert.deepStrictEqual(lateAckDecision, timeoutDecision());
    assert.strictEqual(
      lateAckDecision.kind,
      STREAM_NEGOTIATION_DECISION.CLOSE_CONNECTION_AND_PIN_LEGACY,
    );
    assert.strictEqual(lateAckDecision.pinsSessionLegacy, true);
    assert.strictEqual(Object.hasOwn(lateAckDecision, 'mode'), false);
    assert.strictEqual(shouldSendConfig(true, lateAckDecision.pinsSessionLegacy), false);
    assert.notStrictEqual(
      lateAckDecision.kind,
      STREAM_NEGOTIATION_DECISION.FALLBACK_IN_PLACE_AND_PIN_LEGACY,
    );
  });

  it('keeps waiting for other messages before the negotiation deadline', () => {
    assert.deepStrictEqual(
      decisionForServerMessage('{"type":"PONG"}', true),
      { kind: STREAM_NEGOTIATION_DECISION.WAIT },
    );
    assert.deepStrictEqual(
      decisionForServerMessage('not-json', true),
      { kind: STREAM_NEGOTIATION_DECISION.WAIT },
    );
  });
});
