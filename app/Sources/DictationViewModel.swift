import Foundation
import AVFoundation
import UIKit

/// Thread-safe storage for completed dictation results. Shared between
/// @MainActor view model code (writes) and LocalhostServer's @Sendable
/// resultProvider closure (reads). Marked @unchecked Sendable because
/// all access is serialized via internal NSLock.
final class ResultStore: @unchecked Sendable {
    private var results: [UUID: DictationResultSnapshot] = [:]
    private let lock = NSLock()

    func get(_ id: UUID) -> DictationResultSnapshot? {
        lock.lock(); defer { lock.unlock() }
        return results[id]
    }

    func set(_ result: DictationResultSnapshot, for id: UUID) {
        lock.lock(); defer { lock.unlock() }
        results[id] = result
    }
}

@MainActor
final class DictationViewModel: ObservableObject {
    enum DictationPhase: Equatable {
        case recording
        case transcribing
        case done(String)
        case error(String)
    }

    @Published var phase: DictationPhase = .recording {
        didSet {
            updateStateSnapshot()
            DarwinNotifier.post(SharedConfig.Defaults.darwinStateChangedNotificationName)
            storeTerminalResultIfNeeded()
        }
    }
    @Published private(set) var livePartial: String = ""
    @Published private(set) var activeModeLabel: String = ""

    // MARK: - Localhost Server (Phase 1)

    private var localhostServer: LocalhostServer?

    /// Thread-safe guard for state snapshots read by the HTTP server's
    /// background connection handlers. Nested with `resultStore`
    /// writes in terminal-transition `didSet`.
    private let stateLock = NSLock()
    /// Snapshot updated on every `phase` change, safe for background reads.
    private var safeStateSnapshot = DictationStateSnapshot(phase: "idle", activeID: nil, startedAt: nil)
    /// Terminal results by job ID, populated on `.done` / `.error` transitions.
    private let resultStore = ResultStore()

    private var recorder: AudioRecorder?
    private var activeID: UUID?
    private var recordingStartTime: Date?

    private var streamRecorder: StreamingAudioRecorder?
    private var streamClient: WhisperStreamClient?

    private var selectedServer: String?
    private var serverSelectionTask: Task<String?, Never>?

    // MARK: - Stream Chunk Queue

    private let chunkQueueLock = NSLock()
    private var chunkQueue: [(UInt32, [Float])] = []
    private var chunkQueueOverflowed = false
    private var chunkConsumerTask: Task<Void, Never>?
    private var recordingActive = false

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

        let server = LocalhostServer(
            port: SharedConfig.Defaults.localhostServerPort,
            stateProvider: { [weak self] in
                guard let self = self else {
                    return DictationStateSnapshot(phase: "idle", activeID: nil, startedAt: nil)
                }
                self.stateLock.lock()
                let snapshot = self.safeStateSnapshot
                self.stateLock.unlock()
                return snapshot
            },
            resultProvider: { [weak self] id in
                return self?.resultStore.get(id)
            }
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

    /// Snapshots the current `@MainActor` state into the lock-guarded
    /// `safeStateSnapshot` so that background HTTP handlers can read it.
    private func updateStateSnapshot() {
        let phaseStr: String
        switch phase {
        case .recording:     phaseStr = "recording"
        case .transcribing:  phaseStr = "transcribing"
        case .done:          phaseStr = "done"
        case .error:         phaseStr = "error"
        }
        let snapshot = DictationStateSnapshot(
            phase: phaseStr,
            activeID: activeID?.uuidString,
            startedAt: recordingStartTime
        )
        stateLock.lock()
        safeStateSnapshot = snapshot
        stateLock.unlock()
    }

    /// Captures terminal results (`.done`, `.error`) into `resultStore`
    /// so the localhost server can serve them via `/result`.
    private func storeTerminalResultIfNeeded() {
        guard let id = activeID else { return }
        let result: DictationResultSnapshot?
        switch phase {
        case .done(let text):
            result = DictationResultSnapshot(
                id: id.uuidString,
                status: "completed",
                text: text,
                errorMessage: nil,
                timestamp: Date()
            )
        case .error(let msg):
            result = DictationResultSnapshot(
                id: id.uuidString,
                status: "error",
                text: nil,
                errorMessage: msg,
                timestamp: Date()
            )
        default:
            result = nil
        }
        guard let result = result else { return }
        resultStore.set(result, for: id)
    }

    // MARK: - Clipboard Transport

    /// Writes the dictation result to the clipboard as a MULTI-TYPE pasteboard
    /// entry so the keyboard can auto-read and auto-insert it:
    ///   - `public.utf8-plain-text`: the clean transcription text, so manual paste
    ///     and other apps behave exactly as before.
    ///   - `org.ritoras.dictation`: a tagged JSON payload ({source, id, status,
    ///     text, timestamp}) the keyboard uses to identify our result and insert it.
    ///
    /// The clipboard is the reliable cross-process channel under SideStore signing,
    /// where the App Group container is NOT shared between the app and the keyboard.
    /// Only terminal statuses are written, so we don't clobber the user's clipboard
    /// while recording/transcribing.
    private func writeToClipboard(status: String, text: String? = nil, errorMessage: String? = nil) {
        guard status == "completed" || status == "error" || status == "cancelled" else { return }
        guard let id = activeID else { return }

        var payload: [String: Any] = [
            "source": "ritoras",
            "id": id.uuidString,
            "status": status,
            "timestamp": Date().timeIntervalSince1970,
        ]
        if let text = text { payload["text"] = text }
        if let errorMessage = errorMessage { payload["errorMessage"] = errorMessage }
        guard let jsonData = try? JSONSerialization.data(withJSONObject: payload) else { return }

        var item: [String: Any] = ["org.ritoras.dictation": jsonData]
        // Clean plain text only on success, so manual paste yields the words.
        if status == "completed", let text = text, !text.isEmpty {
            item["public.utf8-plain-text"] = text
        }
        UIPasteboard.general.setItems([item], options: [:])
    }

    // MARK: - Server Transport

    /// Posts dictation status to the Whisper server so the keyboard can poll
    /// for results. Works even when the app is backgrounded (clipboard fails).
    private func postResultToServer(status: String, text: String? = nil, errorMessage: String? = nil) {
        let config = SharedConfig.load()
        let candidate = SharedConfig.selectedServer()
        let resolved = (config.servers.contains(candidate ?? "") ? candidate : nil) ?? config.servers.first
        let server = resolved?.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let baseURL = server, !baseURL.isEmpty else {
            FileLogger.shared.warn(.network, "postResultToServer: no server configured")
            return
        }
        guard let url = URL(string: "\(baseURL)/dictation_result") else {
            FileLogger.shared.warn(.network, "postResultToServer: invalid URL",
                                   payload: ["baseURL": baseURL])
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10

        var payload: [String: Any] = [
            "source": "ritoras",
            "timestamp": Date().timeIntervalSince1970,
            "status": status
        ]
        if let text = text { payload["text"] = text }
        if let errorMessage = errorMessage { payload["errorMessage"] = errorMessage }

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        } catch {
            FileLogger.shared.error(.network, "postResultToServer: failed to serialize JSON",
                                    payload: ["error": error.localizedDescription])
            return
        }

        FileLogger.shared.info(.network, "postResultToServer: POSTing",
                               payload: ["url": url.absoluteString, "status": status])
        URLSession.shared.dataTask(with: request) { _, response, error in
            if let error = error {
                FileLogger.shared.error(.network, "postResultToServer: error",
                                        payload: ["error": error.localizedDescription])
            } else if let response = response as? HTTPURLResponse {
                FileLogger.shared.info(.network, "postResultToServer: response",
                                       payload: ["statusCode": response.statusCode])
            }
        }.resume()
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
        FileLogger.shared.info(.transcription, "dictation start", payload: [
            "id": id.uuidString,
            "mode": mode == .stream ? "stream" : "batch"
        ])

        writeToClipboard(status: "recording")
        postResultToServer(status: "recording")

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
                writeToClipboard(status: "error", errorMessage: message)
                postResultToServer(status: "error", errorMessage: message)
                DarwinNotifier.post(SharedConfig.Defaults.darwinNotificationName)
                phase = .error(message)
                serverSelectionTask?.cancel()
                serverSelectionTask = nil
                selectedServer = nil
                return
            }
        case .denied:
            let message = "Microphone access denied. Enable it in Settings \u{2192} Ritoras."
            writeToClipboard(status: "error", errorMessage: message)
            postResultToServer(status: "error", errorMessage: message)
            DarwinNotifier.post(SharedConfig.Defaults.darwinNotificationName)
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

        activeModeLabel = mode == .stream ? "STREAM" : "BATCH"

        switch mode {
        case .batch:
            do {
                try AudioSession.configure()
                let newRecorder = AudioRecorder()
                _ = try await newRecorder.startRecording(jobId: id)
                recorder = newRecorder
                recordingStartTime = Date()
                UIApplication.shared.isIdleTimerDisabled = true
            } catch {
                let message = error.localizedDescription
                writeToClipboard(status: "error", errorMessage: message)
                postResultToServer(status: "error", errorMessage: message)
                DarwinNotifier.post(SharedConfig.Defaults.darwinNotificationName)
                phase = .error(message)
            }

        case .stream:
            FileLogger.shared.info(.transcription, "start mode: stream")

            livePartial = ""

            let config = SharedConfig.load()

            do {
                try AudioSession.configure()

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
                                FileLogger.shared.warn(.network, "Stream: probe-selected server failed",
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
                            FileLogger.shared.warn(.network, "Stream: server failed",
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

                let recorder = StreamingAudioRecorder()
                streamRecorder = recorder

                let wavURL = RecordingStore.shared.streamWavURL(for: id)
                try await recorder.start(fileURL: wavURL) { [weak self] chunkId, samples in
                    FileLogger.shared.debug(.audio, "Stream: chunk produced",
                                            payload: ["chunkId": chunkId, "sampleCount": samples.count])
                    self?.enqueueChunk(id: chunkId, samples: samples)
                }
                FileLogger.shared.info(.audio, "Stream: recorder started")

                // Reset queue state and launch consumer
                chunkQueueLock.lock()
                chunkQueue.removeAll()
                chunkQueueOverflowed = false
                recordingActive = true
                chunkQueueLock.unlock()
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
                writeToClipboard(status: "error", errorMessage: message)
                postResultToServer(status: "error", errorMessage: message)
                DarwinNotifier.post(SharedConfig.Defaults.darwinNotificationName)
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
                writeToClipboard(status: "error", errorMessage: message)
                postResultToServer(status: "error", errorMessage: message)
                DarwinNotifier.post(SharedConfig.Defaults.darwinNotificationName)
                phase = .error(message)
                return
            }

            phase = .transcribing
            postResultToServer(status: "transcribing")
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

            let uploadT0 = Date()

            do {
                let audioBytes = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? UInt64 ?? 0

                // Await probe result with 3s cap; fall back to iterating transcribe on timeout.
                let probeResult: String?
                if let task = serverSelectionTask {
                    FileLogger.shared.debug(.network, "stop probe await start", payload: ["active_id": activeID?.uuidString ?? "nil"])
                    probeResult = await withTaskGroup(of: String?.self) { group in
                        group.addTask { await task.value }
                        group.addTask {
                            try? await Task.sleep(nanoseconds: 3_000_000_000)
                            return nil
                        }
                        let first = await group.next()
                        group.cancelAll()
                        return first ?? nil
                    }
                } else {
                    probeResult = nil
                }
                let chosenServer = probeResult ?? config.servers.first
                FileLogger.shared.debug(.network, "stop probe await done", payload: ["probe_result": probeResult ?? "nil", "chosen": chosenServer ?? "nil"])
                serverSelectionTask?.cancel()
                serverSelectionTask = nil

                FileLogger.shared.info(.transcription, "upload start", payload: [
                    "id": id.uuidString,
                    "audioBytes": audioBytes,
                    "serverCount": config.servers.count,
                    "server": probeResult ?? config.servers.first ?? ""
                ])

                let text: String
                let duration = recordingStartTime.map { Date().timeIntervalSince($0) } ?? 0
                if duration >= SharedConfig.AsyncTranscription.longAudioThresholdSeconds {
                    do {
                        text = try await WhisperClient.transcribeAsync(
                            audioURL: url, jobId: id, config: config, correlationId: activeID)
                        FileLogger.shared.debug(.network, "async transcription succeeded",
                                                payload: ["durationSec": duration, "textLength": text.count])
                    } catch WhisperError.asyncUnsupported {
                        FileLogger.shared.info(.network, "async unsupported, falling back to sync",
                                               payload: ["durationSec": duration])
                        // Fall through to the sync path below.
                        if let server = chosenServer, config.servers.contains(server) {
                            text = try await WhisperClient.transcribe(audioURL: url, serverURL: server, correlationId: activeID)
                        } else {
                            text = try await WhisperClient.transcribe(audioURL: url, config: config, correlationId: activeID)
                        }
                    }
                } else {
                    if let server = chosenServer, config.servers.contains(server) {
                        do {
                            text = try await WhisperClient.transcribe(audioURL: url, serverURL: server, correlationId: activeID)
                        } catch {
                            FileLogger.shared.warn(.network, "single-server transcribe failed, falling back to iterating transcribe",
                                                   payload: ["server": server, "error": error.localizedDescription])
                            text = try await WhisperClient.transcribe(audioURL: url, config: config, correlationId: activeID)
                        }
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

                let ucTime = Date()
                writeToClipboard(status: "completed", text: text)
                FileLogger.shared.debug(.transcription, "result delivered", payload: [
                    "id": id.uuidString, "channel": "clipboard",
                    "elapsed_ms_since_upload_complete": Date().timeIntervalSince(ucTime) * 1000
                ])
                postResultToServer(status: "completed", text: text)
                FileLogger.shared.debug(.transcription, "result delivered", payload: [
                    "id": id.uuidString, "channel": "server",
                    "elapsed_ms_since_upload_complete": Date().timeIntervalSince(ucTime) * 1000
                ])
                FileLogger.shared.debug(.network, "stop posting darwin", payload: ["active_id": activeID?.uuidString ?? "nil", "elapsed_since_stop_start": Date().timeIntervalSince(stopStartTime) * 1000])
                DarwinNotifier.post(SharedConfig.Defaults.darwinNotificationName)
                FileLogger.shared.info(.transcription, "result delivered", payload: [
                    "id": id.uuidString, "channel": "darwin",
                    "elapsed_ms_since_upload_complete": Date().timeIntervalSince(ucTime) * 1000
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
                writeToClipboard(status: "error", errorMessage: message)
                postResultToServer(status: "error", errorMessage: message)
                DarwinNotifier.post(SharedConfig.Defaults.darwinNotificationName)
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
                    FileLogger.shared.warn(.app, "failed-job record SKIPPED — audio file not found", payload: [
                        "jobId": id.uuidString,
                        "audioPath": url.path
                    ])
                }
                phase = .error(message)
            }

            if backgroundTaskID != .invalid {
                UIApplication.shared.endBackgroundTask(backgroundTaskID)
                backgroundTaskID = .invalid
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
            postResultToServer(status: "transcribing")
            UIApplication.shared.isIdleTimerDisabled = false

            var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
            backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "WhisperTranscription") {
                UIApplication.shared.endBackgroundTask(backgroundTaskID)
                backgroundTaskID = .invalid
            }

            // Signal recording done and drain queue
            chunkQueueLock.lock()
            recordingActive = false
            chunkQueueLock.unlock()

            await streamRecorder?.stop()

            guard activeID == id else { return }

            let drainDeadline = Date().addingTimeInterval(SharedConfig.Defaults.streamFinalTimeout)
            var queueDrained = false
            var finalOverflowed = false
            while Date() < drainDeadline {
                chunkQueueLock.lock()
                let empty = chunkQueue.isEmpty
                finalOverflowed = chunkQueueOverflowed
                chunkQueueLock.unlock()
                if empty { queueDrained = true; break }
                if finalOverflowed { break }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }

            chunkConsumerTask?.cancel()
            chunkConsumerTask = nil

            let uploadT0 = Date()

            if queueDrained && !finalOverflowed {
                do {
                    try await streamClient?.sendEnd()
                    FileLogger.shared.info(.network, "Stream: END sent, awaiting final")

                    FileLogger.shared.info(.transcription, "upload start", payload: [
                        "id": id.uuidString
                    ])

                    let text = try await streamClient?.receiveMessages { [weak self] partial in
                        FileLogger.shared.debug(.transcription, "livePartial updated",
                                                payload: ["preview": String(partial.prefix(60)),
                                                          "length": partial.count])
                        Task { @MainActor in
                            self?.livePartial = partial
                        }
                    } ?? ""

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

                    let ucTime = Date()
                    writeToClipboard(status: "completed", text: text)
                    FileLogger.shared.debug(.transcription, "result delivered", payload: [
                        "id": id.uuidString, "channel": "clipboard",
                        "elapsed_ms_since_upload_complete": Date().timeIntervalSince(ucTime) * 1000
                    ])
                    postResultToServer(status: "completed", text: text)
                    FileLogger.shared.debug(.transcription, "result delivered", payload: [
                        "id": id.uuidString, "channel": "server",
                        "elapsed_ms_since_upload_complete": Date().timeIntervalSince(ucTime) * 1000
                    ])
                    DarwinNotifier.post(SharedConfig.Defaults.darwinNotificationName)
                    FileLogger.shared.info(.transcription, "result delivered", payload: [
                        "id": id.uuidString, "channel": "darwin",
                        "elapsed_ms_since_upload_complete": Date().timeIntervalSince(ucTime) * 1000
                    ])
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

            await streamClient?.disconnect()
            streamClient = nil
            streamRecorder = nil
        }
    }

    // MARK: - Recovery (Phase 4)

    /// Retries a failed transcription job from saved audio. Structurally
    /// isolated from `activeID` — does NOT fire Darwin notifications,
    /// does NOT call `postResultToServer`, and refuses to run while a
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
            FileLogger.shared.warn(.app, "retry: audio file no longer exists", payload: [
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
        } catch {
            handleRetryFailure(error: error, jobId: jobId)
        }
    }

    // MARK: - Retry Helpers

    /// Handles a successful retry: delivers to clipboard, persists in history,
    /// stores in resultStore, then cleans up audio file and failed-job record.
    private func handleRetrySuccess(text: String, jobId: UUID, audioURL: URL) {
        // Deliver to clipboard — mirror the writeToClipboard pattern
        // but write directly since activeID is nil during recovery.
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

        // Store in resultStore so localhost server can serve it.
        resultStore.set(DictationResultSnapshot(
            id: jobId.uuidString, status: "completed", text: text,
            errorMessage: nil, timestamp: Date()), for: jobId)

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
        FileLogger.shared.warn(.app, "retry failed", payload: [
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
            FileLogger.shared.warn(.app, "retryAsLiveDictation: audio not found",
                                   payload: ["jobId": jobId.uuidString])
            phase = .error("Saved audio no longer available")
            return
        }

        let audioURL = URL(fileURLWithPath: record.audioFilePath)
        let config = SharedConfig.load()

        // Transition to transcribing — user sees the loading UI
        activeID = jobId
        phase = .transcribing
        postResultToServer(status: "transcribing")

        do {
            let text = try await WhisperClient.transcribe(
                audioURL: audioURL, config: config, correlationId: jobId)

            // Supersede guard — same pattern as stop()
            guard activeID == jobId else { return }

            // Deliver via the same path as stop()'s success
            let ucTime = Date()
            writeToClipboard(status: "completed", text: text)
            FileLogger.shared.debug(.transcription, "retryAsLiveDictation result delivered", payload: [
                "jobId": jobId.uuidString, "channel": "clipboard",
                "elapsed_ms_since_upload_complete": Date().timeIntervalSince(ucTime) * 1000
            ])
            postResultToServer(status: "completed", text: text)
            FileLogger.shared.debug(.transcription, "retryAsLiveDictation result delivered", payload: [
                "jobId": jobId.uuidString, "channel": "server",
                "elapsed_ms_since_upload_complete": Date().timeIntervalSince(ucTime) * 1000
            ])
            DarwinNotifier.post(SharedConfig.Defaults.darwinNotificationName)
            FileLogger.shared.info(.transcription, "retryAsLiveDictation result delivered", payload: [
                "jobId": jobId.uuidString, "channel": "darwin",
                "elapsed_ms_since_upload_complete": Date().timeIntervalSince(ucTime) * 1000
            ])
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
            FileLogger.shared.warn(.app, "retryAsLiveDictation failed",
                                  payload: ["jobId": jobId.uuidString, "error": message])
        }
    }

    // MARK: - Stream Chunk Queue Helpers

    /// Enqueues a chunk for the consumer to send. Must return in microseconds —
    /// called from the VAD audio thread. Drops the chunk if the queue is at
    /// capacity (overflow is tracked as terminal failure at stop time).
    private func enqueueChunk(id: UInt32, samples: [Float]) {
        chunkQueueLock.lock()
        if chunkQueue.count >= SharedConfig.Defaults.streamChunkQueueMaxDepth {
            chunkQueueOverflowed = true
            let depth = chunkQueue.count
            chunkQueueLock.unlock()
            FileLogger.shared.warn(.network, "Chunk queue overflow — dropping chunk",
                                    payload: ["chunkId": id, "queueDepth": depth])
            return
        }
        chunkQueue.append((id, samples))
        chunkQueueLock.unlock()
    }

    /// Background task that dequeues and sends chunks with unbounded retry
    /// while recording is active. Runs until the queue is empty AND recording
    /// has stopped (natural completion), or until cancelled.
    private func runChunkConsumer(client: WhisperStreamClient) async {
        let backoff = SharedConfig.Defaults.streamChunkRetryBackoffSeconds
        while !Task.isCancelled {
            chunkQueueLock.lock()
            let entry = chunkQueue.isEmpty ? nil : chunkQueue.removeFirst()
            chunkQueueLock.unlock()

            guard let (chunkId, samples) = entry else {
                // Queue empty: check if recording is done
                chunkQueueLock.lock()
                let stillRecording = recordingActive
                let queueEmpty = chunkQueue.isEmpty
                chunkQueueLock.unlock()
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
                    FileLogger.shared.warn(.network, "Chunk send failed, retrying",
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
    /// path as a normal result (clipboard, postResultToServer, Darwin notification,
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

        writeToClipboard(status: "error", errorMessage: error)
        postResultToServer(status: "error", errorMessage: error)
        DarwinNotifier.post(SharedConfig.Defaults.darwinNotificationName)
        phase = .error(error)
    }

    /// Cleans up stream session resources: ends background task, disconnects
    /// WebSocket, and nils out stream references. Idempotent — safe to call
    /// multiple times or on already-cleaned-up sessions.
    private func cleanupStreamSession(backgroundTaskID: inout UIBackgroundTaskIdentifier) async {
        chunkQueueLock.lock()
        recordingActive = false
        chunkQueueLock.unlock()
        chunkConsumerTask?.cancel()
        chunkConsumerTask = nil
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
        chunkQueueLock.lock()
        chunkQueue.removeAll()
        chunkQueueOverflowed = false
        recordingActive = false
        chunkQueueLock.unlock()
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
            writeToClipboard(status: "cancelled")
            postResultToServer(status: "cancelled")
            DarwinNotifier.post(SharedConfig.Defaults.darwinNotificationName)
        }
        activeID = nil
    }
}
