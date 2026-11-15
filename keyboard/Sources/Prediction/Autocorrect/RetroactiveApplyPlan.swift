import Foundation

/// Pure offset arithmetic for replacing a typed word with a correction at a
/// cursor-relative location. No UIKit import.
///
/// The plan is expressed as `textDocumentProxy` operations applied in order:
///   1. `adjustTextPosition(byCharacterOffset: backMove)` — move the cursor
///      back to the end of the typed word.
///   2. `deleteBackward()` × `deleteCount` — remove the typed word.
///   3. `insertText(insert)` — place the correction.
///   4. `adjustTextPosition(byCharacterOffset: forwardMove)` — return the
///      cursor to its original relative spot.
enum RetroactiveApplyPlan {

    /// A cursor-relative replacement plan.
    struct Plan {
        /// Negative offset: move the cursor back to the end of the typed word.
        let backMove: Int
        /// Number of characters to delete (always `typedWord.count`).
        let deleteCount: Int
        /// The correction text to insert.
        let insert: String
        /// Positive offset: move the cursor forward again after inserting.
        let forwardMove: Int
        /// Exact body bytes that must still occupy the deletion range.
        let expectedText: String
        /// Context captured with the word, used to re-anchor against live text.
        let contextAnchor: String
    }

    /// Builds a plan for replacing `typedWord` with `correction` when the typed
    /// word's body ends `offsetFromCursorEnd` characters before the cursor.
    ///
    /// INVARIANT: `forwardMove == offsetFromCursorEnd` REGARDLESS of any length
    /// difference between `typedWord` and `correction`. The delete + insert
    /// happens entirely between the cursor's back-move target and the cursor's
    /// original position, so the cursor's RELATIVE distance from the corrected
    /// word's end is preserved — the cursor ends up at the same relative spot
    /// whether the correction is shorter, longer, or the same length as the
    /// typed word. (In absolute terms the cursor shifts by the length delta,
    /// which is exactly what keeps it aligned with the corrected word.)
    static func plan(
        typedWord: String,
        correction: String,
        offsetFromCursorEnd: Int,
        contextAnchor: String
    ) -> Plan {
        Plan(
            backMove: -offsetFromCursorEnd,
            deleteCount: typedWord.count,
            insert: correction,
            forwardMove: offsetFromCursorEnd,
            expectedText: typedWord,
            contextAnchor: contextAnchor
        )
    }

    /// Resolves the candidate against live text and rejects any byte mismatch
    /// before the caller performs the first cursor or document mutation.
    static func revalidated(_ plan: Plan, in liveContext: String) -> Plan? {
        guard let anchorRange = uniqueByteRange(of: plan.contextAnchor, in: liveContext),
              let anchoredWord = RecentWordsExtractor
                .extract(from: plan.contextAnchor + " ", maxCount: 1)
                .first,
              anchoredWord.wordBody.utf8.elementsEqual(plan.expectedText.utf8) else {
            return nil
        }

        let textAfterAnchor = liveContext[anchorRange.upperBound..<liveContext.endIndex]
        let anchorOffset = anchoredWord.offsetFromCursorEnd - 1
        guard anchorOffset >= 0 else { return nil }
        let offsetFromCursorEnd = textAfterAnchor.utf16.count + anchorOffset
        guard hasByteExactText(
            plan.expectedText,
            endingAtOffsetFromCursorEnd: offsetFromCursorEnd,
            in: liveContext
        ) else {
            return nil
        }

        return Plan(
            backMove: -offsetFromCursorEnd,
            deleteCount: plan.expectedText.count,
            insert: plan.insert,
            forwardMove: offsetFromCursorEnd,
            expectedText: plan.expectedText,
            contextAnchor: plan.contextAnchor
        )
    }

    private static func uniqueByteRange(of needle: String, in haystack: String) -> Range<String.Index>? {
        let haystackBytes = Array(haystack.utf8)
        let needleBytes = Array(needle.utf8)
        guard !needleBytes.isEmpty, haystackBytes.count >= needleBytes.count else { return nil }

        var match: Range<String.Index>?
        for byteOffset in 0...(haystackBytes.count - needleBytes.count) {
            let byteRange = byteOffset..<(byteOffset + needleBytes.count)
            guard haystackBytes[byteRange].elementsEqual(needleBytes) else { continue }

            let utf8Start = haystack.utf8.index(haystack.utf8.startIndex, offsetBy: byteOffset)
            let utf8End = haystack.utf8.index(utf8Start, offsetBy: needleBytes.count)
            guard let start = String.Index(utf8Start, within: haystack),
                  let end = String.Index(utf8End, within: haystack) else {
                return nil
            }
            guard match == nil else { return nil }
            match = start..<end
        }
        return match
    }

    private static func hasByteExactText(
        _ expectedText: String,
        endingAtOffsetFromCursorEnd offsetFromCursorEnd: Int,
        in context: String
    ) -> Bool {
        let contextUTF16 = context.utf16
        let endOffset = contextUTF16.count - offsetFromCursorEnd
        let startOffset = endOffset - expectedText.utf16.count
        guard offsetFromCursorEnd >= 0,
              startOffset >= 0,
              let start = String.Index(
                contextUTF16.index(contextUTF16.startIndex, offsetBy: startOffset),
                within: context
              ),
              let end = String.Index(
                contextUTF16.index(contextUTF16.startIndex, offsetBy: endOffset),
                within: context
              ) else {
            return false
        }
        return context[start..<end].utf8.elementsEqual(expectedText.utf8)
    }
}
