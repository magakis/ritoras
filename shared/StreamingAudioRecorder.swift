import AVFoundation
import os

// MARK: - Streaming Recorder Error

enum StreamingRecorderError: LocalizedError {
    case alreadyStreaming
    case engineStartFailed(Error)

    var errorDescription: String? {
        switch self {
        case .alreadyStreaming:
            return "Streaming recorder is already running."
        case .engineStartFailed(let error):
            return "Failed to start audio engine: \(error.localizedDescription)"
        }
    }
}

// MARK: - VAD Emission

struct VADEmission {
    let chunkId: UInt32
    let samples: [Float]
}

// MARK: - VAD Context (Thread-safe via internal lock)

/// Energy-based Voice Activity Detection state machine.
///
/// Called exclusively from the audio callback thread. All mutable state is
/// protected by `lock`; callers must lock before any mutation.
private final class VADContext: @unchecked Sendable {
    // MARK: Configuration (constants)
    let speechRms: Float
    let silenceThresholdSamples: Int
    let minSpeechSamples: Int
    let maxChunkSamples: Int

    // MARK: Lock
    let lock = NSLock()

    // MARK: Mutable state
    var accumulator: [Float] = []
    var isSpeaking = false
    var speechSampleCount: Int = 0
    var silenceSampleCount: Int = 0
    var chunkId: UInt32 = 0

    init(speechRms: Float, silenceThresholdSamples: Int, minSpeechSamples: Int, maxChunkSamples: Int) {
        self.speechRms = speechRms
        self.silenceThresholdSamples = silenceThresholdSamples
        self.minSpeechSamples = minSpeechSamples
        self.maxChunkSamples = maxChunkSamples
    }

    /// Process one audio frame. Returns an `VADEmission` if a chunk boundary
    /// is detected (pause timeout or force-flush), otherwise `nil`.
    func process(frame: [Float], frameLength: Int, rms: Float) -> VADEmission? {
        accumulator.append(contentsOf: frame)
        let totalSamples = accumulator.count

        if rms >= speechRms {
            // --- Speech frame ---
            silenceSampleCount = 0

            if !isSpeaking {
                speechSampleCount += frameLength
                if speechSampleCount >= minSpeechSamples {
                    isSpeaking = true
                    #if DEBUG
                    os_log(.debug, "[StreamingAudioRecorder] VAD: idle → speaking")
                    #endif
                }
            }
        } else {
            // --- Silence / noise frame ---
            silenceSampleCount += frameLength

            if isSpeaking && silenceSampleCount >= silenceThresholdSamples {
                #if DEBUG
                let silenceMs = Double(silenceSampleCount) / 16.0
                os_log(.debug, "[StreamingAudioRecorder] VAD: pause %.0f ms → emit", silenceMs)
                #endif
                return emit()
            }
        }

        // Force-flush at max chunk size regardless of VAD state
        if totalSamples >= maxChunkSamples {
            #if DEBUG
            os_log(.debug, "[StreamingAudioRecorder] VAD: force-flush at %d samples", totalSamples)
            #endif
            return emit()
        }

        return nil
    }

    /// Emit current accumulator and reset all VAD state.
    func emit() -> VADEmission {
        let snapshot = accumulator
        let id = chunkId
        chunkId &+= 1
        accumulator = []
        isSpeaking = false
        speechSampleCount = 0
        silenceSampleCount = 0
        return VADEmission(chunkId: id, samples: snapshot)
    }

    /// Flush any remaining accumulator into an emission (for `stop()`).
    func flush() -> VADEmission? {
        guard !accumulator.isEmpty else { return nil }
        #if DEBUG
        os_log(.debug, "[StreamingAudioRecorder] VAD: flush %d trailing samples", accumulator.count)
        #endif
        return emit()
    }
}

// MARK: - Streaming Audio Recorder

/// Captures microphone audio via `AVAudioEngine`, runs an energy-based VAD
/// state machine, and emits pause-bounded float32 PCM chunks via a callback.
///
/// Chunks are delivered as `[Float]` at 16 kHz mono, one chunk per detected
/// speech segment. The caller should forward them to a Whisper streaming server
/// (e.g. via WebSocket).
///
/// ## Thread safety
/// The audio-tap callback runs on a real-time audio thread. VAD state is
/// isolated behind `VADContext.lock` (an `NSLock`) and the callback captures
/// only the lock-protected helper and the `@Sendable` handler — never `self`
/// of the actor — avoiding cross-isolation violations.
actor StreamingAudioRecorder {
    typealias ChunkHandler = @Sendable (UInt32, [Float]) async -> Void

    // MARK: - Private Properties

    private let engine = AVAudioEngine()
    private var isRecording = false
    private var onChunk: ChunkHandler?

    /// VAD state machine; accessed only via its internal lock from the audio
    /// callback and (under lock) from this actor's `stop()` method.
    private let vad: VADContext

    // MARK: - Initialization

    init() {
        let silenceSamples = Int(Double(SharedConfig.Defaults.streamVadSilenceMs) * 16.0)
        let minSpeechSamples = Int(Double(SharedConfig.Defaults.streamVadMinSpeechMs) * 16.0)
        let maxChunkSamples = Int(SharedConfig.Defaults.streamMaxChunkSeconds * 16000.0)
        vad = VADContext(
            speechRms: SharedConfig.Defaults.streamVadSpeechRms,
            silenceThresholdSamples: silenceSamples,
            minSpeechSamples: minSpeechSamples,
            maxChunkSamples: maxChunkSamples
        )
    }

    // MARK: - Start

    /// Begins streaming audio capture.
    ///
    /// - Parameter onChunk: Called asynchronously for each detected speech
    ///   segment. The first argument is a monotonically increasing chunk ID
    ///   (starting at 0); the second is float32 PCM samples at 16 kHz mono.
    /// - Throws: `AudioRecorder.AudioRecorderError.permissionDenied` or `.permissionNotRequested`
    ///   if mic access is unavailable; `AudioRecorder.AudioRecorderError.invalidSessionConfiguration`
    ///   if session setup fails; `StreamingRecorderError.engineStartFailed` if
    ///   the audio engine cannot start.
    func start(onChunk: @escaping ChunkHandler) async throws {
        guard !isRecording else {
            throw StreamingRecorderError.alreadyStreaming
        }

        // 1. Check microphone permission
        let permission = AVAudioApplication.shared.recordPermission
        switch permission {
        case .granted:
            break
        case .denied:
            throw AudioRecorder.AudioRecorderError.permissionDenied
        case .undetermined:
            throw AudioRecorder.AudioRecorderError.permissionNotRequested
        @unknown default:
            throw AudioRecorder.AudioRecorderError.permissionNotRequested
        }

        // 2. Configure audio session (must be before engine start)
        do {
            try AudioSession.configure()
        } catch {
            throw AudioRecorder.AudioRecorderError.invalidSessionConfiguration(error)
        }

        self.onChunk = onChunk

        // 3. Set up engine tap at 16 kHz mono float32
        let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        )!

        let inputNode = engine.inputNode

        // Capture handler and VAD locally for the @Sendable closure.
        // The closure does NOT capture actor self — it only touches
        // lock-protected VAD state and the Sendable handler.
        let handler = onChunk
        let vad = self.vad

        inputNode.installTap(
            onBus: 0,
            bufferSize: 4096,
            format: targetFormat
        ) { buffer, _ in
            let frameLength = Int(buffer.frameLength)
            guard frameLength > 0,
                  let channelData = buffer.floatChannelData else { return }

            let floatPtr = UnsafeBufferPointer(start: channelData[0], count: frameLength)

            // Compute RMS energy
            var sumSquares: Float = 0
            for i in 0..<frameLength {
                let s = floatPtr[i]
                sumSquares += s * s
            }
            let rms = sqrt(sumSquares / Float(frameLength))

            // Copy frames into an array for the accumulator
            let frameArray = Array(floatPtr)

            // Process through VAD state machine (under lock)
            vad.lock.lock()
            let emission = vad.process(frame: frameArray, frameLength: frameLength, rms: rms)
            vad.lock.unlock()

            // Dispatch emission asynchronously — never inside the lock or
            // on the audio thread.
            if let emission = emission {
                Task {
                    await handler(emission.chunkId, emission.samples)
                }
            }
        }

        // 4. Prepare and start engine
        engine.prepare()
        do {
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            self.onChunk = nil
            AudioSession.deactivate()
            throw StreamingRecorderError.engineStartFailed(error)
        }

        isRecording = true

        #if DEBUG
        os_log(.debug,
               "[StreamingAudioRecorder] Started | RMS: %.4f | silence: %d ms | minSpeech: %d ms | maxChunk: %.1f s",
               SharedConfig.Defaults.streamVadSpeechRms,
               SharedConfig.Defaults.streamVadSilenceMs,
               SharedConfig.Defaults.streamVadMinSpeechMs,
               SharedConfig.Defaults.streamMaxChunkSeconds)
        #endif
    }

    // MARK: - Stop

    /// Stops streaming audio capture and flushes any in-progress accumulator
    /// as a final chunk.
    func stop() async {
        guard isRecording else { return }
        isRecording = false

        // Remove tap first to guarantee no more callbacks mutate VAD state
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        AudioSession.deactivate()

        // Flush remaining accumulator (under lock)
        let emission: VADEmission?
        vad.lock.lock()
        emission = vad.flush()
        vad.lock.unlock()

        // Dispatch final chunk
        if let emission = emission, let handler = onChunk {
            await handler(emission.chunkId, emission.samples)
        }

        onChunk = nil

        #if DEBUG
        os_log(.debug, "[StreamingAudioRecorder] Stopped")
        #endif
    }
}
