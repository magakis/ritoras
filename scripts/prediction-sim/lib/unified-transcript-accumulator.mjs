// Pure-logic mirror of shared/UnifiedStreamProtocol.swift message parsing and transcript state.

function requireObject(value, label) {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) {
    throw new TypeError(`${label} must be a JSON object.`);
  }
  return value;
}

function requireString(value, field) {
  if (typeof value !== 'string') {
    throw new TypeError(`${field} must be a string.`);
  }
  return value;
}

function requireNumber(value, field) {
  if (typeof value !== 'number' || !Number.isFinite(value)) {
    throw new TypeError(`${field} must be a finite number.`);
  }
  return value;
}

function requireInteger(value, field) {
  if (!Number.isInteger(value)) {
    throw new TypeError(`${field} must be an integer.`);
  }
  return value;
}

function parseFinalSegment(value) {
  const segment = requireObject(value, 'Final segment');
  return {
    segmentIndex: requireInteger(segment.segment_index, 'segment_index'),
    transcription: requireString(segment.transcription, 'transcription'),
    startS: requireNumber(segment.start_s, 'start_s'),
    endS: requireNumber(segment.end_s, 'end_s'),
    emittedAtS: requireNumber(segment.emitted_at_s, 'emitted_at_s'),
    reason: requireString(segment.reason, 'reason'),
  };
}

export function parseUnifiedStreamMessage(text) {
  const message = requireObject(JSON.parse(text), 'Server message');
  const type = requireString(message.type, 'type');

  switch (type) {
    case 'interim':
      return {
        type,
        segmentIndex: requireInteger(message.segment_index, 'segment_index'),
        transcription: requireString(message.transcription, 'transcription'),
        startS: requireNumber(message.start_s, 'start_s'),
        audioEndS: requireNumber(message.audio_end_s, 'audio_end_s'),
      };
    case 'final_segment':
      return { type, ...parseFinalSegment(message) };
    case 'final': {
      if (!Array.isArray(message.segments)) {
        throw new TypeError('segments must be an array.');
      }
      return {
        type,
        transcription: requireString(message.transcription, 'transcription'),
        segments: message.segments.map(parseFinalSegment),
        reason: requireString(message.reason, 'reason'),
      };
    }
    case 'PONG':
      return { type: 'pong' };
    case 'error':
      return { type, message: requireString(message.message, 'message') };
    case 'cancelled':
      return { type };
    default:
      return { type: 'unknown', messageType: type };
  }
}

export class UnifiedStreamTranscriptAccumulator {
  #committedSegments = new Map();
  #interimSegmentIndex = null;
  #interimText = null;
  #finalText = null;

  consume(message) {
    switch (message?.type) {
      case 'interim':
        if (this.#committedSegments.has(message.segmentIndex)) return;
        this.#interimSegmentIndex = message.segmentIndex;
        this.#interimText = message.transcription;
        break;
      case 'final_segment':
        this.#committedSegments.set(message.segmentIndex, message.transcription);
        if (this.#interimSegmentIndex === message.segmentIndex) {
          this.#interimSegmentIndex = null;
          this.#interimText = null;
        }
        break;
      case 'final':
        for (const segment of message.segments) {
          this.#committedSegments.set(segment.segmentIndex, segment.transcription);
        }
        this.#interimSegmentIndex = null;
        this.#interimText = null;
        this.#finalText = message.transcription;
        break;
      default:
        break;
    }
  }

  get displayText() {
    const committedText = [...this.#committedSegments.keys()]
      .sort((left, right) => left - right)
      .map(segmentIndex => this.#committedSegments.get(segmentIndex));
    const visibleText = [...committedText, this.#interimText]
      .filter(text => text !== null && text !== undefined && text.length > 0);
    return visibleText.join(' ');
  }

  get terminalAggregate() {
    return this.#finalText;
  }

  get degradedAggregate() {
    return this.#finalText === null ? this.displayText : null;
  }

  snapshot() {
    return {
      displayText: this.displayText,
      terminalAggregate: this.terminalAggregate,
      degradedAggregate: this.degradedAggregate,
    };
  }
}
