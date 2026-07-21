import Foundation
import AVFoundation
import UIKit

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
    /// background connection handlers. Nested with `completedResults`
    /// writes in terminal-transition `didSet`.
    private let stateLock = NSLock()
    /// Snapshot updated on every `phase` change, safe for background reads.
    private var safeStateSnapshot = DictationStateSnapshot(phase: "idle", activeID: nil, startedAt: nil)
    /// Terminal results by job ID, populated on `.done` / `.error` transitions.
    private var completedResults: [UUID: DictationResultSnapshot] = [:]

    private var recorder: AudioRecorder?
    private var activeID: UUID?
    private var recordingStartTime: Date?

    private var streamRecorder: StreamingAudioRecorder?
    private var streamClient: WhisperStreamClient?

    private var selectedServer: String?
    private var serverSelectionTask: Task<String?, Never>?

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
                guard let self = self else { return nil }
                self.stateLock.lock()
                let result = self.completedResults[id]
                self.stateLock.unlock()
                return result
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

    /// Captures terminal results (`.done`, `.error`) into `completedResults`
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
        stateLock.lock()
        completedResults[id] = result
        stateLock.unlock()
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
                _ = try await newRecorder.startRecording()
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
                        let candidate = WhisperStreamClient(baseURL: base)
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
                        remainingServers = trimmedServers.filter { $0 != base }
                    }
                }

                if client == nil {
                    for server in remainingServers {
                        guard !server.isEmpty else { continue }
                        let candidate = WhisperStreamClient(baseURL: server)
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

                try await recorder.start { [weak self] chunkId, samples in
                    FileLogger.shared.debug(.audio, "Stream: chunk produced",
                                            payload: ["chunkId": chunkId, "sampleCount": samples.count])
                    guard let client = await self?.streamClient else { return }
                    try? await client.sendChunk(id: chunkId, samples: samples)
                }
                FileLogger.shared.info(.audio, "Stream: recorder started")
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
                phase = .done(text)
            } catch {
                guard activeID == id else { return }
                let message = error.localizedDescription
                let failedElapsed = Date().timeIntervalSince(uploadT0) * 1000
                FileLogger.shared.info(.transcription, "upload failed", payload: [
                    "id": id.uuidString,
                    "elapsed_ms": failedElapsed,
                    "error": message
                ])
                writeToClipboard(status: "error", errorMessage: message)
                postResultToServer(status: "error", errorMessage: message)
                DarwinNotifier.post(SharedConfig.Defaults.darwinNotificationName)
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

            await streamRecorder?.stop()

            let uploadT0 = Date()

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

                guard activeID == id else { return }

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
                phase = .done(text)
            } catch {
                guard activeID == id else { return }
                let message = error.localizedDescription
                let failedElapsed = Date().timeIntervalSince(uploadT0) * 1000
                FileLogger.shared.error(.transcription, "Stream error",
                                        payload: ["error": message])
                FileLogger.shared.info(.transcription, "upload failed", payload: [
                    "id": id.uuidString,
                    "elapsed_ms": failedElapsed,
                    "error": message
                ])
                writeToClipboard(status: "error", errorMessage: message)
                postResultToServer(status: "error", errorMessage: message)
                DarwinNotifier.post(SharedConfig.Defaults.darwinNotificationName)
                phase = .error(message)
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

    func cancel() async {
        FileLogger.shared.info(.transcription, "cancel: stream teardown")
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
            writeToClipboard(status: "cancelled")
            postResultToServer(status: "cancelled")
            DarwinNotifier.post(SharedConfig.Defaults.darwinNotificationName)
        }
        activeID = nil
    }
}
