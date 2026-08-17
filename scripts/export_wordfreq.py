#!/usr/bin/env python3
"""
Export wordfreq word list as a `word count` frequency dictionary.

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

    For "el" (Modern Greek) only:
    - Tokens are kept only when every character is in the modern monotonic
      Greek allowlist (uppercase incl. accented U+0386, U+0388–U+038A, U+038C,
      U+038E–U+0390, U+0391–U+03A9; monotonic lowercase U+03AC–U+03CE).
      Polytonic (precomposed U+1F00–U+1FFF and NFD combining U+0300–U+036F),
      digits/symbols, Latin, and mixed tokens (π.χ, 1η, απ'το) are dropped.
      Accepted tradeoff: ~310 tokens containing an apostrophe/hyphen are
      excluded.
    - Word-final sigma is mapped σ → ς after filtering: wordfreq's NFKC
      normalization collapses final sigma (e.g. "τησ" → "της").

License:
    - Data: CC BY-SA 4.0 (https://creativecommons.org/licenses/by-sa/4.0/)
    - Code: Apache 2.0 (https://www.apache.org/licenses/LICENSE-2.0)

Usage:
    pip install -r scripts/wordfreq-requirements.txt
    python3 scripts/export_wordfreq.py [--lang en|el]

    Supported languages follow wordfreq's ISO 639-1 codes: "en" (English),
    "el" (Modern Greek). The output lands in
    keyboard/Sources/Prediction/Resources/frequency_dictionary_<lang>_wordfreq_50k.txt.

    If the output file already exists, pass --force to overwrite.
"""

import argparse
import os
import sys

# Paths relative to the repo root (this script lives under scripts/).
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.normpath(os.path.join(SCRIPT_DIR, ".."))

# Characters allowed in the "el" (Modern Greek) output: uppercase incl.
# accented (U+0386, U+0388–U+038A, U+038C, U+038E–U+0390, U+0391–U+03A9) and
# monotonic lowercase (U+03AC–U+03CE, which includes σ and ς). Polytonic
# precomposed (U+1F00–U+1FFF), NFD combining marks (U+0300–U+036F), digits,
# symbols, Latin, and mixed tokens are all excluded.
GREEK_ALLOWED = frozenset(
    chr(cp)
    for cp in [
        *range(0x0386, 0x0387),  # Ά
        *range(0x0388, 0x038B),  # Έ Ή Ί
        *range(0x038C, 0x038D),  # Ό
        *range(0x038E, 0x0391),  # Ύ Ώ ΐ
        *range(0x0391, 0x03AA),  # Α–Ω
        *range(0x03AC, 0x03CF),  # ά–ώ, ϊ ϋ σ ς (monotonic lowercase)
    ]
)


def output_path_for(lang: str) -> str:
    return os.path.join(
        REPO_ROOT,
        f"keyboard/Sources/Prediction/Resources/frequency_dictionary_{lang}_wordfreq_50k.txt",
    )


def main() -> None:
    parser = argparse.ArgumentParser(description="Export wordfreq frequency dictionary")
    parser.add_argument(
        "--lang",
        default="en",
        help="wordfreq language code (ISO 639-1), e.g. en, el (default: en)",
    )
    parser.add_argument(
        "--force",
        action="store_true",
        help="Overwrite the output file if it already exists",
    )
    args = parser.parse_args()

    lang = args.lang
    output_path = output_path_for(lang)

    if os.path.exists(output_path) and not args.force:
        print(
            f"Output file already exists at {output_path}",
            file=sys.stderr,
        )
        print("Pass --force to overwrite, or delete the file first.", file=sys.stderr)
        sys.exit(1)

    import wordfreq

    print(f"Fetching top 50,000 {lang} words from wordfreq...")
    words = wordfreq.top_n_list(lang, 50_000)

    lines: list[str] = []
    min_zipf = float("inf")
    max_zipf = float("-inf")

    for word in words:
        zipf = wordfreq.zipf_frequency(word, lang)
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

        if lang == "el":
            # Keep only modern monotonic Greek tokens (see GREEK_ALLOWED);
            # this drops polytonic, combining-mark, digit/symbol, Latin, and
            # mixed tokens. Accepted tradeoff: ~310 tokens containing an
            # apostrophe/hyphen are excluded.
            if not all(c in GREEK_ALLOWED for c in lower):
                continue

            # Restore word-final sigma: wordfreq's NFKC normalization folds
            # final ς to medial σ, so map a trailing σ back to ς.
            if lower.endswith("σ"):
                lower = lower[:-1] + "ς"

        lines.append(f"{lower} {count}\n")

    # Write output file.
    os.makedirs(os.path.dirname(output_path), exist_ok=True)
    with open(output_path, "w", encoding="utf-8") as f:
        f.writelines(lines)

    file_size_kb = os.path.getsize(output_path) / 1024
    print(f"\nWrote {len(lines)} words to {output_path}")
    print(f"Zipf range: {min_zipf:.2f} – {max_zipf:.2f}")
    print(f"Output file size: {file_size_kb:.1f} KB")


if __name__ == "__main__":
    main()
