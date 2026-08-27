import Darwin
import Foundation

final class ReadOnlyMappedFile {

    let baseAddress: UnsafeRawPointer
    let fileSize: Int

    private let mappedAddress: UnsafeMutableRawPointer

    var rawRegion: UnsafeRawBufferPointer {
        UnsafeRawBufferPointer(start: baseAddress, count: fileSize)
    }

    init?(url: URL) {
        let descriptor = Darwin.open(url.path, O_RDONLY)
        guard descriptor >= 0 else { return nil }
        defer { Darwin.close(descriptor) }

        var fileInfo = stat()
        guard Darwin.fstat(descriptor, &fileInfo) == 0 else { return nil }
        guard fileInfo.st_size > 0, fileInfo.st_size <= off_t(Int.max) else { return nil }

        let size = Int(fileInfo.st_size)
        guard let address = mmap(nil, size, PROT_READ, MAP_PRIVATE, descriptor, 0) else {
            return nil
        }
        guard Int(bitPattern: address) != -1 else { return nil }

        mappedAddress = address
        baseAddress = UnsafeRawPointer(address)
        fileSize = size

        _ = posix_madvise(address, size, POSIX_MADV_WILLNEED)
    }

    deinit {
        _ = munmap(mappedAddress, fileSize)
    }
}

/// Read-only, memory-mapped access to a serialized SymSpell v1 index.
///
/// The mapped data and all section views are immutable after initialization.
/// `@unchecked Sendable` is safe because the mapping is read-only and this class
/// contains no mutable state; its retained mapping remains valid for its lifetime.
final class MappedSymSpellIndex: SymSpellQuerying, @unchecked Sendable {

    struct LoadResult {
        let index: MappedSymSpellIndex?
        let failureReason: String?
    }

    private struct Layout {
        let wordOffsets: Int
        let sortedWordIdx: Int
        let counts: Int
        let deleteKeyOffsets: Int
        let deleteOffsets: Int
        let deleteValues: Int
        let stringPool: Int
        let blobFnv1a64: Int
    }

    private struct ValidationError: LocalizedError {
        let reason: String

        var errorDescription: String? { reason }
    }

    private struct Candidate {
        let wordIndex: Int
        let count: Int64
        let distance: Int
        let insertionOrder: Int
    }

    private static let headerBytes = 64
    private static let formatVersion: UInt16 = 1
    private static let fnv1a64OffsetBasis: UInt64 = 14_695_981_039_346_656_037
    private static let fnv1a64Prime: UInt64 = 1_099_511_628_211

    private let mappedFile: ReadOnlyMappedFile
    private let wordOffsets: UnsafeBufferPointer<UInt32>
    private let sortedWordIdx: UnsafeBufferPointer<UInt32>
    private let counts: UnsafeBufferPointer<Int32>
    private let deleteKeyOffsets: UnsafeBufferPointer<UInt32>
    private let deleteOffsets: UnsafeBufferPointer<Int32>
    private let deleteValues: UnsafeBufferPointer<Int32>
    private let stringPool: UnsafeRawBufferPointer

    let maxEditDistance: Int
    let prefixLength: Int
    let wordCount: Int
    let deleteKeyCount: Int
    let deleteValueCount: Int
    let stringPoolBytes: Int

    init?(url: URL, language: KeyboardLanguage) {
        guard let mappedFile = ReadOnlyMappedFile(url: url) else { return nil }
        do {
            try self.init(mappedFile: mappedFile, language: language)
        } catch {
            return nil
        }
    }

    static func load(from url: URL, language: KeyboardLanguage) -> LoadResult {
        guard let mappedFile = ReadOnlyMappedFile(url: url) else {
            return LoadResult(index: nil, failureReason: "open or mmap failed")
        }

        do {
            let index = try MappedSymSpellIndex(mappedFile: mappedFile, language: language)
            return LoadResult(index: index, failureReason: nil)
        } catch let error as ValidationError {
            return LoadResult(index: nil, failureReason: error.reason)
        } catch {
            return LoadResult(index: nil, failureReason: error.localizedDescription)
        }
    }

    private init(mappedFile: ReadOnlyMappedFile, language: KeyboardLanguage) throws {
        let region = mappedFile.rawRegion
        guard region.count >= Self.headerBytes else {
            throw ValidationError(reason: "truncated header")
        }
        guard let regionBaseAddress = region.baseAddress else {
            throw ValidationError(reason: "empty mapped region")
        }

        guard region[0] == 82, region[1] == 83, region[2] == 83, region[3] == 49 else {
            throw ValidationError(reason: "invalid magic")
        }

        let version = Self.readUInt16LE(region, at: 4)
        guard version == Self.formatVersion else {
            throw ValidationError(reason: "unsupported format version")
        }

        let expectedLanguageBytes = Array(language.rawValue.utf8)
        guard expectedLanguageBytes.count == 2,
              region[8] == expectedLanguageBytes[0],
              region[9] == expectedLanguageBytes[1],
              region[10] == 0,
              region[11] == 0 else {
            throw ValidationError(reason: "language mismatch")
        }

        let maxEditDistance = Int(region[6])
        guard maxEditDistance == SharedConfig.Defaults.symspellMaxEditDistance else {
            throw ValidationError(reason: "unexpected max edit distance")
        }

        let prefixLength = Int(region[7])
        guard prefixLength == SharedConfig.Defaults.symspellPrefixLength else {
            throw ValidationError(reason: "unexpected prefix length")
        }

        let wordCount = Self.readUInt32LE(region, at: 0x0c)
        let deleteKeyCount = Self.readUInt32LE(region, at: 0x10)
        let deleteValueCount = Self.readUInt32LE(region, at: 0x14)
        let stringPoolBytes = Self.readUInt32LE(region, at: 0x18)
        guard wordCount > 0,
              deleteKeyCount > 0,
              deleteValueCount > 0,
              stringPoolBytes > 0 else {
            throw ValidationError(reason: "invalid dimensions")
        }

        let layout = try Self.makeLayout(
            wordCount: wordCount,
            deleteKeyCount: deleteKeyCount,
            deleteValueCount: deleteValueCount,
            stringPoolBytes: stringPoolBytes,
            fileSize: mappedFile.fileSize
        )

        let wordCountInt = Int(wordCount)
        let deleteKeyCountInt = Int(deleteKeyCount)
        let deleteValueCountInt = Int(deleteValueCount)
        let stringPoolBytesInt = Int(stringPoolBytes)
        guard wordCountInt > 0,
              deleteKeyCountInt > 0,
              deleteValueCountInt > 0,
              stringPoolBytesInt > 0 else {
            throw ValidationError(reason: "invalid dimensions")
        }

        let wordOffsets = Self.makeBuffer(
            baseAddress: regionBaseAddress,
            offset: layout.wordOffsets,
            count: wordCountInt + 1,
            type: UInt32.self
        )
        let sortedWordIdx = Self.makeBuffer(
            baseAddress: regionBaseAddress,
            offset: layout.sortedWordIdx,
            count: wordCountInt,
            type: UInt32.self
        )
        let counts = Self.makeBuffer(
            baseAddress: regionBaseAddress,
            offset: layout.counts,
            count: wordCountInt,
            type: Int32.self
        )
        let deleteKeyOffsets = Self.makeBuffer(
            baseAddress: regionBaseAddress,
            offset: layout.deleteKeyOffsets,
            count: deleteKeyCountInt + 1,
            type: UInt32.self
        )
        let deleteOffsets = Self.makeBuffer(
            baseAddress: regionBaseAddress,
            offset: layout.deleteOffsets,
            count: deleteKeyCountInt + 1,
            type: Int32.self
        )
        let deleteValues = Self.makeBuffer(
            baseAddress: regionBaseAddress,
            offset: layout.deleteValues,
            count: deleteValueCountInt,
            type: Int32.self
        )
        let stringPool = UnsafeRawBufferPointer(
            start: regionBaseAddress.advanced(by: layout.stringPool),
            count: stringPoolBytesInt
        )

        try Self.validateStructure(
            wordOffsets: wordOffsets,
            sortedWordIdx: sortedWordIdx,
            counts: counts,
            deleteKeyOffsets: deleteKeyOffsets,
            deleteOffsets: deleteOffsets,
            deleteValues: deleteValues,
            stringPool: stringPool,
            wordCount: wordCountInt,
            deleteKeyCount: deleteKeyCountInt,
            deleteValueCount: deleteValueCountInt,
            stringPoolBytes: stringPoolBytesInt
        )

        for index in 0x24..<Self.headerBytes {
            guard region[index] == 0 else {
                throw ValidationError(reason: "non-zero reserved header bytes")
            }
        }
        for index in (layout.stringPool + stringPoolBytesInt)..<layout.blobFnv1a64 {
            guard region[index] == 0 else {
                throw ValidationError(reason: "non-zero alignment padding")
            }
        }

        let storedWordlistHash = Self.readUInt64LE(region, at: 0x1c)
        let wordlistURL = WordListLoader.bundledURL(language: language)
        guard let wordlistURL else {
            throw ValidationError(reason: "bundled wordlist missing")
        }
        let wordlistData: Data
        do {
            wordlistData = try Data(contentsOf: wordlistURL)
        } catch {
            throw ValidationError(reason: "bundled wordlist unreadable")
        }
        let wordlistHash = wordlistData.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> UInt64 in
            Self.fnv1a64(bytes)
        }
        guard storedWordlistHash == wordlistHash else {
            throw ValidationError(reason: "source wordlist checksum mismatch")
        }

        let storedBlobHash = Self.readUInt64LE(region, at: layout.blobFnv1a64)
        let blobHash = Self.fnv1a64(
            UnsafeRawBufferPointer(start: regionBaseAddress, count: layout.blobFnv1a64)
        )
        guard storedBlobHash == blobHash else {
            throw ValidationError(reason: "blob checksum mismatch")
        }

        self.mappedFile = mappedFile
        self.wordOffsets = wordOffsets
        self.sortedWordIdx = sortedWordIdx
        self.counts = counts
        self.deleteKeyOffsets = deleteKeyOffsets
        self.deleteOffsets = deleteOffsets
        self.deleteValues = deleteValues
        self.stringPool = stringPool
        self.maxEditDistance = maxEditDistance
        self.prefixLength = prefixLength
        self.wordCount = wordCountInt
        self.deleteKeyCount = deleteKeyCountInt
        self.deleteValueCount = deleteValueCountInt
        self.stringPoolBytes = stringPoolBytesInt
    }

    func count(for word: String) -> Int64 {
        let query = Data(word.utf8)
        let index: Int? = query.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> Int? in
            findWordIndex(bytes)
        }
        guard let index else { return 0 }
        return Int64(counts[index])
    }

    func lookup(
        input: String,
        editDistance: Int? = nil,
        verbosity: SymSpell.Verbosity = .top
    ) -> [(term: String, count: Int64, distance: Int)] {
        let maxED = editDistance ?? maxEditDistance
        let inputLower = input.lowercased()
        var candidates: [Candidate] = []
        var suggestionSet: Set<Int> = []
        var insertionOrder = 0

        let inputData = Data(inputLower.utf8)
        let exactIndex: Int? = inputData.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> Int? in
            findWordIndex(bytes)
        }
        if let exactIndex {
            suggestionSet.insert(exactIndex)
            candidates.append(
                Candidate(
                    wordIndex: exactIndex,
                    count: Int64(counts[exactIndex]),
                    distance: 0,
                    insertionOrder: insertionOrder
                )
            )
            insertionOrder += 1
        }

        let inputPrefix = String(inputLower.prefix(prefixLength))
        let inputDeletes = edits(word: inputPrefix, editDistance: maxED)

        for deleteKey in inputDeletes {
            let deleteKeyData = Data(deleteKey.utf8)
            let deleteIndex: Int? = deleteKeyData.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> Int? in
                findDeleteKeyIndex(bytes)
            }
            guard let deleteIndex else { continue }

            let start = Int(deleteOffsets[deleteIndex])
            let end = Int(deleteOffsets[deleteIndex + 1])
            for valueIndex in start..<end {
                let wordIndex = Int(deleteValues[valueIndex])
                if suggestionSet.contains(wordIndex) { continue }

                guard let word = wordString(at: wordIndex) else { continue }
                let distance = SymSpell.levenshteinDistance(inputLower, word)
                if distance <= maxED {
                    suggestionSet.insert(wordIndex)
                    candidates.append(
                        Candidate(
                            wordIndex: wordIndex,
                            count: Int64(counts[wordIndex]),
                            distance: distance,
                            insertionOrder: insertionOrder
                        )
                    )
                    insertionOrder += 1
                }
            }
        }

        let sorted = candidates.sorted { a, b in
            if a.distance != b.distance { return a.distance < b.distance }
            if a.count != b.count { return a.count > b.count }
            return a.insertionOrder < b.insertionOrder
        }

        var results: [(term: String, count: Int64, distance: Int)] = []
        results.reserveCapacity(sorted.count)
        for candidate in sorted {
            guard let term = wordString(at: candidate.wordIndex) else { continue }
            results.append((term: term, count: candidate.count, distance: candidate.distance))
        }

        switch verbosity {
        case .top:
            return Array(results.prefix(1))
        case .all, .closest:
            return results
        }
    }

    private func findWordIndex(_ query: UnsafeRawBufferPointer) -> Int? {
        var low = 0
        var high = sortedWordIdx.count - 1
        while low <= high {
            let middle = (low + high) / 2
            let wordIndex = Int(sortedWordIdx[middle])
            guard let wordBytes = wordBytes(at: wordIndex) else { return nil }
            let comparison = Self.compareBytes(wordBytes, query)
            if comparison == 0 { return wordIndex }
            if comparison < 0 {
                low = middle + 1
            } else {
                high = middle - 1
            }
        }
        return nil
    }

    private func findDeleteKeyIndex(_ query: UnsafeRawBufferPointer) -> Int? {
        var low = 0
        var high = deleteKeyCount - 1
        while low <= high {
            let middle = (low + high) / 2
            guard let keyBytes = deleteKeyBytes(at: middle) else { return nil }
            let comparison = Self.compareBytes(keyBytes, query)
            if comparison == 0 { return middle }
            if comparison < 0 {
                low = middle + 1
            } else {
                high = middle - 1
            }
        }
        return nil
    }

    private func wordBytes(at index: Int) -> UnsafeRawBufferPointer? {
        guard index >= 0, index < wordCount else { return nil }
        let start = Int(wordOffsets[index])
        guard start >= 0, start < stringPool.count else { return nil }
        var end = start
        while end < stringPool.count {
            if stringPool[end] == 0 {
                return Self.rawSlice(stringPool, start: start, end: end)
            }
            end += 1
        }
        return nil
    }

    private func deleteKeyBytes(at index: Int) -> UnsafeRawBufferPointer? {
        guard index >= 0, index < deleteKeyCount else { return nil }
        let start = Int(deleteKeyOffsets[index])
        let end = Int(deleteKeyOffsets[index + 1]) - 1
        guard end > start, end <= stringPool.count else { return nil }
        return Self.rawSlice(stringPool, start: start, end: end)
    }

    private func wordString(at index: Int) -> String? {
        guard let bytes = wordBytes(at: index) else { return nil }
        return String(decoding: bytes, as: UTF8.self)
    }

    private func edits(word: String, editDistance: Int) -> Set<String> {
        var results: Set<String> = [word]
        guard editDistance > 0, !word.isEmpty else { return results }

        let chars = Array(word)
        let n = chars.count
        let maxDelete = min(editDistance, n)

        for deleteCount in 1...maxDelete {
            var indices = Array(0..<deleteCount)
            while true {
                var result = ""
                var deleteIndex = 0
                for index in 0..<n {
                    if deleteIndex < deleteCount && indices[deleteIndex] == index {
                        deleteIndex += 1
                    } else {
                        result.append(chars[index])
                    }
                }
                results.insert(result)

                var nextIndex = deleteCount - 1
                while nextIndex >= 0 && indices[nextIndex] == n - deleteCount + nextIndex {
                    nextIndex -= 1
                }
                if nextIndex < 0 { break }
                indices[nextIndex] += 1
                if nextIndex + 1 < deleteCount {
                    for index in (nextIndex + 1)..<deleteCount {
                        indices[index] = indices[index - 1] + 1
                    }
                }
            }
        }

        return results
    }

    private static func makeLayout(
        wordCount: UInt32,
        deleteKeyCount: UInt32,
        deleteValueCount: UInt32,
        stringPoolBytes: UInt32,
        fileSize: Int
    ) throws -> Layout {
        guard fileSize >= 8 else {
            throw ValidationError(reason: "invalid dimensions")
        }

        var offset: UInt64 = UInt64(headerBytes)
        let wordOffsets = offset
        guard let wordOffsetsBytes = checkedMultiply(UInt64(wordCount) + 1, 4),
              let nextWordOffsets = checkedAdd(offset, wordOffsetsBytes) else {
            throw ValidationError(reason: "invalid dimensions")
        }
        offset = nextWordOffsets

        let sortedWordIdx = offset
        guard let sortedWordIdxBytes = checkedMultiply(UInt64(wordCount), 4),
              let nextSortedWordIdx = checkedAdd(offset, sortedWordIdxBytes) else {
            throw ValidationError(reason: "invalid dimensions")
        }
        offset = nextSortedWordIdx

        let counts = offset
        guard let countsBytes = checkedMultiply(UInt64(wordCount), 4),
              let nextCounts = checkedAdd(offset, countsBytes) else {
            throw ValidationError(reason: "invalid dimensions")
        }
        offset = nextCounts

        let deleteKeyOffsets = offset
        guard let deleteKeyOffsetsBytes = checkedMultiply(UInt64(deleteKeyCount) + 1, 4),
              let nextDeleteKeyOffsets = checkedAdd(offset, deleteKeyOffsetsBytes) else {
            throw ValidationError(reason: "invalid dimensions")
        }
        offset = nextDeleteKeyOffsets

        let deleteOffsets = offset
        guard let deleteOffsetsBytes = checkedMultiply(UInt64(deleteKeyCount) + 1, 4),
              let nextDeleteOffsets = checkedAdd(offset, deleteOffsetsBytes) else {
            throw ValidationError(reason: "invalid dimensions")
        }
        offset = nextDeleteOffsets

        let deleteValues = offset
        guard let deleteValuesBytes = checkedMultiply(UInt64(deleteValueCount), 4),
              let nextDeleteValues = checkedAdd(offset, deleteValuesBytes) else {
            throw ValidationError(reason: "invalid dimensions")
        }
        offset = nextDeleteValues

        let stringPool = offset
        guard let nextStringPool = checkedAdd(offset, UInt64(stringPoolBytes)),
              nextStringPool <= UInt64.max - 7 else {
            throw ValidationError(reason: "invalid dimensions")
        }
        let sectionEndUInt64 = (nextStringPool + 7) & ~UInt64(7)
        guard sectionEndUInt64 <= UInt64(Int.max),
              sectionEndUInt64 == UInt64(fileSize - 8) else {
            throw ValidationError(reason: "section layout does not match file size")
        }

        let offsets = [
            wordOffsets,
            sortedWordIdx,
            counts,
            deleteKeyOffsets,
            deleteOffsets,
            deleteValues,
            stringPool,
            sectionEndUInt64
        ]
        guard offsets.allSatisfy({ $0 % 4 == 0 }), sectionEndUInt64 % 8 == 0 else {
            throw ValidationError(reason: "section alignment mismatch")
        }

        return Layout(
            wordOffsets: Int(wordOffsets),
            sortedWordIdx: Int(sortedWordIdx),
            counts: Int(counts),
            deleteKeyOffsets: Int(deleteKeyOffsets),
            deleteOffsets: Int(deleteOffsets),
            deleteValues: Int(deleteValues),
            stringPool: Int(stringPool),
            blobFnv1a64: Int(sectionEndUInt64)
        )
    }

    private static func validateStructure(
        wordOffsets: UnsafeBufferPointer<UInt32>,
        sortedWordIdx: UnsafeBufferPointer<UInt32>,
        counts: UnsafeBufferPointer<Int32>,
        deleteKeyOffsets: UnsafeBufferPointer<UInt32>,
        deleteOffsets: UnsafeBufferPointer<Int32>,
        deleteValues: UnsafeBufferPointer<Int32>,
        stringPool: UnsafeRawBufferPointer,
        wordCount: Int,
        deleteKeyCount: Int,
        deleteValueCount: Int,
        stringPoolBytes: Int
    ) throws {
        _ = counts

        guard deleteValueCount <= Int(UInt32(Int32.max)),
              wordCount <= Int(UInt32(Int32.max)) else {
            throw ValidationError(reason: "section dimensions exceed Int32")
        }
        guard wordOffsets.first == 0,
              wordOffsets.last == UInt32(stringPoolBytes),
              deleteKeyOffsets.last == UInt32(stringPoolBytes),
              deleteOffsets.first == 0,
              deleteOffsets.last == Int32(deleteValueCount) else {
            throw ValidationError(reason: "invalid section sentinels")
        }

        for index in 1..<deleteKeyOffsets.count {
            guard deleteKeyOffsets[index] >= deleteKeyOffsets[index - 1] else {
                throw ValidationError(reason: "delete key offsets are not monotonic")
            }
        }
        for index in 1..<deleteOffsets.count {
            guard deleteOffsets[index] >= deleteOffsets[index - 1] else {
                throw ValidationError(reason: "delete offsets are not monotonic")
            }
        }

        for index in 0..<deleteKeyCount {
            let start = Int(deleteKeyOffsets[index])
            let end = Int(deleteKeyOffsets[index + 1])
            guard end > start, end <= stringPool.count, stringPool[end - 1] == 0 else {
                throw ValidationError(reason: "invalid delete key boundary")
            }
        }

        for index in 0..<wordCount {
            let start = Int(wordOffsets[index])
            guard start >= 0, start < stringPool.count else {
                throw ValidationError(reason: "invalid word offset")
            }
            var terminator = start
            while terminator < stringPool.count, stringPool[terminator] != 0 {
                terminator += 1
            }
            guard terminator < stringPool.count else {
                throw ValidationError(reason: "unterminated word")
            }
            if index + 1 < wordCount {
                guard wordOffsets[index + 1] == UInt32(terminator + 1) else {
                    throw ValidationError(reason: "invalid word boundary")
                }
            } else {
                guard deleteKeyOffsets[0] == UInt32(terminator + 1) else {
                    throw ValidationError(reason: "delete key pool does not follow words")
                }
            }
        }

        for index in sortedWordIdx {
            guard index < UInt32(wordCount) else {
                throw ValidationError(reason: "sorted word index out of range")
            }
        }
        for index in deleteValues {
            guard index >= 0, index < Int32(wordCount) else {
                throw ValidationError(reason: "delete value out of range")
            }
        }

        for index in 1..<sortedWordIdx.count {
            let previousIndex = Int(sortedWordIdx[index - 1])
            let currentIndex = Int(sortedWordIdx[index])
            guard let previous = Self.wordBytes(
                at: previousIndex,
                offsets: wordOffsets,
                stringPool: stringPool,
                wordCount: wordCount
            ), let current = Self.wordBytes(
                at: currentIndex,
                offsets: wordOffsets,
                stringPool: stringPool,
                wordCount: wordCount
            ), Self.compareBytes(previous, current) <= 0 else {
                throw ValidationError(reason: "sorted words are not UTF-8 ordered")
            }
        }

        for index in 1..<deleteKeyCount {
            let previousStart = Int(deleteKeyOffsets[index - 1])
            let previousEnd = Int(deleteKeyOffsets[index]) - 1
            let currentStart = Int(deleteKeyOffsets[index])
            let currentEnd = Int(deleteKeyOffsets[index + 1]) - 1
            guard let previous = Self.rawSlice(stringPool, start: previousStart, end: previousEnd),
                  let current = Self.rawSlice(stringPool, start: currentStart, end: currentEnd),
                  Self.compareBytes(previous, current) <= 0 else {
                throw ValidationError(reason: "delete keys are not UTF-8 ordered")
            }
        }
    }

    private static func wordBytes(
        at index: Int,
        offsets: UnsafeBufferPointer<UInt32>,
        stringPool: UnsafeRawBufferPointer,
        wordCount: Int
    ) -> UnsafeRawBufferPointer? {
        guard index >= 0, index < wordCount else { return nil }
        let start = Int(offsets[index])
        guard start >= 0, start < stringPool.count else { return nil }
        var end = start
        while end < stringPool.count {
            if stringPool[end] == 0 {
                return rawSlice(stringPool, start: start, end: end)
            }
            end += 1
        }
        return nil
    }

    private static func rawSlice(
        _ buffer: UnsafeRawBufferPointer,
        start: Int,
        end: Int
    ) -> UnsafeRawBufferPointer? {
        guard start >= 0, end >= start, end <= buffer.count,
              let baseAddress = buffer.baseAddress else { return nil }
        return UnsafeRawBufferPointer(start: baseAddress.advanced(by: start), count: end - start)
    }

    private static func compareBytes(
        _ lhs: UnsafeRawBufferPointer,
        _ rhs: UnsafeRawBufferPointer
    ) -> Int {
        let commonCount = min(lhs.count, rhs.count)
        for index in 0..<commonCount {
            if lhs[index] != rhs[index] {
                return lhs[index] < rhs[index] ? -1 : 1
            }
        }
        if lhs.count == rhs.count { return 0 }
        return lhs.count < rhs.count ? -1 : 1
    }

    private static func makeBuffer<T>(
        baseAddress: UnsafeRawPointer,
        offset: Int,
        count: Int,
        type: T.Type
    ) -> UnsafeBufferPointer<T> {
        _ = type
        let typedAddress = baseAddress.advanced(by: offset).assumingMemoryBound(to: T.self)
        return UnsafeBufferPointer(start: typedAddress, count: count)
    }

    private static func checkedAdd(_ lhs: UInt64, _ rhs: UInt64) -> UInt64? {
        guard lhs <= UInt64.max - rhs else { return nil }
        return lhs + rhs
    }

    private static func checkedMultiply(_ lhs: UInt64, _ rhs: UInt64) -> UInt64? {
        guard rhs == 0 || lhs <= UInt64.max / rhs else { return nil }
        return lhs * rhs
    }

    private static func readUInt16LE(_ bytes: UnsafeRawBufferPointer, at offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    private static func readUInt32LE(_ bytes: UnsafeRawBufferPointer, at offset: Int) -> UInt32 {
        UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }

    private static func readUInt64LE(_ bytes: UnsafeRawBufferPointer, at offset: Int) -> UInt64 {
        var value: UInt64 = 0
        for index in 0..<8 {
            value |= UInt64(bytes[offset + index]) << UInt64(index * 8)
        }
        return value
    }

    private static func fnv1a64(_ bytes: UnsafeRawBufferPointer) -> UInt64 {
        var hash = fnv1a64OffsetBasis
        for byte in bytes {
            hash ^= UInt64(byte)
            hash = hash &* fnv1a64Prime
        }
        return hash
    }
}
