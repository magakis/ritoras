// KenLM-specific apostrophe normalization: U+2019/U+2018 → U+0027.
// Mirrors TrigramProvider.normalizeForKenLM in
// keyboard/Sources/Prediction/Trigram/TrigramProvider.swift.
//
// The shipped trigram model vocabulary is ASCII-only (e.g. "don't" with the
// straight apostrophe, zero curly-apostrophe tokens), while prediction
// candidates carry the display-canonical U+2019 (see AMBIGUOUS_CONTRACTIONS
// and CONTRACTIONS). Without this normalization every contraction scores as
// KenLM <unk> (large negative), which makes the ambiguous-contraction margin
// gate provably always-negative and degrades contraction ranking in fusedPool.
//
// Direction matters: the shared ApostropheNormalizer
// (text-normalization.mjs) canonicalizes TOWARDS U+2019 (the display form).
// This goes the OPPOSITE way — towards ASCII for the KenLM lookup — and so
// lives in its own module instead of reusing that normalizer.

/** Returns the input with U+2019/U+2018 replaced by ASCII U+0027. Idempotent. */
export function normalizeForKenLM(s) {
  let out = '';
  for (const ch of s) {
    out += (ch === '\u{2019}' || ch === '\u{2018}') ? '\u{0027}' : ch;
  }
  return out;
}
