import Foundation

/// Shared, UIKit-free schema and bounded recorder for keyboard keystroke traces.
public enum KeystrokeTraceSchema {
    /// Version written into every trace record.
    public static let currentVersion = 1
    /// Maximum context retained before and after the caret.
    public static let contextWindowCharacters = 128
    /// Maximum characters retained for a word in a decision skip payload.
    public static let decisionTextCharacters = 64
    /// Maximum preallocated in-memory byte ring.
    public static let ringCapacityBytes = 256 * 1024
    /// Maximum size of either on-disk segment.
    public static let segmentCapacityBytes = 2 * 1024 * 1024
    /// Maximum combined size of the live and rotated segments.
    public static let totalDiskCapacityBytes = 4 * 1024 * 1024
    /// Active trace segment name.
    public static let liveFileName = "ritoras-trace.log"
    /// Single retained previous trace segment name.
    public static let rotatedFileName = "ritoras-trace.log.1"
}

/// Stable reason codes shared by autocorrect guards, deferred applies, and host callbacks.
public enum KeystrokeTraceReasonCode: String, CaseIterable, Codable, Equatable, Sendable {
    /// Autocorrect was disabled in settings.
    case autocorrectSettingDisabled = "autocorrect-setting-disabled"
    /// The current text-input traits do not permit autocorrect.
    case autocorrectTraitsBlocked = "autocorrect-traits-blocked"
    /// The current word did not originate from ordinary typing.
    case autocorrectOriginNotTyping = "autocorrect-origin-not-typing"
    /// Current-word extraction failed.
    case autocorrectExtractionFailed = "autocorrect-extraction-failed"
    /// The extracted current word differs from the lookup word.
    case autocorrectCurrentWordLookupWordMismatch = "autocorrect-current-word-lookup-word-mismatch"
    /// The extracted input contains no word to score.
    case autocorrectEmptyInput = "autocorrect-empty-input"
    /// The prediction engine was not ready to make a correction.
    case autocorrectEngineNotReady = "autocorrect-engine-not-ready"
    /// The system spellchecker accepted the current word.
    case autocorrectSpellcheckPass = "autocorrect-spellcheck-pass"
    /// The current word is in the learned-word store.
    case autocorrectLearnedWord = "autocorrect-learned-word"
    /// The proposed correction does not preserve the first letter.
    case autocorrectFirstLetterMismatch = "autocorrect-first-letter-mismatch"
    /// No correction survived literal-word and trigram exclusions.
    case autocorrectPoolEmptyAfterFilters = "autocorrect-pool-empty-after-filters"
    /// The winner was below the language-model floor and failed the literal-margin rescue.
    case autocorrectLanguageModelFloor = "autocorrect-language-model-floor"
    /// The ambiguous contraction did not clear its language-model margin gate.
    case autocorrectContractionMargin = "autocorrect-contraction-margin"
    /// The proposed correction score did not meet the configured confidence threshold.
    case autocorrectScoreBelowThreshold = "autocorrect-score-below-threshold"
    /// The proposed correction is identical to the current word.
    case autocorrectSameWord = "autocorrect-same-word"
    /// The current word length is outside the supported correction bounds.
    case autocorrectLengthOutOfBounds = "autocorrect-length-out-of-bounds"
    /// A deferred apply was invalidated by a keyboard epoch change.
    case deferredApplyEpochChanged = "deferred-apply-epoch-changed"
    /// A deferred apply was invalidated by a context-token change.
    case deferredApplyContextTokenChanged = "deferred-apply-context-token-changed"
    /// A deferred apply was invalidated by a document identity change.
    case deferredApplyDocumentIdentityChanged = "deferred-apply-document-identity-changed"
    /// The keyboard was no longer live when the deferred apply ran.
    case deferredApplyKeyboardNotLive = "deferred-apply-keyboard-not-live"
    /// The deferred apply's host target no longer existed.
    case deferredApplyHostTargetGone = "deferred-apply-host-target-gone"
    /// The live text around the caret no longer matched the captured context.
    case deferredApplyLiveContextMismatch = "deferred-apply-live-context-mismatch"
    /// The text and context at the retroactive deletion caret did not match.
    case autocorrectApplyTargetMismatch = "autocorrect-apply-target-mismatch"
    /// A successful autocorrect application.
    case autocorrectApplied = "autocorrect-applied"
    /// A retroactive correction was queued for a later guarded apply.
    case autocorrectRetroQueued = "autocorrect-retro-queued"
    /// The host's textDidChange callback bumped the keyboard epoch.
    case hostTextDidChangeEpochBump = "host-text-did-change-epoch-bump"
    /// A host selection-change callback bumped the keyboard epoch.
    case hostSelectionChangeEpochBump = "host-selection-change-epoch-bump"
    /// The host callback path cleared the trace ring.
    case hostRingCleared = "host-ring-cleared"
}

/// Kinds of key-path activity represented by a key event.
public enum KeystrokeTraceKeyAction: String, Codable, Equatable {
    case insert
    case backspace
    case shift
    case mode
    case trigger
    case suggestionTap
    case redacted
}

/// Context-bearing key event. `caretPosition` is the UTF-16 length of the full
/// captured before-context, before context is clipped to 128 characters per side.
public struct KeystrokeTraceKeyEvent: Codable, Equatable {
    public let action: KeystrokeTraceKeyAction
    public let keyValue: String?
    public let epoch: UInt64
    /// UTF-16 offset from the start of the full captured before-context to the caret.
    public let caretPosition: Int?
    public let contextBefore: String?
    public let contextAfter: String?
    public let deleteCount: Int?
    public let liveContextSuffix: String?

    /// Creates a key event and clips supplied caret context to the schema window.
    public init(
        action: KeystrokeTraceKeyAction,
        keyValue: String? = nil,
        epoch: UInt64,
        caretPosition: Int? = nil,
        contextBefore: String? = nil,
        contextAfter: String? = nil,
        deleteCount: Int? = nil,
        liveContextSuffix: String? = nil
    ) {
        self.action = action
        self.keyValue = action == .redacted ? nil : keyValue
        self.epoch = epoch
        self.caretPosition = action == .redacted ? nil : caretPosition
        self.contextBefore = action == .redacted ? nil : contextBefore.map {
            String($0.suffix(KeystrokeTraceSchema.contextWindowCharacters))
        }
        self.contextAfter = action == .redacted ? nil : contextAfter.map {
            String($0.prefix(KeystrokeTraceSchema.contextWindowCharacters))
        }
        self.deleteCount = action == .redacted ? nil : deleteCount
        self.liveContextSuffix = action == .redacted ? nil : liveContextSuffix.map {
            String($0.suffix(KeystrokeTraceSchema.contextWindowCharacters))
        }
    }
}

/// One prediction candidate and its named component scores.
public struct KeystrokeTraceCandidate: Codable, Equatable {
    public let candidate: String
    public let scoreComponents: [String: Double]

    /// Creates one candidate with named numeric score components.
    public init(candidate: String, scoreComponents: [String: Double]) {
        self.candidate = candidate
        self.scoreComponents = scoreComponents
    }
}

/// Snapshot of a suggestion refresh, including scores and the displayed subset.
public struct KeystrokeTraceSuggestionEvent: Codable, Equatable {
    public let currentWord: String
    public let lookupWord: String
    public let previousWord: String?
    public let previousWord2: String?
    public let candidates: [KeystrokeTraceCandidate]
    public let displayedCandidates: [String]
    public let epoch: UInt64
    public let contextToken: String?
    public let documentContextLength: Int
    public let documentContextSuffix: String

    /// Creates a suggestion snapshot and bounds the stored context suffix.
    public init(
        currentWord: String,
        lookupWord: String,
        previousWord: String? = nil,
        previousWord2: String? = nil,
        candidates: [KeystrokeTraceCandidate],
        displayedCandidates: [String],
        epoch: UInt64,
        contextToken: String? = nil,
        documentContextLength: Int,
        documentContextSuffix: String
    ) {
        self.currentWord = currentWord
        self.lookupWord = lookupWord
        self.previousWord = previousWord
        self.previousWord2 = previousWord2
        self.candidates = candidates
        self.displayedCandidates = displayedCandidates
        self.epoch = epoch
        self.contextToken = contextToken
        self.documentContextLength = documentContextLength
        self.documentContextSuffix = String(
            documentContextSuffix.suffix(KeystrokeTraceSchema.contextWindowCharacters)
        )
    }
}

/// Bounded operands attached to a skipped decision when the guard computed them.
public struct KeystrokeTraceDecisionSkip: Codable, Equatable, Sendable {
    public let reasonCode: KeystrokeTraceReasonCode
    public let path: KeystrokeTraceDecisionPath?
    public let candidate: String?
    public let fusedScore: Double?
    public let rawLMLogProb: Double?
    public let typedLiteralRawLMLogProb: Double?
    public let typedLiteralLogProbMargin: Double?
    public let absoluteLogProbFloor: Double?
    public let checkedWord: String?
    public let expectedWindow: String?
    public let foundWindow: String?

    /// Creates a skip payload with short text operands and rounded scores.
    public init(
        reasonCode: KeystrokeTraceReasonCode,
        path: KeystrokeTraceDecisionPath? = nil,
        candidate: String? = nil,
        fusedScore: Double? = nil,
        rawLMLogProb: Double? = nil,
        typedLiteralRawLMLogProb: Double? = nil,
        typedLiteralLogProbMargin: Double? = nil,
        absoluteLogProbFloor: Double? = nil,
        checkedWord: String? = nil,
        expectedWindow: String? = nil,
        foundWindow: String? = nil
    ) {
        self.reasonCode = reasonCode
        self.path = path
        self.candidate = candidate.map {
            String($0.prefix(KeystrokeTraceSchema.decisionTextCharacters))
        }
        self.fusedScore = fusedScore.map { ($0 * 1_000).rounded() / 1_000 }
        self.rawLMLogProb = rawLMLogProb.map { ($0 * 1_000).rounded() / 1_000 }
        self.typedLiteralRawLMLogProb = typedLiteralRawLMLogProb.map {
            ($0 * 1_000).rounded() / 1_000
        }
        self.typedLiteralLogProbMargin = typedLiteralLogProbMargin.map {
            ($0 * 1_000).rounded() / 1_000
        }
        self.absoluteLogProbFloor = absoluteLogProbFloor.map {
            ($0 * 1_000).rounded() / 1_000
        }
        self.checkedWord = checkedWord.map {
            String($0.prefix(KeystrokeTraceSchema.decisionTextCharacters))
        }
        self.expectedWindow = expectedWindow.map {
            String($0.prefix(KeystrokeTraceSchema.decisionTextCharacters))
        }
        self.foundWindow = foundWindow.map {
            String($0.prefix(KeystrokeTraceSchema.decisionTextCharacters))
        }
    }
}

/// The inline or retroactive path that produced an autocorrect decision.
public enum KeystrokeTraceDecisionPath: String, Codable, Equatable, Sendable {
    case inline
    case retro
}

/// Bounded words attached to a retroactive correction queue decision.
public struct KeystrokeTraceDecisionQueued: Equatable, Sendable {
    public let reasonCode: KeystrokeTraceReasonCode
    public let checkedWord: String
    public let candidate: String

    /// Creates a queue decision with bounded checked-word and candidate operands.
    public init(
        reasonCode: KeystrokeTraceReasonCode = .autocorrectRetroQueued,
        checkedWord: String,
        candidate: String
    ) {
        self.reasonCode = reasonCode
        self.checkedWord = String(
            checkedWord.prefix(KeystrokeTraceSchema.decisionTextCharacters)
        )
        self.candidate = String(
            candidate.prefix(KeystrokeTraceSchema.decisionTextCharacters)
        )
    }
}

/// Apply details with raw language-model operands rounded to trace precision.
public struct KeystrokeTraceDecisionApply: Equatable, Sendable {
    public let reasonCode: KeystrokeTraceReasonCode
    public let path: KeystrokeTraceDecisionPath?
    public let rawLMLogProb: Double?
    public let typedLiteralRawLMLogProb: Double?
    public let beforeText: String
    public let afterText: String
    public let deleteCount: Int
    public let insertCount: Int

    /// Creates an apply decision and rounds optional scores to three decimals.
    public init(
        reasonCode: KeystrokeTraceReasonCode,
        path: KeystrokeTraceDecisionPath? = nil,
        rawLMLogProb: Double? = nil,
        typedLiteralRawLMLogProb: Double? = nil,
        beforeText: String,
        afterText: String,
        deleteCount: Int,
        insertCount: Int
    ) {
        self.reasonCode = reasonCode
        self.path = path
        self.rawLMLogProb = rawLMLogProb.map { ($0 * 1_000).rounded() / 1_000 }
        self.typedLiteralRawLMLogProb = typedLiteralRawLMLogProb.map {
            ($0 * 1_000).rounded() / 1_000
        }
        self.beforeText = beforeText
        self.afterText = afterText
        self.deleteCount = deleteCount
        self.insertCount = insertCount
    }
}

/// Apply decisions carry edit details; skips and queued corrections carry their operands.
public enum KeystrokeTraceDecisionEvent: Equatable, Codable {
    case apply(KeystrokeTraceDecisionApply)
    case queued(KeystrokeTraceDecisionQueued)
    case skip(KeystrokeTraceDecisionSkip)

    private enum CodingKeys: String, CodingKey {
        case outcome
        case reasonCode
        case path
        case beforeText
        case afterText
        case deleteCount
        case insertCount
        case candidate
        case fusedScore
        case rawLMLogProb
        case typedLiteralRawLMLogProb
        case typedLiteralLogProbMargin
        case absoluteLogProbFloor
        case checkedWord
        case expectedWindow
        case foundWindow
    }

    private enum Outcome: String, Codable {
        case apply
        case queued
        case skip
    }

    /// Decodes apply, queued, or skip fields while requiring each outcome's operands.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let outcome = try container.decode(Outcome.self, forKey: .outcome)
        let reasonCode = try container.decode(
            KeystrokeTraceReasonCode.self,
            forKey: .reasonCode
        )
        switch outcome {
        case .apply:
            self = .apply(KeystrokeTraceDecisionApply(
                reasonCode: reasonCode,
                path: try container.decodeIfPresent(
                    KeystrokeTraceDecisionPath.self,
                    forKey: .path
                ),
                rawLMLogProb: try container.decodeIfPresent(Double.self, forKey: .rawLMLogProb),
                typedLiteralRawLMLogProb: try container.decodeIfPresent(
                    Double.self,
                    forKey: .typedLiteralRawLMLogProb
                ),
                beforeText: try container.decode(String.self, forKey: .beforeText),
                afterText: try container.decode(String.self, forKey: .afterText),
                deleteCount: try container.decode(Int.self, forKey: .deleteCount),
                insertCount: try container.decode(Int.self, forKey: .insertCount)
            ))
        case .queued:
            self = .queued(KeystrokeTraceDecisionQueued(
                reasonCode: reasonCode,
                checkedWord: try container.decode(String.self, forKey: .checkedWord),
                candidate: try container.decode(String.self, forKey: .candidate)
            ))
        case .skip:
            self = .skip(KeystrokeTraceDecisionSkip(
                reasonCode: reasonCode,
                path: try container.decodeIfPresent(
                    KeystrokeTraceDecisionPath.self,
                    forKey: .path
                ),
                candidate: try container.decodeIfPresent(String.self, forKey: .candidate),
                fusedScore: try container.decodeIfPresent(Double.self, forKey: .fusedScore),
                rawLMLogProb: try container.decodeIfPresent(
                    Double.self,
                    forKey: .rawLMLogProb
                ),
                typedLiteralRawLMLogProb: try container.decodeIfPresent(
                    Double.self,
                    forKey: .typedLiteralRawLMLogProb
                ),
                typedLiteralLogProbMargin: try container.decodeIfPresent(
                    Double.self,
                    forKey: .typedLiteralLogProbMargin
                ),
                absoluteLogProbFloor: try container.decodeIfPresent(
                    Double.self,
                    forKey: .absoluteLogProbFloor
                ),
                checkedWord: try container.decodeIfPresent(String.self, forKey: .checkedWord),
                expectedWindow: try container.decodeIfPresent(
                    String.self,
                    forKey: .expectedWindow
                ),
                foundWindow: try container.decodeIfPresent(String.self, forKey: .foundWindow)
            ))
        }
    }

    /// Encodes decision fields without an ambiguous synthesized enum wrapper.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .apply(apply):
            try container.encode(Outcome.apply, forKey: .outcome)
            try container.encode(apply.reasonCode, forKey: .reasonCode)
            try container.encodeIfPresent(apply.path, forKey: .path)
            try container.encodeIfPresent(apply.rawLMLogProb, forKey: .rawLMLogProb)
            try container.encodeIfPresent(
                apply.typedLiteralRawLMLogProb,
                forKey: .typedLiteralRawLMLogProb
            )
            try container.encode(apply.beforeText, forKey: .beforeText)
            try container.encode(apply.afterText, forKey: .afterText)
            try container.encode(apply.deleteCount, forKey: .deleteCount)
            try container.encode(apply.insertCount, forKey: .insertCount)
        case let .queued(queued):
            try container.encode(Outcome.queued, forKey: .outcome)
            try container.encode(queued.reasonCode, forKey: .reasonCode)
            try container.encode(queued.checkedWord, forKey: .checkedWord)
            try container.encode(queued.candidate, forKey: .candidate)
        case let .skip(skip):
            try container.encode(Outcome.skip, forKey: .outcome)
            try container.encode(skip.reasonCode, forKey: .reasonCode)
            try container.encodeIfPresent(skip.path, forKey: .path)
            try container.encodeIfPresent(skip.candidate, forKey: .candidate)
            try container.encodeIfPresent(skip.fusedScore, forKey: .fusedScore)
            try container.encodeIfPresent(skip.rawLMLogProb, forKey: .rawLMLogProb)
            try container.encodeIfPresent(
                skip.typedLiteralRawLMLogProb,
                forKey: .typedLiteralRawLMLogProb
            )
            try container.encodeIfPresent(
                skip.typedLiteralLogProbMargin,
                forKey: .typedLiteralLogProbMargin
            )
            try container.encodeIfPresent(skip.absoluteLogProbFloor, forKey: .absoluteLogProbFloor)
            try container.encodeIfPresent(skip.checkedWord, forKey: .checkedWord)
            try container.encodeIfPresent(skip.expectedWindow, forKey: .expectedWindow)
            try container.encodeIfPresent(skip.foundWindow, forKey: .foundWindow)
        }
    }
}

/// State changes emitted by the keyboard and trace store.
public enum KeystrokeTraceStateAction: String, Codable, Equatable {
    case epochBump
    case ringCleared
    case modelLoaded
    case modelUnloaded
    case segmentRolled
}

/// Epoch, ring, model, or segment state transition.
public struct KeystrokeTraceStateEvent: Codable, Equatable {
    public let action: KeystrokeTraceStateAction
    public let epoch: UInt64?
    public let reasonCode: KeystrokeTraceReasonCode?
    public let model: String?
    public let detail: String?

    /// Creates a state transition with optional epoch, reason, and model details.
    public init(
        action: KeystrokeTraceStateAction,
        epoch: UInt64? = nil,
        reasonCode: KeystrokeTraceReasonCode? = nil,
        model: String? = nil,
        detail: String? = nil
    ) {
        self.action = action
        self.epoch = epoch
        self.reasonCode = reasonCode
        self.model = model
        self.detail = detail
    }
}

/// Session and recorder lifecycle metadata kinds.
public enum KeystrokeTraceMetaAction: String, Codable, Equatable {
    case schemaVersion
    case enabled
    case disabled
    case sessionStarted
    case sessionEnded
}

/// Session identity or recorder lifecycle metadata.
public struct KeystrokeTraceMetaEvent: Codable, Equatable {
    public let action: KeystrokeTraceMetaAction
    public let sessionID: String?
    public let attributes: [String: String]?

    /// Creates session metadata or a recorder lifecycle event.
    public init(
        action: KeystrokeTraceMetaAction,
        sessionID: String? = nil,
        attributes: [String: String]? = nil
    ) {
        self.action = action
        self.sessionID = sessionID
        self.attributes = attributes
    }
}

/// Tagged payload for the five line-level event families.
public enum KeystrokeTraceEvent: Equatable, Codable {
    case key(KeystrokeTraceKeyEvent)
    case suggestion(KeystrokeTraceSuggestionEvent)
    case decision(KeystrokeTraceDecisionEvent)
    case state(KeystrokeTraceStateEvent)
    case meta(KeystrokeTraceMetaEvent)

    private enum CodingKeys: String, CodingKey {
        case type
        case payload
    }

    private enum EventType: String, Codable {
        case key
        case suggestion
        case decision
        case state
        case meta
    }

    /// Decodes a tagged payload into its event-specific value type.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(EventType.self, forKey: .type) {
        case .key:
            self = .key(try container.decode(KeystrokeTraceKeyEvent.self, forKey: .payload))
        case .suggestion:
            self = .suggestion(
                try container.decode(KeystrokeTraceSuggestionEvent.self, forKey: .payload)
            )
        case .decision:
            self = .decision(
                try container.decode(KeystrokeTraceDecisionEvent.self, forKey: .payload)
            )
        case .state:
            self = .state(
                try container.decode(KeystrokeTraceStateEvent.self, forKey: .payload)
            )
        case .meta:
            self = .meta(try container.decode(KeystrokeTraceMetaEvent.self, forKey: .payload))
        }
    }

    /// Encodes a compact tagged payload for this event family.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .key(payload):
            try container.encode(EventType.key, forKey: .type)
            try container.encode(payload, forKey: .payload)
        case let .suggestion(payload):
            try container.encode(EventType.suggestion, forKey: .type)
            try container.encode(payload, forKey: .payload)
        case let .decision(payload):
            try container.encode(EventType.decision, forKey: .type)
            try container.encode(payload, forKey: .payload)
        case let .state(payload):
            try container.encode(EventType.state, forKey: .type)
            try container.encode(payload, forKey: .payload)
        case let .meta(payload):
            try container.encode(EventType.meta, forKey: .type)
            try container.encode(payload, forKey: .payload)
        }
    }
}

/// Common NDJSON envelope. `schemaVersion` is present on every encoded record.
public struct KeystrokeTraceRecord: Codable, Equatable {
    public static let currentSchemaVersion = KeystrokeTraceSchema.currentVersion

    public let schemaVersion: Int
    public let timestamp: String
    public let event: KeystrokeTraceEvent

    /// Creates a schema-versioned envelope for one event.
    public init(
        timestamp: String,
        event: KeystrokeTraceEvent,
        schemaVersion: Int = KeystrokeTraceRecord.currentSchemaVersion
    ) {
        self.schemaVersion = schemaVersion
        self.timestamp = timestamp
        self.event = event
    }
}

/// Capture-path boundary at which buffered bytes may be written to disk.
public enum KeystrokeTraceFlushBoundary: Equatable {
    case highWaterMark
    case idle
    case triggerKey
}

/// Byte and event counts for one completed flush.
public struct KeystrokeTraceFlushResult: Equatable {
    public let boundary: KeystrokeTraceFlushBoundary
    public let bytesWritten: Int
    public let eventsWritten: Int
    public let remainingByteCount: Int
}

/// Summary passed to the caller after a successful live-segment rotation.
public struct KeystrokeTraceSegmentRoll: Equatable {
    public let archivedBytes: Int
    public let discardedBytes: Int
    public let totalBytesAfterRoll: Int
}

/// Result of the bounded append operation.
public enum KeystrokeTraceAppendResult: Equatable {
    case appended(
        encodedByteCount: Int,
        evictedByteCount: Int,
        shouldFlushAtHighWaterMark: Bool
    )
    case eventExceedsRingCapacity(encodedByteCount: Int, capacity: Int)
}

/// Failures encountered while initializing or writing the bounded trace store.
public enum KeystrokeTraceCoreError: Error {
    case invalidRingCapacity(Int)
    case invalidTraceDirectory(URL)
    case invalidLineAlignedData
    case segmentFileTooLarge(Int)
    case segmentFileCreationFailed(URL)
    case segmentFileSizeUnavailable(URL)
    case segmentFileReadAndCloseFailed(URL, Error, Error)
    case segmentFileWriteFailed(URL, Error)
    case segmentFileCloseFailed(URL, Error)
    case segmentFileWriteAndCloseFailed(URL, Error, Error)
}

/// Preallocated byte ring. Appends and evictions always preserve complete NDJSON lines.
private final class KeystrokeTraceByteRing {
    private var storage: [UInt8]
    private var readIndex = 0
    private var writeIndex = 0
    private(set) var byteCount = 0

    let capacity: Int

    init(capacity: Int) {
        self.capacity = capacity
        storage = [UInt8](repeating: 0, count: capacity)
    }

    var shouldFlushAtHighWaterMark: Bool {
        byteCount >= capacity * 3 / 4
    }

    func append(_ encodedRecord: Data) -> Int {
        let incomingByteCount = encodedRecord.count + 1
        var evictedByteCount = 0
        while capacity - byteCount < incomingByteCount {
            evictedByteCount += discardFirstLine()
        }

        for byte in encodedRecord {
            storage[writeIndex] = byte
            writeIndex += 1
            if writeIndex == capacity {
                writeIndex = 0
            }
        }
        byteCount += encodedRecord.count
        storage[writeIndex] = 0x0A
        writeIndex += 1
        if writeIndex == capacity {
            writeIndex = 0
        }
        byteCount += 1
        return evictedByteCount
    }

    func discardFirstLine() -> Int {
        guard let lineLength = firstLineLength() else { return 0 }
        for offset in 0..<lineLength {
            storage[(readIndex + offset) % capacity] = 0
        }
        readIndex = (readIndex + lineLength) % capacity
        byteCount -= lineLength
        return lineLength
    }

    func drain() -> Data? {
        guard byteCount > 0 else { return nil }
        var data = Data(capacity: byteCount)
        for offset in 0..<byteCount {
            data.append(byte(at: offset))
        }
        clear()
        return data
    }

    func clear() {
        for index in storage.indices {
            storage[index] = 0
        }
        readIndex = 0
        writeIndex = 0
        byteCount = 0
    }

    private func firstLineLength() -> Int? {
        for offset in 0..<byteCount where byte(at: offset) == 0x0A {
            return offset + 1
        }
        return nil
    }

    private func byte(at offset: Int) -> UInt8 {
        storage[(readIndex + offset) % capacity]
    }
}

/// Owns exactly one live and one rotated file, with a 2 MB limit on each.
private final class KeystrokeTraceSegmentStore {
    private let directoryURL: URL
    private let fileManager: FileManager
    private(set) var liveByteCount: Int
    private(set) var rotatedByteCount: Int
    private var liveEndsWithLineFeed: Bool
    var onSegmentRoll: ((KeystrokeTraceSegmentRoll) -> Void)?

    var liveFileURL: URL {
        directoryURL.appendingPathComponent(KeystrokeTraceSchema.liveFileName)
    }

    var rotatedFileURL: URL {
        directoryURL.appendingPathComponent(KeystrokeTraceSchema.rotatedFileName)
    }

    var totalByteCount: Int {
        liveByteCount + rotatedByteCount
    }

    init(directoryURL: URL, fileManager: FileManager = .default) throws {
        guard directoryURL.isFileURL else {
            throw KeystrokeTraceCoreError.invalidTraceDirectory(directoryURL)
        }
        self.directoryURL = directoryURL
        self.fileManager = fileManager
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: nil
        )
        liveByteCount = try Self.existingSegmentByteCount(
            at: directoryURL.appendingPathComponent(KeystrokeTraceSchema.liveFileName),
            fileManager: fileManager
        )
        liveEndsWithLineFeed = try Self.endsWithLineFeed(
            at: directoryURL.appendingPathComponent(KeystrokeTraceSchema.liveFileName),
            byteCount: liveByteCount
        )
        rotatedByteCount = try Self.existingSegmentByteCount(
            at: directoryURL.appendingPathComponent(KeystrokeTraceSchema.rotatedFileName),
            fileManager: fileManager
        )
    }

    func append(_ line: Data) throws -> KeystrokeTraceSegmentRoll? {
        guard line.count <= KeystrokeTraceSchema.segmentCapacityBytes,
              line.last == 0x0A else {
            throw KeystrokeTraceCoreError.segmentFileTooLarge(line.count)
        }

        reconcileMissingSegments()
        var segmentRoll: KeystrokeTraceSegmentRoll?
        if !liveEndsWithLineFeed, fileManager.fileExists(atPath: liveFileURL.path) {
            segmentRoll = try rotate()
        }
        if liveByteCount + line.count > KeystrokeTraceSchema.segmentCapacityBytes {
            if let capacityRoll = try rotate() {
                segmentRoll = capacityRoll
            }
        }
        liveEndsWithLineFeed = false
        try appendToLiveSegment(line)
        liveByteCount += line.count
        liveEndsWithLineFeed = true
        return segmentRoll
    }

    func removeAll() throws {
        if fileManager.fileExists(atPath: liveFileURL.path) {
            try fileManager.removeItem(at: liveFileURL)
        }
        liveByteCount = 0
        liveEndsWithLineFeed = true
        if fileManager.fileExists(atPath: rotatedFileURL.path) {
            try fileManager.removeItem(at: rotatedFileURL)
        }
        rotatedByteCount = 0
    }

    private func rotate() throws -> KeystrokeTraceSegmentRoll? {
        reconcileMissingSegments()
        guard fileManager.fileExists(atPath: liveFileURL.path) else { return nil }

        let discardedBytes = rotatedByteCount
        if fileManager.fileExists(atPath: rotatedFileURL.path) {
            try fileManager.removeItem(at: rotatedFileURL)
        }
        rotatedByteCount = 0

        if liveByteCount > 0 {
            do {
                try fileManager.moveItem(at: liveFileURL, to: rotatedFileURL)
            } catch {
                guard fileManager.fileExists(atPath: liveFileURL.path) else {
                    liveByteCount = 0
                    liveEndsWithLineFeed = true
                    return nil
                }
                throw error
            }
            rotatedByteCount = liveByteCount
            liveByteCount = 0
        } else if fileManager.fileExists(atPath: liveFileURL.path) {
            try fileManager.removeItem(at: liveFileURL)
        }
        liveEndsWithLineFeed = true

        let segmentRoll = KeystrokeTraceSegmentRoll(
            archivedBytes: rotatedByteCount,
            discardedBytes: discardedBytes,
            totalBytesAfterRoll: totalByteCount
        )
        onSegmentRoll?(segmentRoll)
        return segmentRoll
    }

    private func appendToLiveSegment(_ data: Data) throws {
        if !fileManager.fileExists(atPath: liveFileURL.path) {
            liveByteCount = 0
            liveEndsWithLineFeed = true
            let didCreateFile = fileManager.createFile(
                atPath: liveFileURL.path,
                contents: Data()
            )
            guard didCreateFile || fileManager.fileExists(atPath: liveFileURL.path) else {
                throw KeystrokeTraceCoreError.segmentFileCreationFailed(liveFileURL)
            }
        }

        let handle = try FileHandle(forWritingTo: liveFileURL)
        var writeError: Error?
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            writeError = error
        }

        var closeError: Error?
        do {
            try handle.close()
        } catch {
            closeError = error
        }

        if let writeError, let closeError {
            throw KeystrokeTraceCoreError.segmentFileWriteAndCloseFailed(
                liveFileURL,
                writeError,
                closeError
            )
        }
        if let writeError {
            throw KeystrokeTraceCoreError.segmentFileWriteFailed(liveFileURL, writeError)
        }
        if let closeError {
            throw KeystrokeTraceCoreError.segmentFileCloseFailed(liveFileURL, closeError)
        }
    }

    private func reconcileMissingSegments() {
        if !fileManager.fileExists(atPath: liveFileURL.path) {
            liveByteCount = 0
            liveEndsWithLineFeed = true
        }
        if !fileManager.fileExists(atPath: rotatedFileURL.path) {
            rotatedByteCount = 0
        }
    }

    private static func existingSegmentByteCount(
        at url: URL,
        fileManager: FileManager
    ) throws -> Int {
        guard fileManager.fileExists(atPath: url.path) else { return 0 }
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber else {
            throw KeystrokeTraceCoreError.segmentFileSizeUnavailable(url)
        }
        let byteCount = size.intValue
        if byteCount > KeystrokeTraceSchema.segmentCapacityBytes {
            try fileManager.removeItem(at: url)
            return 0
        }
        return byteCount
    }

    private static func endsWithLineFeed(at url: URL, byteCount: Int) throws -> Bool {
        guard byteCount > 0 else { return true }
        let handle = try FileHandle(forReadingFrom: url)
        do {
            try handle.seek(toOffset: UInt64(byteCount - 1))
            let lastByte = try handle.read(upToCount: 1)
            try handle.close()
            return lastByte?.first == 0x0A
        } catch {
            let readError = error
            do {
                try handle.close()
            } catch {
                throw KeystrokeTraceCoreError.segmentFileReadAndCloseFailed(
                    url,
                    readError,
                    error
                )
            }
            throw readError
        }
    }
}

/// Stateful recorder with a bounded ring and no per-event retained objects.
///
/// Ring access is locked only while copying or appending bytes. Flushes hand a
/// bounded batch to the caller before doing segment I/O, so a capture append
/// never waits for a disk write. The caller serializes segment-store operations.
public final class KeystrokeTraceRecorder: @unchecked Sendable {

    private let ringCapacityBytes: Int
    private let segmentStore: KeystrokeTraceSegmentStore
    private let encoder: JSONEncoder
    private let dateFormatter: ISO8601DateFormatter
    private let flushEncoder: JSONEncoder
    private let flushDateFormatter: ISO8601DateFormatter
    private let ringLock = NSLock()
    private var ring: KeystrokeTraceByteRing?
    private var pendingFlushBatch: Data?
    private var pendingFlushOffset = 0

    /// Called once after each successful segment roll; the core never logs.
    public var onSegmentRoll: ((KeystrokeTraceSegmentRoll) -> Void)? {
        get { segmentStore.onSegmentRoll }
        set { segmentStore.onSegmentRoll = newValue }
    }

    /// Number of bytes currently buffered but not yet written to disk.
    public var unflushedByteCount: Int {
        ringLock.lock()
        defer { ringLock.unlock() }
        let pendingBatchByteCount = (pendingFlushBatch?.count ?? 0) - pendingFlushOffset
        return (ring?.byteCount ?? 0) + pendingBatchByteCount
    }

    /// Indicates that the keyboard may request a high-water flush.
    public var shouldFlushAtHighWaterMark: Bool {
        ringLock.lock()
        defer { ringLock.unlock() }
        return ring?.shouldFlushAtHighWaterMark ?? false
    }

    /// URL of the active trace segment.
    public var liveFileURL: URL {
        segmentStore.liveFileURL
    }

    /// URL of the one retained previous trace segment.
    public var rotatedFileURL: URL {
        segmentStore.rotatedFileURL
    }

    /// Total bytes currently accounted for across both disk segments.
    public var onDiskByteCount: Int {
        segmentStore.totalByteCount
    }

    /// Creates the output directory, validates the ring bound, and retains only bounded segments.
    public init(
        directoryURL: URL,
        ringCapacityBytes: Int = KeystrokeTraceSchema.ringCapacityBytes
    ) throws {
        guard ringCapacityBytes > 0,
              ringCapacityBytes <= KeystrokeTraceSchema.ringCapacityBytes else {
            throw KeystrokeTraceCoreError.invalidRingCapacity(ringCapacityBytes)
        }
        self.ringCapacityBytes = ringCapacityBytes
        segmentStore = try KeystrokeTraceSegmentStore(directoryURL: directoryURL)
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        flushEncoder = JSONEncoder()
        flushEncoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        flushDateFormatter = ISO8601DateFormatter()
        flushDateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    /// Preallocates the bounded ring before the keyboard accepts user input.
    public func prepareForCapture() {
        ringLock.lock()
        defer { ringLock.unlock() }
        if ring == nil {
            ring = KeystrokeTraceByteRing(capacity: ringCapacityBytes)
        }
    }

    /// Encodes one event and appends only its bytes to the in-memory ring.
    @discardableResult
    public func append(
        _ event: KeystrokeTraceEvent,
        timestamp: Date? = nil
    ) throws -> KeystrokeTraceAppendResult {
        let record = KeystrokeTraceRecord(
            timestamp: dateFormatter.string(from: timestamp ?? Date()),
            event: event
        )
        let encodedRecord = try encoder.encode(record)
        let encodedByteCount = encodedRecord.count + 1
        guard encodedByteCount <= ringCapacityBytes else {
            return .eventExceedsRingCapacity(
                encodedByteCount: encodedByteCount,
                capacity: ringCapacityBytes
            )
        }

        ringLock.lock()
        defer { ringLock.unlock() }
        let activeRing: KeystrokeTraceByteRing
        if let ring {
            activeRing = ring
        } else {
            let newRing = KeystrokeTraceByteRing(capacity: ringCapacityBytes)
            ring = newRing
            activeRing = newRing
        }
        let evictedByteCount = activeRing.append(encodedRecord)
        return .appended(
            encodedByteCount: encodedByteCount,
            evictedByteCount: evictedByteCount,
            shouldFlushAtHighWaterMark: activeRing.shouldFlushAtHighWaterMark
        )
    }

    /// Flushes complete records at the caller-selected high-water, idle, or trigger-key boundary.
    @discardableResult
    public func flush(
        at boundary: KeystrokeTraceFlushBoundary
    ) throws -> KeystrokeTraceFlushResult {
        ringLock.lock()
        if pendingFlushBatch == nil {
            pendingFlushBatch = ring?.drain()
            pendingFlushOffset = 0
        }
        let batch = pendingFlushBatch
        var byteOffset = pendingFlushOffset
        ringLock.unlock()

        guard let batch else {
            return KeystrokeTraceFlushResult(
                boundary: boundary,
                bytesWritten: 0,
                eventsWritten: 0,
                remainingByteCount: unflushedByteCount
            )
        }

        var bytesWritten = 0
        var eventsWritten = 0
        var pendingSegmentRolls: [KeystrokeTraceSegmentRoll] = []
        while byteOffset < batch.endIndex {
            guard let lineFeedIndex = batch[byteOffset..<batch.endIndex].firstIndex(of: 0x0A),
                  lineFeedIndex > byteOffset else {
                throw KeystrokeTraceCoreError.invalidLineAlignedData
            }
            let lineEndIndex = batch.index(after: lineFeedIndex)
            let line = Data(batch[byteOffset..<lineEndIndex])
            if let segmentRoll = try segmentStore.append(line) {
                pendingSegmentRolls.append(segmentRoll)
            }
            byteOffset = lineEndIndex
            ringLock.lock()
            pendingFlushOffset = byteOffset
            ringLock.unlock()
            bytesWritten += line.count
            eventsWritten += 1
        }

        ringLock.lock()
        pendingFlushBatch = nil
        pendingFlushOffset = 0
        ringLock.unlock()

        while !pendingSegmentRolls.isEmpty {
            let completedSegmentRolls = pendingSegmentRolls
            pendingSegmentRolls.removeAll(keepingCapacity: true)
            for segmentRoll in completedSegmentRolls {
                let line = try encodeSegmentRollEvent(segmentRoll)
                if let subsequentRoll = try segmentStore.append(line) {
                    pendingSegmentRolls.append(subsequentRoll)
                }
                bytesWritten += line.count
                eventsWritten += 1
            }
        }

        return KeystrokeTraceFlushResult(
            boundary: boundary,
            bytesWritten: bytesWritten,
            eventsWritten: eventsWritten,
            remainingByteCount: unflushedByteCount
        )
    }

    /// Appends already-encoded, LF-terminated records without re-encoding them.
    ///
    /// This uses the same bounded segment store as capture so received records
    /// keep their original bytes and the same rotation limits.
    public func appendLineAlignedData(_ data: Data) throws {
        guard !data.isEmpty, data.last == 0x0A else {
            throw KeystrokeTraceCoreError.invalidLineAlignedData
        }

        var lineStart = data.startIndex
        for index in data.indices where data[index] == 0x0A {
            guard index > lineStart else {
                throw KeystrokeTraceCoreError.invalidLineAlignedData
            }
            let lineEnd = data.index(after: index)
            let lineByteCount = data.distance(from: lineStart, to: lineEnd)
            guard lineByteCount <= KeystrokeTraceSchema.segmentCapacityBytes else {
                throw KeystrokeTraceCoreError.segmentFileTooLarge(lineByteCount)
            }
            lineStart = lineEnd
        }
        guard lineStart == data.endIndex else {
            throw KeystrokeTraceCoreError.invalidLineAlignedData
        }

        lineStart = data.startIndex
        for index in data.indices where data[index] == 0x0A {
            let lineEnd = data.index(after: index)
            _ = try segmentStore.append(Data(data[lineStart..<lineEnd]))
            lineStart = lineEnd
        }
    }

    private func encodeSegmentRollEvent(_ segmentRoll: KeystrokeTraceSegmentRoll) throws -> Data {
        let detail = "archivedBytes=\(segmentRoll.archivedBytes);" +
            "discardedBytes=\(segmentRoll.discardedBytes);" +
            "totalBytesAfterRoll=\(segmentRoll.totalBytesAfterRoll)"
        let record = KeystrokeTraceRecord(
            timestamp: flushDateFormatter.string(from: Date()),
            event: .state(
                KeystrokeTraceStateEvent(action: .segmentRolled, detail: detail)
            )
        )
        var line = try flushEncoder.encode(record)
        line.append(0x0A)
        return line
    }

    /// Removes both segments and zeroes pending memory.
    public func clear() throws {
        ringLock.lock()
        ring?.clear()
        pendingFlushBatch = nil
        pendingFlushOffset = 0
        ringLock.unlock()
        try segmentStore.removeAll()
    }
}

/// Returns only newline-terminated records, ignoring a possibly torn final write.
public enum KeystrokeTraceSegmentReader {
    /// Returns complete LF-terminated lines and ignores an incomplete trailing line.
    public static func completeLines(from data: Data) -> [Data] {
        var lines: [Data] = []
        var lineStart = 0
        for (offset, byte) in data.enumerated() where byte == 0x0A {
            if offset > lineStart {
                lines.append(data.subdata(in: lineStart..<offset))
            }
            lineStart = offset + 1
        }
        return lines
    }

    /// Reads a trace segment while tolerating a truncated final record.
    public static func readCompleteLines(from fileURL: URL) throws -> [Data] {
        completeLines(from: try Data(contentsOf: fileURL))
    }
}
