export const LOG_SHIPPER_MAX_BODY_BYTES = 60 * 1024;

function requestBodyByteCount(entries) {
  return Buffer.byteLength(JSON.stringify({ entries }), 'utf8');
}

export function chunkLogEntries(
  entries,
  maximumBodyBytes = LOG_SHIPPER_MAX_BODY_BYTES
) {
  if (!Array.isArray(entries)) {
    throw new TypeError('Log shipper entries must be an array');
  }
  if (!Number.isSafeInteger(maximumBodyBytes) || maximumBodyBytes < 1) {
    throw new RangeError('The log request body limit must be a positive integer');
  }

  const chunks = [];
  let currentChunk = [];

  for (const entry of entries) {
    const candidate = [...currentChunk, entry];
    if (requestBodyByteCount(candidate) <= maximumBodyBytes) {
      currentChunk = candidate;
      continue;
    }

    if (currentChunk.length > 0) {
      chunks.push(currentChunk);
    }
    currentChunk = [];

    const singleEntry = [entry];
    if (requestBodyByteCount(singleEntry) <= maximumBodyBytes) {
      currentChunk = singleEntry;
    }
  }

  if (currentChunk.length > 0) {
    chunks.push(currentChunk);
  }
  return chunks;
}
