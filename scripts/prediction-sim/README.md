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

## SymSpell index blobs

Phase 1 stores the finalized SymSpell delete index as a committed, read-only
binary blob for the keyboard extension. The writer is
`bin/build-symspell-blob.mjs`; the Node reader and the single FNV-1a-64
implementation are in `lib/sym-spell-blob.mjs`.

The builder is intentionally the same pipeline as the in-memory mirror:

1. `loadCanonicalDictionary()` loads and canonicalizes the source wordlist.
2. Entries below `symspellMinWordFreq` are pruned (`count < 1500`).
3. `SymSpell(2, 7)` receives every remaining entry and is finalized.
4. The finalized words, counts, sorted delete-key offsets, and flat CSR values
   are serialized without changing word insertion order.

The `2`, `7`, and `1500` values must stay synchronized with
`shared/Config.swift` (`symspellMaxEditDistance`, `symspellPrefixLength`, and
`symspellMinWordFreq`). The JavaScript mirror previously had the edit-distance
and prefix values at their call sites but no shared minimum-frequency constant;
the blob builder records the authoritative values here and in its baseline
dimension checks.

### v1 format

All integers are little-endian. The 64-byte header starts with `RSS1`, format
version `1`, language (`en\0\0` or `el\0\0`), the three CSR dimensions, the
string-pool byte count, and the FNV-1a-64 digest of the source wordlist bytes.
The remaining header bytes are reserved and zero. Sections then begin at
`0x40`, in this fixed order:

```text
u32[wordCount + 1]       wordOffsets
u32[wordCount]           sortedWordIdx
i32[wordCount]           counts
u32[deleteKeyCount + 1]  deleteKeyOffsets
i32[deleteKeyCount + 1]  deleteOffsets
i32[deleteValueCount]    deleteValues
u8[stringPoolBytes]      NUL-terminated UTF-8 strings
padding to 8 bytes
u64                       FNV-1a-64 of all preceding bytes
```

Words remain in original insertion order so their count alignment and
suggestion tie-break behavior are unchanged. `sortedWordIdx` supplies exact
word lookup by binary search over pooled bytes. Both it and the delete-key
section use `Buffer.compare` UTF-8 byte ordering; this is deliberately not
JavaScript UTF-16 string ordering for above-BMP characters. The pool contains
words first, followed by delete keys in sorted order. Offsets are relative to
the pool and each sentinel is its byte length (or `deleteValueCount` for the
CSR value sentinel).

The `wordOffsets` sentinel is the full `stringPoolBytes` value required by the
format, not the end of the word subsection. Consumers find each word's first
NUL terminator; `deleteKeyOffsets[0]` marks the start of the following
delete-key subsection.

FNV-1a-64 uses offset basis `14695981039346656037` and prime
`1099511628211`. The reader validates the header, dimensions, alignment,
sentinels, pooled string boundaries, sort order, and final blob digest before
exposing typed arrays and pooled `lookup()`/`countFor()` accessors.

### Regeneration and freshness checks

Run these commands from the repository root after changing either source
wordlist or the SymSpell configuration:

```bash
node scripts/prediction-sim/bin/build-symspell-blob.mjs
node scripts/prediction-sim/bin/build-symspell-blob.mjs --check
```

The first command writes both blobs beside their wordlists and prints source
and blob hashes plus all dimensions. The second command reads only each
committed blob header, hashes the current wordlist bytes, and checks the
approved dimensions; it exits non-zero for stale or mismatched artifacts.
Never hand-edit a `.blob` file. The expected baseline is:

| Language | File entries | Words | Delete keys | Delete values |
| --- | ---: | ---: | ---: | ---: |
| EN | 49,999 | 23,158 | 230,403 | 504,740 |
| EL | 42,858 | 32,962 | 368,445 | 818,618 |

The generated pool and file sizes are 184,584 + 1,416,756 = 1,601,340 pool
bytes and 5,741,504 total bytes for EN; 554,172 + 4,147,541 = 4,701,713
pool bytes and 11,319,376 total bytes for EL.
