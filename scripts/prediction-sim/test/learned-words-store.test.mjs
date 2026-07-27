import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { LearnedWordsStore } from '../lib/learned-words-store.mjs';
import { CANONICAL_APOSTROPHE } from '../lib/text-normalization.mjs';

describe('LearnedWordsStore (JS port)', () => {
  it('add(don\'t U+2019) then contains(don\'t U+0027) returns true', () => {
    const store = new LearnedWordsStore();
    store.add(`don${CANONICAL_APOSTROPHE}t`); // U+2019
    assert.ok(store.contains("don't"));          // U+0027
  });

  it('add(don\'t U+0027) then contains(don\'t U+2019) returns true', () => {
    const store = new LearnedWordsStore();
    store.add("don't");                          // U+0027
    assert.ok(store.contains(`don${CANONICAL_APOSTROPHE}t`)); // U+2019
  });

  it('idempotent add — adding same word twice does not duplicate', () => {
    const store = new LearnedWordsStore();
    store.add("don't");
    store.add("don't");
    assert.strictEqual(store.allWords().length, 1);
  });

  it('FIFO eviction at the cap', () => {
    const store = new LearnedWordsStore(3);
    store.add('one');
    store.add('two');
    store.add('three');
    store.add('four'); // triggers eviction of 'one'

    assert.ok(!store.contains('one'), 'one should be evicted');
    assert.ok(store.contains('two'));
    assert.ok(store.contains('three'));
    assert.ok(store.contains('four'));
    assert.strictEqual(store.allWords().length, 3);
  });

  it('evicted word\'s insertionOrder entry is removed', () => {
    const store = new LearnedWordsStore(2);
    store.add('first');
    store.add('second');
    store.add('third'); // evicts 'first'

    const recent = store.allWordsMostRecentFirst();
    assert.strictEqual(recent.length, 2);
    assert.ok(recent.includes('second'));
    assert.ok(recent.includes('third'));
    assert.ok(!recent.includes('first'));
  });

  it('contains returns false for word not in store', () => {
    const store = new LearnedWordsStore();
    assert.ok(!store.contains('nonexistent'));
  });

  it('remove removes a word', () => {
    const store = new LearnedWordsStore();
    store.add('hello');
    assert.ok(store.contains('hello'));
    store.remove('hello');
    assert.ok(!store.contains('hello'));
  });

  it('clear removes all words', () => {
    const store = new LearnedWordsStore();
    store.add('one');
    store.add('two');
    store.clear();
    assert.strictEqual(store.allWords().length, 0);
  });

  it('reload with canonicalization upgrades stored words', () => {
    const store = new LearnedWordsStore();
    // Simulate reload from UserDefaults with U+0027 apostrophes
    store.reload(["don't", "can't"]);
    // Should be findable with either apostrophe variant
    assert.ok(store.contains(`don${CANONICAL_APOSTROPHE}t`));
    assert.ok(store.contains(`can${CANONICAL_APOSTROPHE}t`));
    assert.ok(store.contains("don't"));
    assert.ok(store.contains("can't"));
  });

  it('reload respects maxLearnedWords cap', () => {
    const store = new LearnedWordsStore(2);
    store.reload(['a', 'b', 'c', 'd']);
    const words = store.allWords();
    assert.strictEqual(words.length, 2);
    // Should keep the LAST entries (suffix)
    assert.ok(words.includes('c'));
    assert.ok(words.includes('d'));
    assert.ok(!words.includes('a'));
    assert.ok(!words.includes('b'));
  });

  it('reload with empty or null clears the store', () => {
    const store = new LearnedWordsStore();
    store.add('hello');
    store.reload([]);
    assert.strictEqual(store.allWords().length, 0);

    store.add('world');
    store.reload(null);
    assert.strictEqual(store.allWords().length, 0);
  });
});
