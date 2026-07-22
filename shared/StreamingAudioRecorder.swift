import AVFoundation
import os

// MARK: - Streaming Recorder Error

enum StreamingRecorderError: LocalizedError {
    case alreadyStreaming
    case engineStartFailed(Error)
    case nativeFormatUnavailable(String)
    case converterSetupFailed(String)

    var errorDescription: String? {
        switch self {
        case .alreadyStreaming:
            return "Streaming recorder is already running."
        case .engineStartFailed(let error):
            return "Failed to start audio engine: \(error.localizedDescription)"
        case .nativeFormatUnavailable(let reason):
            return "Audio input native format unavailable: \(reason)"
        case .converterSetupFailed(let reason):
            return "Failed to set up audio converter: \(reason)"
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
/// Thread safety through internal locking via `os_unfair_lock`.
/// All mutable state is protected — callers call `process()`/`flush()` directly.
private final class VADContext: @unchecked Sendable {
    // MARK: Configuration (constants)
    let speechRms: Float
    let silenceThresholdSamples: Int
    let minSpeechSamples: Int
    let maxChunkSamples: Int

    // MARK: Lock
    private var unfairLock = os_unfair_lock()

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
        os_unfair_lock_lock(&unfairLock)
        defer { os_unfair_lock_unlock(&unfairLock) }
        accumulator.append(contentsOf: frame)
        let totalSamples = accumulator.count

        if rms >= speechRms {
            // --- Speech frame ---
            silenceSampleCount = 0

            if !isSpeaking {
                speechSampleCount += frameLength
                if speechSampleCount >= minSpeechSamples {
                    isSpeaking = true
                    FileLogger.shared.debug(.audio, "VAD: idle → speaking")
                }
            }
        } else {
            // --- Silence / noise frame ---
            silenceSampleCount += frameLength

            if isSpeaking && silenceSampleCount >= silenceThresholdSamples {
                let silenceMs = Double(silenceSampleCount) / 16.0
                FileLogger.shared.debug(.audio, "VAD: pause → emit",
                                        payload: ["silenceMs": silenceMs])
                return emit()
            }
        }

        // Force-flush at max chunk size regardless of VAD state
        if totalSamples >= maxChunkSamples {
            FileLogger.shared.debug(.audio, "VAD: force-flush",
                                    payload: ["totalSamples": totalSamples])
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
        os_unfair_lock_lock(&unfairLock)
        defer { os_unfair_lock_unlock(&unfairLock) }
        guard !accumulator.isEmpty else { return nil }
        FileLogger.shared.debug(.audio, "VAD: flush trailing samples",
                                payload: ["count": accumulator.count])
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
/// The audio-tap callback runs on a real-time audio thread. The callback is
/// minimal — it reads the buffer, copies samples, and dispatches all heavy
/// work (RMS, VAD, chunk emission) to a dedicated serial `vadQueue`. VAD
/// state is protected internally by `os_unfair_lock`.
actor StreamingAudioRecorder {
    typealias ChunkHandler = @Sendable (UInt32, [Float]) async -> Void

    // MARK: - Private Properties

    private let engine = AVAudioEngine()
    private var isRecording = false
    private var onChunk: ChunkHandler?

    /// Reused audio converter for native → 16 kHz mono resampling.
    /// Created once per `start()`; nil after `stop()`.
    private var converter: AVAudioConverter?

    /// Tracks whether a tap is installed, enabling idempotent teardown.
    private var tapInstalled = false

    /// Serial queue for audio processing off the real-time audio thread.
    private let vadQueue = DispatchQueue(label: "com.ritoras.streaming-vad", qos: .userInitiated)

    /// VAD state machine; accessed only via `process()`/`flush()` which lock internally.
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

        // 3. Build the 16 kHz mono target format (converter output)
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        ) else {
            FileLogger.shared.error(.audio, "CRASH-PROOF: Could not create 16kHz mono float32 audio format")
            throw StreamingRecorderError.engineStartFailed(
                NSError(domain: "StreamingAudioRecorder", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Could not create 16kHz mono float32 audio format"])
            )
        }

        let inputNode = engine.inputNode

        // 4. Get the input node's NATIVE format
        let nativeFormat = inputNode.outputFormat(forBus: 0)
        guard nativeFormat.sampleRate > 0 else {
            FileLogger.shared.error(.audio, "CRASH-PROOF: Audio input unavailable (no microphone route)")
            throw StreamingRecorderError.engineStartFailed(
                NSError(domain: "StreamingAudioRecorder", code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "Audio input unavailable (no microphone route)"])
            )
        }
        guard nativeFormat.channelCount >= 1 else {
            FileLogger.shared.error(.audio, "CRASH-PROOF: Audio input has no channels")
            throw StreamingRecorderError.nativeFormatUnavailable(
                "Input node has \(nativeFormat.channelCount) channels"
            )
        }

        // 5. Build the converter ONCE (not realtime-safe; never per buffer)
        guard let converter = AVAudioConverter(from: nativeFormat, to: targetFormat) else {
            FileLogger.shared.error(.audio,
                "CRASH-PROOF: Could not create converter from \(nativeFormat.sampleRate)Hz/\(nativeFormat.channelCount)ch to 16kHz/mono")
            throw StreamingRecorderError.converterSetupFailed(
                "Cannot convert \(nativeFormat.sampleRate)Hz \(nativeFormat.channelCount)ch → 16kHz mono"
            )
        }
        self.converter = converter

        // Capture references for the closure (no actor self capture).
        let handler = onChunk
        let vad = self.vad
        let vadQueue = self.vadQueue
        let nativeSampleRate = nativeFormat.sampleRate
        let nativeChannelCount = Int(nativeFormat.channelCount)

        // 6. Install tap with NATIVE format (REMOVES the format-mismatch crash)
        inputNode.installTap(
            onBus: 0,
            bufferSize: 4096,
            format: nativeFormat
        ) { buffer, _ in
            let frameLength = Int(buffer.frameLength)
            guard frameLength > 0,
                  let channelData = buffer.floatChannelData else {
                FileLogger.shared.warn(.audio, "tap callback: invalid buffer",
                                       payload: ["frameLength": frameLength,
                                                 "hasChannelData": buffer.floatChannelData != nil])
                return
            }

            // Capture the delivered buffer's actual sample rate (reflects current hardware route).
            let deliveredSampleRate = buffer.format.sampleRate

            // Copy all channel samples into a flat array (bounded, acceptable on audio thread)
            var samples = [Float]()
            samples.reserveCapacity(frameLength * nativeChannelCount)
            for ch in 0..<nativeChannelCount {
                let ptr = UnsafeBufferPointer(start: channelData[ch], count: frameLength)
                samples.append(contentsOf: ptr)
            }

            // Dispatch ALL heavy work (resampling, RMS, VAD, emission) to the serial queue
            vadQueue.async {
                // Route-change guard: compare the delivered buffer's sample rate against
                // the converter's fixed input rate. If they differ (e.g. headphones
                // plugged in mid-session), drop the buffer. Next start() rebuilds the
                // converter.
                guard deliveredSampleRate == converter.inputFormat.sampleRate else {
                    FileLogger.shared.warn(.audio,
                        "Route change detected — delivered \(deliveredSampleRate)Hz but converter expects \(converter.inputFormat.sampleRate)Hz, dropping buffer")
                    return
                }

                // Build input AVAudioPCMBuffer from the copied flat array
                guard let inputBuffer = AVAudioPCMBuffer(
                    pcmFormat: nativeFormat,
                    frameCapacity: AVAudioFrameCount(frameLength)
                ) else {
                    FileLogger.shared.error(.audio, "Failed to allocate converter input buffer")
                    return
                }
                inputBuffer.frameLength = AVAudioFrameCount(frameLength)
                for ch in 0..<nativeChannelCount {
                    let offset = ch * frameLength
                    let dst = inputBuffer.floatChannelData![ch]
                    for i in 0..<frameLength {
                        dst[i] = samples[offset + i]
                    }
                }

                // Allocate output buffer in target format (16 kHz mono float32)
                let outputCapacity = AVAudioFrameCount(
                    ceil(Double(frameLength) * 16000.0 / nativeSampleRate) + 4
                )
                guard let outputBuffer = AVAudioPCMBuffer(
                    pcmFormat: targetFormat,
                    frameCapacity: outputCapacity
                ) else {
                    FileLogger.shared.error(.audio, "Failed to allocate converter output buffer")
                    return
                }

                // Convert native → 16 kHz mono
                do {
                    try converter.convert(to: outputBuffer, from: inputBuffer)
                } catch {
                    FileLogger.shared.error(.audio, "Converter error: \(error.localizedDescription)")
                    return
                }

                let convertedLength = Int(outputBuffer.frameLength)
                guard convertedLength > 0 else { return }

                // Extract converted float samples (always mono at 16 kHz)
                let outputPtr = UnsafeBufferPointer(
                    start: outputBuffer.floatChannelData![0],
                    count: convertedLength
                )
                let convertedSamples = Array(outputPtr)

                // RMS computation (off audio thread)
                var sumSquares: Float = 0
                for s in convertedSamples {
                    sumSquares += s * s
                }
                let rms = sqrt(sumSquares / Float(convertedSamples.count))

                // VAD processing (locks internally via os_unfair_lock)
                // frameLength = post-conversion (16 kHz) — VAD tunables are in 16 kHz samples
                let emission = vad.process(frame: convertedSamples, frameLength: convertedLength, rms: rms)

                // Emit chunk if ready (Task created off the audio thread)
                if let emission = emission {
                    FileLogger.shared.debug(.audio, "vadQueue: emission",
                                            payload: ["chunkId": emission.chunkId,
                                                      "sampleCount": emission.samples.count])
                    Task {
                        await handler(emission.chunkId, emission.samples)
                    }
                }
            }
        }
        tapInstalled = true

        // 7. Prepare and start engine
        engine.prepare()
        do {
            try engine.start()
        } catch {
            teardownEngine()
            self.onChunk = nil
            AudioSession.deactivate()
            throw StreamingRecorderError.engineStartFailed(error)
        }

        isRecording = true

        FileLogger.shared.info(.audio, "Started",
                               payload: ["rms": SharedConfig.Defaults.streamVadSpeechRms,
                                         "silenceMs": SharedConfig.Defaults.streamVadSilenceMs,
                                         "minSpeechMs": SharedConfig.Defaults.streamVadMinSpeechMs,
                                         "maxChunkSeconds": SharedConfig.Defaults.streamMaxChunkSeconds])
    }

    // MARK: - Teardown

    /// Idempotent engine teardown: removes the tap (if installed) and stops the
    /// engine. Safe to call multiple times; `removeTap` does not raise an
    /// NSException when no tap is installed.
    private func teardownEngine() {
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        engine.stop()
        converter = nil
    }

    // MARK: - Stop

    /// Stops streaming audio capture and flushes any in-progress accumulator
    /// as a final chunk.
    func stop() async {
        guard isRecording else { return }
        isRecording = false

        // Tear down engine and tap idempotently
        teardownEngine()
        AudioSession.deactivate()

        // Flush any in-progress accumulator. Route through vadQueue so it
        // runs AFTER all pending process() blocks complete (serial ordering).
        let vadQueue = self.vadQueue
        let vad = self.vad
        let emission: VADEmission? = await withCheckedContinuation { continuation in
            vadQueue.async {
                let result = vad.flush()
                continuation.resume(returning: result)
            }
        }

        // Dispatch final chunk
        if let emission = emission, let handler = onChunk {
            await handler(emission.chunkId, emission.samples)
        }

        onChunk = nil

        FileLogger.shared.info(.audio, "Stopped")
    }
}
