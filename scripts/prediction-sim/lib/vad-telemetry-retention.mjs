export const VAD_TELEMETRY_RETENTION = Object.freeze({
  tailFrameLimit: 500,
  historicalFrameLimit: 1500,
  maxEvents: 256,
  payloadBudgetBytes: 768 * 1024,
});

export function retainTelemetryFrames(frames) {
  const tail = [];
  const history = [];
  let historicalDropped = 0;
  for (const frame of frames) {
    tail.push(frame);
    if (tail.length > VAD_TELEMETRY_RETENTION.tailFrameLimit) {
      history.push(tail.shift());
      if (history.length > VAD_TELEMETRY_RETENTION.historicalFrameLimit) {
        const before = history.length;
        const compacted = history.filter((_, index) => index % 2 === 0);
        historicalDropped += before - compacted.length;
        history.splice(0, history.length, ...compacted);
      }
    }
  }
  return { frames: [...history, ...tail], historicalDropped, tailDropped: 0 };
}

export function serializeTelemetryPayload(payload) {
  const retained = retainTelemetryFrames(payload.frames ?? []);
  const value = {
    ...payload,
    schema_version: 2,
    frames: retained.frames,
    summary: {
      ...payload.summary,
      retention: {
        policy: 'stratified_tail',
        historical_limit: VAD_TELEMETRY_RETENTION.historicalFrameLimit,
        tail_limit: VAD_TELEMETRY_RETENTION.tailFrameLimit,
        historical_dropped: retained.historicalDropped,
        tail_dropped: retained.tailDropped,
        events_dropped: Math.max(0, (payload.events?.length ?? 0) - VAD_TELEMETRY_RETENTION.maxEvents),
      },
    },
    events: (payload.events ?? []).slice(-VAD_TELEMETRY_RETENTION.maxEvents),
  };
  let data = Buffer.from(JSON.stringify(value));
  while (data.length > VAD_TELEMETRY_RETENTION.payloadBudgetBytes) {
    const historyCount = value.frames.length - Math.min(value.frames.length, VAD_TELEMETRY_RETENTION.tailFrameLimit);
    if (historyCount === 0) throw new Error('Telemetry metadata exceeds payload budget');
    const trimCount = Math.min(100, historyCount);
    value.frames.splice(historyCount - trimCount, trimCount);
    value.summary.retention.historical_dropped += trimCount;
    data = Buffer.from(JSON.stringify(value));
  }
  return data;
}
