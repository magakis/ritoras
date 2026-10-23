import Foundation

struct ChunkFinalSegment {
    let chunkId: UInt32
    let chunkLocalText: String
    let startMs: Double
    let endMs: Double
}

enum ChunkFinalMerger {
    static let maxGapMs: Double = 2_500
    private static let ruleBMinGapExclusiveMs: Double = 2_500
    private static let ruleBMaxGapMs: Double = 10_000

    private static let continuationWords: Set<String> = [
        "for", "and", "but", "or", "nor", "so", "yet", "which", "that",
        "because", "with", "also", "to", "from", "when", "while", "since",
        "although", "however", "plus"
    ]

    // Keep Rule B aligned with ZERO_RISK_MERGER_CONFIG in
    // scripts/prediction-sim/lib/chunk-final-merge.mjs:7–23, including exact classes and bounds.
    private static let ruleBAuxiliaryWords: Set<String> = [
        "is", "are", "was", "were", "be", "been", "being", "am", "will", "would",
        "have", "has", "had", "do", "does", "did", "can", "could",
        "should", "must", "may", "might"
    ]
    private static let ruleBHangingClauseAdverbs: Set<String> = [
        "essentially", "basically", "rather", "actually"
    ]
    private static let ruleBGerundSuffix = "ing"

    static func merge(_ finalText: String, segments: [ChunkFinalSegment], maxGapMs: Double = maxGapMs) -> String {
        let nonempty = segments.filter { !$0.chunkLocalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !nonempty.isEmpty else { return finalText }

        var boundaries: [(range: Range<String.Index>, segment: ChunkFinalSegment)] = []
        var searchStart = finalText.startIndex
        for segment in nonempty {
            guard let range = locate(segment.chunkLocalText, in: finalText, from: searchStart) else { return finalText }
            boundaries.append((range, segment))
            searchStart = range.upperBound
        }

        var edits: [(range: Range<String.Index>, replacement: String)] = []
        for index in boundaries.indices.dropLast() {
            let left = boundaries[index]
            let right = boundaries[index + 1]
            let gap = right.segment.startMs - left.segment.endMs
            let leftText = left.segment.chunkLocalText.trimmingCharacters(in: .whitespacesAndNewlines)
            let rightText = right.segment.chunkLocalText.trimmingCharacters(in: .whitespacesAndNewlines)
            let localTail = terminalPunctuationRange(in: leftText)
            let firstRightWord = words(in: rightText).first
            // Port seam evaluation and edit precedence from
            // scripts/prediction-sim/lib/chunk-final-merge.mjs:88–110, 162–177.
            let shouldMergeWithRuleA = gap <= maxGapMs
                && localTail != nil
                && shouldContinue(rightText)
            let shouldMergeWithRuleB = gap > Self.maxGapMs
                && gap > ruleBMinGapExclusiveMs
                && gap <= ruleBMaxGapMs
                && hasAuxiliaryAdverbTail(leftText)
                && isGerund(firstRightWord)
            guard shouldMergeWithRuleA || shouldMergeWithRuleB,
                  let firstRightWord else { continue }

            let punctuationIndex: String.Index?
            if let localTail {
                let punctuationOffset = leftText.distance(from: leftText.startIndex, to: localTail.lowerBound)
                punctuationIndex = finalText.index(left.range.lowerBound, offsetBy: punctuationOffset)
            } else {
                punctuationIndex = nil
            }
            let nextWordStartOffset = rightText.distance(
                from: rightText.startIndex, to: firstWordStart(in: rightText))
            let nextStart = finalText.index(right.range.lowerBound, offsetBy: nextWordStartOffset)
            let nextWordEndOffset = rightText.distance(
                from: firstWordStart(in: rightText), to: firstWordEnd(in: rightText))
            let nextEnd = finalText.index(nextStart, offsetBy: nextWordEndOffset)
            let word = String(finalText[nextStart..<nextEnd])

            if shouldMergeWithRuleA, let punctuationIndex {
                let replacementWord = continuationReplacement(word)
                edits.append((punctuationIndex..<nextStart, " "))
                if replacementWord != word {
                    edits.append((nextStart..<nextEnd, replacementWord))
                }
            } else {
                if let punctuationIndex {
                    edits.append((punctuationIndex..<finalText.index(after: punctuationIndex), ""))
                }
                let replacementWord = lowercaseInitialCharacter(word)
                if replacementWord != word {
                    edits.append((nextStart..<nextEnd, replacementWord))
                }
            }
        }
        var result = finalText
        for edit in edits.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
            result.replaceSubrange(edit.range, with: edit.replacement)
        }
        return result
    }

    private static func locate(_ chunkText: String, in text: String, from start: String.Index) -> Range<String.Index>? {
        let trimmed = chunkText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let anchor = String(trimmed.prefix(24))
        guard let anchorRange = text.range(of: anchor, range: start..<text.endIndex) else { return nil }
        let candidateStart = anchorRange.lowerBound
        let candidate = text[candidateStart...]
        guard candidate.hasPrefix(trimmed) else { return nil }
        return candidateStart..<text.index(candidateStart, offsetBy: trimmed.count)
    }

    private static func terminalPunctuationRange(in text: String) -> Range<String.Index>? {
        var end = text.endIndex
        while end > text.startIndex, text[text.index(before: end)].isWhitespace { end = text.index(before: end) }
        while end > text.startIndex, ["\"", "'", "”", "’", ")"].contains(String(text[text.index(before: end)])) { end = text.index(before: end) }
        guard end > text.startIndex, [".", "!", "?"].contains(String(text[text.index(before: end)])) else { return nil }
        return text.index(before: end)..<end
    }

    private static func firstWordStart(in text: String) -> String.Index {
        text.firstIndex(where: { $0.isLetter }) ?? text.startIndex
    }

    private static func firstWordEnd(in text: String) -> String.Index {
        let start = firstWordStart(in: text)
        return text[start...].firstIndex(where: { !$0.isLetter }) ?? text.endIndex
    }

    private static func shouldContinue(_ text: String) -> Bool {
        let start = firstWordStart(in: text)
        let end = firstWordEnd(in: text)
        let word = String(text[start..<end])
        return word.first?.isLowercase == true || continuationWords.contains(word.lowercased())
    }

    private static func words(in text: String) -> [String] {
        text.split(whereSeparator: { !$0.isLetter }).map(String.init)
    }

    private static func hasAuxiliaryAdverbTail(_ text: String) -> Bool {
        let words = words(in: text)
        guard words.count >= 2 else { return false }
        let auxiliary = words[words.count - 2].lowercased()
        let adverb = words[words.count - 1].lowercased()
        return ruleBAuxiliaryWords.contains(auxiliary)
            && ruleBHangingClauseAdverbs.contains(adverb)
    }

    private static func isGerund(_ word: String?) -> Bool {
        word?.lowercased().hasSuffix(ruleBGerundSuffix) == true
    }

    private static func continuationReplacement(_ word: String) -> String {
        guard continuationWords.contains(word.lowercased()), word.first?.isUppercase == true else { return word }
        return lowercaseInitialCharacter(word)
    }

    private static func lowercaseInitialCharacter(_ word: String) -> String {
        word.prefix(1).lowercased() + word.dropFirst()
    }
}
