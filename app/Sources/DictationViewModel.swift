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

    /// Writes dictation status to the system pasteboard so the keyboard can
    /// read it even when App Groups don't work (SideStore signing).
    private func writeToClipboard(status: String, text: String? = nil, errorMessage: String? = nil) {
        var payload: [String: Any] = [
            "source": "ritoras",
            "timestamp": Date().timeIntervalSince1970,
            "status": status,
            "id": activeID?.uuidString ?? UUID().uuidString
        ]
        if let text = text { payload["text"] = text }
        if let errorMessage = errorMessage { payload["errorMessage"] = errorMessage }

        if let data = try? JSONSerialization.data(withJSONObject: payload),
           let jsonStr = String(data: data, encoding: .utf8) {
            UIPasteboard.general.string = jsonStr
        }
    }

    func start(id: UUID) async {
        activeID = id
        phase = .recording

        // Save initial recording payload
        DictationPayload(id: id, status: .recording, timestamp: Date()).save()
        writeToClipboard(status: "recording")

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
            DarwinNotifier.post(SharedConfig.Defaults.darwinNotificationName)
            phase = .error(message)
            return
        }

        phase = .transcribing
        DictationPayload(id: id, status: .transcribing, timestamp: Date()).save()
        writeToClipboard(status: "transcribing")

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
            DarwinNotifier.post(SharedConfig.Defaults.darwinNotificationName)
        }
        activeID = nil
    }
}
