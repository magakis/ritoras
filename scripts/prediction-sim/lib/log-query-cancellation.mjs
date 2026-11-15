export function isCurrentQueryEpoch(queryEpoch, currentEpoch) {
  return queryEpoch === currentEpoch;
}

export function isQuerySuperseded(queryEpoch, currentEpoch) {
  return !isCurrentQueryEpoch(queryEpoch, currentEpoch);
}
