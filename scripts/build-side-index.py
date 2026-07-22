#!/usr/bin/env python3
"""
Build a side index from a KenLM ARPA file for fast bigram lookups.

The side index maps common bigrams ("<prev2> <prev1>") to their top-N
most likely follower words, extracted from the trigram probabilities
in the ARPA file.

Source:
    trigram.arpa — ARPA-format KenLM language model output.

Output:
    JSON file keyed by bigram string mapping to a list of up to 20 follower
    words, sorted by descending probability.

Example entry:
    {
        "looking very": ["good", "much", "nice", "beautiful", "tired"],
        "i am": ["not", "a", "the", "going"]
    }

License:
    Apache 2.0
"""

import argparse
import json
import os
import re
import sys
from collections import defaultdict

# ARPA file format lines have tab-separated fields:
#   log_prob<TAB>token1 token2 ...<TAB>backoff_prob
# where backoff is optional (trigrams never have backoff in practice).
ARPA_NUM_RE = re.compile(r"^-?[\d.]+(?:e[+-]?\d+)?$")


def parse_arpa_line(line: str) -> tuple[float, list[str], float] | None:
    """Parse a single ARPA n-gram line. Returns (log_prob, [tokens], backoff) or None."""
    line = line.rstrip("\n")
    parts = line.split("\t")
    if len(parts) < 2:
        return None

    log_prob_str = parts[0]
    if not ARPA_NUM_RE.match(log_prob_str):
        return None

    log_prob = float(log_prob_str)
    tokens_str = parts[1]
    tokens = tokens_str.split()

    backoff = 0.0
    if len(parts) >= 3 and parts[2]:
        backoff_str = parts[2]
        if ARPA_NUM_RE.match(backoff_str):
            backoff = float(backoff_str)

    return (log_prob, tokens, backoff)


def parse_arpa(arpa_path: str) -> dict[int, list[tuple[float, list[str], float]]]:
    """
    Parse ARPA file and return n-grams by order.

    Returns dict: order -> list of (log_prob, [tokens], backoff)
    """
    ngrams: dict[int, list[tuple[float, list[str], float]]] = defaultdict(list)
    current_order = 0
    in_ngrams_section = False

    with open(arpa_path, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue

            if line.startswith("\\data\\"):
                in_ngrams_section = False
                continue

            if line.startswith("\\"):
                # Could be "\1-grams:", "\2-grams:", etc.
                m = re.match(r"^\\(\d+)-grams:", line)
                if m:
                    current_order = int(m.group(1))
                    in_ngrams_section = True
                else:
                    in_ngrams_section = False
                continue

            if not in_ngrams_section:
                continue

            parsed = parse_arpa_line(line)
            if parsed is None:
                continue

            log_prob, tokens, backoff = parsed
            ngrams[current_order].append((log_prob, tokens, backoff))

    return dict(ngrams)


def build_side_index(
    ngrams: dict[int, list],
    max_bigrams: int = 5000,
    top_k: int = 20,
) -> dict[str, list[str]]:
    """
    Build side index from parsed n-grams.

    For the top-N most-frequent bigrams (by sum of trigram backoff weights),
    collect the top-K follower words from trigrams where the first two tokens
    match the bigram.

    Args:
        ngrams: Parsed n-grams (from parse_arpa)
        max_bigrams: Max number of bigrams to include in the index
        top_k: Max followers per bigram

    Returns:
        Dict mapping "prev2 prev1" -> [follower1, follower2, ...]
    """
    if 2 not in ngrams:
        print("Warning: No bigrams found in ARPA file", file=sys.stderr)
        return {}

    if 3 not in ngrams:
        print("Warning: No trigrams found in ARPA file", file=sys.stderr)
        return {}

    bigrams = ngrams[2]
    trigrams = ngrams[3]

    # Build a map: bigram_str -> list of (trigram_log_prob, follower_word)
    trigram_map: dict[str, list[tuple[float, str]]] = defaultdict(list)

    for log_prob, tokens, backoff in trigrams:
        if len(tokens) != 3:
            continue
        prev2, prev1, follower = tokens
        bigram_key = f"{prev2} {prev1}"
        trigram_map[bigram_key].append((log_prob, follower))

    # Sort followers by probability (descending) for each bigram
    bigram_followers: dict[str, list[str]] = {}
    for bigram_key, followers in trigram_map.items():
        followers.sort(key=lambda x: x[0], reverse=True)
        bigram_followers[bigram_key] = [f[1] for f in followers[:top_k]]

    # Sort bigrams by log probability descending (more common first)
    # and take top-N. Use the bigram's log_prob as the importance metric.
    bigram_importance: list[tuple[str, float]] = []
    for log_prob, tokens, backoff in bigrams:
        if len(tokens) != 2:
            continue
        bigram_key = f"{tokens[0]} {tokens[1]}"
        # Higher log_prob = more common bigram
        bigram_importance.append((bigram_key, log_prob))

    # Sort by log probability descending (most common first)
    bigram_importance.sort(key=lambda x: x[1], reverse=True)

    # Build the final index
    side_index: dict[str, list[str]] = {}
    count = 0
    for bigram_key, _ in bigram_importance:
        if bigram_key in bigram_followers:
            side_index[bigram_key] = bigram_followers[bigram_key]
            count += 1
            if count >= max_bigrams:
                break

    print(f"Built side index with {len(side_index)} bigrams", file=sys.stderr)
    return side_index


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Build side index JSON from KenLM ARPA file"
    )
    parser.add_argument(
        "-i", "--input-arpa",
        required=True,
        help="Path to input trigram.arpa file",
    )
    parser.add_argument(
        "-o", "--output",
        required=True,
        help="Path to output JSON file",
    )
    parser.add_argument(
        "-n", "--max-bigrams",
        type=int,
        default=5000,
        help="Maximum number of bigrams in the index (default: 5000)",
    )
    parser.add_argument(
        "--top-k",
        type=int,
        default=20,
        help="Maximum follower words per bigram (default: 20)",
    )
    parser.add_argument(
        "--force",
        action="store_true",
        help="Overwrite output file if it already exists",
    )
    args = parser.parse_args()

    if os.path.exists(args.output) and not args.force:
        print(
            f"Output file already exists at {args.output}",
            file=sys.stderr,
        )
        print("Pass --force to overwrite, or delete the file first.", file=sys.stderr)
        sys.exit(1)

    if not os.path.exists(args.input_arpa):
        print(f"ARPA file not found: {args.input_arpa}", file=sys.stderr)
        sys.exit(1)

    print(f"Parsing ARPA file: {args.input_arpa}", file=sys.stderr)
    ngrams = parse_arpa(args.input_arpa)
    print(f"  Unigrams: {len(ngrams.get(1, []))}", file=sys.stderr)
    print(f"  Bigrams: {len(ngrams.get(2, []))}", file=sys.stderr)
    print(f"  Trigrams: {len(ngrams.get(3, []))}", file=sys.stderr)

    side_index = build_side_index(
        ngrams,
        max_bigrams=args.max_bigrams,
        top_k=args.top_k,
    )

    os.makedirs(os.path.dirname(args.output), exist_ok=True)
    with open(args.output, "w", encoding="utf-8") as f:
        json.dump(side_index, f, indent=2, ensure_ascii=False)

    file_size_kb = os.path.getsize(args.output) / 1024
    print(f"Wrote side index ({file_size_kb:.1f} KB) to {args.output}")

    if file_size_kb > 500:
        print(
            f"WARNING: Side index is {file_size_kb:.1f} KB, exceeds 500 KB limit!",
            file=sys.stderr,
        )
        print(
            "  Reduce --max-bigrams or --top-k and re-run.",
            file=sys.stderr,
        )


if __name__ == "__main__":
    main()
