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
    let minChunkSamples: Int
    let maxNoiseSamples: Int
    let noiseGuardSpeechSamples = 1600  // 0.1 s @ 16 kHz — reference client's fixed noise-floor cutoff

    // MARK: Lock
    private var unfairLock = os_unfair_lock()

    // MARK: Mutable state
    var accumulator: [Float] = []
    var silenceSamples: Int = 0
    var speechSamples: Int = 0
    var chunkId: UInt32 = 0

    init(speechRms: Float, silenceThresholdSamples: Int, minSpeechSamples: Int, minChunkSamples: Int, maxNoiseSamples: Int) {
        self.speechRms = speechRms
        self.silenceThresholdSamples = silenceThresholdSamples
        self.minSpeechSamples = minSpeechSamples
        self.minChunkSamples = minChunkSamples
        self.maxNoiseSamples = maxNoiseSamples
    }

    /// Process one audio frame. Returns a `VADEmission` if a chunk boundary
    /// is detected (pause timeout), otherwise `nil`.
    func process(frame: [Float], frameLength: Int, rms: Float) -> VADEmission? {
        os_unfair_lock_lock(&unfairLock)
        defer { os_unfair_lock_unlock(&unfairLock) }

        // Accumulate ALL frames unconditionally — speech and silence alike.
        // No isSpeaking gating, no pre-roll ring. Matches the reference client.
        accumulator.append(contentsOf: frame)

        if rms >= speechRms {
            // Speech frame — resets the consecutive-silence counter.
            silenceSamples = 0
            speechSamples += frameLength
        } else {
            // Silence frame — accumulates the consecutive-silence counter.
            silenceSamples += frameLength
        }

        // Pause emit: consecutive silence AND min total length AND min speech —
        // all three conditions must hold.
        if silenceSamples >= silenceThresholdSamples,
           accumulator.count >= minChunkSamples,
           speechSamples >= minSpeechSamples {
            let silenceMs = Double(silenceSamples) / 16.0
            let totalMs = Double(accumulator.count) / 16.0
            let speechMs = Double(speechSamples) / 16.0
            FileLogger.shared.info(.audio, "VAD: pause → emit",
                                   payload: ["silenceMs": silenceMs,
                                             "totalMs": totalMs,
                                             "speechMs": speechMs,
                                             "sampleCount": accumulator.count])
            return emit(reason: "pause")
        }

        // Noise guard: less than 0.1 s (noiseGuardSpeechSamples) of speech
        // within the max-noise window — discard the buffer so ambient noise
        // never ships.
        if speechSamples < noiseGuardSpeechSamples && accumulator.count > maxNoiseSamples {
            accumulator = []
            silenceSamples = 0
            speechSamples = 0
            FileLogger.shared.debug(.audio, "VAD: noise guard discard")
        }

        return nil
    }

    /// Emit current accumulator and reset all VAD state.
    /// - parameter reason: Label for log distinguishability ("pause", "flush").
    func emit(reason: String = "pause") -> VADEmission {
        let snapshot = accumulator
        let id = chunkId
        chunkId &+= 1
        accumulator = []
        silenceSamples = 0
        speechSamples = 0
        return VADEmission(chunkId: id, samples: snapshot)
    }

    /// Flush any remaining accumulator into an emission (for `stop()`).
    /// Trailing audio without enough speech is discarded as noise.
    func flush() -> VADEmission? {
        os_unfair_lock_lock(&unfairLock)
        defer { os_unfair_lock_unlock(&unfairLock) }
        guard !accumulator.isEmpty else { return nil }
        guard speechSamples >= minSpeechSamples else {
            FileLogger.shared.debug(.audio, "VAD: flush discarded trailing noise",
                                    payload: ["sampleCount": accumulator.count,
                                              "speechSamples": speechSamples])
            return nil
        }
        FileLogger.shared.info(.audio, "VAD: flush trailing samples",
                               payload: ["count": accumulator.count])
        return emit(reason: "flush")
    }
}

// MARK: - Converter Holder (Thread-safe via internal lock)

/// Thread-safe holder for the shared `AVAudioConverter`, protected by
/// `os_unfair_lock`. Mirrors the `VADContext` locking pattern so the
/// converter can be read/written from `vadQueue` without actor-isolation
/// violations or data races against `teardownEngine()`.
private final class ConverterHolder: @unchecked Sendable {
    private var unfairLock = os_unfair_lock()
    private var converter: AVAudioConverter?

    /// Returns the existing converter if its input format matches
    /// `inputFormat`; otherwise builds a new `AVAudioConverter(from:to:)`,
    /// stores it, and returns it. Returns `nil` if construction fails.
    func getOrCreate(inputFormat: AVAudioFormat, outputFormat: AVAudioFormat) -> AVAudioConverter? {
        os_unfair_lock_lock(&unfairLock)
        defer { os_unfair_lock_unlock(&unfairLock) }
        if let existing = converter, existing.inputFormat == inputFormat {
            return existing
        }
        guard let c = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            converter = nil
            return nil
        }
        converter = c
        return c
    }

    /// Returns the current converter's input format, or `nil` if no
    /// converter exists yet. Used only for diagnostic logging.
    func currentInputFormat() -> AVAudioFormat? {
        os_unfair_lock_lock(&unfairLock)
        defer { os_unfair_lock_unlock(&unfairLock) }
        return converter?.inputFormat
    }

    /// Nils out the stored converter. Safe to call from any thread
    /// (including the actor's `teardownEngine()`).
    func invalidate() {
        os_unfair_lock_lock(&unfairLock)
        defer { os_unfair_lock_unlock(&unfairLock) }
        converter = nil
    }
}

// MARK: - Disk Writer Holder (access via vadQueue serialization)

/// Thread-safe holder for the WAV file writer used during streaming disk
/// recording. All access is from `vadQueue` (serial), so no lock is needed.
/// Writes every resampled buffer (including silence) to disk so the full
/// session is available for batch transcription if the stream fails.
/// On write error, logs once at `.error` and disables further writes;
/// the network streaming path is unaffected.
private final class DiskWriterHolder: @unchecked Sendable {
    private var audioFile: AVAudioFile?
    private var disabled = false

    /// Opens a WAV file for writing with the given format settings.
    /// Returns `false` on failure (sets the disabled flag internally).
    func open(url: URL, settings: [String: Any]) -> Bool {
        guard let file = try? AVAudioFile(forWriting: url, settings: settings) else {
            audioFile = nil
            disabled = true
            return false
        }
        audioFile = file
        disabled = false
        return true
    }

    /// Writes one PCM buffer to disk. Safe to call from `vadQueue` only.
    /// On write error, logs once and disables all future writes.
    func write(from buffer: AVAudioPCMBuffer) {
        guard let file = audioFile, !disabled else { return }
        do {
            try file.write(from: buffer)
        } catch {
            FileLogger.shared.error(.audio, "stream WAV write failed — disabling disk recording")
            disabled = true
            audioFile = nil
        }
    }

    /// Closes the file (finalizes WAV header on dealloc). Safe to call
    /// multiple times. Call from `vadQueue` after `vad.flush()`.
    func close() {
        audioFile = nil
        disabled = true
    }
}

// MARK: - Stopped Flag (access via vadQueue serialization)

/// Lockless stopped flag for preventing orphaned tap callbacks after stop().
/// All access is from `vadQueue` (serial), so no lock is needed.
/// Set in stop()'s vadQueue.async block, read in processTapBuffer (also on vadQueue).
private final class StoppedFlag: @unchecked Sendable {
    private var stopped = false
    func set(_ value: Bool) { stopped = value }
    var isStopped: Bool { stopped }
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
    typealias ChunkHandler = @Sendable (UInt32, [Float]) -> Void

    // MARK: - Private Properties

    private let engine = AVAudioEngine()
    private var isRecording = false
    private var onChunk: ChunkHandler?

    /// Thread-safe holder for the lazy `AVAudioConverter`; access only
    /// through its lock-protected methods (never actor-isolated `var`).
    private let converterHolder = ConverterHolder()

    /// Thread-safe holder for the WAV disk writer; accessed only from
    /// `vadQueue` (serial) — no additional locking needed.
    private let diskWriter = DiskWriterHolder()

    /// Lockless stopped flag; set on vadQueue in stop(), read on vadQueue in processTapBuffer.
    private let stoppedFlag = StoppedFlag()

    /// Tracks whether a tap is installed, enabling idempotent teardown.
    private var tapInstalled = false

    /// Serial queue for audio processing off the real-time audio thread.
    private let vadQueue = DispatchQueue(label: "com.ritoras.streaming-vad", qos: .userInitiated)

    /// VAD state machine; accessed only via `process()`/`flush()` which lock internally.
    private let vad: VADContext

    // MARK: - Initialization

    init() {
        let silenceSamples = Int(Double(SharedConfig.streamVadSilenceMs()) * 16.0)
        let minSpeechSamples = Int(Double(SharedConfig.streamVadMinSpeechMs()) * 16.0)
        let minChunkSamples = Int(Double(SharedConfig.streamVadMinChunkMs()) * 16.0)
        let maxNoiseSamples = Int(SharedConfig.streamVadMaxNoiseSec() * 16000.0)
        let speechRms = SharedConfig.streamVadSpeechRms()
        vad = VADContext(
            speechRms: speechRms,
            silenceThresholdSamples: silenceSamples,
            minSpeechSamples: minSpeechSamples,
            minChunkSamples: minChunkSamples,
            maxNoiseSamples: maxNoiseSamples
        )
    }

    // MARK: - Start

    /// Begins streaming audio capture.
    ///
    /// - Parameter onChunk: Called on vadQueue for each detected speech
    ///   segment. The first argument is a monotonically increasing chunk ID
    ///   (starting at 0); the second is float32 PCM samples at 16 kHz mono.
    /// - Throws: `AudioRecorder.AudioRecorderError.permissionDenied` or `.permissionNotRequested`
    ///   if mic access is unavailable; `AudioRecorder.AudioRecorderError.invalidSessionConfiguration`
    ///   if session setup fails; `StreamingRecorderError.engineStartFailed` if
    ///   the audio engine cannot start.
    func start(fileURL: URL? = nil, onChunk: @escaping ChunkHandler) async throws {
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

        // Optionally open disk WAV writer for continuous recording
        if let wavURL = fileURL {
            if !diskWriter.open(url: wavURL, settings: targetFormat.settings) {
                FileLogger.shared.error(.audio, "stream WAV open failed — disk recording disabled")
            }
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

        // Capture references for the closure (no actor self capture).
        let handler = onChunk
        let vad = self.vad
        let vadQueue = self.vadQueue
        let converterHolder = self.converterHolder
        let diskWriter = self.diskWriter
        let stoppedFlag = self.stoppedFlag

        // 6. Install tap with NATIVE format (REMOVES the format-mismatch crash)
        let tapBlock: AVAudioNodeTapBlock = { buffer, _ in
            let frameLength = Int(buffer.frameLength)
            guard frameLength > 0,
                  let channelData = buffer.floatChannelData else {
                FileLogger.shared.debug(.audio, "tap callback: invalid buffer",
                                        payload: ["frameLength": frameLength,
                                                  "hasChannelData": buffer.floatChannelData != nil])
                return
            }

            // Capture the delivered buffer's format — this is the ground truth
            // for what the hardware actually delivered.
            let deliveredFormat = buffer.format
            let deliveredSampleRate = deliveredFormat.sampleRate
            let deliveredChannelCount = Int(deliveredFormat.channelCount)

            // A degenerate delivered format (sampleRate 0) would produce
            // NaN/Inf in the output capacity calculation — guard it out.
            guard deliveredSampleRate > 0 else { return }

            // Copy all channel samples into a flat array (bounded, acceptable on audio thread)
            var samples = [Float]()
            samples.reserveCapacity(frameLength * deliveredChannelCount)
            for ch in 0..<deliveredChannelCount {
                let ptr = UnsafeBufferPointer(start: channelData[ch], count: frameLength)
                samples.append(contentsOf: ptr)
            }

            // Dispatch ALL heavy work (resampling, RMS, VAD, emission) to the serial queue
            vadQueue.async {
                Self.processTapBuffer(
                    samples: samples,
                    frameLength: frameLength,
                    deliveredFormat: deliveredFormat,
                    deliveredSampleRate: deliveredSampleRate,
                    deliveredChannelCount: deliveredChannelCount,
                    converterHolder: converterHolder,
                    targetFormat: targetFormat,
                    vad: vad,
                    handler: handler,
                    diskWriter: diskWriter,
                    stoppedFlag: stoppedFlag
                )
            }
        }
        inputNode.installTap(
            onBus: 0,
            bufferSize: 4096,
            format: nativeFormat,
            block: tapBlock
        )
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
                               payload: ["rms": SharedConfig.streamVadSpeechRms(),
                                         "silenceMs": SharedConfig.streamVadSilenceMs(),
                                         "minSpeechMs": SharedConfig.streamVadMinSpeechMs(),
                                         "minChunkMs": SharedConfig.streamVadMinChunkMs(),
                                         "maxNoiseSec": SharedConfig.streamVadMaxNoiseSec()])
    }

    // MARK: - Process Tap Buffer

    /// Processes one buffer of captured audio on the vadQueue: lazily builds or
    /// reuses an AVAudioConverter, resamples to 16 kHz mono, runs RMS + VAD,
    /// and emits chunks via the handler. This is a static method so the type
    /// checker can resolve it independently of the tap closure.
    private static func processTapBuffer(
        samples: [Float],
        frameLength: Int,
        deliveredFormat: AVAudioFormat,
        deliveredSampleRate: Double,
        deliveredChannelCount: Int,
        converterHolder: ConverterHolder,
        targetFormat: AVAudioFormat,
        vad: VADContext,
        handler: ChunkHandler,
        diskWriter: DiskWriterHolder,
        stoppedFlag: StoppedFlag
    ) {
        // Discard any emission from a late tap callback that runs after stop() set the flag.
        guard !stoppedFlag.isStopped else { return }

        // --- Lazy converter construction / route-change rebuild ---
        // Log a warning if the format changed since the previous buffer.
        let oldFormat = converterHolder.currentInputFormat()
        guard let converter = converterHolder.getOrCreate(
            inputFormat: deliveredFormat,
            outputFormat: targetFormat
        ) else {
            FileLogger.shared.error(.audio,
                "Failed to build AVAudioConverter from delivered format \(deliveredFormat)")
            return
        }
        if let old = oldFormat, old != deliveredFormat {
            FileLogger.shared.info(.audio,
                "Format change detected — rebuilt converter",
                payload: ["old": "\(old)", "new": "\(deliveredFormat)"])
        }

        // Build input AVAudioPCMBuffer using the delivered format
        // (must be `isEqual:` to converter.inputFormat).
        guard let inputBuffer = AVAudioPCMBuffer(
            pcmFormat: deliveredFormat,
            frameCapacity: AVAudioFrameCount(frameLength)
        ) else {
            FileLogger.shared.error(.audio, "Failed to allocate converter input buffer")
            return
        }
        inputBuffer.frameLength = AVAudioFrameCount(frameLength)
        for ch in 0..<deliveredChannelCount {
            let offset = ch * frameLength
            let dst = inputBuffer.floatChannelData![ch]
            for i in 0..<frameLength {
                dst[i] = samples[offset + i]
            }
        }

        // Allocate output buffer in target format (16 kHz mono float32)
        let outputCapacity = AVAudioFrameCount(
            ceil(Double(frameLength) * 16000.0 / deliveredSampleRate) + 64
        )
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: outputCapacity
        ) else {
            FileLogger.shared.error(.audio, "Failed to allocate converter output buffer")
            return
        }

        // Convert native → 16 kHz mono using the block-based API
        // (the simple convert(to:from:) cannot perform sample-rate conversion,
        // per Apple's AVAudioConverter.h and TN3136).
        var convError: NSError?
        var consumed = false
        let inputBlock: AVAudioConverterInputBlock = { _, inStatus in
            if consumed {
                inStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inStatus.pointee = .haveData
            return inputBuffer
        }
        let status = converter.convert(to: outputBuffer, error: &convError, withInputFrom: inputBlock)
        switch status {
        case .haveData:
            break
        case .error:
            let detail = convError.map { $0.localizedDescription } ?? "unknown error"
            FileLogger.shared.error(.audio, "Converter error: \(detail)")
            return
        @unknown default:
            // .endOfStream or any future status — drop this buffer
            return
        }

        let convertedLength = Int(outputBuffer.frameLength)
        guard convertedLength > 0 else { return }

        // Write every converted buffer to disk (incl. silence) so the full
        // session is available for batch transcription if the stream fails.
        diskWriter.write(from: outputBuffer)

        // Extract converted float samples (always mono at 16 kHz)
        let outputPtr = UnsafeBufferPointer(
            start: outputBuffer.floatChannelData![0],
            count: convertedLength
        )
        let convertedSamples = Array(outputPtr)

        // RMS computation (off audio thread) — DC-corrected (mean-subtracted),
        // matching the reference client: rms = sqrt(mean((s - mean(s))^2)).
        var mean: Float = 0
        for s in convertedSamples {
            mean += s
        }
        mean /= Float(convertedSamples.count)
        var sumSquares: Float = 0
        for s in convertedSamples {
            let centered = s - mean
            sumSquares += centered * centered
        }
        let rms = sqrt(sumSquares / Float(convertedSamples.count))

        // VAD processing (locks internally via os_unfair_lock)
        // frameLength = post-conversion (16 kHz) — VAD tunables are in 16 kHz samples
        let emission = vad.process(frame: convertedSamples, frameLength: convertedLength, rms: rms)

        // Emit chunk if ready (handler runs synchronously on vadQueue)
        if let emission = emission {
            FileLogger.shared.debug(.audio, "vadQueue: emission",
                                    payload: ["chunkId": emission.chunkId,
                                              "sampleCount": emission.samples.count])
            handler(emission.chunkId, emission.samples)
        }
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
        converterHolder.invalidate()
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
        let diskWriter = self.diskWriter
        let stoppedFlag = self.stoppedFlag
        let emission: VADEmission? = await withCheckedContinuation { continuation in
            vadQueue.async {
                stoppedFlag.set(true)
                let result = vad.flush()
                diskWriter.close()
                continuation.resume(returning: result)
            }
        }

        // Dispatch final chunk (synchronous call — stoppedFlag is already set)
        if let emission = emission, let handler = onChunk {
            handler(emission.chunkId, emission.samples)
        }

        onChunk = nil

        FileLogger.shared.info(.audio, "Stopped")
    }
}
