import Foundation
import AVFoundation
import AudioToolbox

private final class AACEncodingCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, Error>?

    init(_ continuation: CheckedContinuation<Data, Error>) {
        self.continuation = continuation
    }

    @discardableResult
    func resume(with result: Result<Data, Error>) -> Bool {
        lock.lock()
        guard let continuation else {
            lock.unlock()
            return false
        }
        self.continuation = nil
        lock.unlock()
        continuation.resume(with: result)
        return true
    }
}

private final class AACEncodingState: @unchecked Sendable {
    private let lock = NSLock()
    private var isEncoding = false

    func begin() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isEncoding else { return false }
        isEncoding = true
        return true
    }

    func finish() {
        lock.lock()
        isEncoding = false
        lock.unlock()
    }
}

private final class AACEncodingTemporaryDirectory: @unchecked Sendable {
    let audioFileURL: URL

    private let directoryURL: URL
    private let lock = NSLock()
    private var isClosed = false
    private var cleanupInProgress = false

    init() {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ritoras-stream-\(UUID().uuidString)", isDirectory: true)
        self.directoryURL = directoryURL
        audioFileURL = directoryURL.appendingPathComponent("chunk.m4a")
    }

    func create() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed else {
            throw StreamingAACChunkEncoderError.encodingTimedOut(
                StreamingAACChunkEncoder.encodeTimeoutSeconds)
        }
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true)
    }

    func remove() {
        lock.lock()
        guard !cleanupInProgress else {
            lock.unlock()
            return
        }
        isClosed = true
        cleanupInProgress = true
        lock.unlock()

        guard FileManager.default.fileExists(atPath: directoryURL.path) else { return }
        do {
            try FileManager.default.removeItem(at: directoryURL)
        } catch {
            lock.lock()
            cleanupInProgress = false
            lock.unlock()
            FileLogger.shared.warn(.audio, "Stream AAC temporary cleanup failed", payload: [
                "error": String(error.localizedDescription.prefix(120))
            ])
        }
    }
}

enum StreamingAACChunkEncoderError: LocalizedError {
    case unsupportedSampleRate(Int)
    case invalidPCMBuffer
    case outputFormatUnavailable
    case conversionFailed(Error?)
    case noConvertedSamples
    case emptyEncodedFile
    case bitratePropertyFailed(operation: String, status: OSStatus)
    case invalidBitRatePropertyData
    case applicableBitRatesUnavailable(Int)
    case encodingTimedOut(TimeInterval)
    case previousEncodingStillRunning
    case operationFailed(operation: String, error: Error)

    var errorDescription: String? {
        switch self {
        case .unsupportedSampleRate(let sampleRate):
            return "Unsupported AAC source rate: \(sampleRate) Hz"
        case .invalidPCMBuffer:
            return "Could not prepare the streaming audio chunk"
        case .outputFormatUnavailable:
            return "Could not create the AAC output audio format"
        case .conversionFailed(let error):
            return error?.localizedDescription ?? "Could not convert the streaming audio chunk"
        case .noConvertedSamples:
            return "The converted streaming audio chunk was empty"
        case .emptyEncodedFile:
            return "The encoded streaming audio chunk was empty"
        case .bitratePropertyFailed(let operation, let status):
            return "\(operation) failed with AudioToolbox OSStatus \(status)"
        case .invalidBitRatePropertyData:
            return "AudioToolbox returned invalid AAC bit-rate range data"
        case .applicableBitRatesUnavailable(let sampleRate):
            return "AAC bit rates are unavailable at \(sampleRate) Hz mono"
        case .encodingTimedOut(let seconds):
            return "AAC chunk encoding exceeded its \(seconds)-second limit"
        case .previousEncodingStillRunning:
            return "The previous AAC encode has not returned yet"
        case .operationFailed(let operation, let error):
            return "\(operation) failed: \(error.localizedDescription)"
        }
    }
}

struct StreamingAACChunkEncoder: Sendable {
    private static let requestedBitRate = 64_000
    static let encodeTimeoutSeconds: TimeInterval = 10
    private static let pcmSampleRate = 16_000.0

    private let sourceSampleRate: Int
    private let bitRateSelection: AACBitRateSelection
    private let encodingState = AACEncodingState()

    static func make(sourceSampleRate: Int) async -> StreamingAACChunkEncoder {
        await Task.detached(priority: .utility) {
            StreamingAACChunkEncoder(sourceSampleRate: sourceSampleRate)
        }.value
    }

    init(sourceSampleRate: Int) {
        self.sourceSampleRate = sourceSampleRate
        do {
            let selection = try Self.queryBitRateSelection(sourceSampleRate: sourceSampleRate)
            bitRateSelection = selection
            if selection.rule == .conservativeFallback {
                FileLogger.shared.warn(.audio, "AAC bitrate ranges did not intersect; using fallback", payload: [
                    "sampleRate": sourceSampleRate,
                    "bitrate": selection.bitRate
                ])
            }
        } catch {
            let fallback = AACBitRateSelector.conservativeFallback(
                sourceSampleRate: sourceSampleRate)
            bitRateSelection = fallback
            FileLogger.shared.warn(.audio, "AAC bitrate query failed; using fallback", payload: [
                "sampleRate": sourceSampleRate,
                "bitrate": fallback.bitRate,
                "error": String(error.localizedDescription.prefix(120))
            ])
        }
    }

    func encode(samples: [Float]) async throws -> Data {
        guard encodingState.begin() else {
            throw StreamingAACChunkEncoderError.previousEncodingStillRunning
        }
        FileLogger.shared.debug(.audio, "Stream AAC chunk encode bitrate", payload: [
            "sampleRate": sourceSampleRate,
            "bitrateBps": bitRateSelection.bitRate,
            "selectionRule": bitRateSelection.rule.rawValue
        ])

        let temporaryDirectory = AACEncodingTemporaryDirectory()
        let encodingState = self.encodingState
        return try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Data, Error>) in
            let completion = AACEncodingCompletion(continuation)
            DispatchQueue.global(qos: .utility).asyncAfter(
                deadline: .now() + Self.encodeTimeoutSeconds
            ) {
                let timedOut = StreamingAACChunkEncoderError.encodingTimedOut(
                    Self.encodeTimeoutSeconds)
                if completion.resume(with: .failure(timedOut)) {
                    temporaryDirectory.remove()
                }
            }

            let sourceSampleRate = self.sourceSampleRate
            let bitRate = self.bitRateSelection.bitRate
            Task.detached(priority: .utility) {
                defer {
                    temporaryDirectory.remove()
                    encodingState.finish()
                }
                do {
                    try temporaryDirectory.create()
                    let data = try Self.encodeSynchronously(
                        samples: samples,
                        sourceSampleRate: sourceSampleRate,
                        bitRate: bitRate,
                        fileURL: temporaryDirectory.audioFileURL)
                    completion.resume(with: .success(data))
                } catch {
                    completion.resume(with: .failure(error))
                }
            }
        }
    }

    private static func queryBitRateSelection(
        sourceSampleRate: Int
    ) throws -> AACBitRateSelection {
        guard StreamFormatNegotiation.supportedSourceSampleRates.contains(sourceSampleRate) else {
            throw StreamingAACChunkEncoderError.unsupportedSampleRate(sourceSampleRate)
        }

        let codecBitRateRanges = try availableAACBitRateRanges()
        guard let inputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(sourceSampleRate),
            channels: 1,
            interleaved: false),
              let outputFormat = AVAudioFormat(settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: sourceSampleRate,
                AVNumberOfChannelsKey: 1,
              ]),
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat),
              let applicableBitRates = converter.applicableEncodeBitRates else {
            throw StreamingAACChunkEncoderError.applicableBitRatesUnavailable(sourceSampleRate)
        }

        return AACBitRateSelector.select(
            availableRanges: codecBitRateRanges,
            applicableBitRates: applicableBitRates.map(\.intValue),
            targetBitRate: requestedBitRate,
            fallbackBitRate: AACBitRateSelector.conservativeFallback(
                sourceSampleRate: sourceSampleRate).bitRate)
    }

    private static func availableAACBitRateRanges() throws -> [AACBitRateRange] {
        // AudioFormat reports codec-wide ranges; the configured converter below
        // narrows them to this sample rate and mono channel layout.
        var codecFormatID = kAudioFormatMPEG4AAC
        let specifierSize = UInt32(MemoryLayout<UInt32>.size)
        var propertyDataSize: UInt32 = 0
        let infoStatus = AudioFormatGetPropertyInfo(
            kAudioFormatProperty_AvailableEncodeBitRates,
            specifierSize,
            &codecFormatID,
            &propertyDataSize)
        guard infoStatus == noErr else {
            throw StreamingAACChunkEncoderError.bitratePropertyFailed(
                operation: "AudioFormatGetPropertyInfo(AAC bit rates)",
                status: infoStatus)
        }

        let rangeSize = UInt32(MemoryLayout<AudioValueRange>.stride)
        guard propertyDataSize >= rangeSize,
              propertyDataSize % rangeSize == 0 else {
            throw StreamingAACChunkEncoderError.invalidBitRatePropertyData
        }

        var ranges = [AudioValueRange](
            repeating: AudioValueRange(mMinimum: 0, mMaximum: 0),
            count: Int(propertyDataSize / rangeSize))
        var returnedDataSize = propertyDataSize
        let propertyStatus = ranges.withUnsafeMutableBufferPointer { buffer in
            AudioFormatGetProperty(
                kAudioFormatProperty_AvailableEncodeBitRates,
                specifierSize,
                &codecFormatID,
                &returnedDataSize,
                buffer.baseAddress)
        }
        guard propertyStatus == noErr else {
            throw StreamingAACChunkEncoderError.bitratePropertyFailed(
                operation: "AudioFormatGetProperty(AAC bit rates)",
                status: propertyStatus)
        }
        guard returnedDataSize >= rangeSize,
              returnedDataSize <= propertyDataSize,
              returnedDataSize % rangeSize == 0 else {
            throw StreamingAACChunkEncoderError.invalidBitRatePropertyData
        }
        return ranges.prefix(Int(returnedDataSize / rangeSize)).map {
            AACBitRateRange(minimum: $0.mMinimum, maximum: $0.mMaximum)
        }
    }

    private static func encodeSynchronously(
        samples: [Float],
        sourceSampleRate: Int,
        bitRate: Int,
        fileURL: URL
    ) throws -> Data {
        try write(
            samples: samples,
            sourceSampleRate: sourceSampleRate,
            bitRate: bitRate,
            to: fileURL)
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw StreamingAACChunkEncoderError.operationFailed(
                operation: "Reading the encoded AAC chunk",
                error: error)
        }
        guard !data.isEmpty else {
            throw StreamingAACChunkEncoderError.emptyEncodedFile
        }
        return data
    }

    private static func write(
        samples: [Float],
        sourceSampleRate: Int,
        bitRate: Int,
        to fileURL: URL
    ) throws {
        var settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sourceSampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: bitRate,
        ]
        if sourceSampleRate == 48_000 {
            // Preserve the proven 48 kHz settings; 16 kHz uses bitrate as its sole quality control.
            settings[AVEncoderAudioQualityKey] = AVAudioQuality.high.rawValue
        }

        let file: AVAudioFile
        do {
            file = try AVAudioFile(forWriting: fileURL, settings: settings)
        } catch {
            throw StreamingAACChunkEncoderError.operationFailed(
                operation: "Opening the AAC chunk encoder",
                error: error)
        }
        let outputFormat = file.processingFormat
        guard outputFormat.commonFormat == .pcmFormatFloat32,
              outputFormat.channelCount == 1,
              outputFormat.sampleRate == Double(sourceSampleRate),
              let sourceFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: pcmSampleRate,
                channels: 1,
                interleaved: false) else {
            throw StreamingAACChunkEncoderError.outputFormatUnavailable
        }

        let inputFormat = sourceSampleRate == Int(pcmSampleRate) ? outputFormat : sourceFormat
        let inputBuffer = try makePCMBuffer(samples: samples, format: inputFormat)
        let writeBuffer: AVAudioPCMBuffer
        if sourceSampleRate == Int(pcmSampleRate) {
            writeBuffer = inputBuffer
        } else {
            writeBuffer = try convert(inputBuffer, to: outputFormat)
        }
        do {
            try file.write(from: writeBuffer)
        } catch {
            throw StreamingAACChunkEncoderError.operationFailed(
                operation: "Writing the AAC chunk",
                error: error)
        }
    }

    private static func makePCMBuffer(
        samples: [Float],
        format: AVAudioFormat
    ) throws -> AVAudioPCMBuffer {
        guard !samples.isEmpty,
              let frameCapacity = AVAudioFrameCount(exactly: samples.count),
              format.commonFormat == .pcmFormatFloat32,
              format.channelCount == 1,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCapacity),
              let channel = buffer.floatChannelData?.pointee else {
            throw StreamingAACChunkEncoderError.invalidPCMBuffer
        }

        buffer.frameLength = frameCapacity
        try samples.withUnsafeBufferPointer { source in
            guard let baseAddress = source.baseAddress else {
                throw StreamingAACChunkEncoderError.invalidPCMBuffer
            }
            channel.update(from: baseAddress, count: source.count)
        }
        return buffer
    }

    private static func convert(
        _ inputBuffer: AVAudioPCMBuffer,
        to outputFormat: AVAudioFormat
    ) throws -> AVAudioPCMBuffer {
        let outputCapacity = ceil(
            Double(inputBuffer.frameLength) * outputFormat.sampleRate / inputBuffer.format.sampleRate
        )
        guard outputCapacity > 0,
              outputCapacity <= Double(UInt32.max),
              let outputBuffer = AVAudioPCMBuffer(
                pcmFormat: outputFormat,
                frameCapacity: AVAudioFrameCount(outputCapacity)),
              let converter = AVAudioConverter(from: inputBuffer.format, to: outputFormat) else {
            throw StreamingAACChunkEncoderError.outputFormatUnavailable
        }

        var suppliedInput = false
        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, inputStatus in
            guard !suppliedInput else {
                inputStatus.pointee = .endOfStream
                return nil
            }
            suppliedInput = true
            inputStatus.pointee = .haveData
            return inputBuffer
        }
        guard status != .error else {
            throw StreamingAACChunkEncoderError.conversionFailed(conversionError)
        }
        guard outputBuffer.frameLength > 0 else {
            throw StreamingAACChunkEncoderError.noConvertedSamples
        }
        return outputBuffer
    }
}
