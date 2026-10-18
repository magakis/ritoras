import Foundation

struct ChunkFinalSegment {
    let chunkId: UInt32
    let chunkLocalText: String
    let startMs: Double
    let endMs: Double
}

enum ChunkFinalMerger {
    static let maxGapMs: Double = 2_500

    private static let continuationWords: Set<String> = [
        "for", "and", "but", "or", "nor", "so", "yet", "which", "that",
        "because", "with", "also", "to", "from", "when", "while", "since",
        "although", "however", "plus"
    ]

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
            guard gap <= maxGapMs,
                  let localTail = terminalPunctuationRange(in: left.segment.chunkLocalText.trimmingCharacters(in: .whitespacesAndNewlines)),
                  shouldContinue(right.segment.chunkLocalText) else { continue }

            let leftText = left.segment.chunkLocalText.trimmingCharacters(in: .whitespacesAndNewlines)
            let rightText = right.segment.chunkLocalText.trimmingCharacters(in: .whitespacesAndNewlines)
            let punctuationOffset = leftText.distance(from: leftText.startIndex, to: localTail.lowerBound)
            let finalPunctuation = finalText.index(left.range.lowerBound, offsetBy: punctuationOffset)
            let nextWordStartOffset = rightText.distance(
                from: rightText.startIndex, to: firstWordStart(in: rightText))
            let nextStart = finalText.index(right.range.lowerBound, offsetBy: nextWordStartOffset)
            let nextWordEndOffset = rightText.distance(
                from: firstWordStart(in: rightText), to: firstWordEnd(in: rightText))
            let nextEnd = finalText.index(nextStart, offsetBy: nextWordEndOffset)
            let word = String(finalText[nextStart..<nextEnd])
            let replacementWord = continuationReplacement(word)

            edits.append((finalPunctuation..<nextStart, " "))
            if replacementWord != word {
                edits.append((nextStart..<nextEnd, replacementWord))
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

    private static func continuationReplacement(_ word: String) -> String {
        guard continuationWords.contains(word.lowercased()), word.first?.isUppercase == true else { return word }
        return word.prefix(1).lowercased() + word.dropFirst()
    }
}
