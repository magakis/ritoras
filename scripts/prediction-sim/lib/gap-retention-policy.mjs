const SAMPLE_RATE = 16_000;
const DEFAULT_MIN_VOICE_EVIDENCE_SAMPLES = SAMPLE_RATE / 10;
const STOP_FLUSH_MIN_SAMPLES = 250 * 16;

function isVoiceEvidence(evidence) {
  return evidence === 'strong' || evidence === 'continuing';
}

function sampleCount(frames, field) {
  return frames.reduce((total, frame) => total + frame[field], 0);
}

export class GapRetentionPolicy {
  constructor({
    maxNoiseSamples = 6 * SAMPLE_RATE,
    minVoiceEvidenceSamples = DEFAULT_MIN_VOICE_EVIDENCE_SAMPLES,
    minSpeechSamples = 300 * 16,
    minChunkSamples = 300 * 16,
  } = {}) {
    this.maxNoiseSamples = maxNoiseSamples;
    this.minVoiceEvidenceSamples = minVoiceEvidenceSamples;
    this.minSpeechSamples = minSpeechSamples;
    this.minChunkSamples = minChunkSamples;

    for (const [name, value] of Object.entries({
      maxNoiseSamples,
      minVoiceEvidenceSamples,
      minSpeechSamples,
      minChunkSamples,
    })) {
      if (!Number.isSafeInteger(value) || value < 0) {
        throw new Error(`${name} must be a non-negative integer sample count`);
      }
    }
    this.bufferStartSample = null;
    this.bufferFrames = [];
    this.active = false;
    this.onsetSample = null;
    this.lastSample = null;
    this.endpointFinalizeCount = 0;
    this.chunks = [];
    this.shedSlabs = [];
    this.tailFloorDrops = [];
    this.events = [];
    this.flushOutcome = null;
  }

  processFrame({
    startSample,
    endSample,
    db,
    evidence,
    silenceThresholdDb,
    decision = 'none',
    endpointState = 'idle',
  }) {
    if (!Number.isSafeInteger(startSample)
      || !Number.isSafeInteger(endSample)
      || startSample < 0
      || endSample <= startSample) {
      throw new Error('frame sample range must be a non-empty non-negative interval');
    }
    if (this.lastSample !== null && startSample !== this.lastSample) {
      throw new Error(`non-contiguous frame at sample ${startSample}; expected ${this.lastSample}`);
    }
    if (!Number.isFinite(db) || !Number.isFinite(silenceThresholdDb)) {
      throw new Error('frame dB and silence threshold must be finite');
    }
    if (!['strong', 'continuing', 'ambiguous', 'silence'].includes(evidence)) {
      throw new Error(`unsupported VAD evidence: ${evidence}`);
    }

    this.bufferStartSample ??= startSample;
    const frame = {
      startSample,
      endSample,
      sampleCount: endSample - startSample,
      db,
      evidence,
      silenceThresholdDb,
      voiceSamples: isVoiceEvidence(evidence) ? endSample - startSample : 0,
      aboveSilenceSamples: db >= silenceThresholdDb ? endSample - startSample : 0,
    };
    this.bufferFrames.push(frame);
    this.lastSample = endSample;

    if (decision === 'start_utterance') {
      this.active = true;
      this.onsetSample = endSample;
    }

    if (decision === 'finalize_endpoint') {
      this.endpointFinalizeCount += 1;
      this.active = false;
      const emitted = this.emitEndpointChunk(endSample);
      if (!emitted) {
        this.events.push({
          type: 'endpoint-finalize-held',
          endpoint_finalize_index: this.endpointFinalizeCount,
          start_sample: this.bufferStartSample,
          end_sample: endSample,
          duration_samples: this.bufferSampleCount,
          duration_ms: this.bufferSampleCount / 16,
          voice_samples: this.voiceEvidenceSamples,
          voice_ms: this.voiceEvidenceSamples / 16,
          reason: 'min-gates',
          emitted: false,
          split: false,
        });
      }
      this.onsetSample = null;
      return { emitted, shed: false };
    }

    let shed = false;
    if (!this.active && endpointState === 'idle') {
      shed = this.shedVoicelessBuffer(endSample);
    }

    return { emitted: false, shed };
  }

  emitEndpointChunk(finalizeSample) {
    if (!this.meetsVoiceChunkMinimums()) return false;
    this.chunks.push(this.makeChunk({
      startSample: this.bufferStartSample,
      endSample: finalizeSample,
      finalizeSample,
      reason: 'endpoint-silence',
      onsetSample: this.onsetSample,
      endpointFinalizeIndex: this.endpointFinalizeCount,
    }));
    this.clearBuffer(finalizeSample);
    return true;
  }

  shedVoicelessBuffer(endSample) {
    if (this.bufferSampleCount <= this.maxNoiseSamples
      || this.voiceEvidenceSamples >= this.minVoiceEvidenceSamples) {
      return false;
    }

    const slab = {
      startSample: this.bufferStartSample,
      endSample,
      voiceSamples: this.voiceEvidenceSamples,
    };
    this.shedSlabs.push(slab);
    this.events.push({ type: 'shed', ...slab });
    this.clearBuffer(endSample);
    return true;
  }

  flush({ endSample = this.lastSample } = {}) {
    if (this.bufferFrames.length === 0) {
      this.flushOutcome = {
        offered: false,
        emitted: false,
        tailFloorDrop: null,
        durationSamples: 0,
        durationMs: 0,
        aboveSilenceSamples: 0,
        voiceSamples: 0,
        voiceMs: 0,
      };
      return this.flushOutcome;
    }
    if (endSample !== this.bufferEndSample) {
      throw new Error(
        `flush sample ${endSample} does not match buffered end ${this.bufferEndSample}`,
      );
    }

    const aboveSilenceSamples = this.aboveSilenceSamples;
    const voiceSamples = this.voiceEvidenceSamples;
    // Offer every retained stop tail; downstream defenses handle noise.
    const offered = this.bufferFrames.length > 0;
    const durationSamples = this.bufferSampleCount;
    const emitted = durationSamples >= STOP_FLUSH_MIN_SAMPLES;
    this.flushOutcome = {
      offered,
      emitted,
      tailFloorDrop: null,
      durationSamples,
      durationMs: durationSamples / 16,
      aboveSilenceSamples,
      voiceSamples,
      voiceMs: voiceSamples / 16,
    };

    if (emitted) {
      this.chunks.push(this.makeChunk({
        startSample: this.bufferStartSample,
        endSample,
        finalizeSample: endSample,
        reason: 'stop-flush',
        onsetSample: this.onsetSample,
        aboveSilenceSamples,
      }));
    } else {
      const tailFloorDrop = {
        startSample: this.bufferStartSample,
        endSample,
        durationSamples,
        durationMs: durationSamples / 16,
        voiceSamples,
        voiceMs: voiceSamples / 16,
        reason: 'tail-floor',
      };
      this.tailFloorDrops.push(tailFloorDrop);
      this.flushOutcome.tailFloorDrop = tailFloorDrop;
      this.events.push({ type: 'tail-floor-drop', ...tailFloorDrop });
    }
    this.events.push({ type: 'stop-flush-offer', ...this.flushOutcome });
    this.active = false;
    this.clearBuffer(endSample);
    return this.flushOutcome;
  }

  meetsVoiceChunkMinimums() {
    return this.bufferSampleCount >= this.minChunkSamples
      && this.voiceEvidenceSamples >= this.minSpeechSamples;
  }

  makeChunk({
    startSample,
    endSample,
    finalizeSample,
    reason,
    onsetSample = null,
    endpointFinalizeIndex = null,
    aboveSilenceSamples = null,
  }) {
    return {
      startSample,
      endSample,
      finalizeSample,
      reason,
      onsetSample: onsetSample !== null
        && onsetSample >= startSample
        && onsetSample < endSample
        ? onsetSample
        : null,
      endpointFinalizeIndex,
      voiceSamples: sampleCount(
        this.framesInRange(startSample, endSample),
        'voiceSamples',
      ),
      aboveSilenceSamples: aboveSilenceSamples
        ?? sampleCount(this.framesInRange(startSample, endSample), 'aboveSilenceSamples'),
    };
  }

  framesInRange(startSample, endSample) {
    return this.bufferFrames.flatMap(frame => {
      const start = Math.max(frame.startSample, startSample);
      const end = Math.min(frame.endSample, endSample);
      if (end <= start) return [];
      const count = end - start;
      const proportion = count / frame.sampleCount;
      return [{
        voiceSamples: Math.round(frame.voiceSamples * proportion),
        aboveSilenceSamples: Math.round(frame.aboveSilenceSamples * proportion),
      }];
    });
  }

  clearBuffer(nextSample) {
    this.bufferStartSample = nextSample;
    this.bufferFrames = [];
    this.onsetSample = null;
  }

  get bufferEndSample() {
    return this.bufferFrames.at(-1)?.endSample ?? this.bufferStartSample;
  }

  get bufferSampleCount() {
    return this.bufferFrames.reduce((total, frame) => total + frame.sampleCount, 0);
  }

  get voiceEvidenceSamples() {
    return sampleCount(this.bufferFrames, 'voiceSamples');
  }

  get aboveSilenceSamples() {
    return sampleCount(this.bufferFrames, 'aboveSilenceSamples');
  }

  snapshot() {
    return {
      chunks: this.chunks.map(chunk => ({ ...chunk })),
      shedSlabs: this.shedSlabs.map(slab => ({ ...slab })),
      tailFloorDrops: this.tailFloorDrops.map(drop => ({ ...drop })),
      events: this.events.map(event => ({ ...event })),
      flushOutcome: this.flushOutcome
        ? {
          ...this.flushOutcome,
          tailFloorDrop: this.flushOutcome.tailFloorDrop
            ? { ...this.flushOutcome.tailFloorDrop }
            : null,
        }
        : null,
      pending: {
        startSample: this.bufferStartSample,
        endSample: this.bufferEndSample,
        sampleCount: this.bufferSampleCount,
        voiceSamples: this.voiceEvidenceSamples,
        aboveSilenceSamples: this.aboveSilenceSamples,
      },
    };
  }
}
