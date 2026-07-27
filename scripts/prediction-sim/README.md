# Ritoras Prediction Simulator

The official pure-logic test surface for the Ritoras prediction/autocorrect
pipeline. See `AGENTS.md` → *Test policy* for the rationale.

## What this covers

Pure-logic components only:
- `CurrentWordExtractor` (tokenization, leading/trailing punctuation stripping)
- `ApostropheNormalizer` (U+0027/U+2018/U+2019 → canonical U+2019)
- `WordBoundaryPunctuation` (boundary-quote set)
- `SymSpell` (delete-index generation, lookup, Levenshtein)
- `QwertyGeometry` (keyboard-distance scoring)
- `Trie` (prefix completion)
- `Contractions` (apostrophe-less → contraction fast-path table)
- `AutocorrectController` (threshold-gated decision logic)
- `PredictionEngine` fusion (Apple boost + KenLM min-max normalization + two-tier threshold + absolute-floor gate)

## What this does NOT cover

- UIKit, SwiftUI, or any view-layer behavior
- AVFoundation / audio capture
- `textDocumentProxy` interaction
- The 48 MB Jetsam memory cap (runtime measurement only — use `ritoras-ios-debugging`)
- Real KenLM scoring (the `.klm` binary cannot run in Node — see *KenLM proxy* below)

## Running

```bash
# From the repo root:
node --test 'scripts/prediction-sim/test/**/*.{js,cjs,mjs}'

# Or via npm:
cd scripts/prediction-sim && npm test
```

Requires Node ≥18 (uses the built-in `node:test` runner — no dependencies).

## KenLM proxy

The real `trigram_en_v1.klm` is a C-bridge binary that cannot run in Node. The
fusion tests use a **bigram-count proxy** (zero dependencies): bigram log-probabilities
derived from a public corpus, used as a stand-in for KenLM's trigram scores. This
gives directional test coverage (does the fusion formula behave correctly given a
score function?) but NOT exact numerical fidelity to production KenLM. Final
calibration of α and the thresholds is confirmed on-device via `ritoras-ios-debugging`.

## Keeping the port in sync

Every change to a Swift pure-logic module MUST be mirrored in the corresponding
`.mjs` file here, with tests updated, in the same commit. The directory structure
mirrors `keyboard/Sources/Prediction/` so the correspondence is obvious.
