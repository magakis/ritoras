import Foundation
import AVFoundation

enum StreamingAACChunkEncoderError: LocalizedError {
    case unsupportedSampleRate(Int)
    case invalidPCMBuffer
    case outputFormatUnavailable
    case conversionFailed(Error?)
    case noConvertedSamples
    case emptyEncodedFile
    case cleanupFailed(operation: Error, cleanup: Error)

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
        case .cleanupFailed(let operation, let cleanup):
            return "AAC encoding failed (\(operation.localizedDescription)); "
                + "temporary-file cleanup failed (\(cleanup.localizedDescription))"
        }
    }
}

enum StreamingAACChunkEncoder {
    private static let pcmSampleRate = 16_000.0

    static func encode(samples: [Float], sourceSampleRate: Int) async throws -> Data {
        try await Task.detached(priority: .utility) {
            try encodeSynchronously(samples: samples, sourceSampleRate: sourceSampleRate)
        }.value
    }

    private static func encodeSynchronously(
        samples: [Float],
        sourceSampleRate: Int
    ) throws -> Data {
        guard StreamFormatNegotiation.supportedSourceSampleRates.contains(sourceSampleRate) else {
            throw StreamingAACChunkEncoderError.unsupportedSampleRate(sourceSampleRate)
        }

        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ritoras-stream-\(UUID().uuidString).m4a")
        let result: Result<Data, Error>
        do {
            try write(samples: samples, sourceSampleRate: sourceSampleRate, to: fileURL)
            // `write` releases AVAudioFile before the container is read back.
            let data = try Data(contentsOf: fileURL)
            guard !data.isEmpty else {
                throw StreamingAACChunkEncoderError.emptyEncodedFile
            }
            result = .success(data)
        } catch {
            result = .failure(error)
        }

        if FileManager.default.fileExists(atPath: fileURL.path) {
            do {
                try FileManager.default.removeItem(at: fileURL)
            } catch {
                if case .failure(let operationError) = result {
                    throw StreamingAACChunkEncoderError.cleanupFailed(
                        operation: operationError,
                        cleanup: error)
                }
                throw error
            }
        }

        return try result.get()
    }

    private static func write(
        samples: [Float],
        sourceSampleRate: Int,
        to fileURL: URL
    ) throws {
        // kAudioFormatMPEG4AAC selects AAC-LC, matching the batch recorder.
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sourceSampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            AVEncoderBitRateKey: 64_000,
        ]
        let file = try AVAudioFile(forWriting: fileURL, settings: settings)
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
        try file.write(from: writeBuffer)
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
