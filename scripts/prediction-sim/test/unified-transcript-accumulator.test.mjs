import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import {
  parseUnifiedStreamMessage,
  UnifiedStreamTranscriptAccumulator,
} from '../lib/unified-transcript-accumulator.mjs';

const parse = message => parseUnifiedStreamMessage(JSON.stringify(message));

function finalSegment(segmentIndex, transcription, reason = 'endpoint') {
  return {
    segment_index: segmentIndex,
    transcription,
    start_s: segmentIndex * 2,
    end_s: segmentIndex * 2 + 1,
    emitted_at_s: segmentIndex * 2 + 1.1,
    reason,
  };
}

describe('unified stream server-message parser', () => {
  it('parses interim fields into a typed event', () => {
    assert.deepEqual(parse({
      type: 'interim',
      segment_index: 3,
      transcription: 'live words',
      start_s: 1.25,
      audio_end_s: 4.5,
    }), {
      type: 'interim',
      segmentIndex: 3,
      transcription: 'live words',
      startS: 1.25,
      audioEndS: 4.5,
    });
  });

  it('parses endpoint final_segment fields', () => {
    assert.deepEqual(parse({ type: 'final_segment', ...finalSegment(1, 'committed') }), {
      type: 'final_segment',
      segmentIndex: 1,
      transcription: 'committed',
      startS: 2,
      endS: 3,
      emittedAtS: 3.1,
      reason: 'endpoint',
    });
  });

  it('parses an aggregate final with its end-reason segment', () => {
    assert.deepEqual(parse({
      type: 'final',
      transcription: 'first last',
      segments: [finalSegment(0, 'first'), finalSegment(1, 'last', 'end')],
      reason: 'END',
    }), {
      type: 'final',
      transcription: 'first last',
      segments: [
        {
          segmentIndex: 0,
          transcription: 'first',
          startS: 0,
          endS: 1,
          emittedAtS: 1.1,
          reason: 'endpoint',
        },
        {
          segmentIndex: 1,
          transcription: 'last',
          startS: 2,
          endS: 3,
          emittedAtS: 3.1,
          reason: 'end',
        },
      ],
      reason: 'END',
    });
  });

  it('parses PONG, cancelled, and error events', () => {
    assert.deepEqual(parse({ type: 'PONG', ping_seq: { probe: 4 } }), { type: 'pong' });
    assert.deepEqual(parse({ type: 'cancelled' }), { type: 'cancelled' });
    assert.deepEqual(parse({ type: 'error', message: 'server failed' }), {
      type: 'error',
      message: 'server failed',
    });
  });

  it('rejects malformed JSON, non-object messages, and incomplete schemas', () => {
    assert.throws(() => parseUnifiedStreamMessage('{'), SyntaxError);
    assert.throws(() => parseUnifiedStreamMessage('[]'), TypeError);
    assert.throws(() => parse({ type: 'interim', transcription: 'missing timing' }), TypeError);
    assert.throws(() => parse({ type: 'error' }), TypeError);
  });

  it('preserves an unrecognized message type as a typed unknown event', () => {
    assert.deepEqual(parse({ type: 'future_message' }), {
      type: 'unknown',
      messageType: 'future_message',
    });
  });
});

describe('unified stream transcript accumulator', () => {
  it('replaces interim text for the currently open segment', () => {
    const accumulator = new UnifiedStreamTranscriptAccumulator();
    accumulator.consume(parse({
      type: 'interim', segment_index: 0, transcription: 'hello', start_s: 0, audio_end_s: 1,
    }));
    accumulator.consume(parse({
      type: 'interim', segment_index: 0, transcription: 'hello there', start_s: 0, audio_end_s: 2,
    }));

    assert.equal(accumulator.displayText, 'hello there');
  });

  it('commits a final_segment and clears its matching interim', () => {
    const accumulator = new UnifiedStreamTranscriptAccumulator();
    accumulator.consume(parse({
      type: 'interim', segment_index: 0, transcription: 'first phrase', start_s: 0, audio_end_s: 1,
    }));
    accumulator.consume(parse({ type: 'final_segment', ...finalSegment(0, 'first phrase') }));

    assert.equal(accumulator.displayText, 'first phrase');
    assert.equal(accumulator.degradedAggregate, 'first phrase');
  });

  it('keeps the latest open interim when an earlier segment is finalized', () => {
    const accumulator = new UnifiedStreamTranscriptAccumulator();
    accumulator.consume(parse({
      type: 'interim', segment_index: 1, transcription: 'open words', start_s: 2, audio_end_s: 3,
    }));
    accumulator.consume(parse({ type: 'final_segment', ...finalSegment(0, 'finished words') }));

    assert.equal(accumulator.displayText, 'finished words open words');
  });

  it('orders committed segments by segment_index', () => {
    const accumulator = new UnifiedStreamTranscriptAccumulator();
    accumulator.consume(parse({ type: 'final_segment', ...finalSegment(2, 'third') }));
    accumulator.consume(parse({ type: 'final_segment', ...finalSegment(0, 'first') }));
    accumulator.consume(parse({ type: 'final_segment', ...finalSegment(1, 'second') }));

    assert.equal(accumulator.displayText, 'first second third');
  });

  it('replaces a committed segment when the same segment_index is received again', () => {
    const accumulator = new UnifiedStreamTranscriptAccumulator();
    accumulator.consume(parse({ type: 'final_segment', ...finalSegment(0, 'draft') }));
    accumulator.consume(parse({ type: 'final_segment', ...finalSegment(0, 'corrected') }));

    assert.equal(accumulator.displayText, 'corrected');
  });

  it('includes an END segment and exposes the server final as terminal aggregate', () => {
    const accumulator = new UnifiedStreamTranscriptAccumulator();
    accumulator.consume(parse({ type: 'final_segment', ...finalSegment(0, 'committed') }));
    accumulator.consume(parse({
      type: 'interim', segment_index: 1, transcription: 'open', start_s: 2, audio_end_s: 3,
    }));
    accumulator.consume(parse({
      type: 'final',
      transcription: 'server aggregate',
      segments: [finalSegment(0, 'committed'), finalSegment(1, 'open', 'end')],
      reason: 'END',
    }));

    assert.equal(accumulator.displayText, 'committed open');
    assert.equal(accumulator.terminalAggregate, 'server aggregate');
    assert.equal(accumulator.degradedAggregate, null);
  });

  it('uses committed segments and the latest interim as a degraded fallback', () => {
    const accumulator = new UnifiedStreamTranscriptAccumulator();
    accumulator.consume(parse({ type: 'final_segment', ...finalSegment(0, 'saved') }));
    accumulator.consume(parse({
      type: 'interim', segment_index: 1, transcription: 'still speaking', start_s: 2, audio_end_s: 3,
    }));

    assert.deepEqual(accumulator.snapshot(), {
      displayText: 'saved still speaking',
      terminalAggregate: null,
      degradedAggregate: 'saved still speaking',
    });
  });
});
