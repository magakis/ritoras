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

    @Published var phase: DictationPhase = .recording
    @Published private(set) var livePartial: String = ""
    @Published private(set) var activeModeLabel: String = ""

    private var recorder: AudioRecorder?
    private var activeID: UUID?

    private var streamRecorder: StreamingAudioRecorder?
    private var streamClient: WhisperStreamClient?

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
        guard let server = config.servers.first else {
            FileLogger.shared.warn(.network, "postResultToServer: no server configured")
            return
        }
        let baseURL = server.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
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

        // Save initial recording payload
        DictationPayload(id: id, status: .recording, timestamp: Date()).save()
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
                DictationPayload(
                    id: id, status: .error, errorMessage: message, timestamp: Date()
                ).save()
                writeToClipboard(status: "error", errorMessage: message)
                postResultToServer(status: "error", errorMessage: message)
                DarwinNotifier.post(SharedConfig.Defaults.darwinNotificationName)
                phase = .error(message)
                return
            }
        case .denied:
            let message = "Microphone access denied. Enable it in Settings \u{2192} Ritoras."
            DictationPayload(
                id: id, status: .error, errorMessage: message, timestamp: Date()
            ).save()
            writeToClipboard(status: "error", errorMessage: message)
            postResultToServer(status: "error", errorMessage: message)
            DarwinNotifier.post(SharedConfig.Defaults.darwinNotificationName)
            phase = .error(message)
            return
        case .granted:
            break
        @unknown default:
            break
        }

        let mode = SharedConfig.dictationMode()
        activeModeLabel = mode == .stream ? "STREAM" : "BATCH"

        switch mode {
        case .batch:
            do {
                try AudioSession.configure()
                let newRecorder = AudioRecorder()
                _ = try await newRecorder.startRecording()
                recorder = newRecorder
                UIApplication.shared.isIdleTimerDisabled = true
            } catch {
                let message = error.localizedDescription
                DictationPayload(
                    id: id, status: .error, errorMessage: message, timestamp: Date()
                ).save()
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

                // Try servers in order with failover, mirroring batch (WhisperClient.transcribe).
                // Empty / invalid URLs are skipped.
                var client: WhisperStreamClient?
                var lastError: Error?
                for server in config.servers {
                    let base = server.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                    guard !base.isEmpty else { continue }
                    let candidate = WhisperStreamClient(baseURL: base)
                    do {
                        try await candidate.connect()
                        client = candidate
                        FileLogger.shared.info(.network, "Stream: connected to server",
                                               payload: ["base": base])
                        break
                    } catch {
                        FileLogger.shared.warn(.network, "Stream: server failed",
                                               payload: ["base": base, "error": error.localizedDescription])
                        lastError = error
                        await candidate.disconnect()
                        continue
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

                UIApplication.shared.isIdleTimerDisabled = true
            } catch {
                FileLogger.shared.error(.transcription, "Stream start error",
                                        payload: ["error": error.localizedDescription])
                await streamClient?.disconnect()
                streamClient = nil
                streamRecorder = nil
                AudioSession.deactivate()

                let message = error.localizedDescription
                DictationPayload(
                    id: id, status: .error, errorMessage: message, timestamp: Date()
                ).save()
                writeToClipboard(status: "error", errorMessage: message)
                postResultToServer(status: "error", errorMessage: message)
                DarwinNotifier.post(SharedConfig.Defaults.darwinNotificationName)
                phase = .error(message)
            }
        }
    }

    func stop() async {
        switch SharedConfig.dictationMode() {
        case .batch:
            guard let recorder = recorder, let id = activeID else { return }
            self.recorder = nil

            let audioURL = await recorder.stopRecording()

            guard let url = audioURL else {
                UIApplication.shared.isIdleTimerDisabled = false
                AudioSession.deactivate()
                let message = "Recording was empty. Please try again."
                DictationPayload(
                    id: id, status: .error, errorMessage: message, timestamp: Date()
                ).save()
                writeToClipboard(status: "error", errorMessage: message)
                postResultToServer(status: "error", errorMessage: message)
                DarwinNotifier.post(SharedConfig.Defaults.darwinNotificationName)
                phase = .error(message)
                return
            }

            phase = .transcribing
            DictationPayload(id: id, status: .transcribing, timestamp: Date()).save()
            postResultToServer(status: "transcribing")
            UIApplication.shared.isIdleTimerDisabled = false
            AudioSession.deactivate()

            let config = SharedConfig.load()

            // Foreground upload (Scenario A) — runs immediately while the app is in
            // the foreground and updates the UI directly. A background task keeps
            // the app alive briefly if the user switches away mid-flight.
            var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
            backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "WhisperTranscription") {
                UIApplication.shared.endBackgroundTask(backgroundTaskID)
                backgroundTaskID = .invalid
            }

            do {
                let text = try await WhisperClient.transcribe(audioURL: url, config: config)
                guard activeID == id else { return }
                DictationPayload(id: id, status: .completed, text: text, timestamp: Date()).save()
                writeToClipboard(status: "completed", text: text)
                postResultToServer(status: "completed", text: text)
                DarwinNotifier.post(SharedConfig.Defaults.darwinNotificationName)
                TranscriptionHistory.shared.add(text: text)
                phase = .done(text)
            } catch {
                guard activeID == id else { return }
                let message = error.localizedDescription
                DictationPayload(id: id, status: .error, errorMessage: message, timestamp: Date()).save()
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

            phase = .transcribing
            postResultToServer(status: "transcribing")
            UIApplication.shared.isIdleTimerDisabled = false

            var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
            backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "WhisperTranscription") {
                UIApplication.shared.endBackgroundTask(backgroundTaskID)
                backgroundTaskID = .invalid
            }

            await streamRecorder?.stop()

            do {
                try await streamClient?.sendEnd()
                FileLogger.shared.info(.network, "Stream: END sent, awaiting final")

                let text = try await streamClient?.receiveMessages { [weak self] partial in
                    FileLogger.shared.debug(.transcription, "livePartial updated",
                                            payload: ["preview": String(partial.prefix(60)),
                                                      "length": partial.count])
                    Task { @MainActor in
                        self?.livePartial = partial
                    }
                } ?? ""

                FileLogger.shared.info(.transcription, "Stream final received",
                                       payload: ["preview": String(text.prefix(60)),
                                                 "length": text.count])

                guard activeID == id else { return }

                FileLogger.shared.info(.transcription, "Stream success: delivering via all channels",
                                       payload: ["length": text.count, "preview": String(text.prefix(60))])
                DictationPayload(id: id, status: .completed, text: text, timestamp: Date()).save()
                writeToClipboard(status: "completed", text: text)
                postResultToServer(status: "completed", text: text)
                DarwinNotifier.post(SharedConfig.Defaults.darwinNotificationName)
                TranscriptionHistory.shared.add(text: text)
                phase = .done(text)
            } catch {
                guard activeID == id else { return }
                let message = error.localizedDescription
                FileLogger.shared.error(.transcription, "Stream error",
                                        payload: ["error": message])
                DictationPayload(id: id, status: .error, errorMessage: message, timestamp: Date()).save()
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

        if let id = activeID {
            DictationPayload(
                id: id, status: .cancelled, timestamp: Date()
            ).save()
            writeToClipboard(status: "cancelled")
            postResultToServer(status: "cancelled")
            DarwinNotifier.post(SharedConfig.Defaults.darwinNotificationName)
        }
        activeID = nil
    }
}
