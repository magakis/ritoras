# KenLM — Query-Only Subset

## Provenance

| Field | Value |
|---|---|
| **Upstream** | https://github.com/kpu/kenlm |
| **Pinned SHA** | `4cb443e60b7bf2c0ddf3c745378f76cb59e254e5` |
| **License** | LGPL-2.1+ (GNU Lesser General Public License v2.1 or later) |
| **License file** | `kenlm-source/LICENSE` |

## What's Included

A query-only subset of the KenLM library, capable of loading and querying
binary format language models (`.klm` files) via the `lm::ngram::TrieModel`
class.

### Included directories

| Directory | Purpose |
|---|---|
| `lm/` | Language model headers and source — model loading, trie search, vocabulary, binary format, quantization |
| `util/` | Utility headers and source — memory-mapped file I/O, bit packing, exception handling, hash functions |
| `util/double-conversion/` | Double-to-string conversion for error formatting |

### Excluded directories

| Directory | Reason |
|---|---|
| `lm/builder/` | Training/estimation code (not needed for query-only) |
| `lm/filter/` | Corpus filtering (not needed for query-only) |
| `lm/interpolate/` | Model interpolation (not needed for query-only) |
| `lm/wrappers/` | NPLM wrapper (not needed) |
| `util/stream/` | Streaming chain utilities (used by builder, depends on Boost) |

### Excluded individual files

- All `*test*`, `*_test*`, `*_main*`, `*_main.cc` files
- `lm/common/` — model buffer, print, renumber, size_option (training code, Boost-dependent)
- `util/read_compressed.cc` — replaced by `read_compressed_stub.cc` (compressed file reader not needed
  for binary-only `.klm` loading; the stub provides empty implementations that satisfy the linker)

## Boost Dependencies

**None.** The vendored subset has zero Boost dependencies.

The `read_compressed_stub.cc` stub and the `ersatz_progress.hh` header both use
KenLM's own "ersatz" replacements instead of Boost. The subset was audited by
scanning all `.hh`, `.h`, and `.cc` files for `#include.*boost` — zero hits.

## How to Update

1. Clone the KenLM repo and checkout the new SHA:
   ```bash
   git clone https://github.com/kpu/kenlm.git /tmp/kenlm
   cd /tmp/kenlm
   git checkout <NEW_SHA>
   ```

2. Remove the old vendored subset:
   ```bash
   rm -rf third-party/kenlm/kenlm-source
   ```

3. Create the vendored subset (see `scripts/` or manual copy). The query-only
   files are all `.cc` files in `lm/` listed in `lm/CMakeLists.txt` (minus
   `builder/`, `filter/`, `interpolate/`, `common/`, `wrappers/`, test and main
   files), plus the non-Boost `.cc` files from `util/`, and the
   `util/double-conversion/` library.

4. Create a fresh `read_compressed_stub.cc` for the new version.

5. Update this README and the pinned SHA in `scripts/kenlm-requirements.txt`.

## Compilation Notes

- **C++ standard:** `gnu++17` (requires C++17-compatible compiler)
- **C++ library:** `libc++` (iOS standard)
- **Required defines:**
  - `-DKENLM_MAX_ORDER=6` (KenLM default — sufficient for 3-gram models)
  - `-DNDEBUG` (for release builds)
- **Header search paths:** The KenLM source uses relative `#include "../util/..."` paths,
  so the root include path must point to `third-party/kenlm/kenlm-source`.
- The vendored subset does NOT support reading compressed (`.gz`, `.bz2`, `.xz`)
  ARPA files — it only loads pre-built binary format (`.klm`) models.
