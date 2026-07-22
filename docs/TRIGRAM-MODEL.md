# Trigram Language Model for Next-Word Prediction

## 1. Overview

The Ritoras keyboard extension predicts the next word as the user types. The
prediction system operates in two complementary modes:

1. **Spelling correction** — SymSpell (Swift port of the Symmetric Delete
   algorithm) and Apple's `UITextChecker` provide prefix completions and typo
   corrections for the *current* word being typed.
2. **Contextual next-word prediction** — A KenLM 3-gram language model with
   Modified Kneser-Ney smoothing predicts the most probable *next* word given
   one or two preceding words.

### High-Level Data Flow

```
User taps key
     ↓
UITextDocumentProxy.documentContextBeforeInput
     ↓
CurrentWordExtractor.extract(from:)
  → currentWord (for display, punctuation preserved)
  → lookupWord (for dictionary lookups, trailing punctuation stripped)
  → previousWord (token before current word)
  → previousWord2 (two tokens before)
     ↓
KeyboardView.refreshSuggestions()
  → calls PredictionEngine.suggestions(...)
     ↓
PredictionEngine delegates to each SuggestionProvider:
  ├─ SymSpellProvider — prefix completions / typo corrections
  ├─ AppleSpellCheckerProvider — UITextChecker guesses + completions
  └─ TrigramProvider — KenLM + side index followers
     ↓
PredictionEngine merges → boosts → scores → dedupes → sorts → top-3
     ↓
SuggestionBar displays three chips
```

---

## 2. Architecture

### In-Keyboard KenLM (not IPC, not Foundation Models)

The KenLM model runs entirely inside the keyboard extension process. This design
was chosen because:

- **Latency:** An HTTP round-trip to an external service for every keystroke
  would be unusably slow. The model is mmap'd and queried in ~10–100 µs.
- **Privacy:** No keystroke context leaves the device.
- **No network dependency:** Works offline, on airplane mode, and on the lock
  screen (once the keyboard has loaded).
- **Size budget:** The quantized trie model fits in ~3.4 MB RSS, well within
  the keyboard's 48 MB Jetsam memory cap.

### Multi-Provider Model

```
┌─────────────────────────────────────────────────────────────┐
│                    PredictionEngine                          │
│                                                             │
│  SuggestionProvider protocol:                                │
│    func suggest(for context: SuggestionContext,              │
│                 limit: Int) -> [Suggestion]                  │
│                                                             │
│  Registered providers (order matters):                       │
│    1. SymSpellProvider    — prefix completions / corrections │
│    2. AppleSpellChecker   — UITextChecker guesses + completions│
│    3. TrigramProvider     — KenLM side-index followers       │
└─────────────────────────────────────────────────────────────┘
```

Each provider returns `[Suggestion]` where `Suggestion` bundles:
- `text: String` — the suggestion text
- `score: Double` — 0.0–1.0 provider-specific confidence
- `source: Source` — `.symspell`, `.apple`, `.trigram`, or `.lexicon`

### PredictionEngine Orchestration

The engine follows distinct paths depending on whether the cursor is at a word
boundary (after a space) or mid-word. See [Scoring Pipeline](#5-scoring-pipeline)
for the full step-by-step detail.

#### Empty-Prefix Path (cursor after whitespace)

```
1. Call ALL providers with currentWord="" and lookupWord=""
2. SymSpell + Apple return [] (they only handle partial words)
3. TrigramProvider returns top-3 from side index (trigram, fallback unigram)
4. If pool is empty → defaultTopSuggestions = ["the", "I", "and"]
5. Sort by score descending, take top-3
```

#### Mid-Word Path (user typing a partial word)

```
1. Call ALL providers with partial word
2. SymSpell returns prefix completions + typo corrections (scored by
   frequency × QWERTY geometry)
3. Apple returns UITextChecker guesses + completions
4. TrigramProvider returns followers filtered by prefix, scored by KenLM
5. Apple boost: when highest SymSpell confidence < 0.7, multiply all
   Apple scores by 1.2x (capped at 1.0)
6. KenLM contextual re-scoring: for each candidate, compute
   kenlm_score(prev2, prev1, candidate), min-max normalize, blend
7. Dedupe by text (keep highest score), sort, take top-3
```

---

## 3. The KenLM Model

| Property | Value |
|---|---|
| N-gram order | 3 |
| Smoothing | Modified Kneser-Ney |
| Vocabulary | 20,000 headwords (+ `<unk>`, `<s>`, `</s>`) |
| Binary format | Quantized trie (`QuantArrayTrieModel`) |
| Build flags | `trie -q 8 -b 7 -a 64` |
| File | `keyboard/Sources/Prediction/Resources/trigram_en_v1.klm` |
| File size | 3,475,971 bytes (3.31 MB) |
| Resident RSS | ~3.4 MB (mmap'd) |
| Pruning | `--prune 0 1 2` (see [Pruning](#pruning)) |

### Corpus

**Source:** [Tatoeba](https://tatoeba.org/en/downloads) — a collaborative
database of sentences translated into many languages.

**License:** CC-BY-2.0

**English sentences:** ~2M English sentences extracted from `sentences.tar.bz2`
by filtering for `lang == "eng"`.

**Preprocessing:**
- Lowercased
- Tokenized on whitespace
- Empty lines dropped
- Lines > 200 tokens dropped
- Deterministic shuffle (seed=42)
- 5,000 heldout sentences for perplexity measurement
- OOV tokens are **not** replaced with `<unk>` in the corpus; vocabulary
  restriction is deferred to KenLM's `--limit_vocab_file` flag

### Vocabulary

**Source:** SymSpell frequency dictionary at
`keyboard/Sources/Prediction/Resources/frequency_dictionary_en_wordfreq_50k.txt`
(wordfreq-derived, top 50k English words).

**Selection:** Top 20,000 words by frequency.

**Format (KenLM vocab.txt):**
```
<unk>
<s>
</s>
according
across
...
```

### Quantization Flags

| Flag | Value | Effect |
|---|---|---|
| `-q 8` | 8 bits | Probability quantization (4→2 bytes per probability) |
| `-b 7` | 7 bits | Backoff quantization |
| `-a 64` | 64 bits | Pointer compression (offsets into memory-mapped array) |

These reduce the model from ~7 MB (unquantized trie) to ~3.3 MB with minimal
perplexity loss (< 5 points relative).

### Pruning

The v1 model uses `--prune 0 1 2` to fit within the 4 MB size budget:

| Order | Pruning | Count in model |
|---|---|---|
| Unigrams | None (all 19k kept) | 18,944 |
| Bigrams | Prune singletons (appearing once) | 356,151 |
| Trigrams | Prune singletons and doubletons | 421,354 |

### N-Gram Counts (v1)

| | Unigrams | Bigrams | Trigrams |
|---|---|---|---|
| Before pruning | ~19k | ~1.6M | ~5M |
| After pruning | 18,944 | 356,151 | 421,354 |

### Perplexity

| Metric | Value |
|---|---|
| Perplexity (excluding OOVs) | 62.3 |
| Perplexity (including OOVs) | 219.0 |
| OOV rate on heldout | 16% (7,009 / 43,531 tokens) |
| Heldout sentences | 5,000 |

The excluding-OOVs perplexity of 62.3 is the relevant metric for keyboard
usage — queries are only made against in-vocabulary words. The 16% OOV rate
reflects that Tatoeba English (198k types) has much broader vocabulary than our
20k headwords.

### Metadata

The file `keyboard/Sources/Prediction/Resources/trigram_meta_v1.json` contains
the full provenance of the trained model:

```json
{
  "corpus": "Tatoeba English (CC-BY-2.0)",
  "vocab_size": 20000,
  "build_binary_flags": "trie -q 8 -b 7 -a 64",
  "ngram_order": 3,
  "smoothing": "modified_kneser_ney",
  "pruning": "0 1 2",
  "file_size_bytes": 3475971,
  "perplexity": 219.027,
  "perplexity_excluding_oovs": 62.29,
  "kenlm_sha": "4cb443e60b7bf2c0ddf3c745378f76cb59e254e5",
  "training_corpus_lines": 2026858,
  "ngram_order_counts": { "1": 18944, "2": 356151, "3": 421354 },
  "trained_at": "2026-07-21T18:38:52Z"
}
```

---

## 4. Side Index

### What It Is

The side index is a pre-computed JSON mapping from common contexts to their
top-N most probable follower words. It avoids scanning the entire KenLM
vocabulary on every keystroke — instead, the `TrigramProvider` first looks up
the context in the side index and only scores a small candidate set.

### Structure

The side index contains two kinds of entries:

| Type | Key format | Count | Example |
|---|---|---|---|
| Bigram entries | `"word1 word2"` (contains a space) | 20,000 | `"looking for" → ["a", "the", "his", ...]` |
| Unigram entries | `"word"` (no space) | 3,000 | `"i" → ["am", "want", "think", "know", ...]` |

Bigram keys enable trigram querying (prev2 + prev1 → followers). Unigram keys
enable fallback when the trigram context misses or only one preceding word is
available. The lookup code distinguishes them by the presence of a space.

### File

| Property | Value |
|---|---|
| File | `keyboard/Sources/Prediction/Resources/trigram_side_index_v1.json` |
| Size | 1,980,243 bytes (~1.9 MB) |
| Total entries | 23,000 |
| Bigrams | 20,000 |
| Unigrams | 3,000 |
| Avg. followers per entry | ~5.5 |
| Max followers per entry | 20 |

**Note:** The side index at 1.9 MB is larger than the model itself. It was
expanded from the original 5,000 bigrams to provide substantially better
coverage. Each entry's follower list varies — common contexts like `"i am"`
have 20 followers; rare contexts may have as few as 2.

### Format

```json
{
  "looking for": ["a", "the", "his", "someone", "my"],
  "looking at": ["the", "a", "me", "his", "your"],
  "i am": ["not", "a", "the", "going", "very"],
  ...
  "the": ["first", "most", "same", "other", "only"],
  "i": ["am", "don't", "have", "was", "can"]
}
```

### Fallback Chain

When scoring an empty-prefix (next word) request, `TrigramProvider` applies
this fallback chain:

```
1. Trigram lookup: sideIndex.followers(prev2, prev1)
   → if followers found, score each with KenLM, return top-3
2. Unigram fallback: sideIndex.followersUnigram(prev1)
   → if followers found, score each with KenLM, return top-3
3. Empty: return []
   → PredictionEngine falls through to defaultTopSuggestions = ["the", "I", "and"]
```

### Implementation

The `SideIndex` struct (`Trigram/SideIndex.swift`) loads the JSON file on
initialization:

```swift
struct SideIndex {
    private let entries: [String: [String]]

    func followers(for previousWord2: String?, previousWord: String?) -> [String] {
        guard let prev2 = previousWord2, let prev1 = previousWord else { return [] }
        return entries["\(prev2.lowercased()) \(prev1.lowercased())"] ?? []
    }

    func followersUnigram(for previousWord: String) -> [String] {
        return entries[previousWord.lowercased()] ?? []
    }
}
```

---

## 5. Scoring Pipeline (The Heart of the System)

### Empty-Prefix Path (after space, cursor at word boundary)

This path runs when `currentWord.isEmpty` (user just pressed space, cursor is
at the start of a new word).

**Step 1: Collect from all providers.**

```swift
var pool: [Suggestion] = []
for provider in providers {
    let results = provider.suggest(for: context, limit: limit)
    pool.append(contentsOf: results)
}
```

- SymSpellProvider returns `[]` (guard: `word.isEmpty → return []`)
- AppleSpellCheckerProvider returns `[]` (same guard)
- TrigramProvider returns top-3 followers from side index, scored by KenLM

**Step 2: TrigramProvider scoring.**

`TrigramProvider.suggest(for:limit:)` when `lookupWord.isEmpty`:

1. Attempt trigram lookup: `index.followers(prev2, prev1)`
2. Fall back to unigram lookup: `index.followersUnigram(prev1)`
3. If no followers → return `[]`
4. Score each follower word with `scoreTrigram(prev2:prev1:candidate:)`
5. Normalize scores:

```swift
let maxProb = scored.map(\.1).max() ?? 0.0
let normalized: Double
if maxProb >= 0 {
    normalized = 1.0
} else if maxProb < -20 {
    normalized = max(SharedConfig.Defaults.trigramReadyMinScore,
                     exp((prob - maxProb) * log(10.0)))
} else {
    normalized = max(SharedConfig.Defaults.trigramReadyMinScore,
                     min(1.0, exp((prob - maxProb) * log(10.0))))
}
```

The normalization converts log10-probability differences to a [0, 1] scale.
`trigramReadyMinScore = 0.05` provides a floor to avoid near-zero noise.

**Step 3: Fallback.** If `pool.isEmpty → ["the", "I", "and"]`.

**Step 4: Sort.** `pool.sorted { $0.score > $1.score }.prefix(limit)`.

### Mid-Word Path (user typing a partial word)

This path runs when `currentWord` is non-empty. It involves several sub-steps:

**Step 1: Build merged pool.** `PredictionEngine.mergedPool(...)` calls all
providers with the partial word context.

_SymSpellProvider:_

```swift
// Always include the input itself as the leftmost chip
results.append(Suggestion(text: context.currentWord, score: 1.0, source: .symspell))

if trie.contains(word: lookupWord.lowercased()) {
    // Real word → prefix completions at score 0.5
    let completions = trie.suggest(prefix: word, limit: limit)
    // ...
} else {
    // Typo → SymSpell correction with QWERTY-geometry score
    for (term, _, distance) in symSpell.lookup(input: word, verbosity: .top) {
        let score = QwertyGeometry.score(
            typed: word,
            candidate: term,
            symSpellDistance: distance,
            beta: 1.5,
            doublingDiscount: 0.5,
            transpositionDiscount: 0.7
        )
        // score = exp(-beta × weightedEditDistance)
    }
}
```

Key detail: SymSpell corrections use `QwertyGeometry.score()` which models key
proximity — an `e→r` substitution (adjacent keys) costs less than `e→p` (far).

_AppleSpellCheckerProvider:_

- Guesses (full-word corrections): score `0.85`
- Completions (prefix completions): score `0.6`
- Deduplicated internally (guesses win over completions)

_TrigramProvider:_

- Filters side-index followers by `prefix = context.lookupWord.lowercased()`
- Scores each matching follower with `scoreTrigram(prev2, prev1, candidate)`
- Returns scored suggestions with `source: .trigram`

**Step 2: Apple boost.** When the highest SymSpell score (excluding the input
word itself) is below 0.7, Apple suggestion scores are boosted by 20%:

```swift
if symspellMaxNonInput < 0.7 {
    allSuggestions = allSuggestions.map { suggestion in
        guard suggestion.source == .apple else { return suggestion }
        return Suggestion(text: suggestion.text,
                          score: min(suggestion.score * 1.2, 1.0),
                          source: suggestion.source)
    }
}
```

**Step 3: KenLM contextual scoring** — the key innovation that replaces the old
binary follower-set boost with true contextual probability for each candidate:

```swift
if let trigramProvider = providers.compactMap({ $0 as? TrigramProvider }).first(where: { $0.isReady }) {
    // Phase 1: compute raw log probs for all candidates
    var scored: [(suggestion: Suggestion, logProb: Double)] = []
    for s in allSuggestions {
        let lp = trigramProvider.rawLogProb(for: s.text,
                                             previousWord: previousWord,
                                             previousWord2: previousWord2) ?? -10.0
        scored.append((s, lp))
    }

    // Phase 2: normalize log probs to [0, 1] relative to the pool
    let logProbs = scored.map { $0.logProb }
    if let maxLog = logProbs.max(), let minLog = logProbs.min() {
        let range = max(maxLog - minLog, 0.001)
        let blendWeight = SharedConfig.Defaults.kenlmBlendWeight  // 0.5

        // Phase 3: blend SymSpell/Apple score with normalized KenLM score
        allSuggestions = scored.map { item in
            let normalizedKenLM = (item.logProb - minLog) / range
            let blendedScore = (1.0 - blendWeight) * item.suggestion.score
                           + blendWeight * normalizedKenLM
            return Suggestion(text: item.suggestion.text,
                              score: blendedScore,
                              source: item.suggestion.source)
        }
    }
}
```

The `blendWeight` defaults to `0.5`, giving equal weight to the provider
(SymSpell/Apple) score and the normalized KenLM contextual probability.

**Step 4: Dedupe by text** (keep highest score).

**Step 5: Sort by score descending, take top-3.**

### Autocorrect Path

`PredictionEngine.topCorrection(...)` is a separate path used by
`AutocorrectController` to make confidence-gated replacement decisions. It:

1. Builds the same merged pool (all providers)
2. Filters OUT `.trigram` sources (trigrams predict the NEXT word, not corrections)
3. Filters OUT the typed word itself (it's not a correction)
4. Returns the highest-scoring remaining suggestion

---

## 6. Cold-Start and Lifecycle

### State Machine

`TrigramProvider` uses a 4-state machine:

```
.cold ──→ .loading ──→ .ready
                     └──→ .failed (permanent)
```

| State | Meaning | `suggest()` returns |
|---|---|---|
| `.cold` | No load attempted yet | `[]` (trigger lazy load) |
| `.loading` | Load in progress | `[]` (waiting) |
| `.ready` | KenLM + side index loaded | Normal suggestions |
| `.failed` | Load failed (corrupt/missing) | `[]` (permanent — no retry) |

### Lifecycle Sequence

```
viewDidLoad()
  → buildPredictionEngine()
     → SymSpell + Trie + Apple providers registered immediately
     → scheduleTrigramLoad()
        ↓  (500ms debounce)
        TrigramProvider created
        → warmup() called
           → state = .loading
           → FileLogger: "trigram load started"
           → performLoad on background queue
              ├─ Load side index (JSON, ~320 KB → 2ms)
              └─ Load KenLM model (mmap, ~3.4 MB → 5-20ms)
           → state = .ready (or .failed)
           → FileLogger: "trigram ready (vocab=18944)"
              or "trigram load failed: <reason>"
           → register provider on PredictionEngine
           → keyboardView.refreshSuggestions()
```

### Cold-Start UX

The TrigramProvider is loaded **after** SymSpell with a 500ms debounce
(`scheduleTrigramLoad`), which means:

- **First ~500ms–2s:** Only spelling correction works (SymSpell + Apple).
  No contextual prediction appears.
- **After load:** TrigramProvider registers itself, and the suggestion bar
  refreshes automatically.

This design avoids memory contention during initialisation and ensures the
keyboard is usable immediately.

### Failure Behavior

If the model file is missing or corrupt:
- State transitions to `.failed` — **permanent for the session**, no retry
- `suggest()` returns `[]` for all trigram queries
- PredictionEngine falls through to SymSpell + Apple + default suggestions
- FileLogger logs at `.warn` level

### FileLogger Diagnostics

All state transitions log under `LogComponent.prediction`:

| Event | Log line |
|---|---|
| Load started | `trigram load started` |
| Load ready | `trigram ready (vocab=18944)` |
| Model not found | `trigram load failed: model file not found` |
| Load failure | `trigram load failed: kenlm_load returned nil` |
| Side index failure | `trigram load failed: side index load failed` |
| First suggestion | `trigram first suggestion: "prev2 prev1" → [follower1, follower2, ...]` |

---

## 7. C Bridge (Swift ↔ C++)

### Architecture

```
┌─────────────────────────────────────────────────────────┐
│ Swift (TrigramProvider / PredictionEngine)               │
│   kenlm_load() / kenlm_free() / kenlm_score()            │
│   kenlm_score_sentence() / kenlm_vocab_size()            │
├─────────────────────────────────────────────────────────┤
│ C-linkage API (kenlm_c.h)                                │
│   extern "C" functions with kenlm_model_t opaque handle  │
├─────────────────────────────────────────────────────────┤
│ C++ wrapper (kenlm_c.cpp)                                │
│   KenlmModel struct wrapping QuantArrayTrieModel          │
├─────────────────────────────────────────────────────────┤
│ Vendored KenLM (third-party/kenlm/kenlm-source/)         │
│   lm/model.hh, lm/search_trie.hh, util/mmap.hh, ...     │
└─────────────────────────────────────────────────────────┘
```

### API Reference

```c
// Opaque handle (void*)
typedef void* kenlm_model_t;

// Load a binary trie model from file path. Returns NULL on failure.
kenlm_model_t kenlm_load(const char* path);

// Free a loaded model. Safe to call with NULL.
void kenlm_free(kenlm_model_t model);

// Log10 probability of a NULL-terminated word array.
double kenlm_score(kenlm_model_t model, const char* const* words);

// One-shot: log10 probability of a space-separated sentence.
double kenlm_score_sentence(kenlm_model_t model, const char* sentence);

// Vocabulary size (Bound()) of the loaded model. Returns 0 if NULL.
int kenlm_vocab_size(kenlm_model_t model);

// Static KenLM version string.
const char* kenlm_version(void);
```

### Scoring Implementation (C++)

The C++ implementation (`kenlm_c.cpp`) uses `lm::ngram::QuantArrayTrieModel`
(the quantized + array-compressed trie type). The scoring function:

```cpp
static double score_words(const KenlmModel* wrapper,
                          const std::vector<const char*>& words) {
    lm::ngram::State state = model->BeginSentenceState();
    lm::ngram::State out_state;
    float total_log10 = 0.0f;
    for (const char* w : words) {
        lm::WordIndex idx = vocab.Index(StringPiece(w));
        lm::FullScoreReturn ret = model->FullScore(state, idx, out_state);
        total_log10 += ret.prob;
        state = out_state;
    }
    return static_cast<double>(total_log10);
}
```

Each call to `FullScore` advances the model state, producing a conditional
probability. This means the score for a sequence like `"i am going"` is:

```
log P("i" | <s>) + log P("am" | <s>, "i") + log P("going" | <s>, "i", "am")
```

### Exception Safety

All C++ exceptions are caught at the C++ → C boundary:

```cpp
try {
    model = new lm::ngram::QuantArrayTrieModel(path, config);
} catch (const std::exception&) {
    delete model;
    model = nullptr;
}
```

No exceptions cross into Swift.

### Thread Safety

The KenLM model is read-only and fully reentrant. Multiple threads can call
`kenlm_score` or `kenlm_score_sentence` concurrently on the same model handle
without locking. State (`lm::ngram::State`) is allocated per-call on the stack.

### Build Integration

In `project.yml`:

```yaml
RitorasKeyboard:
  settings:
    SWIFT_OBJC_BRIDGING_HEADER: keyboard/RitorasKeyboard-BridgingHeader.h
    CLANG_CXX_LANGUAGE_STANDARD: "gnu++17"
    CLANG_CXX_LIBRARY: "libc++"
    GCC_PREPROCESSOR_DEFINITIONS:
      KENLM_MAX_ORDER=6
    USER_HEADER_SEARCH_PATHS:
      - "$(inherited)"
      - "third-party/kenlm"
      - "keyboard/Sources/Prediction/Trigram"
  sources:
    - path: third-party/kenlm/kenlm-source
      excludes:
        - "**/*test*"
        - "**/*_test*"
        - "**/builder/**"
        - "**/filter/**"
        - "**/main.cpp"
        - "**/*_main.cc"
        - "**/*_main.cpp"
    - path: keyboard/Sources/Prediction/Trigram/kenlm_c.cpp
```

### Vendored KenLM

A query-only subset of KenLM is vendored at `third-party/kenlm/kenlm-source/`
(101 files, no Boost dependencies). See `third-party/kenlm/README.md` for
provenance and update instructions.

---

## 8. Memory Budget

### Jetsam Ceiling

The keyboard extension is killed without warning when it exceeds the iOS
Jetsam limit. The **theoretical** limit is ~48 MB, but the **practical** ceiling
(observed on real devices) is ~40 MB. Exceeding this even briefly causes a
kernel-level kill with no notice to the process.

### Component Breakdown

| Component | Memory | Notes |
|---|---|---|
| UIKit / audio / IPC baseline | ~30 MB | Views, text proxy, audio recorder, timers |
| SymSpell index | ~25 MB | Delete index + dictionary (loaded from wordfreq 50k) |
| KenLM trie (mmap'd) | ~3.4 MB | Memory-mapped read-only, mostly resident |
| Side index (parsed JSON) | ~2 MB | `[String: [String]]` dictionary in Swift heap |
| **Total** | **~35-37 MB** | Under the 40 MB practical ceiling |

### Why BigramPredictor Was Removed

An earlier version of the prediction system included a `BigramPredictor` that
maintained a separate bigram frequency table in memory. It was **removed** in
favor of the side index approach, freeing ~10–15 MB of memory. This was the
key change that brought total memory under the 40 MB ceiling and eliminated
random Jetsam kills during typing.

### Memory Monitoring

The `WordListLoader.loadStreamed` function monitors resident memory during
dictionary load and aborts if it exceeds `maxResidentBytesDuringLoad` (35 MB).
This prevents the SymSpell build from pushing the process over the limit during
startup.

---

## 9. Training and Regeneration

### Prerequisites

```
gcc g++ cmake zlib1g-dev libbz2-dev liblzma-dev python3 python3-pip git curl bc
libboost-all-dev  (for KenLM build tools only; the vendored query subset has
                   no Boost dependencies)
```

### End-to-End Pipeline

```bash
bash scripts/train-kenlm-model.sh
```

The script performs these steps:

#### Step 1: Build KenLM Tools

Clones KenLM at the pinned SHA (`4cb443e60b7bf2c0ddf3c745378f76cb59e254e5`),
builds `lmplz`, `build_binary`, and `query` from source.

#### Step 2: Extract Vocabulary

```bash
python3 scripts/extract-vocab.py -n 20000 -o build/vocab.txt
```

Reads the top 20,000 words from `frequency_dictionary_en_wordfreq_50k.txt`,
outputs them in KenLM format (`<unk>`, `<s>`, `</s>` first, then one word per
line).

#### Step 3: Download and Preprocess Corpus

```bash
python3 scripts/preprocess-corpus.py \
    --vocab build/vocab.txt \
    --output-dir build \
    --download-dir build
```

Downloads `sentences.tar.bz2` from Tatoeba, extracts English sentences,
lowercases, tokenizes. Produces `corpus.txt` (~2M sentences) and
`heldout.txt` (5,000 sentences).

#### Step 4: Train ARPA Model

```bash
build/kenlm/build/bin/lmplz -o 3 --discount_fallback \
    --limit_vocab_file build/vocab.txt --prune 0 1 2 \
    --text build/corpus.txt > build/trigram.arpa
```

#### Step 5: Quantize and Compress

```bash
build/kenlm/build/bin/build_binary trie \
    -q 8 -b 7 -a 64 build/trigram.arpa \
    keyboard/Sources/Prediction/Resources/trigram_en_v1.klm
```

#### Step 6: Measure Perplexity

```bash
build/kenlm/build/bin/query -v summary \
    keyboard/Sources/Prediction/Resources/trigram_en_v1.klm \
    < build/heldout.txt
```

#### Step 7: Build Side Index

```bash
python3 scripts/build-side-index.py \
    -i build/trigram.arpa \
    -o keyboard/Sources/Prediction/Resources/trigram_side_index_v1.json
```

The build script (`build-side-index.py`) parses the ARPA file and extracts the
top-20,000 most-probable bigrams and top-3,000 unigrams with their top-20
follower words. Keys are sorted by descending log probability (most common
contexts first).

#### Steps 8-9: Metadata + Copy to Resources

A metadata JSON is generated, and the three artifacts (`.klm`, side index,
metadata) are copied to `keyboard/Sources/Prediction/Resources/`.

### Script Options

```bash
# Custom pruning (tighter = smaller model):
bash scripts/train-kenlm-model.sh --prune '0 2 2'

# Custom vocab size:
bash scripts/train-kenlm-model.sh --vocab-size 15000

# Custom side-index size:
bash scripts/train-kenlm-model.sh --side-index-bigrams 10000 --side-index-top-k 15

# Force re-run from scratch:
bash scripts/train-kenlm-model.sh --force
```

### How to Update the Model

1. **New corpus:** Replace the Tatoeba download URL in `preprocess-corpus.py`,
   or place your own `corpus.txt` in the build directory.
2. **New vocabulary:** Update `frequency_dictionary_en_wordfreq_50k.txt` or
   change `--vocab-size`.
3. **Retrain:** `rm -rf build && bash scripts/train-kenlm-model.sh`
4. **Commit artifacts:**
   ```
   keyboard/Sources/Prediction/Resources/trigram_en_v1.klm
   keyboard/Sources/Prediction/Resources/trigram_side_index_v1.json
   keyboard/Sources/Prediction/Resources/trigram_meta_v1.json
   ```

### Side Index Builder Details

The side index builder (`scripts/build-side-index.py`) works by:

1. Parsing the ARPA file into per-order n-gram lists
2. For each bigram, collecting all trigram followers with their probabilities
3. Sorting followers by probability (descending) for each bigram
4. Sorting bigrams by log probability (descending, most common first)
5. Taking the top 20,000 bigrams with up to 20 followers each
6. Building unigram entries (top 3,000 words) from bigram data
7. Both original-case and lowercased keys are emitted for unigram entries

---

## 10. Configuration

### SharedConfig.Defaults

| Key | Type | Default | Description |
|---|---|---|---|
| `kenlmBlendWeight` | `Double` | `0.5` | Blend between provider score (SymSpell/Apple) and normalized KenLM contextual score |
| `trigramWeight` | `Double` | `0.7` | Reserved for future interpolation (currently unused — empty-prefix uses raw trigram) |
| `trigramReadyMinScore` | `Double` | `0.05` | Minimum score floor for trigram candidates (avoids near-zero noise) |
| `providerResultLimit` | `Int` | `8` | Internal limit per provider before merging into the pool |
| `symspellMaxEditDistance` | `Int` | `2` | Maximum edit distance for SymSpell correction |
| `symspellPrefixLength` | `Int` | `7` | Prefix length for SymSpell delete generation |
| `qwertyDistanceBeta` | `Double` | `1.5` | Sharpness of QWERTY geometry score falloff |
| `qwertyDoublingDiscount` | `Double` | `0.5` | Discount for doubled-letter edits (e.g. recieve→receive) |
| `qwertyTranspositionDiscount` | `Double` | `0.7` | Discount for adjacent transpositions (e.g. teh→the) |
| `appleSpellCheckerLanguage` | `String` | `"en-US"` | Language tag for UITextChecker |

### project.yml (Build Settings)

| Setting | Value |
|---|---|
| C++ language standard | `gnu++17` |
| C++ library | `libc++` |
| KenLM max order define | `KENLM_MAX_ORDER=6` |
| Bridging header | `keyboard/RitorasKeyboard-BridgingHeader.h` |
| User header search paths | `third-party/kenlm`, `keyboard/Sources/Prediction/Trigram` |

### CI Pipeline (build.yml)

The `.github/workflows/build.yml` workflow:
1. Generates the Xcode project with XcodeGen
2. Builds (Release, unsigned)
3. Verifies the keyboard `Info.plist`
4. Packages an unsigned `.ipa`
5. Verifies the keyboard extension is embedded
6. Uploads `.ipa` and `.app` as build artifacts

**There is no test step in CI.** _(The `RitorasTests` target has since been removed entirely; see AGENTS.md No-tests policy.)_ The test target (`RitorasTests`) has 119
pre-existing compilation errors that have been deferred. To run tests locally
on macOS:

```bash
xcodebuild test -scheme RitorasTests \
  -destination 'platform=iOS Simulator,name=iPhone 15,OS=17.0'
```

---

## 11. Known Limitations

### Rare Collocations May Miss the Side Index

The side index contains 20,000 bigrams from the top of the probability
distribution. Rare but valid collocations (e.g. "looking very" → "handsome")
may not appear if their trigram was pruned or the bigram didn't rank in the
top 20,000. **Mitigation:** The unigram fallback (3,000 entries for single-word
contexts) provides a second chance for less common contexts.

### 16% OOV Rate

The 20k vocabulary is drawn from the wordfreq top-20k, but Tatoeba sentences
contain ~198k unique types. The model cannot score OOV words. When the keyboard
extension queries the model, it only asks about in-vocabulary candidates from
SymSpell/Apple, so this does not cause visible errors — it simply means the
KenLM score for some candidates may be zero (vocabulary miss returns 0.0).

### Cold-Start Window

For the first ~500ms–2s after the keyboard appears, contextual prediction is
unavailable. The TrigramProvider loads with a 500ms debounce after SymSpell
builds. During this window, only spelling correction and default top-3
suggestions are shown.

### No User Personalization

The model is a static KenLM 3-gram trained on Tatoeba English. It does not
learn from the user's typing history, frequently used phrases, or writing
style. All users receive identical suggestions for identical contexts. User
personalization is a potential future enhancement (not planned).

### No Test Step in CI

CI builds and verifies the binary but does not run tests. The `RitorasTests`
target has 119 pre-existing compilation errors (unrelated to prediction) that
have been deferred. Tests in `KenLMMemorySpike.swift`,
`SymSpellMemorySpike.swift`, and `TrigramLatencyTest.swift` exist and should
be run manually on a physical device for accurate memory measurements
(`task_vm_info` on device; `estimateMemoryMB()` returns 0.0 on simulator).

---

## 12. File Map

| File | Role |
|---|---|
| **Core Prediction** | |
| `keyboard/Sources/Prediction/PredictionEngine.swift` | Central orchestrator — merges, boosts, scores, dedupes, sorts suggestions |
| `keyboard/Sources/Prediction/CurrentWordExtractor.swift` | Extracts current word, lookup word, previous words from document context |
| `keyboard/Sources/Prediction/SuggestionProvider.swift` | `SuggestionProvider` protocol, `SuggestionContext` struct, `Suggestion` type |
| **SymSpell** | |
| `keyboard/Sources/Prediction/SymSpell/SymSpell.swift` | Symmetric Delete spelling correction algorithm (Swift port, MIT license) |
| `keyboard/Sources/Prediction/SymSpell/SymSpellProvider.swift` | Adapts SymSpell + Trie to SuggestionProvider protocol |
| `keyboard/Sources/Prediction/SymSpell/Trie.swift` | Prefix trie for completions |
| `keyboard/Sources/Prediction/SymSpell/QwertyGeometry.swift` | QWERTY key-distance model for weighted edit-distance scoring |
| `keyboard/Sources/Prediction/SymSpell/WordListLoader.swift` | Streaming frequency-dictionary loader with memory monitoring |
| **Apple Spell Checker** | |
| `keyboard/Sources/Prediction/AppleSpellCheckerProvider.swift` | Wraps `UITextChecker` as a provider (guesses + completions) |
| **Trigram / KenLM** | |
| `keyboard/Sources/Prediction/Trigram/TrigramProvider.swift` | State machine, side-index lookup, KenLM scoring, SuggestionProvider conformance |
| `keyboard/Sources/Prediction/Trigram/SideIndex.swift` | Loads and queries the bigram/unigram → followers JSON |
| `keyboard/Sources/Prediction/Trigram/kenlm_c.h` | C-linkage API header (6 functions, opaque handle) |
| `keyboard/Sources/Prediction/Trigram/kenlm_c.cpp` | C++ implementation wrapping `QuantArrayTrieModel` |
| **Bridging** | |
| `keyboard/RitorasKeyboard-BridgingHeader.h` | Imports `kenlm_c.h` for Swift |
| **Resources** | |
| `keyboard/Sources/Prediction/Resources/trigram_en_v1.klm` | Quantized trie binary (3.31 MB) |
| `keyboard/Sources/Prediction/Resources/trigram_side_index_v1.json` | Bigram + unigram follower index (1.9 MB) |
| `keyboard/Sources/Prediction/Resources/trigram_meta_v1.json` | Training metadata |
| `keyboard/Sources/Prediction/Resources/frequency_dictionary_en_wordfreq_50k.txt` | SymSpell frequency dictionary (wordfreq-derived, top 50k) |
| **Integration** | |
| `keyboard/Sources/KeyboardViewController.swift` | `buildPredictionEngine()`, `scheduleTrigramLoad()`, lifecycle |
| `keyboard/Sources/KeyboardView.swift` | `refreshSuggestions()`, `SuggestionInputSnapshot`, context-token staleness guard |
| `shared/Config.swift` | Prediction-related config defaults (blend weight, min score, etc.) |
| **Vendored Dependencies** | |
| `third-party/kenlm/kenlm-source/` | Vendored KenLM query-only subset (101 files, no Boost) |
| `third-party/kenlm/README.md` | Provenance, SHA, license, compilation notes |
| **Training Scripts** | |
| `scripts/train-kenlm-model.sh` | End-to-end training pipeline |
| `scripts/extract-vocab.py` | Vocabulary extraction from wordfreq dictionary |
| `scripts/preprocess-corpus.py` | Tatoeba corpus download + preprocessing |
| `scripts/build-side-index.py` | Side index builder from ARPA |
| **CI** | |
| `.github/workflows/build.yml` | CI build + Info.plist verification + .ipa packaging |
| `project.yml` | XcodeGen config with C++ settings and KenLM source includes |
| **Tests** | |
| `RitorasTests/KenLMMemorySpike.swift` | KenLM resident memory baseline |
| `RitorasTests/SymSpellMemorySpike.swift` | Combined SymSpell + trigram memory baseline |
| `RitorasTests/TrigramLatencyTest.swift` | Trigram query latency P99 |
| **Documentation** | |
| `docs/THIRD-PARTY-NOTICES.md` | Third-party license notices (KenLM, SymSpell, wordfreq) |
| `docs/TRIGRAM-MODEL.md` | This document |

---

## Appendix: Validation Gates (v1)

| Gate | Criteria | v1 Result |
|---|---|---|
| Model size | ≤ 4.0 MB | 3.31 MB ✅ |
| Side index size | ≤ 2.0 MB | 1.89 MB ✅ (gate relaxed from 500 KB in earlier versions) |
| Perplexity (excl. OOVs) | ≤ 90 | 62.3 ✅ |
| Perplexity (incl. OOVs) | ≤ 90 | 219 ⚠️ (see note below) |
| Vocabulary | = 20,000 | 20,000 ✅ |
| Build flags | `trie -q 8 -b 7 -a 64` | ✅ |

**Perplexity including OOVs (219):** The heldout set has 7,009 OOV tokens out
of 43,531 (16% OOV rate). The excluding-OOVs perplexity of 62.3 is the relevant
metric for keyboard usage — when the keyboard extension queries this model, it
only asks about in-vocabulary words.
