import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { AMBIGUOUS_CONTRACTIONS, expansion } from '../lib/ambiguous-contractions.mjs';
import { CONTRACTIONS } from '../lib/contractions.mjs';
import { applyCapitalizationTemplate } from '../lib/apply-capitalization-template.mjs';
import { SymSpell } from '../lib/symspell.mjs';
import { SymSpellProvider } from '../lib/symspell-provider.mjs';
import { topCorrection } from '../lib/top-correction.mjs';
import { normalizeForKenLM } from '../lib/kenlm-normalize.mjs';

const APOSTROPHE = '\u{2019}';

const EXPECTED = new Map([
  ['its', `it${APOSTROPHE}s`],
  ['cant', `can${APOSTROPHE}t`],
  ['id', `I${APOSTROPHE}d`],
  ['well', `we${APOSTROPHE}ll`],
  ['were', `we${APOSTROPHE}re`],
  ['shell', `she${APOSTROPHE}ll`],
  ['ill', `I${APOSTROPHE}ll`],
  ['wed', `we${APOSTROPHE}d`],
  ['lets', `let${APOSTROPHE}s`],
]);

describe('AmbiguousContractions table', () => {
  it('maps all 9 ambiguous tokens to correctly-cased contractions', () => {
    assert.strictEqual(AMBIGUOUS_CONTRACTIONS.size, 9);
    for (const [input, expected] of EXPECTED) {
      assert.strictEqual(expansion(input), expected, `expansion("${input}")`);
    }
  });

  it('pronoun contractions carry the capital "I"', () => {
    assert.strictEqual(expansion('id'), `I${APOSTROPHE}d`);
    assert.strictEqual(expansion('ill'), `I${APOSTROPHE}ll`);
  });

  it('uses canonical U+2019 apostrophes only', () => {
    for (const [key, value] of AMBIGUOUS_CONTRACTIONS) {
      for (let i = 0; i < value.length; i++) {
        if ([0x2019, 0x2018, 0x27].includes(value.charCodeAt(i))) {
          assert.strictEqual(value.charCodeAt(i), 0x2019,
            `key "${key}" has non-canonical apostrophe at position ${i}`);
        }
      }
    }
  });

  it('returns null for unknown words and for deterministic-only keys', () => {
    assert.strictEqual(expansion('dont'), null);
    assert.strictEqual(expansion('xyzzz'), null);
  });

  it('excludes "hell" (low value — omitted by decision)', () => {
    assert.strictEqual(expansion('hell'), null);
  });

  it('no key overlaps the deterministic CONTRACTIONS table', () => {
    for (const key of AMBIGUOUS_CONTRACTIONS.keys()) {
      assert.ok(!CONTRACTIONS.has(key),
        `"${key}" must not also live in the deterministic Contractions table`);
    }
  });
});

describe('SymSpellProvider candidate injection', () => {
  it('for an ambiguous real-word token, verbatim and ambiguousContraction are both present', () => {
    const speller = new SymSpell(2, 7);
    speller.createDictionaryEntry('its', 5000);
    const dict = new Map([['its', { count: 5000 }]]);
    const provider = new SymSpellProvider(speller, dict);

    const results = provider.suggest('its', { verbosity: 'all' });

    const verbatim = results.find(s => s.text === 'its');
    assert.ok(verbatim, 'verbatim "its" present');
    assert.strictEqual(verbatim.score, 1.0, 'verbatim keeps score 1.0 (no deterministic demotion)');

    const contraction = results.find(s => s.text === `it${APOSTROPHE}s`);
    assert.ok(contraction, 'ambiguous contraction "it\'s" present');
    assert.strictEqual(contraction.source, 'ambiguousContraction');
    assert.strictEqual(contraction.score, 0.5);
    assert.strictEqual(contraction.isUnknownVerbatim, false);
  });

  it('injects the contraction regardless of isRealWord (alongside the typo branch)', () => {
    const speller = new SymSpell(2, 7);
    // "lets" below the real-word threshold → isRealWord=false → typo branch runs too.
    const dict = new Map([['lets', { count: 10 }]]);
    const provider = new SymSpellProvider(speller, dict);

    const results = provider.suggest('lets', { verbosity: 'all' });

    const verbatim = results.find(s => s.text === 'lets');
    assert.ok(verbatim, 'verbatim "lets" present');

    const contraction = results.find(s => s.text === `let${APOSTROPHE}s`);
    assert.ok(contraction, 'ambiguous contraction injected even when token is not a real word');
    assert.strictEqual(contraction.source, 'ambiguousContraction');
    assert.strictEqual(contraction.score, 0.5);
  });
});

describe('capital-I handling', () => {
  it('"id" renders as "I\'d" (capital I)', () => {
    const provider = new SymSpellProvider(new SymSpell(2, 7), new Map());
    const results = provider.suggest('id', { verbosity: 'all' });
    const contraction = results.find(s => s.source === 'ambiguousContraction');
    assert.ok(contraction, 'ambiguous candidate present');
    assert.strictEqual(contraction.text, `I${APOSTROPHE}d`);
  });

  it('"ill" renders as "I\'ll" (capital I)', () => {
    const provider = new SymSpellProvider(new SymSpell(2, 7), new Map());
    const results = provider.suggest('ill', { verbosity: 'all' });
    const contraction = results.find(s => s.source === 'ambiguousContraction');
    assert.ok(contraction, 'ambiguous candidate present');
    assert.strictEqual(contraction.text, `I${APOSTROPHE}ll`);
  });

  it('applyCapitalizationTemplate normalizes a lowercase i-pronoun to capital I', () => {
    assert.strictEqual(applyCapitalizationTemplate('id', `i${APOSTROPHE}d`), `I${APOSTROPHE}d`);
    assert.strictEqual(applyCapitalizationTemplate('ill', `i${APOSTROPHE}ll`), `I${APOSTROPHE}ll`);
    // ASCII apostrophe variant also normalized.
    assert.strictEqual(applyCapitalizationTemplate('id', "i'd"), "I'd");
  });

  it('does NOT capitalize arbitrary leading "i" (information)', () => {
    assert.strictEqual(applyCapitalizationTemplate('information', 'information'), 'information');
    assert.strictEqual(applyCapitalizationTemplate('id', 'information'), 'information');
  });
});

describe('margin gate (topCorrection)', () => {
  function ambiguousPool() {
    return [
      { text: 'its', score: 1.0, source: 'symspell' },
      { text: `it${APOSTROPHE}s`, score: 0.5, source: 'ambiguousContraction' },
    ];
  }

  it('returns the contraction when LM strongly favors it (large positive delta)', () => {
    // delta = -1.0 - (-5.0) = 4.0 ≥ 1.0 margin → flip.
    // The scorer models the ASCII-only KenLM vocabulary: it matches the
    // normalized U+0027 form, never the display-canonical U+2019.
    const scorer = (candidate) => {
      if (candidate === "it's") return -1.0;
      if (candidate === 'its') return -5.0;
      return -10.0;
    };
    const result = topCorrection({
      pool: ambiguousPool(),
      currentWord: 'its',
      previousWord: 'dog',
      previousWord2: null,
      kenlmScorer: scorer,
      trigramReady: true,
    });
    assert.ok(result !== null, 'contraction returned');
    assert.strictEqual(result.text, `it${APOSTROPHE}s`);
  });

  it('returns null when the delta is below the margin', () => {
    // delta = -2.0 - (-2.5) = 0.5 < 1.0 margin → no flip.
    const scorer = (candidate) => {
      if (candidate === "it's") return -2.0;
      if (candidate === 'its') return -2.5;
      return -10.0;
    };
    const result = topCorrection({
      pool: ambiguousPool(),
      currentWord: 'its',
      previousWord: 'dog',
      previousWord2: null,
      kenlmScorer: scorer,
      trigramReady: true,
    });
    assert.strictEqual(result, null, 'no flip when LM does not clearly favor the contraction');
  });

  it('returns null when there is no previous-word context (never auto-flip without LM)', () => {
    const result = topCorrection({
      pool: ambiguousPool(),
      currentWord: 'its',
      previousWord: null,
      previousWord2: null,
      kenlmScorer: null,
      trigramReady: false,
    });
    assert.strictEqual(result, null, 'ambiguous candidate without LM context → null');
  });

  it('returns null when trigram is not ready even with a previous word', () => {
    const scorer = (candidate) => {
      if (candidate === `it${APOSTROPHE}s`) return -1.0;
      if (candidate === 'its') return -5.0;
      return -10.0;
    };
    const result = topCorrection({
      pool: ambiguousPool(),
      currentWord: 'its',
      previousWord: 'dog',
      previousWord2: null,
      kenlmScorer: scorer,
      trigramReady: false,
    });
    assert.strictEqual(result, null, 'no flip without a ready trigram provider');
  });

  it('treats nil rawLogProb defensively as -10.0 (no flip)', () => {
    const scorer = () => null;
    const result = topCorrection({
      pool: ambiguousPool(),
      currentWord: 'its',
      previousWord: 'dog',
      previousWord2: null,
      kenlmScorer: scorer,
      trigramReady: true,
    });
    // both log probs fall back to -10.0 → delta = 0 < 1.0 → no flip.
    assert.strictEqual(result, null);
  });

  it('non-ambiguous candidates are unaffected by the margin gate', () => {
    const pool = [
      { text: 'bith', score: 1.0, source: 'symspell' },
      { text: 'both', score: 0.61, source: 'symspell' },
    ];
    const scorer = (candidate) => (candidate === 'both' ? -2.0 : -10.0);
    const result = topCorrection({
      pool,
      currentWord: 'bith',
      previousWord: 'for',
      previousWord2: null,
      kenlmScorer: scorer,
      trigramReady: true,
    });
    assert.ok(result !== null, 'plain symspell correction still returned');
    assert.strictEqual(result.text, 'both');
  });
});

describe('ASCII-only KenLM apostrophe normalization (regression)', () => {
  function ambiguousPool() {
    return [
      { text: 'its', score: 1.0, source: 'symspell' },
      { text: `it${APOSTROPHE}s`, score: 0.5, source: 'ambiguousContraction' },
    ];
  }

  // Models the real shipped trigram_en_v1.klm behavior: the vocabulary is
  // ASCII-only, so tokens carrying a non-ASCII apostrophe (U+2019/U+2018)
  // score as KenLM <unk> (strong negative) while ASCII-apostrophe tokens
  // score normally. This is the scorer the old stub suite never exercised —
  // it is what makes the defect observable.
  function asciiOnlyKenLM(candidate) {
    if (candidate.includes('\u{2019}') || candidate.includes('\u{2018}')) return -10.0;
    if (candidate === "it's") return -2.0;
    if (candidate === 'its') return -6.0;
    return -10.0;
  }

  it('normalizeForKenLM maps U+2019 and U+2018 to U+0027 (idempotent, ASCII untouched)', () => {
    assert.strictEqual(normalizeForKenLM(`it${APOSTROPHE}s`), "it's");
    assert.strictEqual(normalizeForKenLM("it\u{2018}s"), "it's");
    assert.strictEqual(normalizeForKenLM(`don${APOSTROPHE}t`), "don't");
    assert.strictEqual(normalizeForKenLM("don't"), "don't"); // already ASCII
    assert.strictEqual(normalizeForKenLM('apple'), 'apple');
    assert.strictEqual(normalizeForKenLM(''), '');
  });

  it('U+2019 contraction scores correctly against the ASCII scorer and the margin gate FIRES on a large positive delta', () => {
    // The pool carries the display-canonical U+2019; the scorer only
    // understands ASCII — exactly the real KenLM gap this fix addresses.
    // Without normalization: contraction → <unk> -10.0, typed literal → -6.0,
    // delta = -4.0 < margin → gate never fires (the pre-fix defect).
    const result = topCorrection({
      pool: ambiguousPool(),
      currentWord: 'its',
      previousWord: 'dog',
      previousWord2: null,
      kenlmScorer: asciiOnlyKenLM,
      trigramReady: true,
    });
    assert.ok(result !== null, 'contraction returned');
    assert.strictEqual(result.text, `it${APOSTROPHE}s`);
  });

  it('U+2018 contractions are normalized to ASCII as well', () => {
    const scorer = (candidate) => {
      if (candidate.includes('\u{2019}') || candidate.includes('\u{2018}')) return -10.0;
      if (candidate === "it's") return -1.0;
      if (candidate === 'its') return -6.0;
      return -10.0;
    };
    const pool = [
      { text: 'its', score: 1.0, source: 'symspell' },
      { text: "it\u{2018}s", score: 0.5, source: 'ambiguousContraction' },
    ];
    const result = topCorrection({
      pool,
      currentWord: 'its',
      previousWord: 'dog',
      previousWord2: null,
      kenlmScorer: scorer,
      trigramReady: true,
    });
    assert.ok(result !== null, 'U+2018 contraction normalized and gate fires');
    assert.strictEqual(result.text, "it\u{2018}s");
  });

  it('still REJECTS when the normalized delta is below the margin', () => {
    // delta = -2.0 - (-2.5) = 0.5 < 1.0 margin → no flip, even with the
    // normalization in place (the gate math is unchanged).
    const scorer = (candidate) => {
      if (candidate.includes('\u{2019}') || candidate.includes('\u{2018}')) return -10.0;
      if (candidate === "it's") return -2.0;
      if (candidate === 'its') return -2.5;
      return -10.0;
    };
    const result = topCorrection({
      pool: ambiguousPool(),
      currentWord: 'its',
      previousWord: 'dog',
      previousWord2: null,
      kenlmScorer: scorer,
      trigramReady: true,
    });
    assert.strictEqual(result, null, 'no flip when delta 0.5 < 1.0 margin');
  });
});
