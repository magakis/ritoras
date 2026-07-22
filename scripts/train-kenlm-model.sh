#!/usr/bin/env bash
#
# Train a KenLM 3-gram model from Tatoeba English sentences.
#
# Pipeline:
#   1. Clone and build KenLM tools (lmplz, build_binary, query)
#   2. Extract vocabulary from SymSpell dictionary
#   3. Download and preprocess Tatoeba English corpus
#   4. Train 3-gram model with lmplz (with pruning to meet size gate)
#   5. Quantize and compress with build_binary (trie -q 8 -b 7 -a 64)
#   6. Measure perplexity on heldout set
#   7. Build trigram side index
#   8. Generate metadata JSON
#   9. Copy artifacts to keyboard/Sources/Prediction/Resources/
#
# Usage:
#     bash scripts/train-kenlm-model.sh
#
#     Re-running with artifacts already present skips completed steps.
#     Pass --force to re-run the full pipeline.
#
# Prerequisites (system):
#     gcc g++ cmake zlib1g-dev libbz2-dev liblzma-dev python3 python3-pip git curl bc
#
# License:
#     Script: Apache 2.0
#     KenLM: LGPL-2.1+ (https://github.com/kpu/kenlm)
#     Tatoeba corpus: CC-BY-2.0

set -euo pipefail

# ---- Paths ----
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

BUILD_DIR="$REPO_ROOT/build"
KENLM_DIR="$BUILD_DIR/kenlm"
KENLM_BUILD_DIR="$KENLM_DIR/build"
LMPLZ="$KENLM_BUILD_DIR/bin/lmplz"
BUILD_BINARY="$KENLM_BUILD_DIR/bin/build_binary"
QUERY="$KENLM_BUILD_DIR/bin/query"

VOCAB_PATH="$BUILD_DIR/vocab.txt"
CORPUS_PATH="$BUILD_DIR/corpus.txt"
HELDOUT_PATH="$BUILD_DIR/heldout.txt"
ARPA_PATH="$BUILD_DIR/trigram.arpa"
KLM_PATH="$BUILD_DIR/trigram_en_v1.klm"
PERPLEXITY_LOG="$BUILD_DIR/perplexity.log"
PERPLEXITY_STDOUT="$BUILD_DIR/perplexity_stdout.txt"
SIDE_INDEX_PATH="$BUILD_DIR/trigram_side_index_v1.json"
META_PATH="$BUILD_DIR/trigram_meta_v1.json"

RESOURCES_DIR="$REPO_ROOT/keyboard/Sources/Prediction/Resources"

# KenLM pinned SHA (from scripts/kenlm-requirements.txt)
KENLM_SHA="4cb443e60b7bf2c0ddf3c745378f76cb59e254e5"

# Defaults
FORCE=false
NGRAM_ORDER=3
VOCAB_SIZE=20000
# Pruning counts per order: unigrams, bigrams, trigrams
# Default: keep all unigrams, prune singleton bigrams and trigrams
PRUNE_ARGS="0 1 1"
SIDE_INDEX_BIGRAMS=5000
SIDE_INDEX_TOP_K=20
JOBS=$(nproc 2>/dev/null || echo 4)

# ---- Parse args ----
while [[ $# -gt 0 ]]; do
    case "$1" in
        --force) FORCE=true; shift ;;
        --vocab-size) VOCAB_SIZE="$2"; shift 2 ;;
        --prune) PRUNE_ARGS="$2"; shift 2 ;;
        --side-index-bigrams) SIDE_INDEX_BIGRAMS="$2"; shift 2 ;;
        --side-index-top-k) SIDE_INDEX_TOP_K="$2"; shift 2 ;;
        --jobs) JOBS="$2"; shift 2 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# ---- Utilities ----
info()  { echo "=== $*" >&2; }
ok()    { echo "  OK  $*" >&2; }
skip()  { echo "  SKIP  $*" >&2; }
fail()  { echo "  FAIL $*" >&2; exit 1; }

check_cmd() {
    if ! command -v "$1" &>/dev/null; then
        fail "Required command not found: $1"
    fi
}

need_run() {
    # Returns 0 (true/need-run) if --force or the given path doesn't exist
    local path="$1"
    $FORCE || [ ! -e "$path" ]
}

# ---- Pre-flight checks ----
info "Checking prerequisites..."
for cmd in git cmake g++ python3 bc; do
    check_cmd "$cmd"
done
ok "All prerequisites found"

mkdir -p "$BUILD_DIR" "$RESOURCES_DIR"

# ---- Step 1: Clone + build KenLM ----
info "Step 1: Build KenLM tools"
if $FORCE; then
    rm -rf "$KENLM_DIR"
fi

if [ ! -f "$LMPLZ" ]; then
    if [ ! -d "$KENLM_DIR" ]; then
        info "Cloning KenLM (SHA: $KENLM_SHA)..."
        git clone https://github.com/kpu/kenlm.git "$KENLM_DIR"
        (cd "$KENLM_DIR" && git checkout "$KENLM_SHA")
        ok "KenLM cloned"
    fi

    info "Building KenLM..."
    mkdir -p "$KENLM_BUILD_DIR"
    (
        cd "$KENLM_BUILD_DIR"
        cmake "$KENLM_DIR" -DCMAKE_BUILD_TYPE=Release
        make -j"$JOBS" lmplz build_binary query
    )
    ok "KenLM built"
else
    skip "KenLM binaries already built"
fi

for tool in "$LMPLZ" "$BUILD_BINARY" "$QUERY"; do
    [ -x "$tool" ] || fail "Missing KenLM tool: $tool"
done

# ---- Step 2: Extract vocabulary ----
info "Step 2: Extract vocabulary (top $VOCAB_SIZE)"
if need_run "$VOCAB_PATH"; then
    python3 "$SCRIPT_DIR/extract-vocab.py" -n "$VOCAB_SIZE" -o "$VOCAB_PATH" --force
    ok "Vocabulary extracted"
else
    skip "Vocabulary already exists at $VOCAB_PATH"
fi

# ---- Step 3: Download and preprocess corpus ----
info "Step 3: Preprocess Tatoeba corpus"
if $FORCE; then
    rm -f "$CORPUS_PATH" "$HELDOUT_PATH"
fi

if [ ! -f "$CORPUS_PATH" ] || [ ! -f "$HELDOUT_PATH" ]; then
    info "Downloading and preprocessing corpus..."
    python3 "$SCRIPT_DIR/preprocess-corpus.py" \
        --vocab "$VOCAB_PATH" \
        --output-dir "$BUILD_DIR" \
        --download-dir "$BUILD_DIR" \
        --holdout 5000 --seed 42 --force
    ok "Corpus preprocessed"
else
    skip "Corpus files already exist"
fi

[ -f "$CORPUS_PATH" ] || fail "Missing corpus file"
CORPUS_LINES=$(wc -l < "$CORPUS_PATH")
HELDOUT_LINES=$(wc -l < "$HELDOUT_PATH")
info "Corpus: $CORPUS_LINES training sentences, $HELDOUT_LINES heldout sentences"

# ---- Step 4: Train with lmplz (with pruning) ----
info "Step 4: Train $NGRAM_ORDER-gram model (prune=$PRUNE_ARGS)"
if need_run "$ARPA_PATH"; then
    info "Running lmplz..."
    "$LMPLZ" -o "$NGRAM_ORDER" \
        --discount_fallback \
        --limit_vocab_file "$VOCAB_PATH" \
        --prune $PRUNE_ARGS \
        --text "$CORPUS_PATH" \
        --arpa "$ARPA_PATH"
    ok "ARPA model trained"
else
    skip "ARPA model already exists at $ARPA_PATH"
fi

ARPA_SIZE=$(stat -c%s "$ARPA_PATH" 2>/dev/null || echo "0")
ARPA_SIZE_MB=$(echo "scale=1; $ARPA_SIZE / 1048576" | bc 2>/dev/null || echo "0")
info "ARPA file size: ${ARPA_SIZE_MB} MB"

# ---- Step 5: Build binary with quantization/compression ----
info "Step 5: Build binary with quantization and pointer compression"
if need_run "$KLM_PATH"; then
    info "Running build_binary trie -q 8 -b 7 -a 64..."
    "$BUILD_BINARY" trie -q 8 -b 7 -a 64 "$ARPA_PATH" "$KLM_PATH"
    ok "Binary model built"
else
    skip "Binary model already exists at $KLM_PATH"
fi

KLM_SIZE=$(stat -c%s "$KLM_PATH" 2>/dev/null || echo "0")
KLM_SIZE_MB=$(echo "scale=2; $KLM_SIZE / 1048576" | bc 2>/dev/null || echo "0")
KLM_SIZE_KB=$(echo "scale=1; $KLM_SIZE / 1024" | bc 2>/dev/null || echo "0")
info "Binary model size: ${KLM_SIZE_MB} MB (${KLM_SIZE_KB} KB)"

if [ "$KLM_SIZE" -gt 4194304 ]; then
    echo "WARNING: Model size ${KLM_SIZE_MB} MB exceeds 4.0 MB limit!" >&2
    echo "  Try --prune '0 2 2' or --vocab-size 15000" >&2
fi

# ---- Step 6: Measure perplexity ----
info "Step 6: Measure perplexity on heldout set"
if need_run "$PERPLEXITY_LOG"; then
    info "Running perplexity evaluation..."
    # query outputs perplexity to stdout with -v summary, timing to stderr
    "$QUERY" -v summary "$KLM_PATH" < "$HELDOUT_PATH" >"$PERPLEXITY_STDOUT" 2>"$PERPLEXITY_LOG" || true
    ok "Perplexity measured"
else
    skip "Perplexity already measured"
fi

# Extract perplexity (including OOVs) from query output
PERPLEXITY=""
if [ -f "$PERPLEXITY_STDOUT" ]; then
    PERPLEXITY=$(grep -i 'Perplexity including OOVs' "$PERPLEXITY_STDOUT" | grep -oP '[\d.]+' | tail -1 || echo "")
fi
if [ -z "$PERPLEXITY" ] && [ -f "$PERPLEXITY_STDOUT" ]; then
    # Fallback: any perplexity line
    PERPLEXITY=$(grep -i 'perplexity' "$PERPLEXITY_STDOUT" | grep -oP '[\d.]+' | head -1 || echo "")
fi
PERPLEXITY="${PERPLEXITY:-0}"

info "Perplexity (including OOVs): $PERPLEXITY"
PPL_PASS=$(echo "$PERPLEXITY <= 90" | bc -l 2>/dev/null || echo "0")
if [ "$PPL_PASS" = "0" ] && [ "$PERPLEXITY" != "0" ]; then
    echo "WARNING: Perplexity $PERPLEXITY exceeds 90 target!" >&2
fi

# ---- Step 7: Build side index ----
info "Step 7: Build trigram side index"
if need_run "$SIDE_INDEX_PATH"; then
    python3 "$SCRIPT_DIR/build-side-index.py" \
        -i "$ARPA_PATH" \
        -o "$SIDE_INDEX_PATH" \
        -n "$SIDE_INDEX_BIGRAMS" \
        --top-k "$SIDE_INDEX_TOP_K" \
        --force
    ok "Side index built"
else
    skip "Side index already exists at $SIDE_INDEX_PATH"
fi

SIDE_INDEX_SIZE=$(stat -c%s "$SIDE_INDEX_PATH" 2>/dev/null || echo "0")
SIDE_INDEX_SIZE_KB=$(echo "scale=1; $SIDE_INDEX_SIZE / 1024" | bc 2>/dev/null || echo "0")

if [ "$SIDE_INDEX_SIZE" -gt 512000 ]; then
    echo "WARNING: Side index ${SIDE_INDEX_SIZE_KB} KB exceeds 500 KB limit!" >&2
fi

# ---- Step 8: Generate metadata JSON ----
info "Step 8: Generate metadata"

TRAINED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
KLM_SHA256=$(sha256sum "$KLM_PATH" 2>/dev/null | cut -d' ' -f1 || echo "unavailable")
ARPA_SHA256=$(sha256sum "$ARPA_PATH" 2>/dev/null | cut -d' ' -f1 || echo "unavailable")

# Count n-grams in ARPA (per-order from header)
NGRAM_COUNTS=""
if [ -f "$ARPA_PATH" ]; then
    NGRAM_COUNTS=$(python3 -c "
import json, re
with open('$ARPA_PATH') as f:
    header = f.read(500)
counts = {}
for m in re.finditer(r'ngram (\d+)=(\d+)', header):
    counts[int(m.group(1))] = int(m.group(2))
print(json.dumps(counts))
" 2>/dev/null || echo "")
fi
if [ -z "$NGRAM_COUNTS" ]; then
    NGRAM_COUNTS='""'
fi

cat > "$META_PATH" <<METAEOF
{
  "corpus": "Tatoeba English (CC-BY-2.0)",
  "corpus_url": "https://tatoeba.org/en/downloads",
  "license": "CC-BY-2.0",
  "vocab_size": $VOCAB_SIZE,
  "vocab_source": "keyboard/Sources/Prediction/Resources/frequency_dictionary_en_wordfreq_50k.txt (top ${VOCAB_SIZE}k)",
  "build_binary_flags": "trie -q 8 -b 7 -a 64",
  "ngram_order": $NGRAM_ORDER,
  "smoothing": "modified_kneser_ney",
  "pruning": "$PRUNE_ARGS",
  "file_size_bytes": $KLM_SIZE,
  "sha256": "$KLM_SHA256",
  "arpa_sha256": "$ARPA_SHA256",
  "perplexity": $PERPLEXITY,
  "trained_at": "$TRAINED_AT",
  "kenlm_sha": "$KENLM_SHA",
  "training_corpus_lines": $CORPUS_LINES,
  "heldout_lines": $HELDOUT_LINES,
  "ngram_order_counts": $NGRAM_COUNTS
}
METAEOF
ok "Metadata written to $META_PATH"

# ---- Step 9: Copy artifacts ----
info "Step 9: Copy artifacts to Resources/"
mkdir -p "$RESOURCES_DIR"

cp "$KLM_PATH" "$RESOURCES_DIR/trigram_en_v1.klm"
cp "$SIDE_INDEX_PATH" "$RESOURCES_DIR/trigram_side_index_v1.json"
cp "$META_PATH" "$RESOURCES_DIR/trigram_meta_v1.json"
ok "Artifacts copied to $RESOURCES_DIR"

# ---- Summary ----
echo ""
echo "============================================"
echo "  TRAINING COMPLETE"
echo "============================================"
echo "  Model:      $RESOURCES_DIR/trigram_en_v1.klm"
echo "  Size:       ${KLM_SIZE_MB} MB (${KLM_SIZE} bytes)"
echo "  Side index: $RESOURCES_DIR/trigram_side_index_v1.json"
echo "  Side size:  ${SIDE_INDEX_SIZE_KB} KB (${SIDE_INDEX_SIZE} bytes)"
echo "  Perplexity: $PERPLEXITY"
echo "  Vocab:      $VOCAB_SIZE words"
echo "  Prune:      $PRUNE_ARGS"
echo "  Trained at: $TRAINED_AT"
echo "  KenLM SHA:  $KENLM_SHA"
echo "============================================"
echo ""
echo "--- Hard Gate Checks ---"

if [ "$KLM_SIZE" -le 4194304 ]; then
    echo "  [PASS] Model size ≤ 4.0 MB: ${KLM_SIZE_MB} MB"
else
    echo "  [FAIL] Model size > 4.0 MB: ${KLM_SIZE_MB} MB"
fi

if [ "$SIDE_INDEX_SIZE" -le 512000 ]; then
    echo "  [PASS] Side index ≤ 500 KB: ${SIDE_INDEX_SIZE_KB} KB"
else
    echo "  [FAIL] Side index > 500 KB: ${SIDE_INDEX_SIZE_KB} KB"
fi

if [ "$(echo "$PERPLEXITY <= 90" | bc -l 2>/dev/null)" = "1" ] && [ "$PERPLEXITY" != "0" ]; then
    echo "  [PASS] Perplexity ≤ 90: $PERPLEXITY"
else
    echo "  [WARN] Perplexity > 90 or unknown: $PERPLEXITY"
fi

echo "  Build flags: trie -q 8 -b 7 -a 64"
echo ""
