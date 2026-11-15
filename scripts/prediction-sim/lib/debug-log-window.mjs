export const MAXIMUM_RESIDENT_LOG_ROWS = 200;

export function mergeDebugLogWindow({
  loadedIds,
  pageIds,
  direction,
  totalCount,
  limit = MAXIMUM_RESIDENT_LOG_ROWS,
}) {
  if (!Number.isSafeInteger(limit) || limit < 1) {
    throw new Error('limit must be a positive integer');
  }
  if (!Number.isSafeInteger(totalCount) || totalCount < 0) {
    throw new Error('totalCount must be a non-negative integer');
  }
  if (direction !== 'older' && direction !== 'newer') {
    throw new Error(`unsupported page direction: ${direction}`);
  }

  const mergedIds = [...new Set([...loadedIds, ...pageIds])]
    .sort((left, right) => right - left);
  const residentIds = mergedIds.length > limit
    ? direction === 'older'
      ? mergedIds.slice(-limit)
      : mergedIds.slice(0, limit)
    : mergedIds;
  const residentIdSet = new Set(residentIds);
  const evictedIds = mergedIds.filter(id => !residentIdSet.has(id));

  return {
    residentIds,
    evictedIds,
    newestCursor: residentIds[0] ?? null,
    oldestCursor: residentIds.at(-1) ?? null,
    loadedCount: residentIds.length,
    totalCount,
  };
}
