#!/usr/bin/env python3
"""
Download and preprocess the Tatoeba English sentence corpus for KenLM training.

Source:
    https://tatoeba.org/en/downloads — Community-contributed sentence corpus.
    CC-BY-2.0 license (https://creativecommons.org/licenses/by/2.0/).

    We download sentences.tar.bz2 which contains one CSV file (sentences.csv)
    with columns: id, lang, text. We filter to rows where lang == "eng".

Output:
    Two files:
        corpus.txt  — training sentences (one per line, all remaining lines)
        heldout.txt — heldout sentences (5,000 lines, deterministic split)

    Both files are:
        - Lowercased
        - Tokenized on whitespace
        - Filtered: no empty lines, max 200 tokens per line
        - OOV tokens replaced with <unk> (using the provided vocab)

License:
    Script: Apache 2.0
    Corpus: CC-BY-2.0 (https://creativecommons.org/licenses/by/2.0/)
"""

import argparse
import os
import random
import sys
import tarfile
import tempfile
import urllib.request

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.normpath(os.path.join(SCRIPT_DIR, ".."))

TATOEBA_URL = "https://downloads.tatoeba.org/exports/sentences.tar.bz2"
TATOEBA_FILENAME = "sentences.tar.bz2"


def download_tatoeba(download_dir: str) -> str:
    """Download Tatoeba sentences.tar.bz2, returns path to extracted sentences.csv."""
    archive_path = os.path.join(download_dir, TATOEBA_FILENAME)
    csv_path = os.path.join(download_dir, "sentences.csv")

    if not os.path.exists(csv_path):
        if not os.path.exists(archive_path):
            print(f"Downloading Tatoeba sentences from {TATOEBA_URL}...", file=sys.stderr)
            urllib.request.urlretrieve(TATOEBA_URL, archive_path)
            size_mb = os.path.getsize(archive_path) / (1024 * 1024)
            print(f"Downloaded {size_mb:.1f} MB", file=sys.stderr)

        print("Extracting sentences.tar.bz2...", file=sys.stderr)
        with tarfile.open(archive_path, "r:bz2") as tar:
            tar.extractall(path=download_dir)
        print(f"Extracted to {csv_path}", file=sys.stderr)
    else:
        print(f"Found existing {csv_path}, skipping download.", file=sys.stderr)

    return csv_path


def load_vocab(vocab_path: str) -> set[str]:
    """Load vocabulary from vocab.txt (KenLM format: one word per line)."""
    vocab: set[str] = set()
    with open(vocab_path, "r", encoding="utf-8") as f:
        for line in f:
            word = line.strip()
            if word:
                vocab.add(word)
    print(f"Loaded {len(vocab)} vocabulary words from {vocab_path}", file=sys.stderr)
    return vocab


def preprocess(csv_path: str, vocab: set[str], output_dir: str, holdout: int = 5000, seed: int = 42) -> tuple[str, str]:
    """
    Preprocess Tatoeba CSV: filter English, lowercase, tokenize,
    split into train/holdout.

    OOV tokens are NOT replaced with <unk>. Vocabulary restriction is
    handled by KenLM's --limit_vocab_file flag at training time.
    """
    corpus_path = os.path.join(output_dir, "corpus.txt")
    heldout_path = os.path.join(output_dir, "heldout.txt")

    if os.path.exists(corpus_path) and os.path.exists(heldout_path):
        print(f"Corpus files already exist at {output_dir}, skipping preprocessing.", file=sys.stderr)
        return corpus_path, heldout_path

    print("Filtering English sentences from CSV...", file=sys.stderr)
    sentences: list[str] = []

    with open(csv_path, "r", encoding="utf-8") as f:
        for line_num, line in enumerate(f, 1):
            line = line.strip()
            if not line:
                continue

            # CSV format: id<TAB>lang<TAB>text
            parts = line.split("\t")
            if len(parts) < 3:
                continue

            lang = parts[1].strip()
            if lang != "eng":
                continue

            text = parts[2].strip().lower()

            # Tokenize on whitespace
            tokens = text.split()

            # Drop empty lines
            if not tokens:
                continue

            # Drop lines > 200 tokens
            if len(tokens) > 200:
                continue

            # Keep original tokens. Vocabulary restriction is handled
            # by KenLM's --limit_vocab_file at training time.
            sentence = " ".join(tokens)
            sentences.append(sentence)

    print(f"Extracted {len(sentences)} English sentences", file=sys.stderr)

    # Deterministic shuffle (seed=42)
    rng = random.Random(seed)
    rng.shuffle(sentences)

    # Hold out 5,000 lines for perplexity measurement
    heldout_sentences = sentences[:holdout]
    corpus_sentences = sentences[holdout:]

    print(f"Train: {len(corpus_sentences)} sentences", file=sys.stderr)
    print(f"Heldout: {len(heldout_sentences)} sentences", file=sys.stderr)

    os.makedirs(output_dir, exist_ok=True)

    with open(corpus_path, "w", encoding="utf-8") as f:
        for s in corpus_sentences:
            f.write(s + "\n")

    with open(heldout_path, "w", encoding="utf-8") as f:
        for s in heldout_sentences:
            f.write(s + "\n")

    train_size_mb = os.path.getsize(corpus_path) / (1024 * 1024)
    heldout_size_kb = os.path.getsize(heldout_path) / 1024
    print(f"Wrote corpus: {corpus_path} ({train_size_mb:.1f} MB)", file=sys.stderr)
    print(f"Wrote heldout: {heldout_path} ({heldout_size_kb:.1f} KB)", file=sys.stderr)

    return corpus_path, heldout_path


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Download and preprocess the Tatoeba English corpus"
    )
    parser.add_argument(
        "--vocab",
        default=None,
        help="Path to vocab.txt (optional, used only for logging)",
    )
    parser.add_argument(
        "-o", "--output-dir",
        required=True,
        help="Directory to write corpus.txt and heldout.txt",
    )
    parser.add_argument(
        "--download-dir",
        default=None,
        help="Directory for downloaded/extracted Tatoeba files (default: output-dir)",
    )
    parser.add_argument(
        "--holdout",
        type=int,
        default=5000,
        help="Number of heldout sentences (default: 5000)",
    )
    parser.add_argument(
        "--seed",
        type=int,
        default=42,
        help="Random seed for deterministic shuffle (default: 42)",
    )
    parser.add_argument(
        "--force",
        action="store_true",
        help="Re-download and reprocess even if outputs exist",
    )
    args = parser.parse_args()

    download_dir = args.download_dir or args.output_dir
    os.makedirs(download_dir, exist_ok=True)
    os.makedirs(args.output_dir, exist_ok=True)

    # Clean if --force
    if args.force:
        csv_path = os.path.join(download_dir, "sentences.csv")
        archive_path = os.path.join(download_dir, TATOEBA_FILENAME)
        for p in [csv_path, archive_path]:
            if os.path.exists(p):
                os.remove(p)
        for fname in ["corpus.txt", "heldout.txt"]:
            p = os.path.join(args.output_dir, fname)
            if os.path.exists(p):
                os.remove(p)

    # Download and extract
    csv_path = download_tatoeba(download_dir)

    # Load vocab (optional, for logging only — OOV handling is done by KenLM --limit_vocab_file)
    vocab: set[str] = set()
    if args.vocab:
        vocab = load_vocab(args.vocab)

    # Preprocess
    preprocess(csv_path, vocab, args.output_dir, args.holdout, args.seed)


if __name__ == "__main__":
    main()
