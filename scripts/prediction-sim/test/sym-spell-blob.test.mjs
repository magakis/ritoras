import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { SymSpell } from '../lib/symspell.mjs';
import { loadCanonicalDictionary } from '../lib/word-list-loader.mjs';
import {
  SYMSPELL_BLOB_HEADER_BYTES,
  SYMSPELL_MAX_EDIT_DISTANCE,
  SYMSPELL_MIN_WORD_FREQ,
  SYMSPELL_PREFIX_LENGTH,
  buildSymSpellBlob,
  fnv1a64,
  readSymSpellBlob,
  readSymSpellBlobHeader,
} from '../lib/sym-spell-blob.mjs';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const RESOURCE_DIR = path.resolve(__dirname, '../../../keyboard/Sources/Prediction/Resources');
const FIXTURE_PATH = path.resolve(__dirname, '../fixtures/typo-corpus.json');
const LANGUAGE_CASES = {
  en: {
    wordlist: path.resolve(RESOURCE_DIR, 'frequency_dictionary_en_wordfreq_50k.txt'),
    blob: path.resolve(RESOURCE_DIR, 'symspell_index_en_v1.blob'),
    fileEntries: 49_999,
    wordCount: 23_158,
    deleteKeyCount: 230_403,
    deleteValueCount: 504_740,
  },
  el: {
    wordlist: path.resolve(RESOURCE_DIR, 'frequency_dictionary_el_wordfreq_50k.txt'),
    blob: path.resolve(RESOURCE_DIR, 'symspell_index_el_v1.blob'),
    fileEntries: 42_858,
    wordCount: 32_962,
    deleteKeyCount: 368_445,
    deleteValueCount: 818_618,
  },
};

const realCases = new Map();

function makeSymSpell(entries) {
  const symspell = new SymSpell(SYMSPELL_MAX_EDIT_DISTANCE, SYMSPELL_PREFIX_LENGTH);
  symspell.bulkLoad(entries);
  symspell.finalize();
  return symspell;
}

function realCase(lang) {
  if (realCases.has(lang)) return realCases.get(lang);

  const paths = LANGUAGE_CASES[lang];
  const wordlistBytes = fs.readFileSync(paths.wordlist);
  const allEntries = loadCanonicalDictionary(paths.wordlist);
  assert.strictEqual(allEntries.length, paths.fileEntries);
  const entries = allEntries
    .filter(entry => entry.count >= SYMSPELL_MIN_WORD_FREQ);
  const legacy = makeSymSpell(entries);
  const blob = readSymSpellBlob(paths.blob, {
    expectedLang: lang,
    expectedWordlistFnv1a64: fnv1a64(wordlistBytes),
  });
  const value = { paths, wordlistBytes, entries, legacy, blob };
  realCases.set(lang, value);
  return value;
}

function rebuildBlobHash(bytes) {
  const output = Buffer.from(bytes);
  output.writeBigUInt64LE(fnv1a64(output.subarray(0, -8)), output.length - 8);
  return output;
}

function expectBlobFailure(bytes, message, options = { expectedLang: 'en' }) {
  assert.throws(() => readSymSpellBlob(bytes, options), new RegExp(message));
}

function mangleWord(word) {
  const chars = [...word];
  const variants = [];
  if (chars.length >= 2) {
    const transposed = [...chars];
    [transposed[0], transposed[1]] = [transposed[1], transposed[0]];
    variants.push(transposed.join(''));
  }
  if (chars.length >= 1) variants.push(chars.slice(1).join(''));
  if (chars.length >= 1) {
    variants.push(`${chars.slice(0, -1).join('')}${chars.at(-1) === 'a' ? 'e' : 'a'}`);
  }
  return [...new Set(variants)].filter(variant => variant !== word);
}

describe('SymSpell v1 blob format', () => {
  it('round-trips every field of a small dictionary', () => {
    const entries = [
      { word: 'Zebra', count: 40 },
      { word: 'alpha', count: 900 },
      { word: 'don\u{2019}t', count: 75 },
      { word: '😀alpha', count: 12 },
    ];
    const sourceBytes = Buffer.from('synthetic dictionary\n', 'utf8');
    const original = makeSymSpell(entries);
    const bytes = buildSymSpellBlob(original, {
      lang: 'en',
      wordlistFnv1a64: fnv1a64(sourceBytes),
    });
    const blob = readSymSpellBlob(bytes, { expectedLang: 'en' });

    assert.ok(blob.buffer.equals(bytes));
    assert.strictEqual(blob.formatVersion, 1);
    assert.strictEqual(blob.maxEditDistance, 2);
    assert.strictEqual(blob.prefixLength, 7);
    assert.strictEqual(blob.lang, 'en');
    assert.strictEqual(blob.wordCount, original.words.length);
    assert.strictEqual(blob.deleteKeyCount, original.deleteKeys.length);
    assert.strictEqual(blob.deleteValueCount, original.deleteValues.length);
    assert.strictEqual(blob.wordlistFnv1a64, fnv1a64(sourceBytes));
    const wordPoolBytes = original.words.reduce(
      (total, word) => total + Buffer.byteLength(word, 'utf8') + 1,
      0
    );
    const deleteKeyPoolBytes = original.deleteKeys.reduce(
      (total, key) => total + Buffer.byteLength(key, 'utf8') + 1,
      0
    );
    const sortedDeleteKeys = [...original.deleteKeys]
      .sort((a, b) => Buffer.compare(Buffer.from(a), Buffer.from(b)));
    const expectedDeleteKeyOffsets = [wordPoolBytes];
    for (const key of sortedDeleteKeys) {
      expectedDeleteKeyOffsets.push(
        expectedDeleteKeyOffsets.at(-1) + Buffer.byteLength(key, 'utf8') + 1
      );
    }
    const expectedDeleteOffsets = [0];
    const expectedDeleteValues = [];
    for (const key of sortedDeleteKeys) {
      const index = original.deleteKeys.indexOf(key);
      expectedDeleteValues.push(
        ...original.deleteValues.slice(original.deleteOffsets[index], original.deleteOffsets[index + 1])
      );
      expectedDeleteOffsets.push(expectedDeleteValues.length);
    }
    assert.deepStrictEqual([...blob.wordOffsets], [
      ...original.words.reduce((offsets, word) => {
        offsets.push(offsets.at(-1) + Buffer.byteLength(word, 'utf8') + 1);
        return offsets;
      }, [0]),
    ].slice(0, -1).concat(wordPoolBytes + deleteKeyPoolBytes));
    assert.deepStrictEqual(
      Array.from({ length: blob.wordCount }, (_, index) => blob.wordAt(index)),
      original.words
    );
    assert.deepStrictEqual(
      Array.from(blob.sortedWordIdx, index => blob.wordAt(index)),
      [...original.words].sort((a, b) => Buffer.compare(Buffer.from(a), Buffer.from(b)))
    );
    assert.deepStrictEqual(
      Array.from(blob.counts),
      original.counts
    );
    assert.deepStrictEqual(Array.from(blob.deleteKeyOffsets), expectedDeleteKeyOffsets);
    assert.deepStrictEqual(Array.from(blob.deleteOffsets), expectedDeleteOffsets);
    assert.deepStrictEqual(Array.from(blob.deleteValues), expectedDeleteValues);
    assert.deepStrictEqual(
      Array.from(blob.stringPool),
      Array.from(bytes.subarray(blob.sectionOffsets.stringPool, blob.sectionOffsets.stringPool + blob.stringPoolBytes))
    );
    assert.strictEqual(blob.sectionOffsets.fileSize, bytes.length);
  });

  it('matches the legacy in-memory index on sampled real English and Greek inputs', () => {
    assert.ok(fs.existsSync(FIXTURE_PATH), `missing typo fixture: ${FIXTURE_PATH}`);
    for (const lang of ['en', 'el']) {
      const { legacy, blob } = realCase(lang);
      const inputs = new Set();
      for (let index = 0; index < legacy.words.length; index += 20) {
        const word = legacy.words[index];
        inputs.add(word);
        for (const variant of mangleWord(word)) inputs.add(variant);
      }
      if (lang === 'en') {
        for (const entry of JSON.parse(fs.readFileSync(FIXTURE_PATH, 'utf8'))) {
          inputs.add(entry.typedWord);
        }
      }

      for (const input of inputs) {
        assert.deepStrictEqual(
          blob.lookup(input, undefined, 'all'),
          legacy.lookup(input, undefined, 'all'),
          `${lang} lookup mismatch for ${JSON.stringify(input)}`
        );
      }
      for (let index = 0; index < legacy.words.length; index += 20) {
        const word = legacy.words[index];
        assert.strictEqual(blob.countFor(word), legacy.countFor(word), `${lang} count mismatch for ${word}`);
      }
    }
  });

  it('rejects wrong magic, version, language, truncation, checksum, source hash, and config', () => {
    const { blob: source } = realCase('en');

    const wrongMagic = Buffer.from(source.buffer);
    wrongMagic.write('BAD!', 0, 4, 'ascii');
    expectBlobFailure(wrongMagic, 'magic');

    const wrongVersion = Buffer.from(source.buffer);
    wrongVersion.writeUInt16LE(2, 4);
    expectBlobFailure(rebuildBlobHash(wrongVersion), 'version');

    const wrongLanguage = Buffer.from(source.buffer);
    wrongLanguage.write('zz\0\0', 8, 4, 'ascii');
    expectBlobFailure(rebuildBlobHash(wrongLanguage), 'language');

    expectBlobFailure(source.buffer.subarray(0, -1), 'dimensions');

    const flipped = Buffer.from(source.buffer);
    flipped[flipped.length - 1] ^= 1;
    expectBlobFailure(flipped, 'checksum');

    const staleWordlist = Buffer.from(source.buffer);
    staleWordlist.writeBigUInt64LE(source.wordlistFnv1a64 ^ 1n, 0x1c);
    expectBlobFailure(
      rebuildBlobHash(staleWordlist),
      'source wordlist checksum',
      { expectedLang: 'en', expectedWordlistFnv1a64: source.wordlistFnv1a64 }
    );

    const wrongEditDistance = Buffer.from(source.buffer);
    wrongEditDistance.writeUInt8(1, 6);
    expectBlobFailure(rebuildBlobHash(wrongEditDistance), 'edit distance');

    const wrongPrefixLength = Buffer.from(source.buffer);
    wrongPrefixLength.writeUInt8(6, 7);
    expectBlobFailure(rebuildBlobHash(wrongPrefixLength), 'prefix length');
  });

  it('keeps all section offsets aligned and all sentinels exact', () => {
    const { blob } = realCase('en');
    const offsets = blob.sectionOffsets;
    for (const [name, offset] of Object.entries(offsets)) {
      if (name === 'fileSize') continue;
      assert.strictEqual(offset % 4, 0, `${name} is not 4-byte aligned`);
    }
    assert.strictEqual(offsets.blobFnv1a64 % 8, 0);
    assert.strictEqual(offsets.blobFnv1a64, blob.buffer.length - 8);
    assert.strictEqual(blob.wordOffsets.at(-1), blob.stringPoolBytes);
    assert.strictEqual(blob.deleteKeyOffsets.at(-1), blob.stringPoolBytes);
    assert.strictEqual(blob.deleteOffsets.at(-1), blob.deleteValueCount);
    assert.strictEqual(blob.stringPool.length, blob.stringPoolBytes);
    assert.strictEqual(blob.buffer.length, offsets.fileSize);
  });

  it('is deterministic when the same index is built twice', () => {
    const entries = [
      { word: 'one', count: 100 },
      { word: 'two', count: 90 },
      { word: 'three', count: 80 },
      { word: '😀four', count: 70 },
    ];
    const options = { lang: 'el', wordlistFnv1a64: fnv1a64(Buffer.from('same source')) };
    const first = buildSymSpellBlob(entries, options);
    const second = buildSymSpellBlob(entries, options);
    assert.ok(first.equals(second));
  });

  it('pins UTF-8 byte ordering for above-BMP words and delete keys', () => {
    const entries = [
      { word: '😀a', count: 50 },
      { word: '😃a', count: 40 },
      { word: 'a😀', count: 30 },
      { word: '😀b', count: 20 },
    ];
    const legacy = makeSymSpell(entries);
    const bytes = buildSymSpellBlob(legacy, {
      lang: 'en',
      wordlistFnv1a64: fnv1a64(Buffer.from('emoji source')),
    });
    const blob = readSymSpellBlob(bytes, { expectedLang: 'en' });
    const expectedWordOrder = [...legacy.words]
      .sort((a, b) => Buffer.compare(Buffer.from(a, 'utf8'), Buffer.from(b, 'utf8')));
    assert.deepStrictEqual(
      Array.from(blob.sortedWordIdx, index => blob.wordAt(index)),
      expectedWordOrder
    );
    for (let index = 1; index < blob.deleteKeyCount; index++) {
      assert.ok(Buffer.compare(blob.deleteKeyBytesAt(index - 1), blob.deleteKeyBytesAt(index)) <= 0);
    }
    for (const input of ['😀a', '😃a', 'a😀', '😀c', '😀']) {
      assert.deepStrictEqual(blob.lookup(input, undefined, 'all'), legacy.lookup(input, undefined, 'all'));
    }
  });

  it('committed blob headers are fresh and match the approved dimensions', () => {
    for (const lang of ['en', 'el']) {
      const paths = LANGUAGE_CASES[lang];
      const header = readSymSpellBlobHeader(paths.blob);
      const expected = LANGUAGE_CASES[lang];
      assert.strictEqual(header.lang, lang);
      assert.strictEqual(header.wordCount, expected.wordCount);
      assert.strictEqual(header.deleteKeyCount, expected.deleteKeyCount);
      assert.strictEqual(header.deleteValueCount, expected.deleteValueCount);
      assert.strictEqual(header.wordlistFnv1a64, fnv1a64(fs.readFileSync(paths.wordlist)));
      assert.strictEqual(header.formatVersion, 1);
      assert.strictEqual(header.maxEditDistance, 2);
      assert.strictEqual(header.prefixLength, 7);
      assert.strictEqual(SYMSPELL_BLOB_HEADER_BYTES, 64);
    }
  });
});
