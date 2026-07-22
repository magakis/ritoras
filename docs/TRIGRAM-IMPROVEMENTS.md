# Trigram Prediction — Improvement Roadmap

**Last updated:** 2026-07-22
**Current model version:** v1 (`trigram_en_v1.klm`)
**Reference doc:** [`TRIGRAM-MODEL.md`](TRIGRAM-MODEL.md) — authoritative architecture documentation

---

## Current State

The prediction system is functional and deployed:

- **3-gram KenLM model** trained on Tatoeba English (~2M sentences, CC-BY-2.0)
- **20k headword vocabulary** sourced from SymSpell top-20k
- **Side index:** 23,000 entries (20,000 bigrams + 3,000 unigrams)
- **Mid-word scoring:** direct `kenlm_score(prev2, prev1, candidate)` blended 50/50 with SymSpell
- **Empty-prefix scoring:** side index lookup → unigram fallback → `["the", "I", "and"]` defaults
- **Cold-start:** ~500ms–2s window with SymSpell-only corrections
- **Memory:** ~35–37 MB total resident (under the 40 MB practical Jetsam ceiling)

**What works well:** common phrases, adjective collocations (`"very"` → `good/much/well`), mid-word contextual ranking.

**Known gaps:** rare collocations (`"looking very"` not in side index — mitigated by unigram fallback), 16% OOV rate, no personalization, no Test step in CI.

---

## Improvement Options

Ranked by impact vs. effort. Each section describes the improvement, why it matters, estimated effort, prerequisites, and how to implement it.

---

### 🎯 Priority 1: Corpus Blend (Tatoeba + DailyDialog + Reddit)

**Problem:** Tatoeba alone (2M sentences) is too small for rare collocations. Bigrams like `"looking very"` don't appear in the top 20,000. The unigram fallback catches the most common cases, but rarer contextual patterns are missed.

**Solution:** Blend Tatoeba with one or more additional corpora:
- **DailyDialog** (~13k human-annotated dialogs, cleaner conversational data) — best fit
- **Reddit Pushshift archive** (millions of comments, huge but ToS caveats)
- **OpenSubtitles** (huge, but post-2018 ToS is restrictive — last resort)

A 70/30 Tatoeba/DailyDialog blend trained on the existing 20k vocab would dramatically improve rare-collocation coverage without significantly increasing model size.

**Effort:** ~2–3 hours
- Download and preprocess the additional corpus (~30 min)
- Modify `scripts/preprocess-corpus.py` to blend multiple sources (~30 min)
- Retrain model + rebuild side index (~1 hour)
- Verify quality with spot-checks (~30 min)

**Prerequisites:** None beyond the existing training pipeline.

**Implementation:**
1. Add `--corpus-mix` flag to `scripts/preprocess-corpus.py` that accepts multiple TSV paths with weight ratios
2. Download DailyDialog from http://yanran.li/files/ijcnlp_dailydialog.zip
3. Preprocess: lowercase, tokenize, filter to 20k vocab
4. Retrain: `lmplz -o 3 --discount_fallback --vocab vocab.txt < blended.txt > trigram.arpa`
5. Rebuild side index: `python3 scripts/build-side-index.py --arpa trigram.arpa --output trigram_side_index_v1.json --max-bigrams 20000 --max-unigrams 3000`
6. Spot-check: `"looking very"` should now appear in the side index with followers including adjectives

**Expected impact:** High. This addresses the root cause of most remaining "why didn't it suggest X?" cases.

---

### 🎯 Priority 2: Direct KenLM Scoring for Empty-Prefix

**Problem:** The empty-prefix path (after space) uses the side index lookup, which is limited to 23,000 entries. If a bigram isn't in the index, the unigram fallback fires. But the unigram index is also limited to 3,000 words. For bigrams like `"she said"` → followers, or `"I think"` → followers, the side index may miss.

**Solution:** Apply the same direct KenLM scoring we built for mid-word to the empty-prefix case. Instead of relying on the side index, score candidate words from the vocabulary directly:

1. For the empty-prefix case, get the top-N most frequent words from the vocabulary
2. Score each with `kenlm_score(prev2, prev1, candidate)`
3. Return the top-3

This catches EVERY bigram, not just the indexed ones, because KenLM's full trie model contains all learned n-gram probabilities with Kneser-Ney backoff.

**Effort:** ~2 hours
- Add a `topFollowers(previousWord:previousWord2:limit:)` method to TrigramProvider that iterates the vocabulary
- Or: pre-compute a larger "vocabulary list" (~500 most common words) and score those
- Wire into PredictionEngine's empty-prefix path

**Prerequisites:** The vocabulary list must be available at runtime. Either:
- Embed a text file with the top-500 words (tiny, ~2 KB)
- Or extract from the KenLM model via a new C bridge function (`kenlm_vocab_top_n`)

**Performance concern:** Scoring 500 candidates per empty-prefix keystroke at ~10–100 µs each = 5–50 ms. This may be too slow for older devices. Mitigations:
- Score fewer candidates (top-100 instead of top-500)
- Cache results per context (same `prev2+prev1` → same results within a session)
- Pre-compute during the 500ms warmup debounce

**Expected impact:** Medium-high. Eliminates the side index coverage gap entirely.

---

### 🎯 Priority 3: Tune the Blend Weight (A/B Test)

**Problem:** The mid-word blend is currently 50/50 between SymSpell and KenLM (`kenlmBlendWeight = 0.5`). This might not be optimal — some users may prefer more contextual emphasis (higher KenLM weight), while others may prefer more spelling-frequency emphasis (lower KenLM weight).

**Solution:** Experiment with different values:
- `0.4` — favors SymSpell (spelling frequency dominates)
- `0.5` — current default (balanced)
- `0.6` — favors KenLM (contextual probability dominates)
- `0.7` — strong contextual emphasis

**Effort:** ~30 minutes per configuration
- Change one config value in `shared/Config.swift`
- Rebuild + redeploy
- Test with common phrases

**Prerequisites:** None.

**Implementation:**
1. Change `kenlmBlendWeight` in `SharedConfig.Defaults`
2. Deploy to device
3. Type various sentences and compare suggestion quality
4. Pick the value that feels best

**Expected impact:** Low-medium. The current 0.5 is likely close to optimal, but 0.6 might feel slightly smarter.

---

### 🔧 Priority 4: Larger Vocabulary (20k → 30k)

**Problem:** The 20k headword vocabulary has a 16% OOV rate on Tatoeba's heldout set. Words outside the vocabulary are mapped to `<unk>` and lose their identity — KenLM can't distinguish between them.

**Solution:** Expand the vocabulary to 30k headwords (the SymSpell dictionary has 50k, so there's room). This reduces the OOV rate to ~8%.

**Effort:** ~30 minutes
- Change `head -n 20000` to `head -n 30000` in `scripts/extract-vocab.py`
- Retrain model (the trie will be ~20% larger, still under the 4 MB budget)
- Rebuild side index

**Prerequisites:** None.

**Trade-off:** Model size increases from ~3.4 MB to ~4.0 MB. Side index increases proportionally. Still within memory budget, but with less headroom. If the model exceeds 4 MB, reduce pruning aggressiveness or fall back to 25k.

**Expected impact:** Medium. Fewer OOV words means more candidates get proper KenLM scoring instead of the `<unk>` fallback.

---

### 🔧 Priority 5: State-Based KenLM API (Performance)

**Problem:** The current mid-word scoring calls `kenlm_score_sentence` for each candidate (~10–20 per keystroke). Each call re-processes the context words (`prev2`, `prev1`) from scratch. For 15 candidates, that's 15 redundant context-processings.

**Solution:** Expose KenLM's State API through the C bridge:
1. Add `kenlm_state_t` type and `kenlm_state_from_words(model, words)` function
2. Add `kenlm_score_from_state(model, state, word)` function
3. In TrigramProvider, compute the context state once per keystroke, then score each candidate from that state

**Effort:** ~3 hours
- Add State API to `kenlm_c.h` / `kenlm_c.cpp` (~1 hour)
- Update TrigramProvider to use state-based scoring (~1 hour)
- Benchmark before/after (~30 min)

**Prerequisites:** None.

**Expected impact:** Low (performance only). ~5x faster scoring loop (from ~1–2 ms to ~0.2–0.4 ms per keystroke). Only noticeable on older devices (A12/A13 chips).

---

### 🔧 Priority 6: Re-Enable CI Test Step

**Problem:** Phase 5 added a Test step to CI, but it exposed 119 pre-existing test compilation errors across the `RitorasTests` target. The Test step was removed to keep CI green. Our new Trigram tests exist but don't run in CI.

**Solution:** Fix the 119 pre-existing errors (or at least enough to compile), then re-enable the Test step. Alternatively, mark the Test step as `continue-on-error` so it runs but doesn't block merges.

**Effort:** ~3–4 hours for full fix, ~30 min for `continue-on-error` approach

**Error breakdown (from CI logs):**
- 24 errors: "cannot infer contextual base in reference to member 'yes'" — keyboard type enum in test target
- 21 errors: "cannot find 'SharedConfig' in scope" — shared/ module not in test target
- 20 errors: "errors thrown from here are not handled" — throwing functions not wrapped in `try`
- 14 errors: "cannot find 'AutoCorrectTraits' in scope" — excluded from test target
- 6 errors: "cannot find 'FileLogger' in scope"
- 5 errors: "missing argument for parameter 'previousWord2'" — Swift 6 init pattern
- 4 errors: "UnsafeMutablePointer<CChar> conversion" — TrigramBridgeSmokeTest
- ~25 other miscellaneous errors

**Prerequisites:** Understanding of the test target's source inclusion in `project.yml`.

**Expected impact:** Medium. Real test enforcement prevents regressions. Currently, tests can only be run locally by developers on macOS.

---

### 🚀 Priority 7: User History / Personalization

**Problem:** The current model is static — it doesn't adapt to the user's writing patterns. Gboard feels "smart" because it learns from what you type over time (via federated learning).

**Solution:** Implement a lightweight per-user n-gram store:
1. When the user accepts a suggestion (taps it from the suggestion bar), record the bigram `(previousWord, acceptedWord)` with a count
2. Store in `LearnedWordsStore` (already exists, currently only stores unigrams) or a new `UserHistoryStore`
3. During scoring, boost candidates that appear in the user's history
4. Apply exponential decay so recent patterns dominate

**Effort:** ~1 week
- Design the storage format (SQLite? plist? JSON?)
- Implement the recording hook in `KeyboardViewController.keyboardView(_:didTapSuggestion:)`
- Implement the boosting logic in `PredictionEngine`
- Handle persistence across keyboard sessions (app group or localhost IPC)
- Test on device

**Prerequisites:** Working app group or localhost IPC for cross-session persistence. The SideStore app group issue (see `.opencode/skills/debugging/sidestore-app-group/`) may complicate this.

**Expected impact:** High over time. This is the single feature that makes a keyboard feel personally intelligent rather than generic.

---

### 🚀 Priority 8: CIFG-LSTM Neural Model (Hard et al. 2018)

**Problem:** N-gram models have a hard ceiling on quality. They can't capture long-range dependencies, semantic similarity, or syntactic structure. Neural models (even small ones) outperform n-grams on standard benchmarks.

**Solution:** Port the Gboard architecture (Hard et al. 2018, "Federated Learning for Mobile Keyboard Prediction") to Core ML:
- CIFG-LSTM (Coupled Input-Forget Gates) with ~1.4M parameters
- Character-level input handling for OOV words
- Quantized to INT8: model size < 2 MB
- Inference latency: ~1–5 ms per query on A14+

**Effort:** ~2–3 weeks
- Set up training pipeline (TensorFlow/PyTorch → Core ML via coremltools)
- Train on conversational corpus (Tatoeba + DailyDialog + Reddit)
- Convert to Core ML model
- Integrate into the keyboard (replacing or augmenting KenLM)
- Benchmark quality vs. KenLM baseline
- Memory/latency testing on oldest supported device (iPhone XS, A12)

**Prerequisites:** ML engineering expertise. Core ML / coremltools familiarity. Training infrastructure (GPU).

**Expected impact:** Highest. A neural model would dramatically improve suggestion quality, especially for:
- Long-range dependencies ("I went to the ___ yesterday" → "store", "park", "doctor")
- Semantic similarity (knowing that "exhausted" and "tired" are related)
- Syntactic awareness (knowing that after "the", a noun is expected)

**Reference:** Hard et al. 2018 — https://arxiv.org/abs/1811.03604

---

## Tracking

Mark improvements as they're implemented:

| # | Improvement | Status | Date | Commit |
|---|-------------|--------|------|--------|
| 1 | Corpus blend | Not started | — | — |
| 2 | Direct KenLM scoring for empty-prefix | Not started | — | — |
| 3 | Tune blend weight | Not started | — | — |
| 4 | Larger vocabulary | Not started | — | — |
| 5 | State-based KenLM API | Not started | — | — |
| 6 | Re-enable CI Test step | Not started | — | — |
| 7 | User history / personalization | Not started | — | — |
| 8 | CIFG-LSTM neural model | Not started | — | — |

---

## Related Documents

- [`TRIGRAM-MODEL.md`](TRIGRAM-MODEL.md) — authoritative architecture documentation
- [`THIRD-PARTY-NOTICES.md`](THIRD-PARTY-NOTICES.md) — KenLM LGPL-2.1+ license attribution
- [`SERVER-CONTRACT.md`](SERVER-CONTRACT.md) — Whisper dictation server contract (unrelated to prediction)
- [`../third-party/kenlm/README.md`](../third-party/kenlm/README.md) — vendored KenLM provenance
