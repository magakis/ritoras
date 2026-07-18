import Foundation

struct SharedConfig {
    struct Defaults {
        static let baseUrl = "http://100.107.181.45:5000"
        static let timeoutSeconds: TimeInterval = 30.0
        static let appGroupId = "group.com.ritoras.app"
        static let urlScheme = "ritoras"
        static let dictateURLPath = "dictate"
        static let darwinNotificationName = "com.ritoras.dictationCompleted"
        static let dictationPayloadKey = "dictation.payload"
        static let dictationTimeoutSeconds: TimeInterval = 30
        static let backspaceInitialRepeatDelay: TimeInterval = 0.5
        static let backspaceCharRepeatInterval: TimeInterval = 0.1
        static let backspaceCharsBeforeWordMode: Int = 22
        static let backspaceWordRepeatInterval: TimeInterval = 0.35
        static let backspaceWordCharInterval: TimeInterval = 0.015   // 15ms per char while spreading a word's deletes
        static let backspaceNilContextRetryLimit: Int = 3
        static let backspaceNilContextRetryInterval: TimeInterval = 0.15
        static var dictateURL: URL { URL(string: "\(urlScheme)://\(dictateURLPath)")! }

        // MARK: - Auto-Capitalization

        static let autoCapitalizationEnabledKey = "autoCapitalizationEnabled"
        static let autoCapitalizationEnabledDefault = true

        // MARK: - Dictation Mode

        static let dictationModeKey = "dictationMode"
        static let dictationModeDefault: DictationMode = .batch

        // MARK: - Streaming / VAD Tunables

        /// RMS threshold for VAD speech detection. Higher = less sensitive.
        static let streamVadSpeechRms: Float = 0.02
        /// Silence duration (ms) before a chunk is finalized.
        static let streamVadSilenceMs: Int = 600
        /// Minimum speech duration (ms) to accept a chunk.
        static let streamVadMinSpeechMs: Int = 300
        /// Maximum audio segment length before forced chunk finalization.
        static let streamMaxChunkSeconds: TimeInterval = 8.0
        /// WebSocket connection timeout.
        static let streamWsConnectTimeout: TimeInterval = 8.0
        /// How long to wait for a final transcription after the last audio chunk.
        static let streamFinalTimeout: TimeInterval = 30.0

        // MARK: - SymSpell / Prediction Tunables

        /// Maximum edit distance for SymSpell fuzzy correction.
        static let symspellMaxEditDistance = 2
        /// Prefix length for SymSpell delete generation.
        static let symspellPrefixLength = 7
        /// Internal limit per provider before merging/deduping.
        static let providerResultLimit = 8

        // MARK: - UITextChecker Spellcheck

        /// Language tag passed to `UITextChecker` APIs. Matches `PrimaryLanguage`
        /// in `keyboard/Info.plist`.
        static let appleSpellCheckerLanguage = "en-US"

        // MARK: - Bigram Prediction Tunables

        /// Minimum bigram count to include in the prediction map. Bigrams with
        /// fewer occurrences are pruned to reduce memory pressure. 5 cuts to
        /// ~80–120k entries (~4 MB).
        static let bigramMinCount = 5

        /// Score multiplier applied when a candidate from another provider is
        /// also a common bigram follower of the previous word.
        static let bigramBoostFactor = 1.3

        // MARK: - Memory Management

        /// Maximum resident bytes allowed during dictionary load (default ~35 MB).
        /// If the process exceeds this during `WordListLoader.loadStreamed`, the
        /// load is aborted and a warning is logged. The engine still marks itself
        /// ready with whatever partial vocabulary was loaded.
        static let maxResidentBytesDuringLoad: UInt64 = 35 * 1024 * 1024

        // MARK: - Autocorrect-on-Space

        /// Minimum character count for a typed word to be considered for autocorrect.
        static let autocorrectMinWordLength: Int = 2

        /// Maximum character count for a typed word to be considered for autocorrect.
        /// UITextChecker has a ~25-char practical cap.
        static let autocorrectMaxWordLength: Int = 25

        /// Minimum score (0.0–1.0) a suggestion must reach to be auto-applied.
        /// Apple guesses = 0.85, Apple completions = 0.6, SymSpell varies.
        /// 0.7 trusts Apple guesses + high-frequency SymSpell hits, ignores completions.
        static let autocorrectMinConfidenceScore: Double = 0.7

        /// Trailing-punctuation characters that, when typed, trigger autocorrect
        /// evaluation of the immediately-preceding word — same as space/return.
        /// Apostrophes deliberately excluded (mid-word for contractions).
        static let autocorrectTriggerPunctuation: Set<String> = [".", ",", "!", "?", ";", ":"]

        // Used by the Auto-Correction settings toggle in the container app.
        static let autocorrectOnSpaceEnabledKey = "autocorrectOnSpaceEnabled"
        static let autocorrectOnSpaceEnabledDefault = true
    }

    // MARK: - Dictation Mode

    enum DictationMode: String, CaseIterable {
        case batch
        case stream
    }

    let servers: [String]
    let timeoutSeconds: TimeInterval

    static func load() -> SharedConfig {
        if let suiteDefaults = UserDefaults(suiteName: Defaults.appGroupId) {
            let servers: [String]
            if let data = suiteDefaults.data(forKey: "servers"),
               let decoded = try? JSONDecoder().decode([String].self, from: data)
            {
                servers = decoded
            } else {
                servers = [Defaults.baseUrl]
            }

            return SharedConfig(
                servers: servers,
                timeoutSeconds: suiteDefaults.object(forKey: "timeoutSeconds") as? TimeInterval ?? Defaults.timeoutSeconds
            )
        }
        return SharedConfig(
            servers: [Defaults.baseUrl],
            timeoutSeconds: Defaults.timeoutSeconds
        )
    }

    /// Reads the dictation mode from the App Group.
    /// Used by the keyboard extension, which cannot link `AppSettings`.
    /// Returns `.batch` when the App Group is unavailable or the key is unset.
    static func dictationMode() -> DictationMode {
        guard let defaults = UserDefaults(suiteName: Defaults.appGroupId) else {
            return Defaults.dictationModeDefault
        }
        guard let raw = defaults.string(forKey: Defaults.dictationModeKey) else {
            return Defaults.dictationModeDefault
        }
        return DictationMode(rawValue: raw) ?? Defaults.dictationModeDefault
    }

    /// Reads the auto-capitalization enabled flag from the App Group.
    /// Used by the keyboard extension, which cannot link `AppSettings`.
    /// Returns the default (`true`) when the App Group is unavailable or the key is unset.
    static func autoCapitalizationEnabled() -> Bool {
        guard let defaults = UserDefaults(suiteName: Defaults.appGroupId) else {
            return Defaults.autoCapitalizationEnabledDefault
        }
        return (defaults.object(forKey: Defaults.autoCapitalizationEnabledKey) as? Bool)
            ?? Defaults.autoCapitalizationEnabledDefault
    }

    /// Reads the autocorrect-on-space enabled flag from the App Group.
    /// Used by the keyboard extension, which cannot link `AppSettings`.
    /// Returns the default (`true`) when the App Group is unavailable or the key is unset.
    static func autocorrectOnSpaceEnabled() -> Bool {
        guard let defaults = UserDefaults(suiteName: Defaults.appGroupId) else {
            return Defaults.autocorrectOnSpaceEnabledDefault
        }
        return (defaults.object(forKey: Defaults.autocorrectOnSpaceEnabledKey) as? Bool)
            ?? Defaults.autocorrectOnSpaceEnabledDefault
    }
}
