import Foundation
import AVFoundation
import UIKit

/// Thread-safe in-memory queue of audio chunks awaiting WebSocket send.
/// Shared between the VAD audio thread (producer, off-MainActor), the
/// @MainActor view model, and the background consumer Task. Marked
/// @unchecked Sendable because all access is serialized via internal NSLock.
final class ChunkSendQueue: @unchecked Sendable {
    private var chunks: [(UInt32, [Float])] = []
    private var recordingActive = false
    private let lock = NSLock()

    func enqueue(id: UInt32, samples: [Float]) {
        lock.lock(); defer { lock.unlock() }
        chunks.append((id, samples))
    }

    func dequeue() -> (UInt32, [Float])? {
        lock.lock(); defer { lock.unlock() }
        guard !chunks.isEmpty else { return nil }
        return chunks.removeFirst()
    }

    var isEmpty: Bool { lock.lock(); defer { lock.unlock() }; return chunks.isEmpty }
    var depth: Int { lock.lock(); defer { lock.unlock() }; return chunks.count }
    var isRecordingActive: Bool { lock.lock(); defer { lock.unlock() }; return recordingActive }

    func setRecordingActive(_ value: Bool) {
        lock.lock(); defer { lock.unlock() }
        recordingActive = value
    }

    /// Reset queue contents for a new recording (keeps recordingActive).
    func resetForNewRecording() {
        lock.lock(); defer { lock.unlock() }
        chunks.removeAll()
    }

    /// Full reset including recordingActive (used by cancel).
    func clearAll() {
        lock.lock(); defer { lock.unlock() }
        chunks.removeAll()
        recordingActive = false
    }
}

/// Thread-safe holder of the latest published dictation snapshot. Read by the
/// localhost server's background `conn_queue` (via the `/state` route), written
/// by the @MainActor view model. Marked @unchecked Sendable because all access
/// is serialized via internal NSLock.
private final class LastPayloadHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var _payload: DictationPayload?

    func get() -> DictationPayload? {
        lock.lock(); defer { lock.unlock() }
        return _payload
    }

    func set(_ payload: DictationPayload?) {
        lock.lock(); defer { lock.unlock() }
        _payload = payload
    }
}

@MainActor
final class DictationViewModel: ObservableObject {
    enum DictationPhase: Equatable {
        case recording
        case transcribing
        case done(String)
        case error(String)
        case cancelled
    }

    @Published var phase: DictationPhase = .recording {
        didSet {
            updateStateSnapshot()                                    // publish intermediate states first (app-group)
            storeTerminalResultIfNeeded()                            // publish terminal result — BEFORE the post
            switch phase {
            case .recording, .transcribing:
                if localhostServer != nil {
                    startHealthCheckTimer()
                }
            default:
                stopHealthCheckTimer()
            }
            DarwinNotifier.post(SharedConfig.Defaults.darwinStateChangedNotificationName)  // LAST — only signal after data is visible
        }
    }
    @Published private(set) var livePartial: String = ""
    @Published private(set) var activeModeLabel: String = ""

    // MARK: - Localhost Server (Phase 1)

    private var localhostServer: LocalhostServer?

    /// Re-entrancy guard + generation token for ensureLocalhostServerHealthy().
    /// The boolean is set synchronously before the first await; the token is
    /// compared after the await so a rapid foreground→background→foreground
    /// cycle cannot run two concurrent health checks that both restart the server.
    private var isEnsuringLocalhostHealth = false
    private var ensureHealthToken = 0

    /// Periodic localhost health check timer. Runs only while a dictation is
    /// actively recording or transcribing so a "ready but wedged" listener is
    /// caught even when the app stays foregrounded (no scenePhase transition).
    private var healthCheckTimer: Timer?
    private static let healthCheckInterval: TimeInterval = 10.0

    /// Locked holder of the latest published snapshot, readable from the
    /// localhost server's background conn_queue without touching @MainActor state.
    private let lastPayloadHolder = LastPayloadHolder()

    /// Monotonic revision counter for app-group snapshot writes.
    /// Bumped on every write so the keyboard can detect freshness.
    private var snapshotRevision: UInt64 = 0

    private var recorder: AudioRecorder?
    private(set) var activeID: UUID?
    /// Start of the current recording; @Published so the overlay badge can render
    /// live elapsed time. Deliberately has NO didSet — unlike `phase`, publishing
    /// this must not write IPC snapshots.
    @Published private(set) var recordingStartTime: Date?

    private var streamRecorder: StreamingAudioRecorder?
    private var streamClient: WhisperStreamClient?

    private var selectedServer: String?
    private var serverSelectionTask: Task<String?, Never>?

    // MARK: - Stream Chunk Queue

    private let chunkSendQueue = ChunkSendQueue()
    private var chunkConsumerTask: Task<Void, Never>?
    private var receiveTask: Task<String, Error>?
    private var transcriptionTask: Task<Void, Never>?

    /// True once the streaming server has returned ≥1 partial transcription for
    /// the current session — proof it is transcribing THIS recording's audio.
    /// Reset in start(); read in stop() to reject empty/stale results that did
    /// not come from this session. Streaming WhisperLive always emits partials
    /// while decoding, so a session with no partials was never transcribed.
    private var transcriptionDeliveredThisSession = false

    /// Idempotency guard: tracks job IDs currently being retried to prevent
    /// concurrent retries of the same job (defense against retry loops).
    private var retryingJobIds: Set<UUID> = []
    private let retryLock = NSLock()

    // MARK: - Localhost Server Helpers

    /// Returns the latest published snapshot. `nonisolated` so the localhost
    /// server's background conn_queue can call it directly — it touches only
    /// the locked `lastPayloadHolder`, never @MainActor state.
    nonisolated func currentSnapshot() -> DictationPayload? {
        lastPayloadHolder.get()
    }

    /// Starts the localhost HTTP server if not already running. Idempotent.
    func startLocalhostServer() {
        guard localhostServer == nil else {
            FileLogger.shared.debug(.network, "DictationViewModel: localhost server already running")
            return
        }

        let server = LocalhostServer(
            port: SharedConfig.Defaults.localhostServerPort,
            onStop:   { [weak self] in await self?.stop() },
            onCancel: { [weak self] in await self?.cancel() },
            onState:  { [weak self] in self?.currentSnapshot() }
        )

        do {
            try server.start()
            localhostServer = server
            FileLogger.shared.info(.app, "DictationViewModel: localhost server started",
                                   payload: ["port": SharedConfig.Defaults.localhostServerPort])
        } catch {
            FileLogger.shared.error(.app, "DictationViewModel: failed to start localhost server",
                                    payload: ["error": error.localizedDescription])
        }
    }

    /// Verifies the localhost server is still responding and restarts it if not.
    /// Called on app activation (scenePhase .active). Heals an already-started
    /// server only — never eagerly starts one (that is the ritoras://dictate
    /// URL path's job). Not async: the SwiftUI scenePhase call site stays
    /// synchronous; the async work runs in a @MainActor Task guarded against
    /// re-entrancy.
    func ensureLocalhostServerHealthy() {
        guard localhostServer != nil else { return }

        Task { @MainActor [weak self] in
            guard !(self?.isEnsuringLocalhostHealth ?? true) else { return }
            self?.isEnsuringLocalhostHealth = true
            defer { self?.isEnsuringLocalhostHealth = false }

            let token = self?.ensureHealthToken ?? 0
            let healthy = await LocalhostClient.healthCheck()

            guard let self = self, token == self.ensureHealthToken, self.localhostServer != nil else { return }

            if healthy {
                FileLogger.shared.debug(.network, "localhost health check ok")
                return
            }
            FileLogger.shared.warn(.network, "localhost server unhealthy on probe, restarting")
            self.localhostServer?.restart()
        }
    }

    /// Starts the periodic localhost health check timer. Runs only while a
    /// dictation is actively recording or transcribing; stopped on terminal
    /// phases and in deinit so it never survives a session.
    private func startHealthCheckTimer() {
        guard healthCheckTimer == nil else { return }
        healthCheckTimer = Timer.scheduledTimer(withTimeInterval: Self.healthCheckInterval, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                // Fast-path: the listener is already dead — restart synchronously
                // without the GET /health network round-trip.
                if self.localhostServer?.isHealthy == false || self.localhostServer?.hasListener == false {
                    FileLogger.shared.warn(.network, "localhost server listener dead, restarting")
                    self.localhostServer?.restart()
                    return
                }
                self.ensureLocalhostServerHealthy()
            }
        }
    }

    private func stopHealthCheckTimer() {
        healthCheckTimer?.invalidate()
        healthCheckTimer = nil
    }

    /// Publishes intermediate states (recording, transcribing, cancelled) to app-group snapshot.
    private func updateStateSnapshot() {
        let payloadStatus: DictationPayload.Status?
        switch phase {
        case .recording:
            payloadStatus = .recording
        case .transcribing:
            payloadStatus = .transcribing
        case .cancelled:
            payloadStatus = .cancelled
        case .done, .error:
            payloadStatus = nil   // terminal results handled by storeTerminalResultIfNeeded
        }
        if let payloadStatus = payloadStatus {
            publishSnapshot(status: payloadStatus)
        }
    }

    /// Captures terminal results (`.done`, `.error`) and publishes them
    /// through the app-group canonical snapshot.
    private func storeTerminalResultIfNeeded() {
        guard let id = activeID else { return }
        let snapshotStatus: DictationPayload.Status?
        let snapshotText: String?
        let snapshotError: String?
        switch phase {
        case .done(let text):
            snapshotStatus = .completed
            snapshotText = text
            snapshotError = nil
        case .error(let msg):
            snapshotStatus = .error
            snapshotText = nil
            snapshotError = msg
        default:
            snapshotStatus = nil
            snapshotText = nil
            snapshotError = nil
        }
        if let snapshotStatus = snapshotStatus {
            publishSnapshot(status: snapshotStatus, text: snapshotText, errorMessage: snapshotError)
        }
    }

    /// Publishes the current dictation state to the app-group canonical snapshot.
    private func publishSnapshot(status: DictationPayload.Status, text: String? = nil, errorMessage: String? = nil) {
        guard let activeID = activeID else {
            FileLogger.shared.warn(.app, "publishSnapshot: no activeID, skipping")
            return
        }
        snapshotRevision &+= 1
        let payload = DictationPayload(
            id: activeID,
            status: status,
            text: text,
            errorMessage: errorMessage,
            timestamp: Date(),
            revision: snapshotRevision
        )
        // Mirror into the locked holder so the localhost /state fallback can serve
        // the same payload even when the app-group container is nil (SideStore).
        lastPayloadHolder.set(payload)
        // ALL snapshots go to the app-group container FILE (cfprefsd bypass) so the
        // keyboard discovers each state — recording, transcribing, terminal —
        // sub-second instead of waiting ~2s for cfprefsd. Order is deliberate: file
        // BEFORE UserDefaults, both before the Darwin post. The keyboard clears the
        // file only on terminal results.
        SharedConfig.setSnapshotFile(payload)
        FileLogger.shared.debug(.app, "snapshot file written",
                                payload: ["status": status.rawValue,
                                          "rev": snapshotRevision,
                                          "id": String(activeID.uuidString.prefix(8))])
        SharedConfig.setDictationSnapshot(payload)
    }



    func start(id: UUID) async {
        activeID = id
        livePartial = ""
        transcriptionDeliveredThisSession = false
        phase = .recording

        // Kick off parallel health probe — runs in background while mic
        // permission is checked and recording starts.
        selectedServer = nil
        let probeConfig = SharedConfig.load()
        serverSelectionTask = Task { [weak self] in
            let selected = await WhisperClient.selectFirstHealthyServer(servers: probeConfig.servers)
            SharedConfig.setSelectedServer(selected)
            await MainActor.run { self?.selectedServer = selected }
            return selected
        }

        let mode = SharedConfig.dictationMode()
        // Fire-and-forget model warm-up: batch mode only connects to the server
        // AFTER recording stops, so pre-load the engine now — the ~5 s load
        // overlaps with the user's speech. Stream mode already loads at WS connect.
        if mode != .stream {
            let selectionTask = serverSelectionTask
            Task.detached(priority: .utility) {
                guard let selected = await selectionTask?.value, !selected.isEmpty else { return }
                await WhisperClient.warmup(serverURL: selected)
            }
        }
        activeModeLabel = mode == .stream ? "STREAM" : "BATCH"
        FileLogger.shared.info(.transcription, "dictation start", payload: [
            "id": id.uuidString,
            "mode": mode == .stream ? "stream" : "batch"
        ])

        // Check microphone permission before attempting to record
        switch AVAudioSession.sharedInstance().recordPermission {
        case .undetermined:
            let granted = await withCheckedContinuation { continuation in
                AVAudioSession.sharedInstance().requestRecordPermission { allowed in
                    continuation.resume(returning: allowed)
                }
            }
            if !granted {
                let message = "Microphone access denied. Enable it in Settings \u{2192} Ritoras."
                phase = .error(message)
                serverSelectionTask?.cancel()
                serverSelectionTask = nil
                selectedServer = nil
                return
            }
        case .denied:
            let message = "Microphone access denied. Enable it in Settings \u{2192} Ritoras."
            phase = .error(message)
            serverSelectionTask?.cancel()
            serverSelectionTask = nil
            selectedServer = nil
            return
        case .granted:
            break
        @unknown default:
            break
        }

        switch mode {
        case .batch:
            do {
                let newRecorder = AudioRecorder()
                _ = try await newRecorder.startRecording(jobId: id)
                recorder = newRecorder
                recordingStartTime = Date()
                UIApplication.shared.isIdleTimerDisabled = true
            } catch {
                let message = error.localizedDescription
                phase = .error(message)
            }

        case .stream:
            FileLogger.shared.info(.transcription, "start mode: stream")

            livePartial = ""

            let config = SharedConfig.load()

            do {
                // Await probe result and try the selected server first.
                // If unavailable or the probe-selected connection fails, iterate
                // the remaining servers with the existing failover behaviour.
                var client: WhisperStreamClient?
                var lastError: Error?
                let probeResult = await serverSelectionTask?.value

                // Pre-trim once for efficient comparison and iteration.
                let trimmedServers = config.servers.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "/")) }.filter { !$0.isEmpty }
                var remainingServers = trimmedServers

                if let selected = probeResult {
                    let base = selected.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                    if !base.isEmpty, config.servers.contains(selected) {
                        if let candidate = WhisperStreamClient(baseURL: base) {
                            do {
                                try await candidate.connect()
                                client = candidate
                                FileLogger.shared.info(.network, "Stream: connected to probe-selected server",
                                                       payload: ["base": base])
                            } catch {
                                FileLogger.shared.info(.network, "Stream: probe-selected server failed",
                                                       payload: ["base": base, "error": error.localizedDescription])
                                lastError = error
                                await candidate.disconnect()
                            }
                        } else {
                            lastError = WhisperError.networkError(URLError(.badURL))
                            FileLogger.shared.warn(.network, "Stream: invalid probe-selected server URL",
                                                   payload: ["base": base])
                        }
                        remainingServers = trimmedServers.filter { $0 != base }
                    }
                }

                if client == nil {
                    for server in remainingServers {
                        guard !server.isEmpty else { continue }
                        guard let candidate = WhisperStreamClient(baseURL: server) else {
                            FileLogger.shared.warn(.network, "Stream: invalid server URL",
                                                   payload: ["base": server])
                            lastError = WhisperError.networkError(URLError(.badURL))
                            continue
                        }
                        do {
                            try await candidate.connect()
                            client = candidate
                            FileLogger.shared.info(.network, "Stream: connected to server",
                                                   payload: ["base": server])
                            break
                        } catch {
                            FileLogger.shared.info(.network, "Stream: server failed",
                                                   payload: ["base": server, "error": error.localizedDescription])
                            lastError = error
                            await candidate.disconnect()
                            continue
                        }
                    }
                }

                guard let client = client else {
                    throw lastError ?? WhisperError.allServersFailed(config.servers)
                }
                FileLogger.shared.info(.network, "Stream: WebSocket connected")
                streamClient = client

                let receiveClient = client
                let sessionID = id
                receiveTask?.cancel()
                receiveTask = Task { [weak self] in
                    guard let self = self else { throw WhisperError.networkError(URLError(.cancelled)) }
                    return try await receiveClient.receiveMessages(onPartial: { [weak self] partial in
                        FileLogger.shared.debug(.transcription, "livePartial updated",
                                                payload: ["preview": String(partial.prefix(60)), "length": partial.count])
                        Task { @MainActor [weak self] in
                            guard let self else { return }
                            guard self.activeID == sessionID else { return }
                            self.livePartial = partial
                            self.transcriptionDeliveredThisSession = true
                        }
                    })
                }

                let recorder = StreamingAudioRecorder()
                streamRecorder = recorder

                let wavURL = RecordingStore.shared.streamWavURL(for: id)
                try await recorder.start(fileURL: wavURL) { [chunkQueue = self.chunkSendQueue] chunkId, samples in
                    FileLogger.shared.debug(.audio, "Stream: chunk produced",
                                            payload: ["chunkId": chunkId, "sampleCount": samples.count])
                    chunkQueue.enqueue(id: chunkId, samples: samples)
                }
                FileLogger.shared.info(.audio, "Stream: recorder started")

                // Reset queue state and launch consumer
                chunkSendQueue.resetForNewRecording()
                chunkSendQueue.setRecordingActive(true)
                chunkConsumerTask?.cancel()
                let consumerClient = client
                chunkConsumerTask = Task { [weak self] in
                    guard let self = self else { return }
                    await self.runChunkConsumer(client: consumerClient)
                }

                recordingStartTime = Date()

                UIApplication.shared.isIdleTimerDisabled = true
            } catch {
                FileLogger.shared.error(.transcription, "Stream start error",
                                        payload: ["error": error.localizedDescription])
                await streamClient?.disconnect()
                receiveTask?.cancel()
                receiveTask = nil
                streamClient = nil
                streamRecorder = nil
                DispatchQueue.global(qos: .utility).async {
                    let deactivateStart = Date()
                    AudioSession.deactivate()
                    let elapsed = Date().timeIntervalSince(deactivateStart) * 1000
                    FileLogger.shared.debug(.audio, "audio deactivate (background)",
                                            payload: ["elapsed_ms": elapsed])
                }

                let message = error.localizedDescription
                phase = .error(message)
            }
        }
    }

    func stop() async {
        let stopStartTime = Date()
        switch SharedConfig.dictationMode() {
        case .batch:
            guard let recorder = recorder, let id = activeID else { return }
            self.recorder = nil

            let recordedDurationMs = recordingStartTime.map { Date().timeIntervalSince($0) * 1000 } ?? 0
            FileLogger.shared.info(.transcription, "dictation stop (user requested)", payload: [
                "id": id.uuidString,
                "recordedDurationMs": recordedDurationMs
            ])

            let audioURL = await recorder.stopRecording()

            guard let url = audioURL else {
                UIApplication.shared.isIdleTimerDisabled = false
                DispatchQueue.global(qos: .utility).async {
                    let deactivateStart = Date()
                    AudioSession.deactivate()
                    let elapsed = Date().timeIntervalSince(deactivateStart) * 1000
                    FileLogger.shared.debug(.audio, "audio deactivate (background)",
                                            payload: ["elapsed_ms": elapsed])
                }
                let message = "Recording was empty. Please try again."
                phase = .error(message)
                return
            }

            phase = .transcribing
            UIApplication.shared.isIdleTimerDisabled = false
            // Deactivate audio session on a background queue — do not block the upload.
            DispatchQueue.global(qos: .utility).async {
                let deactivateStart = Date()
                AudioSession.deactivate()
                let elapsed = Date().timeIntervalSince(deactivateStart) * 1000
                FileLogger.shared.debug(.audio, "audio deactivate (background)",
                                        payload: ["elapsed_ms": elapsed])
            }

            let config = SharedConfig.load()

            // Foreground upload (Scenario A) — runs immediately while the app is in
            // the foreground and updates the UI directly. A background task keeps
            // the app alive briefly if the user switches away mid-flight.
            var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
            backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "WhisperTranscription") {
                UIApplication.shared.endBackgroundTask(backgroundTaskID)
                backgroundTaskID = .invalid
            }

            transcriptionTask = Task { [weak self] in
                guard let self = self else {
                    if backgroundTaskID != .invalid {
                        UIApplication.shared.endBackgroundTask(backgroundTaskID)
                    }
                    return
                }

                defer { if self.activeID == id { self.transcriptionTask = nil } }

                let uploadT0 = Date()

                do {
                    let audioBytes = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? UInt64 ?? 0

                    // Fast path: await the health probe started in start(). The probe completes
                    // during recording, so this is ~0s on the happy path. If no server was
                    // found, pass nil below so routeTranscription performs a fresh probe and
                    // fast connection failures are retried instead of aborting before upload.
                    let chosenServer = await serverSelectionTask?.value
                    serverSelectionTask = nil

                    FileLogger.shared.info(.transcription, "upload start", payload: [
                        "id": id.uuidString,
                        "audioBytes": audioBytes,
                        "serverCount": config.servers.count,
                        "server": chosenServer ?? config.servers.first ?? ""
                    ])

                    let text = try await transcribeWithAutoRetry(
                        audioURL: url, jobId: id, config: config,
                        correlationId: activeID, initialServer: chosenServer,
                        language: SharedConfig.keyboardLanguage().dictationLanguageField)
                    FileLogger.shared.debug(.network, "async transcription succeeded",
                                            payload: ["textLength": text.count])
                    guard activeID == id else { endStopBackgroundTask(&backgroundTaskID); return }

                    let uploadElapsed = Date().timeIntervalSince(uploadT0) * 1000
                    FileLogger.shared.info(.transcription, "upload complete", payload: [
                        "id": id.uuidString,
                        "elapsed_ms": uploadElapsed,
                        "textLength": text.count
                    ])

                    TranscriptionHistory.shared.add(text: text)
                    // Audio delivered — clean up the recording file.
                    let deleteJobId = id
                    RecordingStore.shared.delete(jobId: deleteJobId)
                    FileLogger.shared.debug(.audio, "audio deleted on success",
                                            payload: ["jobId": deleteJobId.uuidString])
                    phase = .done(text)
                } catch WhisperError.cancelled {
                    guard activeID == id else { endStopBackgroundTask(&backgroundTaskID); return }
                    // User cancelled — do not record as failure.
                    FileLogger.shared.debug(.app, "transcription cancelled",
                                            payload: ["jobId": id.uuidString])
                    phase = .cancelled
                } catch {
                    guard activeID == id else { endStopBackgroundTask(&backgroundTaskID); return }
                    let message = error.localizedDescription
                    let failedElapsed = Date().timeIntervalSince(uploadT0) * 1000
                    FileLogger.shared.info(.transcription, "upload failed", payload: [
                        "id": id.uuidString,
                        "elapsed_ms": failedElapsed,
                        "error": message
                    ])
                    // Audio preserved on disk for Phase 4 retry.
                    FileLogger.shared.debug(.audio, "audio preserved for retry",
                                            payload: ["jobId": id.uuidString])
                    // Phase 4: preserve failed job for retry if audio exists.
                    FileLogger.shared.debug(.app, "transcription failed, checking audio for recovery", payload: [
                        "jobId": id.uuidString,
                        "audioPath": url.path,
                        "audioExists": FileManager.default.fileExists(atPath: url.path)
                    ])
                    if FileManager.default.fileExists(atPath: url.path) {
                        let duration = recordingStartTime.map { Date().timeIntervalSince($0) } ?? 0
                        FailedJobStore.shared.append(FailedJobRecord(
                            jobId: id,
                            audioFilePath: url.path,
                            errorMessage: message,
                            recordedDurationSeconds: duration,
                            createdAt: Date(),
                            retryCount: 0,
                            lastRetriedAt: nil))
                        FileLogger.shared.debug(.app, "failed-job record appended",
                                                payload: ["jobId": id.uuidString, "durationSec": duration, "audioPath": url.path])
                    } else {
                        FileLogger.shared.debug(.app, "failed-job record SKIPPED — audio file not found", payload: [
                            "jobId": id.uuidString,
                            "audioPath": url.path
                        ])
                    }
                    phase = .error(message)
                }

                if backgroundTaskID != .invalid {
                    UIApplication.shared.endBackgroundTask(backgroundTaskID)
                }
            }

        case .stream:
            FileLogger.shared.info(.transcription, "stop mode: stream")

            guard let id = activeID else { return }

            let recordedDurationMs = recordingStartTime.map { Date().timeIntervalSince($0) * 1000 } ?? 0
            FileLogger.shared.info(.transcription, "dictation stop (user requested)", payload: [
                "id": id.uuidString,
                "recordedDurationMs": recordedDurationMs
            ])

            phase = .transcribing
            UIApplication.shared.isIdleTimerDisabled = false

            var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
            backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "WhisperTranscription") {
                UIApplication.shared.endBackgroundTask(backgroundTaskID)
                backgroundTaskID = .invalid
            }

            // Signal recording done and drain queue
            await streamRecorder?.stop()

            guard activeID == id else { endStopBackgroundTask(&backgroundTaskID); return }
            chunkSendQueue.setRecordingActive(false)

            var queueDrained = false
            let drainHardCap = Date().addingTimeInterval(SharedConfig.Defaults.streamFinalTimeout)
            while Date() < drainHardCap {
                if chunkSendQueue.isEmpty { queueDrained = true; break }
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard activeID == id else { endStopBackgroundTask(&backgroundTaskID); return }
            }

            chunkConsumerTask?.cancel()
            chunkConsumerTask = nil

            let uploadT0 = Date()

            if queueDrained {
                do {
                    try await streamClient?.sendEnd()
                    FileLogger.shared.info(.network, "Stream: END sent, awaiting final from receive task")

                    FileLogger.shared.info(.transcription, "upload start", payload: [
                        "id": id.uuidString
                    ])

                    let text = try await receiveTask?.value ?? ""

                    guard activeID == id else { endStopBackgroundTask(&backgroundTaskID); return }

                    // A real transcription requires the server to have transcribed THIS
                    // session's audio (≥1 partial) AND a non-empty result. Empty text, or text
                    // that arrived without any partials this session, means the server never
                    // delivered a transcription for this recording → retryable failure (audio
                    // preserved via handleStreamTerminalFailure). This also rejects stale text
                    // from a prior session that must never be re-delivered as this session's.
                    let transcriptionValid = !text.isEmpty && transcriptionDeliveredThisSession
                    if !transcriptionValid {
                        FileLogger.shared.warn(.transcription,
                            "stream stop: no transcription delivered this session — treating as failure",
                            payload: ["jobId": id.uuidString,
                                      "textLen": text.count,
                                      "partialsReceived": transcriptionDeliveredThisSession])
                        handleStreamTerminalFailure(
                            jobId: id,
                            error: text.isEmpty
                                ? "Nothing was heard. Try again."
                                : "Didn't receive a transcription from the server. Try again.")
                    } else {
                        let uploadElapsed = Date().timeIntervalSince(uploadT0) * 1000
                        FileLogger.shared.info(.transcription, "upload complete", payload: [
                            "id": id.uuidString,
                            "elapsed_ms": uploadElapsed,
                            "textLength": text.count
                        ])

                        FileLogger.shared.info(.transcription, "Stream final received",
                                               payload: ["preview": String(text.prefix(60)),
                                                         "length": text.count])

                        guard activeID == id else { endStopBackgroundTask(&backgroundTaskID); return }

                        TranscriptionHistory.shared.add(text: text)
                        RecordingStore.shared.deleteStreamWav(for: id)
                        FileLogger.shared.debug(.audio, "stream wav deleted on success",
                                                payload: ["jobId": id.uuidString])
                        phase = .done(text)
                    }
                } catch WhisperError.cancelled {
                    guard activeID == id else { endStopBackgroundTask(&backgroundTaskID); return }
                    // User cancelled — do not record as failure.
                    RecordingStore.shared.deleteStreamWav(for: id)
                    FileLogger.shared.debug(.app, "transcription cancelled, wav deleted",
                                            payload: ["jobId": id.uuidString])
                    phase = .cancelled
                } catch {
                    guard activeID == id else { endStopBackgroundTask(&backgroundTaskID); return }
                    handleStreamTerminalFailure(jobId: id, error: error.localizedDescription)
                }
            } else {
                handleStreamTerminalFailure(jobId: id, error: "stream send failed — recording preserved for retry")
            }

            if backgroundTaskID != .invalid {
                UIApplication.shared.endBackgroundTask(backgroundTaskID)
                backgroundTaskID = .invalid
            }

            receiveTask?.cancel()
            receiveTask = nil

            await streamClient?.disconnect()
            guard activeID == id else { endStopBackgroundTask(&backgroundTaskID); return }
            streamClient = nil
            streamRecorder = nil
        }
    }

    // MARK: - Recovery (Phase 4)

    /// Retries a failed transcription job from saved audio. Structurally
    /// isolated from `activeID` — does NOT fire Darwin notifications,
    /// publishes directly to app-group (no HTTP server), and refuses to run while a
    /// live dictation is in `.recording` or `.transcribing` phase.
    /// Returns the transcribed text on success, `nil` on failure/cancel/skip.
    func retry(jobId: UUID) async -> String? {
        // HARD GUARD: never retry while a live dictation is in flight.
        // phase may be .recording at startup before any dictation without
        // an active recorder — that's the idle state, not "live". A live
        // dictation only exists when an AudioRecorder or StreamingAudioRecorder
        // is actively recording.
        switch phase {
        case .transcribing:
            return nil  // definitely live
        case .recording:
            // .recording at startup (no recorder) is not live; only block
            // if a recorder is actually active.
            if recorder != nil || streamRecorder != nil {
                return nil
            }
        default:
            break
        }

        do {
            let text = try await transcribeSavedAudio(jobId: jobId)
            handleRetrySuccess(text: text, jobId: jobId)
            return text
        } catch is RetryAlreadyInFlight {
            // Skip — a concurrent retry for this job is already in flight.
            return nil
        } catch WhisperError.cancelled {
            FileLogger.shared.debug(.app, "retry cancelled", payload: ["jobId": jobId.uuidString])
            phase = .cancelled
            return nil
        } catch {
            handleRetryFailure(error: error, jobId: jobId)
            return nil
        }
    }

    // MARK: - Retry Helpers

    /// Handles a successful retry: delivers the transcript to the clipboard.
    /// History persistence and audio/record cleanup happen inside
    /// `transcribeSavedAudio`.
    private func handleRetrySuccess(text: String, jobId: UUID) {
        // Deliver to clipboard — write directly since activeID is nil during recovery.
        var payload: [String: Any] = [
            "source": "ritoras",
            "id": jobId.uuidString,
            "status": "completed",
            "text": text,
            "timestamp": Date().timeIntervalSince1970,
        ]
        if let jsonData = try? JSONSerialization.data(withJSONObject: payload) {
            UIPasteboard.general.setItems([
                ["org.ritoras.dictation": jsonData, "public.utf8-plain-text": text]
            ], options: [:])
        }
    }

    /// Handles a failed retry: logs the error and updates the record's
    /// errorMessage so RecoveryView / DictationView shows the latest error.
    private func handleRetryFailure(error: Error, jobId: UUID) {
        let errorMessage = error.localizedDescription
        FileLogger.shared.info(.app, "retry failed", payload: [
            "jobId": jobId.uuidString,
            "error": errorMessage
        ])
        FailedJobStore.shared.updateErrorMessage(jobId: jobId, message: errorMessage)
    }

    /// Thrown by `transcribeSavedAudio` when the same job is already being
    /// retried. Callers treat it as a no-op, not a failure.
    private struct RetryAlreadyInFlight: Error {}

    private func transcribeWithAutoRetry(
        audioURL: URL,
        jobId: UUID,
        config: SharedConfig,
        correlationId: UUID?,
        initialServer: String?,
        language: String?
    ) async throws -> String {
        let maxAttempts = max(1, SharedConfig.Defaults.transcriptionAutoRetryMaxAttempts)
        var attempt = 0

        while true {
            let attemptStart = Date()
            do {
                return try await WhisperClient.routeTranscription(
                    audioURL: audioURL, jobId: jobId, config: config,
                    correlationId: correlationId,
                    preferredServer: attempt == 0 ? initialServer : nil,
                    language: language)
            } catch WhisperError.cancelled {
                throw WhisperError.cancelled
            } catch {
                let attemptNumber = attempt + 1
                let attemptElapsed = Date().timeIntervalSince(attemptStart)
                let isRetryable = (error as? WhisperError)?.isRetryableConnectionFailure ?? false
                let attemptsRemain = attemptNumber < maxAttempts

                guard !Task.isCancelled else {
                    throw error
                }
                guard isRetryable else {
                    throw error
                }
                if !attemptsRemain {
                    FileLogger.shared.warn(.transcription, "transcription retries exhausted", payload: [
                        "jobId": jobId.uuidString,
                        "attempts": attemptNumber,
                        "error": error.localizedDescription
                    ])
                    throw error
                }

                guard attemptElapsed < SharedConfig.Defaults.transcriptionFastFailWindowSeconds else {
                    throw error
                }

                FileLogger.shared.debug(.transcription, "transcription attempt failed, retrying", payload: [
                    "jobId": jobId.uuidString,
                    "attempt": attemptNumber,
                    "error": error.localizedDescription
                ])
                try await Task.sleep(nanoseconds: UInt64(
                    SharedConfig.Defaults.transcriptionAutoRetryDelaySeconds * 1_000_000_000))
                attempt += 1
            }
        }
    }

    /// Loads saved audio for `jobId`, routes it through the unified transcription
    /// entrypoint, and on success cleans up the audio file + failed-job record.
    /// Returns the transcribed text on success; throws on failure. Does NOT touch
    /// `phase` or `activeID` — callers own delivery.
    private func transcribeSavedAudio(jobId: UUID) async throws -> String {
        // Idempotency guard — prevent concurrent retries of the same job.
        // This stops programmatic retry loops dead regardless of their source.
        retryLock.lock()
        if retryingJobIds.contains(jobId) {
            retryLock.unlock()
            FileLogger.shared.debug(.app, "retry skipped — already in flight",
                                    payload: ["jobId": jobId.uuidString])
            throw RetryAlreadyInFlight()
        }
        retryingJobIds.insert(jobId)
        retryLock.unlock()

        defer {
            retryLock.lock()
            retryingJobIds.remove(jobId)
            retryLock.unlock()
        }

        guard let record = FailedJobStore.shared.list().first(where: { $0.jobId == jobId }) else {
            FileLogger.shared.debug(.app, "retry: no record found",
                                    payload: ["jobId": jobId.uuidString])
            throw WhisperError.jobFailed("Saved audio no longer available")
        }

        let audioURL = URL(fileURLWithPath: record.audioFilePath)
        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            FileLogger.shared.debug(.app, "retry: audio file no longer exists", payload: [
                "jobId": jobId.uuidString,
                "path": record.audioFilePath
            ])
            throw WhisperError.jobFailed("Saved audio no longer available")
        }

        FailedJobStore.shared.incrementRetry(jobId: jobId)
        FileLogger.shared.debug(.app, "retry: starting transcription",
                                payload: ["jobId": jobId.uuidString,
                                          "path": record.audioFilePath,
                                          "attempt": record.retryCount + 1])

        let config = SharedConfig.load()
        do {
            let text = try await transcribeWithAutoRetry(
                audioURL: audioURL, jobId: jobId, config: config,
                correlationId: jobId, initialServer: nil,
                language: SharedConfig.keyboardLanguage().dictationLanguageField)

            // Add to persistent text history.
            TranscriptionHistory.shared.add(text: text)

            // Clean up — delete audio file first, then remove the record.
            try? FileManager.default.removeItem(at: audioURL)
            RecordingStore.shared.delete(jobId: jobId)
            FailedJobStore.shared.remove(jobId: jobId)

            FileLogger.shared.debug(.app, "retry succeeded, cleaning up",
                                    payload: ["jobId": jobId.uuidString])
            return text
        } catch WhisperError.cancelled {
            // Cancelled is not a failure — leave the failed-job record untouched.
            throw WhisperError.cancelled
        } catch {
            let errorMessage = error.localizedDescription
            FailedJobStore.shared.updateErrorMessage(jobId: jobId, message: errorMessage)
            throw error
        }
    }

    // MARK: - Retry As Live Dictation

    /// Retry a failed dictation from the error screen, going through the same
    /// phase transitions as a live dictation. The user sees the transcribing UI.
    func retryAsLiveDictation(jobId: UUID) async {
        // Transition to transcribing — user sees the loading UI
        activeID = jobId
        phase = .transcribing

        do {
            let text = try await transcribeSavedAudio(jobId: jobId)

            // Supersede guard — same pattern as stop()
            guard activeID == jobId else { return }

            phase = .done(text)
            FileLogger.shared.debug(.app, "retryAsLiveDictation succeeded",
                                   payload: ["jobId": jobId.uuidString])
        } catch is RetryAlreadyInFlight {
            // Skip — a concurrent retry for this job is already in flight.
            return
        } catch {
            guard activeID == jobId else { return }
            let message = error.localizedDescription
            phase = .error(message)
            FileLogger.shared.info(.app, "retryAsLiveDictation failed",
                                   payload: ["jobId": jobId.uuidString, "error": message])
        }
    }

    // MARK: - Stream Chunk Queue Helpers

    /// Background task that dequeues and sends chunks with unbounded retry
    /// while recording is active. Runs until the queue is empty AND recording
    /// has stopped (natural completion), or until cancelled.
    private func runChunkConsumer(client: WhisperStreamClient) async {
        let backoff = SharedConfig.Defaults.streamChunkRetryBackoffSeconds
        while !Task.isCancelled {
            let entry = chunkSendQueue.dequeue()

            guard let (chunkId, samples) = entry else {
                // Queue empty: check if recording is done
                let stillRecording = chunkSendQueue.isRecordingActive
                let queueEmpty = chunkSendQueue.isEmpty
                if !stillRecording && queueEmpty { return }
                try? await Task.sleep(nanoseconds: 100_000_000)
                continue
            }

            // Unbounded retry loop for this chunk
            var attempt = 0
            var sent = false
            while !sent && !Task.isCancelled {
                do {
                    try await client.sendChunk(id: chunkId, samples: samples)
                    sent = true
                    if attempt > 0 {
                        FileLogger.shared.info(.network, "Chunk sent after retries",
                                                payload: ["chunkId": chunkId, "attempts": attempt])
                    }
                } catch {
                    attempt += 1
                    FileLogger.shared.debug(.network, "Chunk send failed, retrying",
                                            payload: ["chunkId": chunkId, "attempt": attempt,
                                                      "error": error.localizedDescription])
                    let sleepIdx = min(attempt - 1, backoff.count - 1)
                    let sleepSec = backoff[sleepIdx]
                    do {
                        try await Task.sleep(nanoseconds: UInt64(sleepSec * 1_000_000_000))
                    } catch {
                        return
                    }
                }
            }
            if Task.isCancelled { return }
        }
    }

    /// Consolidated terminal failure handler for stream dictation. Preserves the
    /// WAV file in FailedJobStore, then delivers the error via the same multi-channel
    /// path as a normal result (app-group snapshot + Darwin notification +
    /// phase transition) per the retry-delivery-parity requirement.
    private func handleStreamTerminalFailure(jobId: UUID, error: String) {
        guard activeID == jobId else { return }

        let wavURL = RecordingStore.shared.streamWavURL(for: jobId)
        let wavExists = wavURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        let duration = recordingStartTime.map { Date().timeIntervalSince($0) } ?? 0

        if wavExists, let url = wavURL {
            FailedJobStore.shared.append(FailedJobRecord(
                jobId: jobId,
                audioFilePath: url.path,
                errorMessage: error,
                recordedDurationSeconds: duration,
                createdAt: Date(),
                retryCount: 0,
                lastRetriedAt: nil))
        }

        phase = .error(error)
    }

    /// Supersession exit for stop(): ends ONLY the caller-local background task.
    /// Does NOT cancel streamClient/streamRecorder/receiveTask/chunkConsumerTask —
    /// a superseding start(id:) has reassigned those to the new session and tearing
    /// them down here would clobber it. (Replaces the buggy cleanupStreamSession-
    /// on-supersession calls.)
    private func endStopBackgroundTask(_ id: inout UIBackgroundTaskIdentifier) {
        if id != .invalid {
            UIApplication.shared.endBackgroundTask(id)
            id = .invalid
        }
    }

    func cancel() async {
        FileLogger.shared.info(.transcription, "cancel: stream teardown")
        let id = activeID

        // Keep the localhost /state listener alive for cancelGraceSeconds so a
        // suspended keyboard can return and fetch the terminal .cancelled
        // snapshot (Darwin notifications are dropped while it is suspended).
        var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "DictationCancelGrace") {
            UIApplication.shared.endBackgroundTask(backgroundTaskID)
            backgroundTaskID = .invalid
        }
        Task {
            try? await Task.sleep(nanoseconds: UInt64(
                SharedConfig.Defaults.cancelGraceSeconds * 1_000_000_000))
            endStopBackgroundTask(&backgroundTaskID)
        }

        chunkConsumerTask?.cancel()
        chunkConsumerTask = nil
        receiveTask?.cancel()
        receiveTask = nil
        transcriptionTask?.cancel()
        transcriptionTask = nil
        chunkSendQueue.clearAll()
        await streamRecorder?.stop()
        guard activeID == id else { return }
        await streamClient?.disconnect()
        guard activeID == id else { return }
        streamClient = nil
        streamRecorder = nil

        FileLogger.shared.info(.transcription, "cancel: batch teardown")
        UIApplication.shared.isIdleTimerDisabled = false
        await recorder?.cleanup()
        guard activeID == id else { return }
        recorder = nil

        serverSelectionTask?.cancel()
        serverSelectionTask = nil
        selectedServer = nil

        guard activeID == id else { return }
        if let currentId = activeID {
            RecordingStore.shared.deleteStreamWav(for: currentId)
        }
        if case .done = phase {
            FileLogger.shared.info(.transcription, "cancel: preserving .done from racing task, skipping cancelled publish")
        } else if case .error = phase {
            FileLogger.shared.info(.transcription, "cancel: preserving .error from racing task, skipping cancelled publish")
        } else {
            FileLogger.shared.info(.transcription, "cancel: publishing cancelled snapshot to keyboard")
            phase = .cancelled
        }
        activeID = nil
        // Retain the terminal .cancelled payload in the localhost /state holder
        // for terminalStateRetentionSeconds so a suspended/reappearing keyboard
        // can still fetch it; id-matching on the keyboard side makes a stale
        // payload harmless to a later session.
        let holder = lastPayloadHolder
        let clearedId = id
        Task.detached(priority: .utility) {
            try? await Task.sleep(nanoseconds: UInt64(
                SharedConfig.Defaults.terminalStateRetentionSeconds * 1_000_000_000))
            if holder.get()?.id == clearedId {
                holder.set(nil)
            }
        }
    }

    deinit {
        healthCheckTimer?.invalidate()
    }
}
