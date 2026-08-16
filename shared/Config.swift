import Foundation

struct SharedConfig {
    struct Defaults {
        static let baseUrl = "http://100.107.181.45:5000"
        static let timeoutSeconds: TimeInterval = 20.0
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
        static let darwinStateChangedNotificationName = "com.ritoras.dictationStateChanged"
        static let darwinSettingsChangedNotificationName = "com.ritoras.settingsChanged"
        static let learnedWordsPasteboardName = "com.ritoras.learnedWordsSync"
        static let learnedWordsPasteboardType = "com.ritoras.learnedwords"
        static let darwinLearnedWordsChangedNotificationName = "com.ritoras.learnedWordsChanged"
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
        static var dictateURL: URL { URL(string: "\(urlScheme)://\(dictateURLPath)")! }

        // MARK: - Auto-Capitalization

        static let autoCapitalizationEnabledKey = "autoCapitalizationEnabled"
        static let autoCapitalizationEnabledDefault = true

        // MARK: - Dictation Mode

        static let dictationModeKey = "dictationMode"
        static let dictationModeDefault: DictationMode = .batch

        // MARK: - Streaming / VAD Tunables

        /// RMS threshold for VAD speech detection. Higher = less sensitive.
        static let streamVadSpeechRmsKey = "streamVadSpeechRms"
        static let streamVadSpeechRmsDefault: Float = 0.025
        /// Silence duration (ms) before a chunk is finalized (~3 s).
        static let streamVadSilenceMsKey = "streamVadSilenceMs"
        static let streamVadSilenceMsDefault: Int = 3000
        /// Minimum speech duration (ms) to accept a chunk.
        static let streamVadMinSpeechMsKey = "streamVadMinSpeechMs"
        static let streamVadMinSpeechMsDefault: Int = 300
        /// Minimum total chunk length (speech + silence, ms) before a chunk can be sent.
        static let streamVadMinChunkMsKey = "streamVadMinChunkMs"
        static let streamVadMinChunkMsDefault: Int = 300
        /// Discard buffered audio if no speech is detected within this window (seconds).
        static let streamVadMaxNoiseSecKey = "streamVadMaxNoiseSec"
        static let streamVadMaxNoiseSecDefault: Double = 6.0
        /// WebSocket connection timeout.
        static let streamWsConnectTimeout: TimeInterval = 8.0
        /// How long to wait for a final transcription after the last audio chunk.
        static let streamFinalTimeout: TimeInterval = 30.0
        /// Application-level PING interval; must stay under nginx idle (~60s). Resets the server 600s recv timer and keeps NAT/nginx alive.
        static let streamKeepaliveIntervalSeconds: TimeInterval = 25.0

        /// PING cadence (seconds) for stream liveness monitoring. A busy server answers
        /// PING→PONG immediately, so this detects a dead server without false-timing-out
        /// a long transcription.
        static let streamHealthCheckInterval: TimeInterval = 5.0
        /// Consecutive health-check intervals with no activity (PONG or partial) before
        /// declaring the stream dead. 3 × 5s ≈ 15s tolerance for transient latency.
        static let streamMaxMissedPongs: Int = 3

        /// Backoff intervals (seconds) between chunk send retries.
        /// The last value is the cap for all subsequent retries.
        /// Retry is unbounded while recording is active; terminal failure
        /// is determined at stop time if the queue is not fully drained.
        static let streamChunkRetryBackoffSeconds: [TimeInterval] = [1.0, 2.0, 5.0]

        // MARK: - SymSpell / Prediction Tunables

        /// Maximum edit distance for SymSpell fuzzy correction.
        static let symspellMaxEditDistance = 2
        /// Prefix length for SymSpell delete generation.
        static let symspellPrefixLength = 7
        /// Minimum frequency for a dictionary word to be loaded into SymSpell/Trie.
        /// Words below this count are skipped to cut the index + trie footprint under
        /// the 48 MB Jetsam cap. Tuned via the scripts/prediction-sim precision/recall
        /// harness: at 1500, recall loses 1.2pp (12.7% → 11.5%) vs the unpruned
        /// baseline while pruning 53.7% of the 49,999-word dictionary (~26,800 words).
        /// Increase for more aggressive pruning (less memory, more recall loss);
        /// decrease for more coverage.
        static let symspellMinWordFreq: Int64 = 1500
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

        /// Blend weight for KenLM contextual scoring of mid-word candidates.
        /// 0.0 = pure SymSpell/Apple scores, 1.0 = pure KenLM contextual probability.
        /// Applied after min-max normalization of log probs across the candidate pool.
        /// Tuned by the prediction-sim parameter sweep (Phase 5). The sweep tested
        /// α ∈ {0.3, 0.4, 0.5, 0.6} and confirmed 0.5 is directionally optimal.
        /// Final calibration confirmed on-device (the JS port lacks Apple/QWERTY).
        static let kenlmBlendWeight: Double = 0.5

        /// Minimum score floor for trigram suggestions to avoid near-zero noise.
        static let trigramReadyMinScore: Double = 0.05

        // MARK: - Memory Management

        /// Maximum phys_footprint (private dirty memory) allowed during dictionary load.
        /// Measured via task_vm_info.phys_footprint — same metric iOS Jetsam uses for the
        /// 48 MB keyboard-extension cap. ~25 MB is SymSpell alone, so 40 MB gives headroom
        /// while staying 8 MB under Jetsam. If exceeded during loadStreamed, the load is
        /// aborted and a warning logged; the engine still marks itself ready with whatever
        /// partial vocabulary was loaded.
        static let maxPhysFootprintDuringLoad: UInt64 = 40 * 1024 * 1024

        /// Load guard for the KenLM trigram model ONLY. The enforced ceiling on the
        /// extension is the ~48 MB Jetsam cap; the model adds ~8–10 MB on top of the
        /// pre-load footprint, so a 38 MB pre-load gate keeps the post-load peak at
        /// ≤ ~48 MB. Steady-state footprint after the dictionary loads is 38–43 MB,
        /// so the trigram loads whenever there is headroom under the cap. Trade-off:
        /// after a memory-warning shed (footprint near/above 38 MB) the reload may
        /// defer, which degrades gracefully — the provider resets to `.cold`, the next
        /// `suggest()` retries (throttled to at most one attempt per 30 s), and
        /// suggestions fall back to the SymSpell+Apple fusion without the LM between
        /// attempts.
        static let trigramMaxPhysFootprintDuringLoad: UInt64 = 38 * 1024 * 1024

        // MARK: - Autocorrect-on-Space

        /// Minimum character count for a typed word to be considered for autocorrect.
        static let autocorrectMinWordLength: Int = 2

        /// Maximum character count for a typed word to be considered for autocorrect.
        /// UITextChecker has a ~25-char practical cap.
        static let autocorrectMaxWordLength: Int = 25

        /// Minimum score (0.0–1.0) a suggestion must reach to be auto-applied.
        /// Apple guesses = 0.85, Apple completions = 0.6, SymSpell varies.
        /// 0.7 trusts Apple guesses + high-frequency SymSpell hits, ignores completions.
        /// Tuned by the prediction-sim parameter sweep (Phase 5). The sweep tested
        /// unfusedThreshold ∈ {0.65, 0.70, 0.75} and confirmed 0.70 is directionally
        /// optimal. No tested combination achieved ≥95% precision — final calibration
        /// on-device with Apple/QWERTY is required to reach that target.
        static let autocorrectMinConfidenceScore: Double = 0.7

        /// Two-tier autocorrect threshold: used when KenLM fusion is active
        /// (previous word present AND trigram .ready). Lower than the baseline because
        /// contextual re-scoring improves candidate quality.
        /// Tuned by the prediction-sim parameter sweep (Phase 5). The sweep tested
        /// fusedThreshold ∈ {0.60, 0.65, 0.70} and confirmed 0.65 is directionally optimal.
        static let autocorrectMinConfidenceScoreFused: Double = 0.65

        /// Absolute KenLM log10-probability floor for the autocorrect path. Candidates
        /// below this are rejected even if min-max normalization inflated their score.
        /// -8.0 ≈ probability 1e-8. Tuned by the prediction-sim parameter sweep (Phase 5).
        /// The sweep tested floor ∈ {-6.0, -8.0, -10.0, off} and confirmed -8.0
        /// provides the best trade-off between blocking implausible candidates and
        /// allowing valid context-driven corrections.
        static let kenlmAutocorrectAbsoluteLogProbFloor: Double = -8.0

        /// Minimum KenLM log10-probability advantage the contraction form must hold
        /// over the typed literal before an ambiguous contraction ("its" → "it's")
        /// is auto-applied. 1.0 ≈ e^1 ≈ 2.7× probability ratio. The default is a
        /// conservative starting point; calibrate on-device like the other KenLM
        /// tunables.
        static let ambiguousContractionLogProbMargin: Double = 1.0

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

        /// Per-server health-probe timeout. 5s balances false-negative risk on slow
        /// LANs/Tailscale against the user's failure-tolerance for offline servers.
        static let serverProbeTimeoutSeconds: TimeInterval = 3.0
    }

    // MARK: - Async Transcription

    enum AsyncTranscription {
        /// Two-tier poll cadence: first `initialPollCount` polls at `initialPollInterval`
        /// for quick job-detection, then reverts to `pollInterval` for the remaining duration.
        /// ±10% jitter is applied at the call site (WhisperClient.swift Phase 2).
        static let initialPollInterval: TimeInterval = 0.5
        static let initialPollCount: Int = 10
        /// Baseline poll cadence while the job is in-flight (SERVER-CONTRACT §12 recommends 500–1000 ms).
        static let pollInterval: TimeInterval = 1.0
        /// Hard ceiling on total wait. Server retains jobs ≥10 min (§13) with
        /// STREAM_RECV_TIMEOUT=600s, so 600s matches the server's own window.
        static let totalDeadline: TimeInterval = 600
        /// Per-poll request timeout — short, because each poll is a tiny JSON GET.
        static let pollRequestTimeout: TimeInterval = 5
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

    /// Reads the streaming VAD speech RMS threshold from the App Group.
    /// Used by the keyboard extension, which cannot link `AppSettings`.
    /// Returns the default (`0.025`) when the App Group is unavailable or the key is unset.
    static func streamVadSpeechRms() -> Float {
        guard let defaults = UserDefaults(suiteName: Defaults.appGroupId) else {
            return Defaults.streamVadSpeechRmsDefault
        }
        return (defaults.object(forKey: Defaults.streamVadSpeechRmsKey) as? Float)
            ?? Defaults.streamVadSpeechRmsDefault
    }

    /// Reads the streaming VAD silence threshold (ms) from the App Group.
    /// Used by the keyboard extension, which cannot link `AppSettings`.
    /// Returns the default (`2500`) when the App Group is unavailable or the key is unset.
    static func streamVadSilenceMs() -> Int {
        guard let defaults = UserDefaults(suiteName: Defaults.appGroupId) else {
            return Defaults.streamVadSilenceMsDefault
        }
        return (defaults.object(forKey: Defaults.streamVadSilenceMsKey) as? Int)
            ?? Defaults.streamVadSilenceMsDefault
    }

    /// Reads the streaming VAD minimum speech duration (ms) from the App Group.
    /// Used by the keyboard extension, which cannot link `AppSettings`.
    /// Returns the default (`300`) when the App Group is unavailable or the key is unset.
    static func streamVadMinSpeechMs() -> Int {
        guard let defaults = UserDefaults(suiteName: Defaults.appGroupId) else {
            return Defaults.streamVadMinSpeechMsDefault
        }
        return (defaults.object(forKey: Defaults.streamVadMinSpeechMsKey) as? Int)
            ?? Defaults.streamVadMinSpeechMsDefault
    }

    /// Reads the streaming VAD minimum total chunk duration (ms) from the App Group.
    /// Used by the keyboard extension, which cannot link `AppSettings`.
    /// Returns the default (`300`) when the App Group is unavailable or the key is unset.
    static func streamVadMinChunkMs() -> Int {
        guard let defaults = UserDefaults(suiteName: Defaults.appGroupId) else {
            return Defaults.streamVadMinChunkMsDefault
        }
        return (defaults.object(forKey: Defaults.streamVadMinChunkMsKey) as? Int)
            ?? Defaults.streamVadMinChunkMsDefault
    }

    /// Reads the streaming VAD max-noise discard window (seconds) from the App Group.
    /// Used by the keyboard extension, which cannot link `AppSettings`.
    /// Returns the default (`6.0`) when the App Group is unavailable or the key is unset.
    static func streamVadMaxNoiseSec() -> Double {
        guard let defaults = UserDefaults(suiteName: Defaults.appGroupId) else {
            return Defaults.streamVadMaxNoiseSecDefault
        }
        return (defaults.object(forKey: Defaults.streamVadMaxNoiseSecKey) as? Double)
            ?? Defaults.streamVadMaxNoiseSecDefault
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

    // MARK: - Dictation Snapshot

    /// Reads the current dictation snapshot from the App Group.
    /// Written by the container app; read by the keyboard extension.
    /// Returns nil when the App Group is unavailable or no snapshot has been stored.
    ///
    /// Do NOT add `synchronize()` to this function. Cross-process reads go through
    /// the `cfprefsd` daemon, which holds the fresh value in memory; `synchronize()`
    /// reloads from the on-disk plist (which lags behind `cfprefsd`) and traps the
    /// reader in stale data — see the regression in commit f4c6832.
    static func dictationSnapshot() -> DictationPayload? {
        guard let defaults = UserDefaults(suiteName: Defaults.appGroupId) else { return nil }
        guard let data = defaults.data(forKey: Defaults.dictationPayloadKey) else { return nil }
        return try? JSONDecoder().decode(DictationPayload.self, from: data)
    }

    /// Writes a dictation snapshot to the App Group. Called by the container
    /// app's DictationViewModel to publish transcription state to the keyboard.
    ///
    /// Do NOT add `synchronize()` to this function. Cross-process reads go through
    /// the `cfprefsd` daemon, which holds the fresh value in memory; `synchronize()`
    /// reloads from the on-disk plist (which lags behind `cfprefsd`) and traps the
    /// reader in stale data — see the regression in commit f4c6832.
    static func setDictationSnapshot(_ payload: DictationPayload) {
        guard let defaults = UserDefaults(suiteName: Defaults.appGroupId) else { return }
        if let data = try? JSONEncoder().encode(payload) {
            defaults.set(data, forKey: Defaults.dictationPayloadKey)
        }
    }

    // MARK: - Snapshot file channel (cfprefsd-bypass fast path)
    //
    // Cross-process app-group UserDefaults reads go through the `cfprefsd` daemon,
    // which delivers fresh data ~1–2s after a write. The suspended keyboard
    // discovers each snapshot state (recording, transcribing, terminal) via its
    // 0.5s poll, losing ~2s to cfprefsd lag. These helpers write/read the SAME
    // `DictationPayload` to a plain file in the app-group container;
    // `Data(contentsOf:)` reads committed filesystem state with NO caching layer,
    // so the keyboard's fast path discovers every state sub-second. Secondary
    // transport sharing the single `handleTerminalResult` id-dedup — NOT a
    // parallel competing guard.
    //
    // Do NOT add `synchronize()` anywhere here (see warning on dictationSnapshot()
    // above — commit f4c6832 regression).

    /// Writes the dictation snapshot payload (any status: recording, transcribing,
    /// completed, error, cancelled) to a single overwrite file in the app-group
    /// container. Called by the container app's publishSnapshot for EVERY snapshot
    /// BEFORE the UserDefaults write and BEFORE the Darwin post. No-op when the
    /// container is unavailable (SideStore).
    static func setSnapshotFile(_ payload: DictationPayload) {
        guard let url = snapshotFileURL() else {
            FileLogger.shared.debug(.app, "snapshot file write skipped — container nil",
                payload: ["group": Defaults.appGroupId])
            return
        }
        if let data = try? JSONEncoder().encode(payload) {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Reads the snapshot payload from the file, or nil if absent,
    /// undecodable, or the container is unavailable (SideStore). The keyboard reads
    /// this BEFORE the UserDefaults snapshot as a sub-second fast path.
    static func snapshotFile() -> DictationPayload? {
        guard let url = snapshotFileURL(),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(DictationPayload.self, from: data)
    }

    /// Removes the snapshot file. Called by the keyboard after
    /// handleTerminalResult records lastProcessedPayloadId — only on terminal
    /// results; intermediate-state files persist and are overwritten by the next
    /// publish. No-op if absent.
    static func clearSnapshotFile() {
        guard let url = snapshotFileURL() else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Resolves the single-overwrite snapshot file URL inside the app-group
    /// container, creating the directory if needed. Returns nil (degrades to the
    /// UserDefaults channel) when the container is unavailable under SideStore.
    private static func snapshotFileURL() -> URL? {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: Defaults.appGroupId
        ) else { return nil }
        let dir = container.appendingPathComponent("DictationResults")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("terminal.json")
    }

    /// DIAGNOSTIC LOGGING — TEMPORARY (Bug 1): human-readable path or "nil", for publish/read logs.
    static func snapshotFilePathDescription() -> String {
        snapshotFileURL()?.path ?? "nil"
    }

    /// App-group resolution diagnostics (dev dump, gated by Verbose Logging). Must be
    /// called by a CALLER after `appGroupId` is resolved and FileLogger is initialized —
    /// AppGroupResolver cannot use FileLogger internally (FileLogger depends on the
    /// resolved id → recursion).
    static func logAppGroupDiagnostics(component: LogComponent) {
        let resolver = AppGroupResolver.shared
        let trace = resolver.resolutionTrace
        let strategy = resolver.resolvedStrategy
        let containerOk = resolver.containerAvailable
        let bundleId = Bundle.main.bundleIdentifier ?? "<nil>"
        let resolvedId = SharedConfig.Defaults.appGroupId
        // Read ALTAppGroups from Info.plist (same pattern as resolver Strategy 0)
        let altAppGroups: String
        if let raw = Bundle.main.infoDictionary?["ALTAppGroups"] {
            if let arr = raw as? [String] {
                altAppGroups = arr.joined(separator: ", ")
            } else if let str = raw as? String {
                altAppGroups = str
            } else {
                altAppGroups = "<unparseable>"
            }
        } else {
            altAppGroups = "<absent>"
        }
        FileLogger.shared.debug(component, "app-group resolution diagnostics", payload: [
            "strategy": strategy,
            "containerAvailable": containerOk,
            "bundleId": bundleId,
            "resolvedId": resolvedId,
            "altAppGroups": altAppGroups,
            "trace": trace
        ])
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
///   2. A team-suffixed identifier built from the TeamID derived from the bundle ID
///      (SideStore appends the same TeamID to the bundle ID and the app-group entitlement)
///   3. A team-suffixed identifier constructed from the TeamID in `embedded.mobileprovision`
///   4. The actual app-group string from `embedded.mobileprovision` (most authoritative)
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
    private var _containerAvailable: Bool?
    private var _resolvedStrategy: String?
    private var _resolutionTrace: String?

    /// The resolved app-group identifier. Returns the cached result of
    /// `resolve()`, triggering resolution on first access.
    var resolvedIdentifier: String {
        resolve()
    }

    /// Whether the resolved app-group container is currently available.
    /// Cached after the first computation (which happens inside `resolve()`).
    var containerAvailable: Bool {
        resolve()  // ensures _containerAvailable is cached
        lock.lock()
        defer { lock.unlock() }
        return _containerAvailable ?? false
    }

    /// Which resolution strategy produced the resolved identifier.
    /// Diagnostic field: "original", "bundleid-teamid", "mobileprovision-teamid",
    /// "mobileprovision-direct", or "fallback-original" ("unknown" before first resolve).
    var resolvedStrategy: String {
        resolve()
        lock.lock(); defer { lock.unlock() }
        return _resolvedStrategy ?? "unknown"
    }

    /// Compact trace of every identifier probed during resolution. Diagnostic only;
    /// stored under the lock, safe to read post-resolve. Caller logs at .warn so it
    /// survives a keyboard Jetsam kill.
    var resolutionTrace: String {
        resolve()
        lock.lock(); defer { lock.unlock() }
        return _resolutionTrace ?? ""
    }

    func resolve() -> String {
        lock.lock()
        defer { lock.unlock() }

        if let cached = cached {
            return cached
        }

        let original = SharedConfig.Defaults.originalAppGroupId
        let result = performResolution(original: original)
        cached = result
        _containerAvailable = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: result) != nil
        return result
    }

    private func performResolution(original: String) -> String {
        var trace = ""
        defer { _resolutionTrace = String(trace.prefix(512)) }
        let bundleId = Bundle.main.bundleIdentifier ?? "<nil>"

        // SIDESTORE NOTE: On SideStore installs, the app-group container is
        // fundamentally unavailable. SideStore appends a TeamID (e.g. 64GGL77Z3X)
        // to the bundle ID (com.ritoras.app.64GGL77Z3X) and the resolver correctly
        // derives the suffixed group ID (group.com.ritoras.app.64GGL77Z3X), but
        // containerURL() returns nil for ALL identifiers — original, suffixed, and
        // mobileprovision-derived. The ALTAppGroups plist key is absent. The
        // container simply does not exist under any discoverable name.
        // Dictation result delivery uses the localhost GET /state fallback transport
        // (see LocalhostClient.getState / LocalhostServer /state route) which
        // bypasses the container entirely. Do NOT add a manual override — there is
        // no valid identifier the user could type. Confirmed empirically 2026-08-09.

        // Strategy 0 (GROUND TRUTH): read the app-group identifiers SideStore embedded
        // into this bundle's Info.plist under the custom "ALTAppGroups" key.
        // SideStore's ResignAppOperation.prepare() writes the real (TeamID-suffixed)
        // identifiers granted by the provisioning profile into Info.plist["ALTAppGroups"]
        // for BOTH the main app and each appex. Authoritative — no guessing.
        // Source: SideStore Shared/Extensions/Bundle+AltStore.swift (appGroups = "ALTAppGroups").
        if let raw = Bundle.main.infoDictionary?["ALTAppGroups"] {
            let candidates: [String] = (raw as? [String])
                ?? ((raw as? String).map { [$0] } ?? [])
            if candidates.isEmpty {
                trace += "infoplist[ALTAppGroups]=empty; "
            } else {
                for id in candidates where !id.isEmpty {
                    let ok = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id) != nil
                    trace += "infoplist[\(id)]=\(ok ? "ok" : "nil"); "
                    if ok {
                        NSLog("AppGroupResolver: strategy=infoplist-appgroups identifier=\(id)")
                        _resolvedStrategy = "infoplist-appgroups"
                        return id
                    }
                }
            }
        } else {
            trace += "infoplist[ALTAppGroups]=absent; "
        }

        // Strategy 1: original unsuffixed identifier.
        // Works on App Store, TrollStore, Simulator, and any environment that
        // doesn't rewrite entitlements.
        if FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: original) != nil {
            NSLog("AppGroupResolver: strategy=original-identifier identifier=\(original) bundleId=\(bundleId)")
            _resolvedStrategy = "original"
            trace += "original[\(original)]=ok; "
            return original
        }

        // Strategy 2: team-suffixed identifier, TeamID derived from the BUNDLE ID.
        // SideStore appends the SAME TeamID to the bundle ID and the app-group
        // entitlement (source: SideStore FetchProvisioningProfilesOperation.swift),
        // so the TeamID component of Bundle.main.bundleIdentifier IS the app-group
        // suffix. This does NOT depend on parsing embedded.mobileprovision (fragile
        // in the keyboard appex), so it is the most reliable SideStore strategy.
        let baseBundleId = String(original.dropFirst("group.".count))   // "com.ritoras.app"
        if let bundleId = Bundle.main.bundleIdentifier,
           bundleId.hasPrefix(baseBundleId + ".") {
            let rest = String(bundleId.dropFirst(baseBundleId.count + 1))  // "<TeamID>[.keyboard]"
            if let teamComponent = rest.split(separator: ".").first,
               Self.isValidTeamId(teamComponent) {
                let teamId = String(teamComponent)
                let suffixed = "\(original).\(teamId)"                     // group.com.ritoras.app.<TeamID>
                if FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: suffixed) != nil {
                    NSLog("AppGroupResolver: strategy=bundleid-teamid identifier=\(suffixed) teamId=\(teamId) bundleId=\(bundleId)")
                    _resolvedStrategy = "bundleid-teamid"
                    trace += "bundleid[\(suffixed)]=ok; "
                    return suffixed
                }
                trace += "bundleid[\(suffixed)]=nil; "
                NSLog("AppGroupResolver: bundleid-teamid attempted but containerURL nil identifier=\(suffixed) bundleId=\(bundleId)")
            }
        }

        // Strategy 3: team-suffixed identifier, TeamID extracted from the embedded
        // provisioning profile (may fail in the keyboard appex under SideStore).
        // The bundle-ID strategy above is preferred because it does not depend on
        // parsing the mobileprovision.
        if let teamId = extractTeamIdFromMobileProvision() {
            let suffixed = "\(original).\(teamId)"
            if FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: suffixed) != nil {
                NSLog("AppGroupResolver: strategy=mobileprovision-teamid identifier=\(suffixed) teamId=\(teamId) bundleId=\(bundleId)")
                _resolvedStrategy = "mobileprovision-teamid"
                trace += "mprov-teamid[\(suffixed)]=ok; "
                return suffixed
            }
            trace += "mprov-teamid[\(suffixed)]=nil; "
            NSLog("AppGroupResolver: mobileprovision-teamid attempted but containerURL nil identifier=\(suffixed) bundleId=\(bundleId)")
        } else {
            trace += "mprov-teamid=noteamid; "
            NSLog("AppGroupResolver: no TeamID found in embedded.mobileprovision bundleId=\(bundleId)")
        }

        // Strategy 4: read embedded.mobileprovision and extract the actual
        // app-group string. This is the most authoritative source because it
        // reads the binary's signed entitlements directly.
        if let fromProvision = readFromMobileProvision() {
            NSLog("AppGroupResolver: strategy=mobileprovision identifier=\(fromProvision) bundleId=\(bundleId)")
            _resolvedStrategy = "mobileprovision-direct"
            trace += "mprov-direct[\(fromProvision)]=ok; "
            return fromProvision
        }

        // All strategies failed. Log loudly and return the original identifier
        // so the app still functions (in degraded, pre-fix mode — same as today).
        // The user will see this in the system log via NSLog.
        NSLog("AppGroupResolver: ⚠️ ALL STRATEGIES FAILED — falling back to original identifier. bundleId=\(bundleId)")
        _resolvedStrategy = "fallback-original"
        trace += "fallback"
        return original
    }

    /// Apple TeamIDs are exactly 10 uppercase alphanumeric characters.
    /// Used to extract the TeamID from the SideStore-suffixed bundle ID.
    private static func isValidTeamId(_ s: Substring) -> Bool {
        guard s.count == 10 else { return false }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        return String(s).unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    /// Extracts the TeamID from `embedded.mobileprovision`.
    ///
    /// Checks two sources in order:
    ///   1. `Entitlements["com.apple.developer.team-identifier"]` — the team ID string
    ///   2. Top-level `ApplicationIdentifierPrefix` array — first element (10-char alphanumeric)
    ///
    /// SideStore rewrites app-group entitlements to `group.com.ritoras.app.<TeamID>`,
    /// so we use this TeamID to construct the suffixed identifier and validate it
    /// via `containerURL(forSecurityApplicationGroupIdentifier:)`.
    private func extractTeamIdFromMobileProvision() -> String? {
        guard let plist = parseMobileProvisionPlist() else { return nil }

        // Strategy A: Entitlements["com.apple.developer.team-identifier"]
        if let entitlements = plist["Entitlements"] as? [String: Any],
           let teamId = entitlements["com.apple.developer.team-identifier"] as? String,
           !teamId.isEmpty {
            return teamId
        }

        // Strategy B: top-level ApplicationIdentifierPrefix array
        if let prefixes = plist["ApplicationIdentifierPrefix"] as? [String],
           let prefix = prefixes.first,
           !prefix.isEmpty {
            return prefix
        }

        return nil
    }

    /// Parses `embedded.mobileprovision` and returns the full plist dictionary.
    /// Tries `Bundle.main.url(forResource:withExtension:)` first; if that returns
    /// nil (common in keyboard extensions), falls back to a direct bundle path.
    private func parseMobileProvisionPlist() -> [String: Any]? {
        // Try standard resource lookup first
        if let profileURL = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
           let data = try? Data(contentsOf: profileURL),
           let plist = parseMobileProvisionData(data) {
            return plist
        }
        // Fallback: direct bundle path (keyboard extension workaround)
        let directURL = Bundle.main.bundleURL.appendingPathComponent("embedded.mobileprovision")
        guard let data = try? Data(contentsOf: directURL),
              let plist = parseMobileProvisionData(data) else {
            return nil
        }
        return plist
    }

    /// Extracts the XML plist from CMS-signed mobileprovision data and deserializes it.
    /// Uses `.isoLatin1` encoding (maps every byte 1:1 — never fails on binary data).
    private func parseMobileProvisionData(_ data: Data) -> [String: Any]? {
        guard let raw = String(data: data, encoding: .isoLatin1),
              let xmlStart = raw.range(of: "<?xml"),
              let xmlEnd = raw.range(of: "</plist>"),
              let plistData = String(raw[xmlStart.lowerBound..<xmlEnd.upperBound]).data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil) as? [String: Any] else {
            return nil
        }
        return plist
    }

    /// Reads `embedded.mobileprovision` and extracts the first app-group
    /// identifier from `Entitlements["com.apple.security.application-groups"]`.
    /// Delegates file-lookup and plist-parsing to `parseMobileProvisionPlist()`,
    /// which includes the keyboard-extension fallback path.
    /// Returns the first identifier that resolves to a container, or the first
    /// string if none resolve — caller handles containerURL nil downstream.
    private func readFromMobileProvision() -> String? {
        guard let plist = parseMobileProvisionPlist(),
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
