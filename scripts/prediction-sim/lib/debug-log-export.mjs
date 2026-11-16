function readableValue(value) {
  if (value === null) {
    return 'null';
  }
  if (Array.isArray(value)) {
    return `[${value.map(readableValue).join(', ')}]`;
  }
  if (typeof value === 'object') {
    const fields = Object.keys(value).sort()
      .map(key => `${key}: ${readableValue(value[key])}`);
    return `{${fields.join(', ')}}`;
  }
  return String(value);
}

function formatEntry(entry) {
  const timestamp = entry.timestamp ?? '—';
  const level = entry.level ? `[${String(entry.level).toUpperCase()}]` : '[—]';
  const component = entry.component ? `[${entry.component}]` : '[—]';
  const message = entry.message ? entry.message : entry.raw;
  const lines = [`${timestamp} ${level} ${component} ${message}`];

  if (entry.payload) {
    for (const key of Object.keys(entry.payload).sort()) {
      lines.push(`  ${key}: ${readableValue(entry.payload[key])}`);
    }
  }

  return lines.join('\n');
}

export function buildDebugLogExport(entries, { scrubPII = false, scrub } = {}) {
  if (!Array.isArray(entries)) {
    throw new Error('entries must be an array');
  }
  if (scrubPII && typeof scrub !== 'function') {
    throw new Error('scrub must be provided when scrubPII is enabled');
  }

  const joinedText = entries.map(formatEntry).join('\n');
  const text = scrubPII ? scrub(joinedText) : joinedText;
  const estimatedRawBytes = entries.reduce(
    (total, entry) => total + Buffer.byteLength(entry.raw, 'utf8'),
    0
  );

  return {
    text,
    entryCount: entries.length,
    byteCount: Buffer.byteLength(text, 'utf8'),
    estimatedRawBytes,
  };
}
