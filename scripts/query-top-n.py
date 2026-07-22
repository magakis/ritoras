#!/usr/bin/env python3
"""
Query a KenLM ARPA model for top-N next-word continuations.

Given a context (one or more words), this script computes the conditional
probability P(word | context) for every word in the vocabulary and returns
the top-N candidates ranked by probability.

The computation follows standard Kneser-Ney backoff:
  1. Try trigram match:        P(w3 | w1 w2) = trigram_prob(w1 w2 w3)
  2. Fall back to bigram:      P(w3 | w1 w2) = bow(w1 w2) * P(w3 | w2)
     where P(w3 | w2) = bigram_prob(w2 w3) if exists,
                     else bow(w2) * unigram_prob(w3)

Usage:
    python3 scripts/query-top-n.py build/trigram.arpa \\
        --context "i am looking very" --top-n 10

    python3 scripts/query-top-n.py build/trigram.arpa \\
        --context "i am looking very" --candidates good nice beautiful

    python3 scripts/query-top-n.py build/trigram.arpa \\
        --sentences "i am looking good" "i am looking xyzzy"

License:
    Apache 2.0
"""

import argparse
import math
import re
import sys
from collections import defaultdict
from typing import Optional

ARPA_NUM_RE = re.compile(r"^-?[\d.]+(?:e[+-]?\d+)?$")


def load_arpa(arpa_path: str) -> tuple[dict, dict, dict, set]:
    """
    Load ARPA file into lookup-friendly structures.

    Returns:
        unigrams: dict word -> (log10_prob, log10_backoff)
        bigrams:  dict (w1, w2) -> (log10_prob, log10_backoff)
        trigrams: dict (w1, w2, w3) -> log10_prob
        vocab:    set of all words (including <s>, </s>, <unk>)
    """
    unigrams: dict[str, tuple[float, float]] = {}
    bigrams: dict[tuple[str, str], tuple[float, float]] = {}
    trigrams: dict[tuple[str, str, str], float] = {}
    vocab: set[str] = set()

    current_order = 0
    in_section = False

    with open(arpa_path, "r", encoding="utf-8") as f:
        for line in f:
            line = line.rstrip("\n")
            if not line:
                continue

            if line.startswith("\\data\\"):
                in_section = False
                continue

            if line.startswith("\\"):
                m = re.match(r"^\\(\d+)-grams:", line)
                if m:
                    current_order = int(m.group(1))
                    in_section = True
                else:
                    in_section = False
                continue

            if not in_section:
                continue

            parts = line.split("\t")
            if len(parts) < 2:
                continue

            log_prob_str = parts[0]
            if not ARPA_NUM_RE.match(log_prob_str):
                continue

            log_prob = float(log_prob_str)
            tokens_str = parts[1]
            tokens = tokens_str.split()

            backoff = 0.0
            if len(parts) >= 3 and parts[2]:
                if ARPA_NUM_RE.match(parts[2]):
                    backoff = float(parts[2])

            if current_order == 1 and len(tokens) == 1:
                w = tokens[0]
                unigrams[w] = (log_prob, backoff)
                vocab.add(w)
            elif current_order == 2 and len(tokens) == 2:
                w1, w2 = tokens
                bigrams[(w1, w2)] = (log_prob, backoff)
                vocab.add(w1)
                vocab.add(w2)
            elif current_order == 3 and len(tokens) == 3:
                w1, w2, w3 = tokens
                trigrams[(w1, w2, w3)] = log_prob
                vocab.add(w1)
                vocab.add(w2)
                vocab.add(w3)

    return unigrams, bigrams, trigrams, vocab


def log10_prob_word_given_context(
    word: str,
    w1: Optional[str],
    w2: Optional[str],
    unigrams: dict,
    bigrams: dict,
    trigrams: dict,
) -> float:
    """
    Compute log10 P(word | context) using Kneser-Ney backoff.

    context is (w1, w2) where w1 is the word 2 positions back (may be None)
    and w2 is the immediate preceding word (may be None).
    """
    # --- Trigram case: P(word | w1, w2) ---
    if w1 is not None and w2 is not None:
        key = (w1, w2, word)
        if key in trigrams:
            return trigrams[key]

        # Backoff: bow(w1, w2) * P(word | w2)
        bow_bi = bigrams.get((w1, w2), (0.0, 0.0))[1]
        p_given_w2 = _bigram_prob(word, w2, unigrams, bigrams)
        return bow_bi + p_given_w2

    # --- Bigram case: P(word | w2) ---
    if w2 is not None:
        return _bigram_prob(word, w2, unigrams, bigrams)

    # --- Unigram case: P(word) ---
    return _unigram_prob(word, unigrams)


def _bigram_prob(
    word: str,
    prev: str,
    unigrams: dict,
    bigrams: dict,
) -> float:
    """Compute log10 P(word | prev) using backoff."""
    key = (prev, word)
    if key in bigrams:
        return bigrams[key][0]

    # Backoff: bow(prev) * P(word)
    bow = unigrams.get(prev, (0.0, 0.0))[1]
    return bow + _unigram_prob(word, unigrams)


def _unigram_prob(
    word: str,
    unigrams: dict,
) -> float:
    """Get log10 P(word). If OOV, use <unk> probability."""
    if word in unigrams:
        return unigrams[word][0]
    # OOV fallback
    unk = unigrams.get("<unk>")
    if unk is not None:
        return unk[0]
    return -100.0  # extremely unlikely


def get_top_n(
    context_words: list[str],
    top_n: int,
    unigrams: dict,
    bigrams: dict,
    trigrams: dict,
    vocab: set[str],
    exclude_special: bool = True,
) -> list[tuple[str, float]]:
    """
    Get top-N next-word continuations for a context.

    context_words: list of words forming the context (e.g., ["i", "am", "looking", "very"])
    top_n: number of candidates to return
    exclude_special: if True, exclude <s>, </s>, <unk> from results
    """
    # Determine w1 and w2 for trigram lookup
    w1 = context_words[-2] if len(context_words) >= 2 else None
    w2 = context_words[-1] if len(context_words) >= 1 else None

    # Trim context to history length for display
    display_context = " ".join(context_words)

    # Score every word in vocabulary
    scored: list[tuple[str, float]] = []
    for word in vocab:
        if exclude_special and word in ("<s>", "</s>", "<unk>"):
            continue
        logp = log10_prob_word_given_context(word, w1, w2, unigrams, bigrams, trigrams)
        scored.append((word, logp))

    # Sort by probability descending (highest log10 = highest prob)
    scored.sort(key=lambda x: x[1], reverse=True)

    return scored[:top_n]


def score_sentence(
    sentence: str,
    unigrams: dict,
    bigrams: dict,
    trigrams: dict,
) -> float:
    """
    Compute log10 probability of a full sentence using the 3-gram model.
    The sentence is wrapped in <s> and </s>.
    """
    tokens = sentence.strip().lower().split()
    if not tokens:
        return 0.0

    # Add sentence markers
    augmented = ["<s>", "<s>"] + tokens + ["</s>"]

    total_logp = 0.0
    for i in range(2, len(augmented)):
        w1 = augmented[i - 2]
        w2 = augmented[i - 1]
        word = augmented[i]
        logp = log10_prob_word_given_context(word, w1, w2, unigrams, bigrams, trigrams)
        total_logp += logp

    return total_logp


def format_results(context: str, results: list[tuple[str, float]]) -> None:
    """Print formatted results table."""
    print(f"Context: \"{context}\"")
    print(f"{'Rank':<6} {'Word':<20} {'Log10 P(word|context)':<25} {'P(word|context)'}")
    print("-" * 75)
    for rank, (word, logp) in enumerate(results, 1):
        prob = 10 ** logp if logp > -100 else 0
        print(f"{rank:<6} {word:<20} {logp:<25.4f} {prob:.6f}")
    print()


def main():
    parser = argparse.ArgumentParser(
        description="Query KenLM ARPA model for top-N next-word continuations"
    )
    parser.add_argument("arpa", help="Path to trigram.arpa file")
    parser.add_argument("--context", help="Context string (e.g. 'i am looking very')")
    parser.add_argument("--top-n", type=int, default=10, help="Number of candidates (default: 10)")
    parser.add_argument("--candidates", nargs="*", help="Specific candidate words to score")
    parser.add_argument("--sentences", nargs="*", help="Score full sentences and compare")
    parser.add_argument("--show-vocab", nargs="*", help="Show unigram probability for specific words")
    args = parser.parse_args()

    print(f"Loading ARPA: {args.arpa}...", file=sys.stderr)
    unigrams, bigrams, trigrams, vocab = load_arpa(args.arpa)
    print(f"  Unigrams: {len(unigrams)}", file=sys.stderr)
    print(f"  Bigrams:  {len(bigrams)}", file=sys.stderr)
    print(f"  Trigrams: {len(trigrams)}", file=sys.stderr)
    print(f"  Vocab:    {len(vocab)} words", file=sys.stderr)
    print()

    # --- Show vocab probabilities ---
    if args.show_vocab:
        print("=== VOCABULARY PROBABILITIES ===")
        for word in args.show_vocab:
            if word in unigrams:
                logp, bow = unigrams[word]
                prob = 10 ** logp
                print(f"  {word:<20} log10 P = {logp:.4f}  P = {prob:.8f}  bow = {bow:.4f}")
            else:
                # Check if in vocab but not as unigram (shouldn't happen)
                in_vocab = word in vocab
                print(f"  {word:<20} NOT in unigrams (in_vocab={in_vocab})")
        print()

    # --- Top-N continuations ---
    if args.context:
        context_words = args.context.strip().lower().split()
        print(f"=== TOP-{args.top_n} CONTINUATIONS ===")
        results = get_top_n(context_words, args.top_n, unigrams, bigrams, trigrams, vocab)
        format_results(args.context, results)

        # Also show specific candidates if requested
        if args.candidates:
            w1 = context_words[-2] if len(context_words) >= 2 else None
            w2 = context_words[-1] if len(context_words) >= 1 else None
            print(f"=== SPECIFIC CANDIDATES ===")
            print(f"Context: \"{args.context}\"")
            for word in args.candidates:
                logp = log10_prob_word_given_context(word, w1, w2, unigrams, bigrams, trigrams)
                prob = 10 ** logp if logp > -100 else 0
                print(f"  {word:<20} log10 = {logp:.4f}  P = {prob:.6f}")
            print()

    # --- Sentence scoring ---
    if args.sentences:
        print("=== SENTENCE SCORING ===")
        scored = []
        for sent in args.sentences:
            logp = score_sentence(sent, unigrams, bigrams, trigrams)
            # Perplexity = 2^(-avg_logp) if using log2, but we use log10
            # Convert: log2 = log10 / log10(2)
            num_tokens = len(sent.strip().lower().split())
            log2_total = logp / math.log10(2)
            avg_log2 = log2_total / max(num_tokens, 1)
            ppl = 2 ** (-avg_log2) if avg_log2 != 0 else float('inf')
            scored.append((sent, logp, ppl))

        scored.sort(key=lambda x: x[1], reverse=True)
        print(f"{'Sentence':<45} {'Log10 P(sent)':<20} {'Perplexity'}")
        print("-" * 75)
        for sent, logp, ppl in scored:
            print(f"{sent:<45} {logp:<20.4f} {ppl:.2f}")
        print()

    # --- Diagnostics ---
    print("=== DIAGNOSTICS ===")
    total_uni = len(unigrams)
    total_bi = len(bigrams)
    total_tri = len(trigrams)
    # Count <s> bigrams
    s_bigrams = sum(1 for (w1, w2) in bigrams if w1 == "<s>")
    print(f"  Bigrams with <s>: {s_bigrams}")
    print(f"  Bigrams without <s>: {total_bi - s_bigrams}")
    print(f"  Ratio tri/bi: {total_tri / max(total_bi, 1):.2f}")


if __name__ == "__main__":
    main()
