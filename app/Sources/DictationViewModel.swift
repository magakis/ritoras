import Foundation
import AVFoundation
import UIKit

/// Thread-safe in-memory queue of audio chunks awaiting WebSocket send.
/// Shared between the VAD audio thread (producer, off-MainActor), the
/// @MainActor view model, and the background consumer Task. Marked
/// @unchecked Sendable because all access is serialized via internal NSLock.
final class ChunkSendQueue: @unchecked Sendable {
    private var chunks: [(UInt32, [Float])] = []
    private var overflowed = false
    private var recordingActive = false
    private let lock = NSLock()

    /// Returns true if enqueued; false if dropped (queue at capacity, sets overflowed).
    func enqueue(id: UInt32, samples: [Float], maxDepth: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if chunks.count >= maxDepth {
            overflowed = true
            return false
        }
        chunks.append((id, samples))
        return true
    }

    func dequeue() -> (UInt32, [Float])? {
        lock.lock(); defer { lock.unlock() }
        guard !chunks.isEmpty else { return nil }
        return chunks.removeFirst()
    }

    var isEmpty: Bool { lock.lock(); defer { lock.unlock() }; return chunks.isEmpty }
    var depth: Int { lock.lock(); defer { lock.unlock() }; return chunks.count }
    var hasOverflowed: Bool { lock.lock(); defer { lock.unlock() }; return overflowed }
    var isRecordingActive: Bool { lock.lock(); defer { lock.unlock() }; return recordingActive }

    func setRecordingActive(_ value: Bool) {
        lock.lock(); defer { lock.unlock() }
        recordingActive = value
    }

    /// Reset queue contents + overflow flag for a new recording (keeps recordingActive).
    func resetForNewRecording() {
        lock.lock(); defer { lock.unlock() }
        chunks.removeAll()
        overflowed = false
    }

    /// Full reset including recordingActive (used by cancel).
    func clearAll() {
        lock.lock(); defer { lock.unlock() }
        chunks.removeAll()
        overflowed = false
        recordingActive = false
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
            DarwinNotifier.post(SharedConfig.Defaults.darwinStateChangedNotificationName)  // LAST — only signal after data is visible
        }
    }
    @Published private(set) var livePartial: String = ""
    @Published private(set) var activeModeLabel: String = ""

    // MARK: - Localhost Server (Phase 1)

    private var localhostServer: LocalhostServer?

    /// Monotonic revision counter for app-group snapshot writes.
    /// Bumped on every write so the keyboard can detect freshness.
    private var snapshotRevision: UInt64 = 0

    private var recorder: AudioRecorder?
    private var activeID: UUID?
    private var recordingStartTime: Date?

    private var streamRecorder: StreamingAudioRecorder?
    private var streamClient: WhisperStreamClient?

    private var selectedServer: String?
    private var serverSelectionTask: Task<String?, Never>?

    // MARK: - Stream Chunk Queue

    private let chunkSendQueue = ChunkSendQueue()
    private var chunkConsumerTask: Task<Void, Never>?
    private var receiveTask: Task<String, Error>?
    private var transcriptionTask: Task<Void, Never>?

    /// Idempotency guard: tracks job IDs currently being retried to prevent
    /// concurrent retries of the same job (defense against retry loops).
    private var retryingJobIds: Set<UUID> = []
    private let retryLock = NSLock()

    // MARK: - Localhost Server Helpers

    /// Starts the localhost HTTP server if not already running. Idempotent.
    func startLocalhostServer() {
        guard localhostServer == nil else {
            FileLogger.shared.debug(.network, "DictationViewModel: localhost server already running")
            return
        }

        let server = LocalhostServer(port: SharedConfig.Defaults.localhostServerPort)

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
        SharedConfig.setDictationSnapshot(payload)
    }



    func start(id: UUID) async {
        activeID = id
        livePartial = ""
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
                        }
                    })
                }

                let recorder = StreamingAudioRecorder()
                streamRecorder = recorder

                let wavURL = RecordingStore.shared.streamWavURL(for: id)
                try await recorder.start(fileURL: wavURL) { [chunkQueue = self.chunkSendQueue] chunkId, samples in
                    FileLogger.shared.debug(.audio, "Stream: chunk produced",
                                            payload: ["chunkId": chunkId, "sampleCount": samples.count])
                    if !chunkQueue.enqueue(id: chunkId, samples: samples,
                                           maxDepth: SharedConfig.Defaults.streamChunkQueueMaxDepth) {
                        FileLogger.shared.debug(.network, "Chunk queue overflow — dropping chunk",
                                               payload: ["chunkId": chunkId, "queueDepth": chunkQueue.depth])
                    }
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

                defer { self.transcriptionTask = nil }

                let uploadT0 = Date()

                do {
                    let audioBytes = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? UInt64 ?? 0

                    // Use probe result if already available, otherwise let transcribe iterate servers.
                    let chosenServer = selectedServer
                    serverSelectionTask?.cancel()
                    serverSelectionTask = nil

                    FileLogger.shared.info(.transcription, "upload start", payload: [
                        "id": id.uuidString,
                        "audioBytes": audioBytes,
                        "serverCount": config.servers.count,
                        "server": chosenServer ?? config.servers.first ?? ""
                    ])

                    let text: String
                    let duration = recordingStartTime.map { Date().timeIntervalSince($0) } ?? 0
                    do {
                        text = try await WhisperClient.transcribeAsync(
                            audioURL: url, jobId: id, config: config, correlationId: activeID, preferredServer: chosenServer)
                        FileLogger.shared.debug(.network, "async transcription succeeded",
                                                payload: ["textLength": text.count])
                    } catch WhisperError.asyncUnsupported {
                        FileLogger.shared.info(.network, "async unsupported (404), falling back to sync", payload: [:])
                        if let server = chosenServer, config.servers.contains(server) {
                            text = try await WhisperClient.transcribe(audioURL: url, serverURL: server, correlationId: activeID)
                        } else {
                            text = try await WhisperClient.transcribe(audioURL: url, config: config, correlationId: activeID)
                        }
                    }
                    guard activeID == id else { return }

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
                    // User cancelled — do not record as failure.
                    FileLogger.shared.debug(.app, "transcription cancelled",
                                            payload: ["jobId": id.uuidString])
                    phase = .cancelled
                } catch {
                    guard activeID == id else { return }
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

            guard activeID == id else {
                await cleanupStreamSession(backgroundTaskID: &backgroundTaskID)
                return
            }
            chunkSendQueue.setRecordingActive(false)

            var queueDrained = false
            var finalOverflowed = false
            let drainHardCap = Date().addingTimeInterval(SharedConfig.Defaults.streamFinalTimeout)
            while Date() < drainHardCap {
                if chunkSendQueue.isEmpty { queueDrained = true; break }
                if chunkSendQueue.hasOverflowed { finalOverflowed = true; break }
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard activeID == id else {
                    await cleanupStreamSession(backgroundTaskID: &backgroundTaskID)
                    return
                }
            }

            chunkConsumerTask?.cancel()
            chunkConsumerTask = nil

            let uploadT0 = Date()

            if queueDrained && !finalOverflowed {
                do {
                    try await streamClient?.sendEnd()
                    FileLogger.shared.info(.network, "Stream: END sent, awaiting final from receive task")

                    FileLogger.shared.info(.transcription, "upload start", payload: [
                        "id": id.uuidString
                    ])

                    let text = try await receiveTask?.value ?? ""

                    guard activeID == id else {
                        await cleanupStreamSession(backgroundTaskID: &backgroundTaskID)
                        return
                    }

                    let uploadElapsed = Date().timeIntervalSince(uploadT0) * 1000
                    FileLogger.shared.info(.transcription, "upload complete", payload: [
                        "id": id.uuidString,
                        "elapsed_ms": uploadElapsed,
                        "textLength": text.count
                    ])

                    FileLogger.shared.info(.transcription, "Stream final received",
                                           payload: ["preview": String(text.prefix(60)),
                                                     "length": text.count])

                    guard activeID == id else {
                        await cleanupStreamSession(backgroundTaskID: &backgroundTaskID)
                        return
                    }

                    TranscriptionHistory.shared.add(text: text)
                    RecordingStore.shared.deleteStreamWav(for: id)
                    FileLogger.shared.debug(.audio, "stream wav deleted on success",
                                            payload: ["jobId": id.uuidString])
                    phase = .done(text)
                } catch WhisperError.cancelled {
                    // User cancelled — do not record as failure.
                    RecordingStore.shared.deleteStreamWav(for: id)
                    FileLogger.shared.debug(.app, "transcription cancelled, wav deleted",
                                            payload: ["jobId": id.uuidString])
                    phase = .cancelled
                } catch {
                    guard activeID == id else {
                        await cleanupStreamSession(backgroundTaskID: &backgroundTaskID)
                        return
                    }
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
            streamClient = nil
            streamRecorder = nil
        }
    }

    // MARK: - Recovery (Phase 4)

    /// Retries a failed transcription job from saved audio. Structurally
    /// isolated from `activeID` — does NOT fire Darwin notifications,
    /// publishes directly to app-group (no HTTP server), and refuses to run while a
    /// live dictation is in `.recording` or `.transcribing` phase.
    func retry(jobId: UUID) async {
        // HARD GUARD: never retry while a live dictation is in flight.
        // phase may be .recording at startup before any dictation without
        // an active recorder — that's the idle state, not "live". A live
        // dictation only exists when an AudioRecorder or StreamingAudioRecorder
        // is actively recording.
        switch phase {
        case .transcribing:
            return  // definitely live
        case .recording:
            // .recording at startup (no recorder) is not live; only block
            // if a recorder is actually active.
            if recorder != nil || streamRecorder != nil {
                return
            }
        default:
            break
        }

        // Idempotency guard — prevent concurrent retries of the same job.
        // This stops programmatic retry loops dead regardless of their source.
        retryLock.lock()
        if retryingJobIds.contains(jobId) {
            retryLock.unlock()
            FileLogger.shared.debug(.app, "retry skipped — already in flight",
                                    payload: ["jobId": jobId.uuidString])
            return
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
            return
        }

        let audioURL = URL(fileURLWithPath: record.audioFilePath)
        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            FileLogger.shared.debug(.app, "retry: audio file no longer exists", payload: [
                "jobId": jobId.uuidString,
                "path": record.audioFilePath
            ])
            return
        }

        FailedJobStore.shared.incrementRetry(jobId: jobId)
        FileLogger.shared.debug(.app, "retry: starting transcription",
                                payload: ["jobId": jobId.uuidString,
                                          "path": record.audioFilePath,
                                          "attempt": record.retryCount + 1])

        let config = SharedConfig.load()
        do {
            let text = try await WhisperClient.transcribe(
                audioURL: audioURL, config: config, correlationId: jobId)
            handleRetrySuccess(text: text, jobId: jobId, audioURL: audioURL)
        } catch WhisperError.cancelled {
            FileLogger.shared.debug(.app, "retry cancelled", payload: ["jobId": jobId.uuidString])
            phase = .cancelled
        } catch {
            handleRetryFailure(error: error, jobId: jobId)
        }
    }

    // MARK: - Retry Helpers

    /// Handles a successful retry: delivers to clipboard, persists in history,
    /// publishes to app-group snapshot, then cleans up audio file and failed-job record.
    private func handleRetrySuccess(text: String, jobId: UUID, audioURL: URL) {
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

        // Add to persistent text history.
        TranscriptionHistory.shared.add(text: text)

        // Clean up — delete audio file first, then remove the record.
        try? FileManager.default.removeItem(at: audioURL)
        RecordingStore.shared.delete(jobId: jobId)
        FailedJobStore.shared.remove(jobId: jobId)

        FileLogger.shared.debug(.app, "retry succeeded, cleaning up",
                                payload: ["jobId": jobId.uuidString])
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

    // MARK: - Retry As Live Dictation

    /// Retry a failed dictation from the error screen, going through the same
    /// phase transitions as a live dictation. The user sees the transcribing UI.
    func retryAsLiveDictation(jobId: UUID) async {
        // Idempotency guard — prevent concurrent retries of the same job.
        retryLock.lock()
        if retryingJobIds.contains(jobId) {
            retryLock.unlock()
            FileLogger.shared.debug(.app, "retryAsLiveDictation skipped — already in flight",
                                    payload: ["jobId": jobId.uuidString])
            return
        }
        retryingJobIds.insert(jobId)
        retryLock.unlock()

        defer {
            retryLock.lock()
            retryingJobIds.remove(jobId)
            retryLock.unlock()
        }

        // Look up the saved audio
        guard let record = FailedJobStore.shared.list().first(where: { $0.jobId == jobId }),
              FileManager.default.fileExists(atPath: record.audioFilePath) else {
            FileLogger.shared.debug(.app, "retryAsLiveDictation: audio not found",
                                   payload: ["jobId": jobId.uuidString])
            phase = .error("Saved audio no longer available")
            return
        }

        let audioURL = URL(fileURLWithPath: record.audioFilePath)
        let config = SharedConfig.load()

        // Transition to transcribing — user sees the loading UI
        activeID = jobId
        phase = .transcribing

        do {
            let text = try await WhisperClient.transcribe(
                audioURL: audioURL, config: config, correlationId: jobId)

            // Supersede guard — same pattern as stop()
            guard activeID == jobId else { return }

            // Deliver transcript
            TranscriptionHistory.shared.add(text: text)

            // Clean up audio file and failed-job record
            try? FileManager.default.removeItem(at: audioURL)
            RecordingStore.shared.delete(jobId: jobId)
            FailedJobStore.shared.remove(jobId: jobId)

            phase = .done(text)
            FileLogger.shared.debug(.app, "retryAsLiveDictation succeeded",
                                   payload: ["jobId": jobId.uuidString])
        } catch {
            guard activeID == jobId else { return }
            let message = error.localizedDescription
            FailedJobStore.shared.updateErrorMessage(jobId: jobId, message: message)
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

    /// Cleans up stream session resources: ends background task, disconnects
    /// WebSocket, and nils out stream references. Idempotent — safe to call
    /// multiple times or on already-cleaned-up sessions.
    private func cleanupStreamSession(backgroundTaskID: inout UIBackgroundTaskIdentifier) async {
        chunkSendQueue.setRecordingActive(false)
        chunkConsumerTask?.cancel()
        chunkConsumerTask = nil
        receiveTask?.cancel()
        receiveTask = nil
        if backgroundTaskID != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTaskID)
            backgroundTaskID = .invalid
        }
        await streamClient?.disconnect()
        streamClient = nil
        streamRecorder = nil
    }

    func cancel() async {
        FileLogger.shared.info(.transcription, "cancel: stream teardown")
        chunkConsumerTask?.cancel()
        chunkConsumerTask = nil
        receiveTask?.cancel()
        receiveTask = nil
        transcriptionTask?.cancel()
        transcriptionTask = nil
        chunkSendQueue.clearAll()
        await streamRecorder?.stop()
        await streamClient?.disconnect()
        streamClient = nil
        streamRecorder = nil

        FileLogger.shared.info(.transcription, "cancel: batch teardown")
        UIApplication.shared.isIdleTimerDisabled = false
        await recorder?.cleanup()
        recorder = nil

        serverSelectionTask?.cancel()
        serverSelectionTask = nil
        selectedServer = nil

        if let id = activeID {
            RecordingStore.shared.deleteStreamWav(for: id)
        }
        activeID = nil
    }
}
