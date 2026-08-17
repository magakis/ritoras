import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { fileURLToPath } from 'node:url';
import fs from 'node:fs';

const DICT_PATH = fileURLToPath(new URL('../../../keyboard/Sources/Prediction/Resources/frequency_dictionary_en_wordfreq_50k.txt', import.meta.url));

describe('bundled English dictionary (real file)', () => {
  it('has the "word count" format and is non-empty', () => {
    const lines = fs.readFileSync(DICT_PATH, 'utf8').split('\n').filter(Boolean);
    assert.ok(lines.length > 10_000, `expected 10k+ entries, got ${lines.length}`);
    for (const line of lines) {
      assert.match(line, /^\S+ \d+$/, `malformed line: ${line}`);
    }
  });

  it('contains the highest-frequency English word "the"', () => {
    const lines = fs.readFileSync(DICT_PATH, 'utf8').split('\n').filter(Boolean);
    const words = new Set(lines.map(line => line.slice(0, line.lastIndexOf(' '))));
    assert.ok(words.has('the'), 'the must be present');
  });
});
