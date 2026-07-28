import AVFoundation

// MARK: - Audio Level Monitor Error

enum AudioLevelMonitorError: LocalizedError {
    case permissionDenied
    case permissionNotRequested
    case sessionConfigurationFailed(Error)
    case engineStartFailed(Error)
    case targetFormatUnavailable

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Microphone permission was denied. Enable it in Settings."
        case .permissionNotRequested:
            return "Microphone permission has not been requested yet."
        case .sessionConfigurationFailed(let error):
            return "Audio session configuration failed: \(error.localizedDescription)"
        case .engineStartFailed(let error):
            return "Failed to start audio engine: \(error.localizedDescription)"
        case .targetFormatUnavailable:
            return "Could not create 16 kHz mono float32 audio format."
        }
    }
}

// MARK: - Converter Cache (queue-serial access only)

/// Thread-safe holder for the shared `AVAudioConverter`. All access is from
/// the serial processing queue (`queue`), so no lock is needed.
///
/// Note: format changes during a tuning session are tolerated rather than
/// handled with a full route-change rebuild. If the hardware format changes
/// mid-session, the next frame rebuilds the converter automatically.
private final class ConverterCache: @unchecked Sendable {
    private var converter: AVAudioConverter?
    private var lastInputFormat: AVAudioFormat?
    private(set) var isInvalidated = false

    /// Returns the existing converter if its input format matches
    /// `inputFormat`; otherwise builds a new one. Returns `nil` on failure.
    func getOrCreate(inputFormat: AVAudioFormat, outputFormat: AVAudioFormat) -> AVAudioConverter? {
        if isInvalidated { return nil }
        if let c = converter, let last = lastInputFormat, last == inputFormat {
            return c
        }
        guard let c = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            converter = nil
            lastInputFormat = nil
            return nil
        }
        converter = c
        lastInputFormat = inputFormat
        return c
    }

    /// Nils out the stored converter and marks as invalidated.
    func invalidate() {
        converter = nil
        lastInputFormat = nil
        isInvalidated = true
    }
}

// MARK: - Mutable Level State (queue-serial access only)

/// Holds the running peak RMS value. Accessed only from
/// the serial processing queue — no lock needed.
private final class LevelState: @unchecked Sendable {
    var peak: Float = 0
    var isInvalidated = false
}

// MARK: - Audio Level Monitor

/// Captures microphone audio via `AVAudioEngine` and publishes per-frame RMS
/// levels for a live meter display.
///
/// RMS is computed on the **same 16 kHz mono float32 converted signal** that
/// ``StreamingAudioRecorder`` uses, so the reading exactly matches the VAD's
/// `speechRms` threshold.
///
/// This file lives in the container app target only (`app/Sources/`). The
/// keyboard extension does not compile it.
///
/// ## Thread safety
/// The audio-tap callback runs on a real-time audio thread. The callback is
/// minimal — it reads the buffer, copies samples, and dispatches all heavy
/// work (conversion, RMS, smoothing, peak-hold) to a dedicated serial queue.
actor AudioLevelMonitor {
    public typealias LevelCallback = @Sendable (Float, Float) -> Void

    // MARK: - Private Properties

    private let engine = AVAudioEngine()
    private var tapInstalled = false
    private var isRunning = false
    private var onLevel: LevelCallback?

    /// Converter cache; accessed only from `queue` (serial).
    private let converterCache = ConverterCache()

    /// Running peak RMS; accessed only from `queue` (serial).
    private let levelState = LevelState()

    /// Serial queue for audio processing off the real-time audio thread.
    private let queue = DispatchQueue(label: "com.ritoras.audio-level-monitor", qos: .userInitiated)

    // MARK: - Start

    /// Begins capturing mic audio and publishing raw + peak RMS levels.
    ///
    /// - Parameter onLevel: Called on the serial processing queue for each
    ///   audio frame with `(rawRMS, peakRMS)`.
    /// - Throws: ``AudioLevelMonitorError`` if mic permission is unavailable,
    ///   session configuration fails, or the engine cannot start.
    func start(onLevel: @escaping LevelCallback) async throws {
        guard !isRunning else { return }

        // 1. Check microphone permission (mirrors StreamingAudioRecorder lines 302-312)
        let permission = AVAudioApplication.shared.recordPermission
        switch permission {
        case .granted:
            break
        case .denied:
            throw AudioLevelMonitorError.permissionDenied
        case .undetermined:
            throw AudioLevelMonitorError.permissionNotRequested
        @unknown default:
            throw AudioLevelMonitorError.permissionNotRequested
        }

        // 2. Configure audio session (mirrors StreamingAudioRecorder line 316)
        do {
            try AudioSession.configure()
        } catch {
            throw AudioLevelMonitorError.sessionConfigurationFailed(error)
        }

        self.onLevel = onLevel

        // 3. Build the 16 kHz mono float32 target format (mirrors lines 324-329)
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        ) else {
            FileLogger.shared.error(.audio, "could not create 16 kHz mono float32 format")
            throw AudioLevelMonitorError.targetFormatUnavailable
        }

        let inputNode = engine.inputNode

        // 4. Get the input node's NATIVE format (mirrors line 347)
        let nativeFormat = inputNode.outputFormat(forBus: 0)
        guard nativeFormat.sampleRate > 0 else {
            FileLogger.shared.error(.audio, "audio input unavailable (no microphone route)")
            throw AudioLevelMonitorError.engineStartFailed(
                NSError(domain: "AudioLevelMonitor", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Audio input unavailable (no microphone route)"])
            )
        }

        // Reset state for a fresh capture session
        converterCache.isInvalidated = false
        levelState.isInvalidated = false
        levelState.peak = 0

        // Capture references for the closure (no actor self capture)
        let queue = self.queue
        let converterCache = self.converterCache
        let levelState = self.levelState
        let handler = onLevel

        // 5. Install tap with NATIVE format (mirrors lines 416-421)
        let tapBlock: AVAudioNodeTapBlock = { buffer, _ in
            let frameLength = Int(buffer.frameLength)
            guard frameLength > 0,
                  let channelData = buffer.floatChannelData else {
                return
            }

            // Capture the delivered buffer's format
            let deliveredFormat = buffer.format
            let deliveredSampleRate = deliveredFormat.sampleRate
            let deliveredChannelCount = Int(deliveredFormat.channelCount)
            guard deliveredSampleRate > 0 else { return }

            // Copy all channel samples into a flat array (minimal work on audio thread)
            var samples = [Float]()
            samples.reserveCapacity(frameLength * deliveredChannelCount)
            for ch in 0..<deliveredChannelCount {
                let ptr = UnsafeBufferPointer(start: channelData[ch], count: frameLength)
                samples.append(contentsOf: ptr)
            }

            // Dispatch ALL heavy work (conversion, RMS, smoothing) to the serial queue
            queue.async {
                // Discard any work from a late tap callback after stop()
                guard !converterCache.isInvalidated, !levelState.isInvalidated else { return }

                // --- Lazy converter construction (mirrors lines 466-481) ---
                guard let converter = converterCache.getOrCreate(
                    inputFormat: deliveredFormat,
                    outputFormat: targetFormat
                ) else {
                    FileLogger.shared.error(.audio, "failed to build converter")
                    return
                }

                // Build input PCM buffer (mirrors lines 483-499)
                guard let inputBuffer = AVAudioPCMBuffer(
                    pcmFormat: deliveredFormat,
                    frameCapacity: AVAudioFrameCount(frameLength)
                ) else { return }
                inputBuffer.frameLength = AVAudioFrameCount(frameLength)
                for ch in 0..<deliveredChannelCount {
                    let offset = ch * frameLength
                    let dst = inputBuffer.floatChannelData![ch]
                    for i in 0..<frameLength {
                        dst[i] = samples[offset + i]
                    }
                }

                // Allocate output buffer in target format (mirrors lines 501-511)
                let outputCapacity = AVAudioFrameCount(
                    ceil(Double(frameLength) * 16000.0 / deliveredSampleRate) + 64
                )
                guard let outputBuffer = AVAudioPCMBuffer(
                    pcmFormat: targetFormat,
                    frameCapacity: outputCapacity
                ) else { return }

                // Convert native → 16 kHz mono using the block-based API
                // (mirrors lines 513-527)
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
                guard status == .haveData else { return }

                let convertedLength = Int(outputBuffer.frameLength)
                guard convertedLength > 0 else { return }

                // Extract converted samples (always mono at 16 kHz, lines 547-552)
                let outputPtr = UnsafeBufferPointer(
                    start: outputBuffer.floatChannelData![0],
                    count: convertedLength
                )

                // RMS computation (mirrors lines 554-559)
                var sumSquares: Float = 0
                for i in 0..<convertedLength {
                    let s = outputPtr[i]
                    sumSquares += s * s
                }
                let rms = sqrt(sumSquares / Float(convertedLength))

                // Peak hold: chase raw RMS up, decay 2% per frame
                levelState.peak = max(levelState.peak, rms)
                levelState.peak *= 0.98

                handler(rms, levelState.peak)
            }
        }

        inputNode.installTap(
            onBus: 0,
            bufferSize: 4096,
            format: nativeFormat,
            block: tapBlock
        )
        tapInstalled = true

        // 6. Prepare and start engine
        engine.prepare()
        do {
            try engine.start()
        } catch {
            teardownEngine()
            self.onLevel = nil
            AudioSession.deactivate()
            throw AudioLevelMonitorError.engineStartFailed(error)
        }

        isRunning = true

        FileLogger.shared.info(.audio, "started",
                               payload: ["nativeRate": nativeFormat.sampleRate,
                                         "nativeChannels": nativeFormat.channelCount])
    }

    // MARK: - Stop

    /// Stops monitoring and tears down the engine. Idempotent — safe to call
    /// multiple times.
    func stop() async {
        guard isRunning else { return }
        isRunning = false

        // Invalidate BEFORE teardown so already-enqueued queue blocks
        // short-circuit at their early isInvalidated guard.
        levelState.isInvalidated = true

        // Tear down engine and tap idempotently (mirrors lines 579-586)
        teardownEngine()
        AudioSession.deactivate()
        onLevel = nil

        // Barrier: ensure all previously dispatched blocks finish.
        // isInvalidated was already set above, so they short-circuit
        // with minimal work.
        queue.sync {
            converterCache.invalidate()
            levelState.peak = 0
        }

        FileLogger.shared.info(.audio, "stopped")
    }

    // MARK: - Teardown

    /// Idempotent engine teardown: removes the tap (if installed) and stops
    /// the engine. Safe to call multiple times.
    private func teardownEngine() {
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        engine.stop()
    }
}
