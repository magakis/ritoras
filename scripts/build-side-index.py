#!/usr/bin/env python3
"""
Build a side index from a KenLM ARPA file for fast bigram and unigram lookups.

The side index maps common bigrams ("<prev2> <prev1>") and unigrams ("<word>")
to their top-N most likely follower words, extracted from the trigram and
bigram probabilities in the ARPA file.

Source:
    trigram.arpa — ARPA-format KenLM language model output.

Output:
    JSON file keyed by bigram or unigram string mapping to a list of up to 20
    follower words, sorted by descending probability.

Bigram keys always contain a space ("word1 word2"). Unigram keys never contain
a space ("word"). The lookup code distinguishes them by presence of a space.

Example entry:
    {
        "looking very": ["good", "much", "nice", "beautiful", "tired"],
        "very": ["good", "much", "nice", "important", "well"],
        "i am": ["not", "a", "the", "going"],
        "i": ["am", "want", "think", "know", "have"]
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
    max_bigrams: int = 20000,
    top_k: int = 20,
    max_unigrams: int = 3000,
) -> dict[str, list[str]]:
    """
    Build side index from parsed n-grams.

    Builds two kinds of entries:
    1. **Bigram entries** (key contains a space): For the top-N most-frequent
       bigrams, collect the top-K follower words from trigrams where the first
       two tokens match the bigram.
    2. **Unigram entries** (key has no space): For the top-M most common
       unigrams, collect the top-K follower words from bigrams where the first
       word matches.

    Args:
        ngrams: Parsed n-grams (from parse_arpa)
        max_bigrams: Max number of bigrams to include in the index
        top_k: Max followers per entry
        max_unigrams: Max number of unigrams to include

    Returns:
        Dict mapping "prev2 prev1" or "word" -> [follower1, follower2, ...]
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

    # Build unigram entries
    unigram_entries = _build_unigram_entries(
        ngrams.get(1, []),
        bigrams,
        max_unigrams=max_unigrams,
        top_k=top_k,
    )
    side_index.update(unigram_entries)
    print(f"Added {len(unigram_entries)} unigram entries", file=sys.stderr)

    print(f"Total entries: {len(side_index)}", file=sys.stderr)
    return side_index


def _build_unigram_entries(
    unigrams: list,
    bigrams: list,
    max_unigrams: int = 3000,
    top_k: int = 20,
) -> dict[str, list[str]]:
    """
    Build unigram → follower entries from bigram data.

    For the top-N most common unigrams (by log probability), collect all
    bigrams starting with that word, sort by probability, and take the
    top-K followers. Both original-case and lowercased keys are emitted
    (when they differ) so that lookup code using `.lowercased()` always matches.

    Args:
        unigrams: List of (log_prob, [token], backoff) for order 1
        bigrams: List of (log_prob, [w1, w2], backoff) for order 2
        max_unigrams: Max number of unigrams to include
        top_k: Max followers per unigram

    Returns:
        Dict mapping "word" (and its lowercased variant) -> [follower, ...]
    """
    # Sort unigrams by log probability descending (more common first)
    skip_tokens = {"<unk>", "<s>", "</s>"}
    unigrams_sorted = sorted(
        [
            (log_prob, tokens[0])
            for log_prob, tokens, _ in unigrams
            if len(tokens) == 1 and tokens[0] not in skip_tokens
        ],
        key=lambda x: x[0],
        reverse=True,
    )

    top_unigram_words = [word for log_prob, word in unigrams_sorted[:max_unigrams]]

    # Build map: word -> [(bigram_log_prob, follower)]
    unigram_map: dict[str, list[tuple[float, str]]] = defaultdict(list)
    top_set = set(top_unigram_words)

    for log_prob, tokens, backoff in bigrams:
        if len(tokens) != 2:
            continue
        w1, w2 = tokens
        if w1 in top_set:
            unigram_map[w1].append((log_prob, w2))

    # Sort followers and build result with both original and lowercased keys
    result: dict[str, list[str]] = {}
    for word in top_unigram_words:
        followers = unigram_map.get(word, [])
        followers.sort(key=lambda x: x[0], reverse=True)
        top_followers = [f[1] for f in followers[:top_k]]
        if not top_followers:
            continue
        result[word] = top_followers
        lc = word.lower()
        if lc != word:
            # Lowercased variant gets the same followers
            result[lc] = top_followers

    return result


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
        default=20000,
        help="Maximum number of bigrams in the index (default: 20000)",
    )
    parser.add_argument(
        "--top-k",
        type=int,
        default=20,
        help="Maximum follower words per entry (default: 20)",
    )
    parser.add_argument(
        "--max-unigrams",
        type=int,
        default=3000,
        help="Maximum number of unigrams in the index (default: 3000)",
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
        max_unigrams=args.max_unigrams,
    )

    os.makedirs(os.path.dirname(args.output), exist_ok=True)
    with open(args.output, "w", encoding="utf-8") as f:
        json.dump(side_index, f, indent=2, ensure_ascii=False)

    file_size_kb = os.path.getsize(args.output) / 1024
    print(f"Wrote side index ({file_size_kb:.1f} KB) to {args.output}")

    if file_size_kb > 2000:
        print(
            f"WARNING: Side index is {file_size_kb:.1f} KB, exceeds 2 MB limit!",
            file=sys.stderr,
        )
        print(
            "  Reduce --max-bigrams, --max-unigrams, or --top-k and re-run.",
            file=sys.stderr,
        )


if __name__ == "__main__":
    main()
