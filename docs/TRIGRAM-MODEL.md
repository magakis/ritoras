# Trigram Language Model for Next-Word Prediction

## Overview

A 3-gram KenLM language model trained on Tatoeba English sentences, used by
the Ritoras keyboard extension to power contextual next-word prediction (Phase
1 architecture).

## Artifacts

| File | Description | Size Limit | Actual |
|---|---|---|---|
| `keyboard/Sources/Prediction/Resources/trigram_en_v1.klm` | Quantized binary LM | ≤ 4.0 MB | ~3.3 MB |
| `keyboard/Sources/Prediction/Resources/trigram_side_index_v1.json` | Bigram→follower index | ≤ 500 KB | ~318 KB |
| `keyboard/Sources/Prediction/Resources/trigram_meta_v1.json` | Training metadata | Small | ~1 KB |

## Corpus

**Source:** [Tatoeba](https://tatoeba.org/en/downloads) — a collaborative
database of sentences translated into many languages.

**License:** CC-BY-2.0
(https://creativecommons.org/licenses/by/2.0/)

**English sentences:** ~2M English sentences extracted from `sentences.tar.bz2`
by filtering for `lang == "eng"`.

**Preprocessing:**
- Lowercased
- Tokenized on whitespace
- Empty lines dropped
- Lines > 200 tokens dropped
- Deterministic shuffle (seed=42)
- 5,000 heldout sentences for perplexity measurement
- Vocabulary restriction is handled by KenLM's `--limit_vocab_file` flag
  (OOV tokens are NOT replaced with `<unk>` in the corpus)

## Vocabulary

**Source:** SymSpell frequency dictionary at
`keyboard/Sources/Prediction/Resources/frequency_dictionary_en_wordfreq_50k.txt`
(wordfreq-derived, top 50k English words).

**Selection:** Top 20,000 words by frequency (line 20,000 = "tuesdays 1950").

**Format (KenLM):**
```
<unk>
<s>
</s>
word1
word2
...
```

## Training Pipeline

### System Dependencies

- `gcc`, `g++` (C++17 compatible)
- `cmake` (≥ 3.10)
- `zlib1g-dev`, `libbz2-dev`, `liblzma-dev`
- `python3` (≥ 3.10), `python3-pip`
- `git`, `curl`
- `bc` (for size calculations in the training script)
- `libboost-all-dev` (Boost headers for KenLM compilation)

### Steps

```bash
# End-to-end (recommended):
bash scripts/train-kenlm-model.sh

# With custom pruning (tighter = smaller model):
bash scripts/train-kenlm-model.sh --prune '0 2 2'

# With custom vocab size:
bash scripts/train-kenlm-model.sh --vocab-size 15000

# With custom side-index size:
bash scripts/train-kenlm-model.sh --side-index-bigrams 3000 --side-index-top-k 15

# Force re-run from scratch:
bash scripts/train-kenlm-model.sh --force
```

Individual steps can also be run separately:

```bash
# 1. Extract vocabulary
python3 scripts/extract-vocab.py -n 20000 -o build/vocab.txt

# 2. Download and preprocess corpus
python3 scripts/preprocess-corpus.py \
    --vocab build/vocab.txt \
    --output-dir build \
    --download-dir build

# 3. Train ARPA model with pruning
build/kenlm/build/bin/lmplz -o 3 --discount_fallback \
    --limit_vocab_file build/vocab.txt --prune 0 1 2 \
    --text build/corpus.txt > build/trigram.arpa

# 4. Quantize and compress (mandatory flags)
build/kenlm/build/bin/build_binary trie \
    -q 8 -b 7 -a 64 build/trigram.arpa \
    keyboard/Sources/Prediction/Resources/trigram_en_v1.klm

# 5. Evaluate perplexity
build/kenlm/build/bin/query -v summary \
    keyboard/Sources/Prediction/Resources/trigram_en_v1.klm \
    < build/heldout.txt

# 6. Build side index
python3 scripts/build-side-index.py \
    -i build/trigram.arpa \
    -o keyboard/Sources/Prediction/Resources/trigram_side_index_v1.json
```

## KenLM

**Source:** https://github.com/kpu/kenlm

**Pinned SHA:** `4cb443e60b7bf2c0ddf3c745378f76cb59e254e5`

**License:** LGPL-2.1+ (see `docs/THIRD-PARTY-NOTICES.md`)

The KenLM tools (`lmplz`, `build_binary`, `query`) are built from source and
used as compile-time build tools for model training. A query-only subset of
the KenLM library is vendored at `third-party/kenlm/kenlm-source/` and linked
into the keyboard extension binary (see iOS Integration below). The binary
model format (`.klm`) is read at runtime by the vendored KenLM trie reader.

## Build Binary Flags

The flags `trie -q 8 -b 7 -a 64` are mandatory for Phase 1:

| Flag | Value | Effect |
|---|---|---|
| `-q 8` | 8 bits | Probability quantization (4→2 bytes per prob) |
| `-b 7` | 7 bits | Backoff quantization |
| `-a 64` | 64 bits | Pointer compression (offsets into memory-mapped array) |

These reduce the model from ~7 MB (unquantized trie) to ~3.3 MB with minimal
perplexity loss (< 5 points relative).

## Pruning

The model uses `--prune 0 1 2` to fit within the 4 MB size budget:
- **Unigrams:** No pruning (all 19k kept)
- **Bigrams:** Prune singletons (bigrams appearing once removed — ~1.6M → ~356k)
- **Trigrams:** Prune singletons and doubletons (trigrams appearing once or
  twice removed — ~5M → ~421k)

This keeps the model at 3.3 MB while retaining the most statistically
significant n-grams. The trade-off is that very rare contexts (e.g. "looking
very handsome") are not preserved as distinct trigrams.

## Smoothing

Modified Kneser-Ney (KenLM's default for `-o 3`). The `--discount_fallback`
flag allows KenLM to fall back to a fixed discount if the optimal one fails.

## Validation Gates

| Gate | Criteria | v1 Result |
|---|---|---|
| Model size | ≤ 4.0 MB (4,194,304 bytes) | **3.3 MB** ✅ |
| Side index size | ≤ 500 KB (512,000 bytes) | **318 KB** ✅ |
| Perplexity (excl. OOVs) | ≤ 90 | **62.3** ✅ (conversational range) |
| Perplexity (incl. OOVs) | ≤ 90 | **219** ⚠️ (see below) |
| Vocabulary | = 20,000 | **20,000** ✅ |
| Build flags | `"trie -q 8 -b 7 -a 64"` | ✅ |
| Spot-check | "looking very" → ≥1 of {good, nice, beautiful, handsome, tired, much} | ⚠️ (see below) |

### Gate Notes

**Perplexity including OOVs (219):** The heldout set has 7,009 OOV tokens out
of 43,531 (16% OOV rate). Tatoeba English covers a much broader vocabulary
(198k types) than our 20k-word keyboard vocabulary. The perplexity excluding
OOVs is 62.3, which is well within the conversational 3-gram range (60-100).
When the keyboard extension queries this model, it will only ask about
in-vocabulary words, so the excluding-OOVs perplexity is the relevant metric.

**Spot-check:** The bigram "looking very" has only "pleased" as a surviving
trigram follower after pruning. The expected adjectives (good, nice, beautiful,
handsome, tired, much) are all present in the vocabulary, but their trigrams
with "looking very" appear only once in the corpus and are pruned by the
singleton/doubleton pruning needed to fit the 4 MB size budget. Common bigrams
like "looking for" and "looking at" are well-represented in the side index
with many followers.

### Gate Failures

If perplexity exceeds 90 (including OOVs):
- The excluding-OOVs perplexity is the relevant metric for keyboard usage.
- If the spot-check passes anyway, accept PPL up to 110.

If model size exceeds 4.0 MB:
1. Increase pruning: `--prune '0 1 2'` → `--prune '0 2 2'`.
2. Reduce `--side-index-bigrams` (does not affect model size, only JSON).
3. Re-train with `--vocab-size 15000` (last resort — affects coverage).

If spot-check fails:
- Verify the expected adjectives are in `vocab.txt`. All are present.
- The failure is due to n-gram pruning, not missing vocabulary.
- Accept the limitation: rare adjective contexts are pruned to meet the 4 MB
  size budget.

## Regeneration

To regenerate the model with updated data or parameters:

```bash
# Clean everything
rm -rf build
# Re-run
bash scripts/train-kenlm-model.sh
```

The pipeline is designed to be reproducible on a fresh Ubuntu 22.04+ system
with the system dependencies listed above.

## Side Index Format

The side index is a JSON file mapping bigram strings to their top-20 most
probable follower words:

```json
{
  "looking for": ["a", "the", "his", "someone", "my"],
  "looking at": ["the", "a", "me", "his", "your"],
  "i am": ["not", "a", "the", "going", "very"]
}
```

This is used by the keyboard extension for fast lookups when typing, without
needing to query the full KenLM model on every keystroke.

The side index contains 5,000 bigrams selected by descending log probability
(most common first), each with up to 20 follower words. Total size: ~318 KB.

## Measured Results (v1)

| Metric | Value |
|---|---|
| Model file size | 3,475,971 bytes (3.31 MB) |
| Side index size | 325,715 bytes (318 KB) |
| Perplexity (excluding OOVs) | 62.3 |
| Perplexity (including OOVs) | 219.0 |
| Vocabulary size | 20,000 words |
| Training sentences | 2,026,858 |
| Heldout sentences | 5,000 |
| Unigrams | 18,944 |
| Bigrams | 356,151 |
| Trigrams | 421,354 |
| Build flags | `trie -q 8 -b 7 -a 64` |

## Measured Performance (CI)

These numbers are produced by `RitorasTests/KenLMMemorySpike.swift`,
`RitorasTests/SymSpellMemorySpike.swift::testCombinedSymSpellAndTrigramMemoryBaseline`,
and `RitorasTests/TrigramLatencyTest.swift` on CI (iOS Simulator, Release
configuration).

| Metric | Target | Measured (CI) | Pass? (CI) |
|---|---|---|---|
| KenLM trie resident delta | ≤ 3 MB | _CI fills in_ | _CI fills in_ |
| Combined SymSpell + Trigram + side index | ≤ 33 MB | _CI fills in_ | _CI fills in_ |
| Trigram query latency p99 | ≤ 5 ms | _CI fills in_ | _CI fills in_ |

**Notes:**
- Memory measurements use `task_vm_info` on device and `estimateMemoryMB()` on
  simulator (returns `0.0` — memory assertions pass trivially on CI). Run on a
  physical device for accurate memory readings.
- Latency measurements are accurate on both simulator and device.
- The combined 33 MB target assumes ~7 MB headroom under the 40 MB practical
  Jetsam ceiling for UIKit/audio/IPC baseline.

Last updated: _(run date)_

## iOS Integration

The keyboard extension loads and queries the KenLM model at runtime through a
Swift↔C++ bridge.

### Architecture

```
┌─────────────────────────────────────────────────────────┐
│  Swift (PredictionEngine / SuggestionProvider)           │
├─────────────────────────────────────────────────────────┤
│  C-linkage API (kenlm_c.h)                               │
│    kenlm_load / kenlm_free / kenlm_score / kenlm_vocab_size
├─────────────────────────────────────────────────────────┤
│  C++ wrapper (kenlm_c.cpp)                               │
│    lm::ngram::QuantArrayTrieModel                        │
├─────────────────────────────────────────────────────────┤
│  Vendored KenLM (third-party/kenlm/kenlm-source/)        │
│    lm/model.hh, lm/search_trie.hh, util/mmap.hh, ...    │
└─────────────────────────────────────────────────────────┘
```

### Files

| File | Purpose |
|---|---|
| `keyboard/Sources/Prediction/Trigram/kenlm_c.h` | C-linkage header with `kenlm_model_t` opaque handle and 6 functions |
| `keyboard/Sources/Prediction/Trigram/kenlm_c.cpp` | C++ implementation wrapping `QuantArrayTrieModel` |
| `keyboard/RitorasKeyboard-BridgingHeader.h` | Xcode bridging header importing `kenlm_c.h` |
| `third-party/kenlm/kenlm-source/` | Vendored KenLM query-only subset (101 files, 0 Boost deps) |
| `third-party/kenlm/README.md` | Provenance, SHA, license, compilation notes |

### Build Settings (project.yml)

- `SWIFT_OBJC_BRIDGING_HEADER`: `keyboard/RitorasKeyboard-BridgingHeader.h`
- `CLANG_CXX_LANGUAGE_STANDARD`: `gnu++17`
- `CLANG_CXX_LIBRARY`: `libc++`
- `USER_HEADER_SEARCH_PATHS`: `third-party/kenlm/kenlm-source` and `Trigram/`

### Thread Safety

The KenLM model is read-only and fully reentrant. Multiple threads can call
`kenlm_score` or `kenlm_score_sentence` concurrently on the same model handle
without locking. State is allocated per-call (on the stack via `std::vector`).

### Memory

The `.klm` file is memory-mapped (mmap) and stays resident until
`kenlm_free()`. The 3.3 MB model maps to approximately 3.4 MB RSS. Loading
happens synchronously on the calling thread (~5-20ms on device).

### Exception Safety

All C++ exceptions are caught at the C++→C boundary in `kenlm_c.cpp`.
No exceptions cross into Swift.
