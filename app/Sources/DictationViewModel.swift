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

    private var recorder: AudioRecorder?
    private var activeID: UUID?

    // MARK: - Clipboard Transport

    /// Writes plain dictation text to the clipboard for manual paste fallback.
    /// The server (postResultToServer) handles structured data for the keyboard.
    /// Only writes for "completed" status; other statuses are server-only.
    private func writeToClipboard(status: String, text: String? = nil, errorMessage: String? = nil) {
        if status == "completed", let text = text, !text.isEmpty {
            UIPasteboard.general.string = text
        }
        // For all other statuses, don't touch the clipboard
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
    }

    func stop() async {
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
        writeToClipboard(status: "transcribing")
        postResultToServer(status: "transcribing")

        // Start background task to keep app alive during transcription
        var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "WhisperTranscription") {
            // Expiration handler — app is about to be killed
            UIApplication.shared.endBackgroundTask(backgroundTaskID)
            backgroundTaskID = .invalid
        }

        do {
            let config = SharedConfig.load()
            let text = try await WhisperClient.transcribe(audioURL: url, config: config)

            DictationPayload(
                id: id, status: .completed, text: text, timestamp: Date()
            ).save()
            writeToClipboard(status: "completed", text: text)
            postResultToServer(status: "completed", text: text)
            DarwinNotifier.post(SharedConfig.Defaults.darwinNotificationName)
            TranscriptionHistory.shared.add(text: text)
            UIApplication.shared.isIdleTimerDisabled = false
            AudioSession.deactivate()
            phase = .done(text)
        } catch {
            UIApplication.shared.isIdleTimerDisabled = false
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

        // End background task
        if backgroundTaskID != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTaskID)
            backgroundTaskID = .invalid
        }
    }

    func cancel() async {
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
