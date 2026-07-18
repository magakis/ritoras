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
            print("⚠️ postResultToServer: no server configured")
            return
        }
        let baseURL = server.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(baseURL)/dictation_result") else {
            print("⚠️ postResultToServer: invalid URL")
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
            print("⚠️ postResultToServer: failed to serialize JSON: \(error)")
            return
        }

        print("📡 postResultToServer: POSTing to \(url.absoluteString) status=\(status)")
        URLSession.shared.dataTask(with: request) { _, response, error in
            if let error = error {
                print("⚠️ postResultToServer: error: \(error)")
            } else if let response = response as? HTTPURLResponse {
                print("📡 postResultToServer: response \(response.statusCode)")
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

        switch SharedConfig.dictationMode() {
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
            #if DEBUG
            print("[DictationVM] start mode: stream")
            #endif

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
                        #if DEBUG
                        print("[DictationVM] Stream: connected to \(base)")
                        #endif
                        break
                    } catch {
                        #if DEBUG
                        print("[DictationVM] Stream: server \(base) failed: \(error.localizedDescription)")
                        #endif
                        lastError = error
                        await candidate.disconnect()
                        continue
                    }
                }

                guard let client = client else {
                    throw lastError ?? WhisperError.allServersFailed(config.servers)
                }
                #if DEBUG
                print("[DictationVM] Stream: WebSocket connected")
                #endif
                streamClient = client

                let recorder = StreamingAudioRecorder()
                streamRecorder = recorder

                try await recorder.start { [weak self] chunkId, samples in
                    #if DEBUG
                    print("[DictationVM] Stream: chunk \(chunkId) (\(samples.count) samples)")
                    #endif
                    guard let client = await self?.streamClient else { return }
                    try? await client.sendChunk(id: chunkId, samples: samples)
                }
                #if DEBUG
                print("[DictationVM] Stream: recorder started")
                #endif

                UIApplication.shared.isIdleTimerDisabled = true
            } catch {
                #if DEBUG
                print("[DictationVM] Stream start error: \(error.localizedDescription)")
                #endif
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
            #if DEBUG
            print("[DictationVM] stop mode: stream")
            #endif

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
                #if DEBUG
                print("[DictationVM] Stream: END sent, awaiting final")
                #endif

                let text = try await streamClient?.receiveMessages { [weak self] partial in
                    #if DEBUG
                    let preview = partial.prefix(60)
                    print("[DictationVM] livePartial updated: \"\(preview)...\"")
                    #endif
                    Task { @MainActor in
                        self?.livePartial = partial
                    }
                } ?? ""

                #if DEBUG
                let preview = text.prefix(60)
                print("[DictationVM] Stream final received: \"\(preview)...\"")
                #endif

                guard activeID == id else { return }

                #if DEBUG
                print("[DictationVM] Stream success: delivering via all channels")
                #endif
                DictationPayload(id: id, status: .completed, text: text, timestamp: Date()).save()
                writeToClipboard(status: "completed", text: text)
                postResultToServer(status: "completed", text: text)
                DarwinNotifier.post(SharedConfig.Defaults.darwinNotificationName)
                TranscriptionHistory.shared.add(text: text)
                phase = .done(text)
            } catch {
                guard activeID == id else { return }
                let message = error.localizedDescription
                #if DEBUG
                print("[DictationVM] Stream error: \(message)")
                #endif
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
        #if DEBUG
        print("[DictationVM] cancel: stream teardown")
        #endif
        await streamRecorder?.stop()
        await streamClient?.disconnect()
        streamClient = nil
        streamRecorder = nil

        #if DEBUG
        print("[DictationVM] cancel: batch teardown")
        #endif
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
