import Foundation

struct SharedConfig {
    struct Defaults {
        static let baseUrl = "http://100.107.181.45:5000"
        static let timeoutSeconds: TimeInterval = 30.0
        /// The original (unsuffixed) app-group identifier declared in our entitlements.
        /// Used as the base identifier for runtime resolution.
        /// Under App Store / TrollStore / Simulator installs, this is the actual identifier.
        /// Under SideStore, this gets team-suffixed at resign time.
        static let originalAppGroupId = "group.com.ritoras.app"

        /// Resolves the actual app-group identifier at runtime, accounting for
        /// SideStore's resign-time identifier rewriting. Result is cached for the
        /// lifetime of the process. All callers of `appGroupId` automatically benefit.
        static var appGroupId: String {
            AppGroupResolver.shared.resolve()
        }
        static let urlScheme = "ritoras"
        static let dictateURLPath = "dictate"
        static let darwinNotificationName = "com.ritoras.dictationCompleted"
        static let darwinStateChangedNotificationName = "com.ritoras.dictationStateChanged"
        static let localhostServerPort: UInt16 = 47321
        static let dictationPayloadKey = "dictation.payload"
        /// UX-guard timeout for the keyboard extension's return-to-idle.
        /// Not a correctness timeout — the localhost fallback chain handles
        /// keyboard return-to-idle. Set to AsyncTranscription.totalDeadline
        /// so the keyboard stays alive long enough for async transcription.
        static let dictationTimeoutSeconds: TimeInterval = AsyncTranscription.totalDeadline
        static let backspaceInitialRepeatDelay: TimeInterval = 0.5
        static let backspaceCharRepeatInterval: TimeInterval = 0.1
        static let backspaceCharsBeforeWordMode: Int = 22
        static let backspaceWordRepeatInterval: TimeInterval = 0.35
        static let backspaceWordCharInterval: TimeInterval = 0.015   // 15ms per char while spreading a word's deletes
        static let backspaceNilContextRetryLimit: Int = 3
        static let backspaceNilContextRetryInterval: TimeInterval = 0.15
        static let backspaceStaleHasTextRetryLimit: Int = 3
        static let backspaceStaleHasTextRetryInterval: TimeInterval = 0.05  // 50ms — tighter than nil-context (150ms); on user-perceptible tap path; total max added latency 150ms
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

        /// Beta for QWERTY-geometry-aware scoring: score = exp(-beta * weightedDistance).
        /// Higher = sharper falloff with key distance. 1.5 ≈ adjacent-key score 0.7, far-key score 0.3.
        static let qwertyDistanceBeta: Double = 1.5
        /// Discount applied when the edit is a doubled-letter insertion/deletion (recieve→receive).
        static let qwertyDoublingDiscount: Double = 0.5
        /// Discount applied when the edit is a transposition of adjacent letters (teh→the).
        static let qwertyTranspositionDiscount: Double = 0.7

        // MARK: - UITextChecker Spellcheck

        /// Language tag passed to `UITextChecker` APIs. Matches `PrimaryLanguage`
        /// in `keyboard/Info.plist`.
        static let appleSpellCheckerLanguage = "en-US"

        // MARK: - Trigram Prediction Tunables

        /// Weight for forward-compat interpolation (currently unused — empty-prefix
        /// uses raw trigram, not interpolated).
        static let trigramWeight: Double = 0.7

        /// Score multiplier applied when a mid-word candidate from another provider
        /// is also a common trigram follower of the previous context.
        static let trigramBoostFactor: Double = 1.4

        /// Minimum score floor for trigram suggestions to avoid near-zero noise.
        static let trigramReadyMinScore: Double = 0.05

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

        // MARK: - Haptics

        static let hapticsEnabledKey = "hapticsEnabled"
        static let hapticsEnabledDefault = true

        // MARK: - Verbose Logging

        static let verboseLoggingKey = "verboseLogging"
        static let verboseLoggingDefault = false

        // MARK: - Server Selection (Health Probe)

        /// Ephemeral App Group key holding the probe-selected server URL for the
        /// current/next dictation. Written by the container app's DictationViewModel
        /// on probe completion; read by the keyboard extension's poll path. Not a
        /// durable user preference — overwritten by each probe, never cleared on
        /// cancel (stale value is the best guess for the next dictation).
        static let selectedServerKey = "selectedServer"

        /// Per-server health-probe timeout. 3s balances false-negative risk on slow
        /// LANs/Tailscale against the user's failure-tolerance for offline servers.
        static let serverProbeTimeoutSeconds: TimeInterval = 3.0
    }

    // MARK: - Async Transcription

    enum AsyncTranscription {
        /// Recordings longer than this use the async POST /transcriptions path.
        static let longAudioThresholdSeconds: TimeInterval = 30
        /// Poll cadence while the job is in-flight (SERVER-CONTRACT §12 recommends 500–1000 ms).
        static let pollInterval: TimeInterval = 1.0
        /// Hard ceiling on total wait. Server retains jobs ≥10 min (§12); 15 min covers slow CPU + retry.
        static let totalDeadline: TimeInterval = 900
        /// Per-poll request timeout — short, because each poll is a tiny JSON GET.
        static let pollRequestTimeout: TimeInterval = 10
    }

    // MARK: - Recording

    enum Recording {
        /// Relative path for recording audio files inside the app-group container.
        static let directoryName = "Shared/recordings"
        /// Delete recordings older than this (matched against file modification time).
        /// 24h bounds worst-case disk usage.
        static let retention: TimeInterval = 86_400
    }

    // MARK: - Recovery (Phase 4)

    public enum Recovery {
        /// Auto-retry failed-but-recoverable transcriptions on app launch. Opt-in.
        public static let autoRetryOnLaunch = false
        /// Maximum auto-retry attempts per failed record.
        public static let maxAutoRetries = 2
        /// Backoff between auto-retry attempts.
        public static let retryBackoffSeconds: TimeInterval = 30
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

    /// Reads the verbose-logging enabled flag from the App Group.
    /// Used by FileLogger to gate `.debug`-level writes from both the host app
    /// and the keyboard extension. Returns the default (`false`) when the App
    /// Group is unavailable or the key is unset.
    static func verboseLoggingEnabled() -> Bool {
        guard let defaults = UserDefaults(suiteName: Defaults.appGroupId) else {
            return Defaults.verboseLoggingDefault
        }
        return (defaults.object(forKey: Defaults.verboseLoggingKey) as? Bool)
            ?? Defaults.verboseLoggingDefault
    }

    /// Reads the haptics enabled flag from the App Group.
    /// Used by the keyboard extension, which cannot link `AppSettings`.
    /// Returns the default (`true`) when the App Group is unavailable or the key is unset.
    static func hapticsEnabled() -> Bool {
        guard let defaults = UserDefaults(suiteName: Defaults.appGroupId) else {
            return Defaults.hapticsEnabledDefault
        }
        return (defaults.object(forKey: Defaults.hapticsEnabledKey) as? Bool)
            ?? Defaults.hapticsEnabledDefault
    }

    /// Reads the probe-selected server URL for the current/next dictation.
    /// Used by the keyboard extension to decide where to poll for results.
    /// Returns nil when the App Group is unavailable or no probe has run yet.
    /// The caller MUST validate the returned value is still in `servers` before
    /// using it, in case the user removed the server from Settings after the probe.
    static func selectedServer() -> String? {
        guard let defaults = UserDefaults(suiteName: Defaults.appGroupId) else { return nil }
        return defaults.string(forKey: Defaults.selectedServerKey)
    }

    /// Writes (or clears) the probe-selected server URL. Called by the container
    /// app's DictationViewModel when the parallel health probe completes. Passing
    /// nil removes the key.
    /// NOTE: this is the only *writer* on SharedConfig — justified because
    /// selectedServer is ephemeral runtime state, not a durable preference.
    static func setSelectedServer(_ server: String?) {
        guard let defaults = UserDefaults(suiteName: Defaults.appGroupId) else { return }
        if let server = server {
            defaults.set(server, forKey: Defaults.selectedServerKey)
        } else {
            defaults.removeObject(forKey: Defaults.selectedServerKey)
        }
    }
}

// MARK: - AppGroupResolver

/// Runtime resolver for the app-group identifier.
///
/// Under SideStore, the binary's app-group entitlement is rewritten at resign
/// time from `group.com.ritoras.app` to `group.com.ritoras.app.<TeamID>`.
/// Calling `FileManager.containerURL(forSecurityApplicationGroupIdentifier:)`
/// with the original (unsuffixed) identifier returns nil under SideStore.
///
/// This resolver tries multiple strategies to find a working identifier:
///   1. The original unsuffixed identifier (works on App Store / TrollStore / Simulator)
///   2. A team-suffixed identifier constructed from the bundle ID's TeamID suffix
///   3. The actual app-group string from `embedded.mobileprovision` (most authoritative)
///
/// The first strategy that returns a non-nil containerURL wins. The result is
/// cached for the lifetime of the process.
///
/// IMPORTANT: This resolver uses NSLog (not FileLogger) internally because
/// FileLogger itself depends on the resolved identifier. Using FileLogger here
/// would cause infinite recursion.
final class AppGroupResolver {
    static let shared = AppGroupResolver()
    private init() {}

    private let lock = NSLock()
    private var cached: String?

    func resolve() -> String {
        lock.lock()
        defer { lock.unlock() }

        if let cached = cached {
            return cached
        }

        let original = SharedConfig.Defaults.originalAppGroupId
        let result = performResolution(original: original)
        cached = result
        return result
    }

    private func performResolution(original: String) -> String {
        let bundleId = Bundle.main.bundleIdentifier ?? "<nil>"

        // Strategy 1: original unsuffixed identifier.
        // Works on App Store, TrollStore, Simulator, and any environment that
        // doesn't rewrite entitlements.
        if FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: original) != nil {
            NSLog("AppGroupResolver: strategy=original-identifier identifier=\(original) bundleId=\(bundleId)")
            return original
        }

        // Strategy 2: construct team-suffixed identifier from bundle ID.
        // Under SideStore, the bundle ID gets the TeamID appended (e.g.,
        // com.ritoras.app.64GGL77Z3X). The same TeamID is appended to app-group
        // identifiers in the same resign operation.
        if let teamId = extractTeamIdFromBundleId(bundleId) {
            let suffixed = "\(original).\(teamId)"
            if FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: suffixed) != nil {
                NSLog("AppGroupResolver: strategy=bundle-id-suffix identifier=\(suffixed) teamId=\(teamId) bundleId=\(bundleId)")
                return suffixed
            }
            NSLog("AppGroupResolver: bundle-id-suffix attempted but containerURL nil identifier=\(suffixed) bundleId=\(bundleId)")
        } else {
            NSLog("AppGroupResolver: no TeamID suffix detected in bundleId=\(bundleId)")
        }

        // Strategy 3: read embedded.mobileprovision and extract the actual
        // app-group string. This is the most authoritative source because it
        // reads the binary's signed entitlements directly.
        if let fromProvision = readFromMobileProvision() {
            NSLog("AppGroupResolver: strategy=mobileprovision identifier=\(fromProvision) bundleId=\(bundleId)")
            return fromProvision
        }

        // All strategies failed. Log loudly and return the original identifier
        // so the app still functions (in degraded, pre-fix mode — same as today).
        // The user will see this in the system log via NSLog.
        NSLog("AppGroupResolver: ⚠️ ALL STRATEGIES FAILED — falling back to original identifier. bundleId=\(bundleId)")
        return original
    }

    /// Extracts the TeamID suffix from a bundle ID.
    /// SideStore rewrites `com.ritoras.app` → `com.ritoras.app.64GGL77Z3X`.
    /// Returns the suffix (`64GGL77Z3X`) or nil if the bundle ID doesn't have
    /// a suffix matching the expected pattern (uppercase alphanumeric).
    private func extractTeamIdFromBundleId(_ bundleId: String) -> String? {
        let parts = bundleId.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        let suffix = String(parts.last!)
        // TeamID is a 10-character alphanumeric string (uppercase letters + digits).
        // Validate format to avoid false positives (e.g., a non-SideStore bundle
        // that happens to have a 4th segment).
        guard suffix.count >= 8 && suffix.count <= 12 else { return nil }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        guard suffix.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        return suffix
    }

    /// Reads `embedded.mobileprovision` from the app bundle and extracts the
    /// app-group identifier. The file is CMS-signed but contains an XML plist
    /// inside the binary wrapper. We use `.isoLatin1` encoding (which maps every
    /// byte 1:1 — never fails on binary data, unlike `.ascii`).
    /// Returns the first app-group identifier found, or nil if anything fails.
    private func readFromMobileProvision() -> String? {
        guard let profileURL = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: profileURL),
              let raw = String(data: data, encoding: .isoLatin1),
              let xmlStart = raw.range(of: "<?xml"),
              let xmlEnd = raw.range(of: "</plist>"),
              let plistData = String(raw[xmlStart.lowerBound..<xmlEnd.upperBound]).data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil) as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any],
              let appGroups = entitlements["com.apple.security.application-groups"] as? [String],
              !appGroups.isEmpty else {
            return nil
        }

        // Prefer the first identifier that actually resolves to a container.
        // If none resolve (e.g., SideStore stripped the entitlement entirely),
        // return the first string anyway — caller will see containerURL nil.
        for group in appGroups {
            if FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) != nil {
                return group
            }
        }
        return appGroups.first
    }
}
