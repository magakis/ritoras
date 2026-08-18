// Pure-logic JS port of keyboard/Sources/Prediction/SymSpell/QwertyGeometry.swift.
// Kept in sync per AGENTS.md -> Test policy.

// ---------------------------------------------------------------------------
// Key Centers
// ---------------------------------------------------------------------------

/**
 * Key-center positions measured in key-width units on a standard
 * iOS QWERTY layout. Mirrors `QwertyGeometry.keyCenters` in Swift.
 *
 * Row 0: q w e r t y u i o p  (y=0, x=0..9)
 * Row 1: a s d f g h j k l  (y=1, x=0.25..8.25)
 * Row 2: z x c v b n m  (y=2, x=0.75..6.75)
 * Apostrophe at (9.25, 1) — near L
 *
 * @type {Map<string, {x: number, y: number}>}
 */
export const keyCenters = new Map();

// Row 0: q w e r t y u i o p (y=0)
const row0 = 'qwertyuiop';
for (let i = 0; i < row0.length; i++) {
  keyCenters.set(row0[i], { x: i, y: 0 });
}

// Row 1: a s d f g h j k l (y=1, offset 0.25)
const row1 = 'asdfghjkl';
for (let i = 0; i < row1.length; i++) {
  keyCenters.set(row1[i], { x: i + 0.25, y: 1 });
}

// Row 2: z x c v b n m (y=2, offset 0.75)
const row2 = 'zxcvbnm';
for (let i = 0; i < row2.length; i++) {
  keyCenters.set(row2[i], { x: i + 0.75, y: 2 });
}

// Apostrophe — near L
keyCenters.set("'", { x: 9.25, y: 1 });

/**
 * Greek key-center positions on the Apple Greek QWERTY layout. The top
 * nine-key row uses the same span as the English middle row.
 *
 * Row 0: ε ρ τ υ θ ι ο π '  (y=0, x=0.25..8.25)
 * Row 1: α σ δ φ γ η ξ κ λ     (y=1, x=0.25..8.25)
 * Row 2: ζ χ ψ ω β ν μ         (y=2, x=0.75..6.75)
 *
 * @type {Map<string, {x: number, y: number}>}
 */
export const greekKeyCenters = new Map();

// Row 0: ε ρ τ υ θ ι ο π ' (y=0, offset 0.25)
const greekRow0 = "ερτυθιοπ'";
for (let i = 0; i < greekRow0.length; i++) {
  greekKeyCenters.set(greekRow0[i], { x: i + 0.25, y: 0 });
}

// Row 1: α σ δ φ γ η ξ κ λ (y=1, offset 0.25)
const greekRow1 = 'ασδφγηξκλ';
for (let i = 0; i < greekRow1.length; i++) {
  greekKeyCenters.set(greekRow1[i], { x: i + 0.25, y: 1 });
}
greekKeyCenters.set('ς', greekKeyCenters.get('σ'));

// Row 2: ζ χ ψ ω β ν μ (y=2, offset 0.75)
const greekRow2 = 'ζχψωβνμ';
for (let i = 0; i < greekRow2.length; i++) {
  greekKeyCenters.set(greekRow2[i], { x: i + 0.75, y: 2 });
}

// ---------------------------------------------------------------------------
// Basic Distance
// ---------------------------------------------------------------------------

/**
 * Compute the Euclidean distance between two characters' key centers.
 * Returns 1.0 for unknown characters (neutral). Consults the English grid
 * first, then the Greek grid — mirrors the Swift `keyCenters[a] ?? greekKeyCenters[a]`.
 * Mirrors `QwertyGeometry.distance(_:_:)`.
 *
 * @param {string} a
 * @param {string} b
 * @returns {number}
 */
export function distance(a, b) {
  const posA = keyCenters.get(a) ?? greekKeyCenters.get(a);
  const posB = keyCenters.get(b) ?? greekKeyCenters.get(b);
  if (!posA || !posB) return 1.0;
  const dx = posA.x - posB.x;
  const dy = posA.y - posB.y;
  return Math.sqrt(dx * dx + dy * dy);
}

/**
 * Adjacent-key substitution cost.
 *
 * `distance / 3.0` clamped to `[0.1, 1.0]`. Same-key cost is 0.
 * Returns 1.0 for unknown characters.
 * Mirrors `QwertyGeometry.adjacentKeyCost(_:_:)`.
 *
 * @param {string} a
 * @param {string} b
 * @returns {number}
 */
export function adjacentKeyCost(a, b) {
  if (a === b) return 0;
  const raw = distance(a, b) / 3.0;
  return Math.min(Math.max(raw, 0.1), 1.0);
}

// ---------------------------------------------------------------------------
// Weighted Edit Distance
// ---------------------------------------------------------------------------

/**
 * Compute a QWERTY-geometry-aware weighted edit distance between
 * `typed` and `candidate`.
 *
 * Mirrors `QwertyGeometry.weightedEditDistance(typed:candidate:symSpellDistance:doublingDiscount:transpositionDiscount:)`.
 *
 * @param {string} typed - The word the user typed (will be lowercased).
 * @param {string} candidate - The candidate from SymSpell.
 * @param {number} symSpellDistance - The raw Levenshtein distance from SymSpell.
 * @param {number} [doublingDiscount=0.5] - Discount applied for doubled-letter edits.
 * @param {number} [transpositionDiscount=0.7] - Discount applied for adjacent transpositions.
 * @returns {number} Weighted edit distance in [0, ∞).
 */
export function weightedEditDistance(typed, candidate, symSpellDistance, doublingDiscount = 0.5, transpositionDiscount = 0.7) {
  const chars1 = [...typed.toLowerCase()];
  const chars2 = [...candidate.toLowerCase()];

  let result;
  if (chars1.length === chars2.length) {
    result = _weightedEditDistanceEqual(chars1, chars2, transpositionDiscount);
  } else if (chars1.length === chars2.length + 1) {
    result = _weightedEditDistanceInsertion(chars1, chars2, doublingDiscount);
  } else if (chars1.length + 1 === chars2.length) {
    result = _weightedEditDistanceInsertion(chars2, chars1, doublingDiscount);
  } else if (Math.abs(chars1.length - chars2.length) === 2) {
    result = _weightedEditDistanceDiff2(chars1, chars2, symSpellDistance, doublingDiscount, transpositionDiscount);
  } else {
    result = symSpellDistance;
  }

  return result;
}

// ---------------------------------------------------------------------------
// Score
// ---------------------------------------------------------------------------

/**
 * Convert a weighted edit distance to a [0, 1] probability.
 *
 * `score = exp(-beta * weightedEditDistance(...))`, clamped to [0, 1].
 * When `symSpellDistance == 0`, returns 1.0 (exact match).
 * Mirrors `QwertyGeometry.score(typed:candidate:symSpellDistance:beta:doublingDiscount:transpositionDiscount:)`.
 *
 * @param {string} typed - The word the user typed (will be lowercased).
 * @param {string} candidate - The candidate from SymSpell.
 * @param {number} symSpellDistance - The raw Levenshtein distance from SymSpell.
 * @param {number} beta - The beta parameter for exponential falloff.
 * @param {number} [doublingDiscount=0.5] - Discount applied for doubled-letter edits.
 * @param {number} [transpositionDiscount=0.7] - Discount applied for adjacent transpositions.
 * @returns {number} Score in [0, 1].
 */
export function score(typed, candidate, symSpellDistance, beta, doublingDiscount = 0.5, transpositionDiscount = 0.7) {
  if (symSpellDistance === 0) return 1.0;
  const weighted = weightedEditDistance(typed, candidate, symSpellDistance, doublingDiscount, transpositionDiscount);
  return Math.min(Math.max(Math.exp(-beta * weighted), 0.0), 1.0);
}

// ---------------------------------------------------------------------------
// Private Helpers
// ---------------------------------------------------------------------------

/**
 * Equal-length case: pure substitution with possible adjacent transposition.
 * Mirrors `_weightedEditDistanceEqual(_:_:transpositionDiscount:)`.
 *
 * @param {string[]} chars1
 * @param {string[]} chars2
 * @param {number} transpositionDiscount
 * @returns {number}
 */
function _weightedEditDistanceEqual(chars1, chars2, transpositionDiscount) {
  let totalCost = 0;
  /** @type {number[]} */
  const diffPositions = [];

  for (let i = 0; i < chars1.length; i++) {
    if (chars1[i] !== chars2[i]) {
      diffPositions.push(i);
      totalCost += adjacentKeyCost(chars1[i], chars2[i]);
    }
  }

  // Detect single adjacent transposition (e.g. teh → the).
  if (diffPositions.length === 2 &&
      diffPositions[0] + 1 === diffPositions[1] &&
      chars1[diffPositions[0]] === chars2[diffPositions[1]] &&
      chars1[diffPositions[1]] === chars2[diffPositions[0]]) {
    totalCost *= transpositionDiscount;
  }

  return totalCost;
}

/**
 * Length-diff-1 case: one insertion or deletion.
 * `longer` has one more character than `shorter`.
 * Mirrors `_weightedEditDistanceInsertion(longer:shorter:doublingDiscount:)`.
 *
 * @param {string[]} longer
 * @param {string[]} shorter
 * @param {number} doublingDiscount
 * @returns {number}
 */
function _weightedEditDistanceInsertion(longer, shorter, doublingDiscount) {
  let bestCost = Infinity;
  let isDoubling = false;

  for (let delPos = 0; delPos < longer.length; delPos++) {
    // Build aligned version of longer without char at delPos.
    const aligned = [];
    for (let i = 0; i < longer.length; i++) {
      if (i !== delPos) {
        aligned.push(longer[i]);
      }
    }

    // Compute substitution cost against shorter.
    let cost = 0;
    for (let i = 0; i < shorter.length; i++) {
      if (shorter[i] !== aligned[i]) {
        cost += adjacentKeyCost(shorter[i], aligned[i]);
      }
    }

    // Check doubling: deleted/inserted char identical to neighbor.
    const deletedChar = longer[delPos];
    const hasDoubling =
      (delPos > 0 && longer[delPos - 1] === deletedChar) ||
      (delPos < longer.length - 1 && longer[delPos + 1] === deletedChar);

    // Prefer best cost; on tie prefer the doubling alignment.
    if (cost < bestCost || (cost === bestCost && hasDoubling && !isDoubling)) {
      bestCost = cost;
      isDoubling = hasDoubling;
    }
  }

  if (isDoubling) {
    bestCost *= doublingDiscount;
  }

  return bestCost;
}

/**
 * Length-diff-2 case: try all deletion pairs and return the
 * lowest-cost geometry-aware alignment.
 * Mirrors `_weightedEditDistanceDiff2(_:_:symSpellDistance:doublingDiscount:transpositionDiscount:)`.
 *
 * @param {string[]} chars1
 * @param {string[]} chars2
 * @param {number} symSpellDistance
 * @param {number} doublingDiscount
 * @param {number} transpositionDiscount
 * @returns {number}
 */
function _weightedEditDistanceDiff2(chars1, chars2, symSpellDistance, doublingDiscount, transpositionDiscount) {
  const longer = chars1.length > chars2.length ? chars1 : chars2;
  const shorter = chars1.length > chars2.length ? chars2 : chars1;

  let bestCost = Infinity;

  for (let i = 0; i < longer.length; i++) {
    for (let j = i + 1; j < longer.length; j++) {
      const aligned = [];
      for (let k = 0; k < longer.length; k++) {
        if (k !== i && k !== j) {
          aligned.push(longer[k]);
        }
      }

      let cost = 0;
      for (let k = 0; k < shorter.length; k++) {
        if (shorter[k] !== aligned[k]) {
          cost += adjacentKeyCost(shorter[k], aligned[k]);
        }
      }

      if (cost < bestCost) {
        bestCost = cost;
      }
    }
  }

  return bestCost;
}
