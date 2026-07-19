#!/usr/bin/env python3
"""
Export wordfreq English word list as a `word count` frequency dictionary.

Source:
    wordfreq (https://github.com/rspeer/wordfreq) aggregates word frequencies
    from: Google Books Ngrams, Wikipedia, OpenSubtitles, ParaCrawl, Reddit,
    Twitter, BNC, COCA — providing better coverage of conversational/SMS-style
    text than traditional book-prose corpora.

Output format:
    One `word count` per line, matching WordListLoader.swift's parser
    (Int64 count, space-delimited).

Transformation:
    wordfreq provides Zipf values (log10-frequency, 0.0–8.0). We scale to
    integer counts via: count = int(round(10 ** zipf))

License:
    - Data: CC BY-SA 4.0 (https://creativecommons.org/licenses/by-sa/4.0/)
    - Code: Apache 2.0 (https://www.apache.org/licenses/LICENSE-2.0)

Usage:
    pip install -r scripts/wordfreq-requirements.txt
    python3 scripts/export_wordfreq.py

    If the output file already exists, pass --force to overwrite.
"""

import argparse
import math
import os
import sys

# Paths relative to the repo root (this script lives under scripts/).
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.normpath(os.path.join(SCRIPT_DIR, ".."))
OUTPUT_PATH = os.path.join(
    REPO_ROOT,
    "keyboard/Sources/Prediction/Resources/frequency_dictionary_en_wordfreq_50k.txt",
)


def main() -> None:
    parser = argparse.ArgumentParser(description="Export wordfreq frequency dictionary")
    parser.add_argument(
        "--force",
        action="store_true",
        help="Overwrite the output file if it already exists",
    )
    args = parser.parse_args()

    if os.path.exists(OUTPUT_PATH) and not args.force:
        print(
            f"Output file already exists at {OUTPUT_PATH}",
            file=sys.stderr,
        )
        print("Pass --force to overwrite, or delete the file first.", file=sys.stderr)
        sys.exit(1)

    import wordfreq

    print("Fetching top 50,000 English words from wordfreq...")
    words = wordfreq.top_n_list("en", 50_000)

    lines: list[str] = []
    min_zipf = float("inf")
    max_zipf = float("-inf")

    for word in words:
        zipf = wordfreq.zipf_frequency(word, "en")
        min_zipf = min(min_zipf, zipf)
        max_zipf = max(max_zipf, zipf)

        # Scale Zipf (log10) to a linear integer count.
        count = int(round(10**zipf))
        if count < 1:
            count = 1

        # Skip words containing whitespace or non-printable characters.
        if any(c.isspace() or not c.isprintable() for c in word):
            continue

        lower = word.lower()
        if not lower:
            continue

        lines.append(f"{lower} {count}\n")

    # Write output file.
    os.makedirs(os.path.dirname(OUTPUT_PATH), exist_ok=True)
    with open(OUTPUT_PATH, "w", encoding="utf-8") as f:
        f.writelines(lines)

    file_size_kb = os.path.getsize(OUTPUT_PATH) / 1024
    print(f"\nWrote {len(lines)} words to {OUTPUT_PATH}")
    print(f"Zipf range: {min_zipf:.2f} – {max_zipf:.2f}")
    print(f"Output file size: {file_size_kb:.1f} KB")


if __name__ == "__main__":
    main()
