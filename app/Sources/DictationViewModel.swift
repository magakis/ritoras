import Foundation
import AVFoundation

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

    func start(id: UUID) async {
        activeID = id

        // Save initial recording payload
        DictationPayload(id: id, status: .recording, timestamp: Date()).save()

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
                DarwinNotifier.post(SharedConfig.Defaults.darwinNotificationName)
                phase = .error(message)
                return
            }
        case .denied:
            let message = "Microphone access denied. Enable it in Settings \u{2192} Ritoras."
            DictationPayload(
                id: id, status: .error, errorMessage: message, timestamp: Date()
            ).save()
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
        } catch {
            let message = error.localizedDescription
            DictationPayload(
                id: id, status: .error, errorMessage: message, timestamp: Date()
            ).save()
            DarwinNotifier.post(SharedConfig.Defaults.darwinNotificationName)
            phase = .error(message)
        }
    }

    func stop() async {
        guard let recorder = recorder, let id = activeID else { return }
        self.recorder = nil

        let audioURL = await recorder.stopRecording()

        guard let url = audioURL else {
            let message = "Recording was empty. Please try again."
            DictationPayload(
                id: id, status: .error, errorMessage: message, timestamp: Date()
            ).save()
            DarwinNotifier.post(SharedConfig.Defaults.darwinNotificationName)
            phase = .error(message)
            return
        }

        phase = .transcribing
        DictationPayload(id: id, status: .transcribing, timestamp: Date()).save()

        do {
            let config = SharedConfig.load()
            let text = try await WhisperClient.transcribe(audioURL: url, config: config)

            DictationPayload(
                id: id, status: .completed, text: text, timestamp: Date()
            ).save()
            DarwinNotifier.post(SharedConfig.Defaults.darwinNotificationName)
            phase = .done(text)
        } catch {
            let message = error.localizedDescription
            DictationPayload(
                id: id, status: .error, errorMessage: message, timestamp: Date()
            ).save()
            DarwinNotifier.post(SharedConfig.Defaults.darwinNotificationName)
            phase = .error(message)
        }
    }

    func cancel() async {
        await recorder?.cleanup()
        recorder = nil

        if let id = activeID {
            DictationPayload(
                id: id, status: .cancelled, timestamp: Date()
            ).save()
            DarwinNotifier.post(SharedConfig.Defaults.darwinNotificationName)
        }
        activeID = nil
    }
}
