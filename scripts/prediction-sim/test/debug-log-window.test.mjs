import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import {
  MAXIMUM_RESIDENT_LOG_ROWS,
  mergeDebugLogWindow,
} from '../lib/debug-log-window.mjs';

function descendingRange(start, end) {
  return Array.from({ length: start - end + 1 }, (_, index) => start - index);
}

function ascendingRange(start, end) {
  return Array.from({ length: end - start + 1 }, (_, index) => start + index);
}

describe('debug log resident window', () => {
  it('keeps the configured cap and evicts rows behind the older-page direction', () => {
    const initial = mergeDebugLogWindow({
      loadedIds: [],
      pageIds: descendingRange(300, 101),
      direction: 'newer',
      totalCount: 500,
    });
    const olderPage = mergeDebugLogWindow({
      loadedIds: initial.residentIds,
      pageIds: descendingRange(100, 1),
      direction: 'older',
      totalCount: 500,
    });

    assert.equal(MAXIMUM_RESIDENT_LOG_ROWS, 200);
    assert.equal(olderPage.loadedCount, MAXIMUM_RESIDENT_LOG_ROWS);
    assert.deepEqual(olderPage.residentIds, descendingRange(200, 1));
    assert.deepEqual(olderPage.evictedIds, descendingRange(300, 201));
    assert.equal(olderPage.totalCount, 500);
    assert.equal(olderPage.newestCursor, 200);
    assert.equal(olderPage.oldestCursor, 1);
  });

  it('retains independent edge cursors so scroll-back can re-fetch without duplicates', () => {
    const olderWindow = mergeDebugLogWindow({
      loadedIds: descendingRange(200, 1),
      pageIds: ascendingRange(201, 250),
      direction: 'newer',
      totalCount: 300,
    });

    assert.deepEqual(olderWindow.residentIds, descendingRange(250, 51));
    assert.deepEqual(olderWindow.evictedIds, descendingRange(50, 1));
    assert.equal(olderWindow.newestCursor, 250);
    assert.equal(olderWindow.oldestCursor, 51);
    assert.equal(new Set(olderWindow.residentIds).size, olderWindow.loadedCount);

    const nextNewerWindow = mergeDebugLogWindow({
      loadedIds: olderWindow.residentIds,
      pageIds: ascendingRange(251, 300),
      direction: 'newer',
      totalCount: 300,
    });

    assert.deepEqual(nextNewerWindow.residentIds, descendingRange(300, 101));
    assert.equal(nextNewerWindow.loadedCount, MAXIMUM_RESIDENT_LOG_ROWS);
    assert.equal(nextNewerWindow.newestCursor, 300);
    assert.equal(nextNewerWindow.oldestCursor, 101);
    assert.equal(new Set(nextNewerWindow.residentIds).size, nextNewerWindow.loadedCount);
  });

  it('deduplicates overlapping pages and reports resident versus total counts', () => {
    const window = mergeDebugLogWindow({
      loadedIds: [8, 7, 6, 5],
      pageIds: [7, 6, 5, 4, 3],
      direction: 'older',
      totalCount: 20,
      limit: 5,
    });

    assert.deepEqual(window.residentIds, [7, 6, 5, 4, 3]);
    assert.deepEqual(window.evictedIds, [8]);
    assert.equal(window.loadedCount, 5);
    assert.equal(window.totalCount, 20);
    assert.equal(window.newestCursor, 7);
    assert.equal(window.oldestCursor, 3);
  });
});
