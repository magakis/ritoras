import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import {
  applyVerified,
  matchesApplyTarget,
  plan,
  revalidatedPlan,
} from '../lib/retroactive-apply-plan.mjs';

describe('RetroactiveApplyPlan.plan (JS port)', () => {

  // The core correctness property, asserted for EVERY case below:
  //   backMove == -offsetFromCursorEnd
  //   deleteCount == typedWord.length
  //   insert == correction
  //   forwardMove == offsetFromCursorEnd
  const cases = [
    // same-length corrections
    { typedWord: 'teh', correction: 'the', offset: 3 },
    { typedWord: 'recieve', correction: 'receive', offset: 5 },
    // correction longer than typed
    { typedWord: 'dont', correction: "don't", offset: 1 },
    { typedWord: 'wit', correction: 'with', offset: 2 },
    // correction much shorter than typed
    { typedWord: 'misspeling', correction: 'mice', offset: 4 },
    // canonical-apostrophe correction (U+2019)
    { typedWord: 'dont', correction: "don\u{2019}t", offset: 2 },
    // offset 0 — cursor directly at the word's body end
    { typedWord: 'teh', correction: 'the', offset: 0 },
    // larger offsets (cursor further after the word)
    { typedWord: 'wich', correction: 'which', offset: 9 },
  ];

  it('for every case: backMove == -offset, deleteCount == typedWord.length, insert == correction, forwardMove == offset', () => {
    for (const c of cases) {
      const p = plan(c.typedWord, c.correction, c.offset);
      assert.strictEqual(p.backMove, -c.offset, `backMove for "${c.typedWord}"`);
      assert.strictEqual(p.deleteCount, c.typedWord.length, `deleteCount for "${c.typedWord}"`);
      assert.strictEqual(p.insert, c.correction, `insert for "${c.typedWord}"`);
      assert.strictEqual(p.forwardMove, c.offset, `forwardMove for "${c.typedWord}"`);
    }
  });

  describe('individual anchors', () => {
    it('teh -> the (same length, offset 3)', () => {
      assert.deepStrictEqual(plan('teh', 'the', 3), {
        backMove: -3,
        deleteCount: 3,
        insert: 'the',
        forwardMove: 3,
        expectedText: 'teh',
        contextAnchor: '',
      });
    });

    it('recieve -> receive (same length, offset 5)', () => {
      assert.deepStrictEqual(plan('recieve', 'receive', 5), {
        backMove: -5,
        deleteCount: 7,
        insert: 'receive',
        forwardMove: 5,
        expectedText: 'recieve',
        contextAnchor: '',
      });
    });

    it('dont -> don\'t (longer correction, offset 1)', () => {
      assert.deepStrictEqual(plan('dont', "don't", 1), {
        backMove: -1,
        deleteCount: 4,
        insert: "don't",
        forwardMove: 1,
        expectedText: 'dont',
        contextAnchor: '',
      });
    });

    it('wit -> with (longer correction, offset 2)', () => {
      assert.deepStrictEqual(plan('wit', 'with', 2), {
        backMove: -2,
        deleteCount: 3,
        insert: 'with',
        forwardMove: 2,
        expectedText: 'wit',
        contextAnchor: '',
      });
    });

    it('misspeling -> mice (much shorter correction, offset 4)', () => {
      assert.deepStrictEqual(plan('misspeling', 'mice', 4), {
        backMove: -4,
        deleteCount: 10,
        insert: 'mice',
        forwardMove: 4,
        expectedText: 'misspeling',
        contextAnchor: '',
      });
    });
  });

  describe('live apply verification', () => {
    it('requires an exact deletion window and its captured preceding anchor', () => {
      const p = plan('teh', 'the', 1, 'hello teh ');

      assert.strictEqual(matchesApplyTarget(p, 'hello teh'), true);
      assert.strictEqual(matchesApplyTarget(p, 'hello the'), false);
      assert.strictEqual(matchesApplyTarget(p, 'other teh'), false);
      assert.strictEqual(matchesApplyTarget(plan('teh', 'the', 0, 'teh '), 'teh'), false);
    });

    it('rejects the wrong their instance even when its deletion window matches', () => {
      const p = plan('their', 'there', 1, 'one their ');
      const secondInstance = 'one their then their';
      const secondCaretContext = secondInstance;

      assert.strictEqual(matchesApplyTarget(p, secondCaretContext), false);
      assert.deepStrictEqual(applyVerified(
        secondInstance,
        secondInstance.length,
        p,
        { cursorAdjustmentSucceeds: false }
      ), {
        doc: secondInstance,
        cursor: secondInstance.length,
        applied: false,
        pendingCorrection: null,
      });
    });

    it('rejects unreadable and empty context at the caret', () => {
      const p = plan('teh', 'the', 1, 'hello teh ');

      assert.strictEqual(matchesApplyTarget(p, null), false);
      assert.strictEqual(matchesApplyTarget(p, ''), false);
      assert.deepStrictEqual(applyVerified('hello teh ', 10, p, {
        contextReadable: false,
      }), {
        doc: 'hello teh ',
        cursor: 9,
        applied: false,
        pendingCorrection: null,
      });
    });

    it('re-resolves a shifted word location from its live context anchor', () => {
      const p = plan('teh', 'the', 1, 'hello teh ');
      const liveContext = 'hello teh extra ';
      const resolved = revalidatedPlan(p, liveContext);

      assert.ok(resolved);
      assert.strictEqual(resolved.backMove, -7);
      assert.strictEqual(resolved.deleteCount, 3);
      assert.strictEqual(resolved.forwardMove, 7);
      assert.deepStrictEqual(applyVerified(liveContext, liveContext.length, p), {
        doc: 'hello the extra ',
        cursor: 'hello the extra '.length,
        applied: true,
        pendingCorrection: null,
      });
    });

    it('aborts without mutation when the live text no longer matches the recorded bytes', () => {
      const p = plan('teh', 'the', 1, 'hello teh ');
      const doc = 'hello the extra ';
      const result = applyVerified(doc, doc.length, p);

      assert.deepStrictEqual(result, {
        doc,
        cursor: doc.length,
        applied: false,
        pendingCorrection: null,
      });
    });

    it('rejects canonically equivalent but byte-different word bodies', () => {
      const p = plan('café', 'cafe', 1, 'café ');
      const doc = 'cafe\u0301 ';
      assert.deepStrictEqual(applyVerified(doc, doc.length, p), {
        doc,
        cursor: doc.length,
        applied: false,
        pendingCorrection: null,
      });
    });
  });

  describe('cursor mechanics — relative distance preserved (the INVARIANT)', () => {
    // Simulates the textDocumentProxy operation sequence on a document string
    // and asserts the cursor ends at the same RELATIVE distance from the
    // corrected word's end, regardless of the length delta.

    function applyPlan(doc, cursor, p) {
      // 1. backMove
      cursor += p.backMove;
      // 2. delete deleteCount chars before the cursor
      doc = doc.slice(0, cursor - p.deleteCount) + doc.slice(cursor);
      cursor -= p.deleteCount;
      // 3. insert
      doc = doc.slice(0, cursor) + p.insert + doc.slice(cursor);
      cursor += p.insert.length;
      // 4. forwardMove
      cursor += p.forwardMove;
      return { doc, cursor };
    }

    it('dont -> don\u2019t in "dont " keeps cursor 1 char after the corrected word', () => {
      const p = plan('dont', "don\u{2019}t", 1);
      const { doc, cursor } = applyPlan('dont ', 'dont '.length, p);
      assert.strictEqual(doc, "don\u{2019}t ");
      assert.strictEqual(cursor, 6);
      // Corrected word "don't" ends at 5; cursor at 6 → relative distance 1 == offset.
      assert.strictEqual(cursor - p.insert.length, 1);
    });

    it('misspeling -> mice in "misspeling " keeps cursor 1 char after the corrected word', () => {
      const p = plan('misspeling', 'mice', 1);
      const { doc, cursor } = applyPlan('misspeling ', 'misspeling '.length, p);
      assert.strictEqual(doc, 'mice ');
      assert.strictEqual(cursor, 5);
      // Corrected word "mice" ends at 4; cursor at 5 → relative distance 1 == offset.
      assert.strictEqual(cursor - p.insert.length, 1);
    });
  });
});
