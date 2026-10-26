import Foundation
import UIKit

@MainActor
final class FullRecordingDiagnosticsUploadLease {
    private let sessionID: UUID
    private var taskIdentifier: UIBackgroundTaskIdentifier = .invalid
    private var uploadTask: Task<Void, Never>?
    private var isEnded = false
    private var didExpire = false

    private init(sessionID: UUID) {
        self.sessionID = sessionID
    }

    static func begin(sessionID: UUID) -> FullRecordingDiagnosticsUploadLease {
        let lease = FullRecordingDiagnosticsUploadLease(sessionID: sessionID)
        let identifier = UIApplication.shared.beginBackgroundTask(
            withName: "FullRecordingDiagnosticsUpload") { [weak lease] in
                lease?.expire()
            }
        lease.installBackgroundTask(identifier)
        FileLogger.shared.debug(.network, "Full recording upload lease begin", payload: [
            "jobId": sessionID.uuidString,
            "active": lease.taskIdentifier != .invalid && !lease.isEnded
        ])
        return lease
    }

    func installUploadTask(_ task: Task<Void, Never>) {
        guard !isEnded, !didExpire else {
            task.cancel()
            return
        }
        uploadTask = task
    }

    func end() {
        guard !isEnded else { return }
        isEnded = true
        uploadTask = nil
        let identifier = taskIdentifier
        taskIdentifier = .invalid
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
    }

    private func installBackgroundTask(_ identifier: UIBackgroundTaskIdentifier) {
        guard identifier != .invalid else {
            FileLogger.shared.warn(.network, "Full recording upload background lease unavailable", payload: [
                "jobId": sessionID.uuidString
            ])
            return
        }
        guard !isEnded else {
            UIApplication.shared.endBackgroundTask(identifier)
            return
        }
        taskIdentifier = identifier
    }

    private func expire() {
        guard !isEnded else { return }
        didExpire = true
        FileLogger.shared.warn(.network, "Full recording diagnostics upload lease expired mid-upload", payload: [
            "jobId": sessionID.uuidString
        ])
        uploadTask?.cancel()
        end()
    }
}

enum FullRecordingDiagnosticsUploader {
    private static let maximumUploadBytes: UInt64 = 100 * 1024 * 1024
    private static let conversionChunkBytes = 256 * 1024
    private static let requestTimeout: TimeInterval = 600
    private static let retryDelay: TimeInterval = 3
    private static let maximumAttempts = 2
    private static let staleStagingAge: TimeInterval = 24 * 60 * 60

    private struct SourceWAVFormat {
        let sampleRate: UInt32
        let channelCount: UInt16
        let blockAlign: UInt16
        let dataOffset: UInt64
        let dataSize: UInt32

        var frameCount: UInt64 {
            UInt64(dataSize) / UInt64(blockAlign)
        }
    }

    private struct ConversionResult {
        let truncated: Bool
        let sampleRate: UInt32
        let channelCount: UInt16
    }

    private struct UploadAttempt {
        let response: HTTPURLResponse
        let bytesSent: Int64
    }

    private struct UploadTransportError: LocalizedError {
        let underlyingError: Error
        let bytesSent: Int64

        var errorDescription: String? {
            underlyingError.localizedDescription
        }
    }

    private enum UploadError: LocalizedError {
        case invalidServerURL
        case invalidSourceWAV
        case unsupportedSourceWAV
        case invalidUploadResponse

        var errorDescription: String? {
            switch self {
            case .invalidServerURL: return "Invalid stream server URL"
            case .invalidSourceWAV: return "Invalid source WAV"
            case .unsupportedSourceWAV: return "Unsupported source WAV format"
            case .invalidUploadResponse: return "Upload returned a non-HTTP response"
            }
        }
    }

    private final class UploadTaskCancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var task: URLSessionUploadTask?
        private var isCancelled = false
        private var lastBytesSent: Int64 = 0

        func install(_ task: URLSessionUploadTask) {
            lock.lock()
            let shouldCancel = isCancelled
            if !shouldCancel {
                self.task = task
            } else {
                lastBytesSent = max(lastBytesSent, max(0, task.countOfBytesSent))
            }
            lock.unlock()

            if shouldCancel {
                task.cancel()
            }
        }

        func cancel() {
            lock.lock()
            isCancelled = true
            let task = self.task
            if let task {
                lastBytesSent = max(lastBytesSent, max(0, task.countOfBytesSent))
            }
            lock.unlock()
            task?.cancel()
        }

        func completeAndGetBytesSent() -> Int64 {
            lock.lock()
            if let task {
                lastBytesSent = max(lastBytesSent, max(0, task.countOfBytesSent))
            }
            self.task = nil
            let bytesSent = lastBytesSent
            lock.unlock()
            return bytesSent
        }
    }

    /// Atomically transfers the completed session WAV to the detached uploader.
    static func stage(sourceURL: URL, sessionID: UUID) throws -> URL {
        let fileManager = FileManager.default
        let stagedURL = sourceURL.deletingLastPathComponent()
            .appendingPathComponent("\(sessionID.uuidString).staged-upload")
        let convertedURL = convertedURL(for: stagedURL)

        if fileManager.fileExists(atPath: stagedURL.path) {
            try fileManager.removeItem(at: stagedURL)
        }
        if fileManager.fileExists(atPath: convertedURL.path) {
            try fileManager.removeItem(at: convertedURL)
        }
        try fileManager.moveItem(at: sourceURL, to: stagedURL)
        return stagedURL
    }

    /// Converts, retries a failed upload once, and removes both owned files without affecting the session flow.
    static func upload(
        stagedURL: URL,
        serverURL: String,
        recordingToken: String,
        sessionID: UUID,
        backgroundTaskLease: FullRecordingDiagnosticsUploadLease
    ) async {
        let uploadStartedAt = Date()
        let outputURL = convertedURL(for: stagedURL)
        var outcome = "failed"
        var reason: String?
        var statusCode: Int?
        var truncated = false
        var audioFormat: String?
        var bytesSent: Int64 = 0
        var attempts = 0
        var attemptOutcomes: [String] = []

        do {
            sweepStaleStagingFiles(
                in: stagedURL.deletingLastPathComponent(),
                preserving: stagedURL)
            try Task.checkCancellation()
            let conversion = try convertFloat32WAV(sourceURL: stagedURL, destinationURL: outputURL)
            truncated = conversion.truncated
            let convertedAudioFormat = Self.audioFormat(
                sampleRate: conversion.sampleRate,
                channelCount: conversion.channelCount)
            audioFormat = convertedAudioFormat

            try Task.checkCancellation()
            for attempt in 1...maximumAttempts {
                try Task.checkCancellation()
                attempts = attempt
                var retryableFailure = false

                do {
                    let uploadAttempt = try await post(
                        fileURL: outputURL,
                        serverURL: serverURL,
                        recordingToken: recordingToken,
                        sessionID: sessionID,
                        truncated: conversion.truncated,
                        audioFormat: convertedAudioFormat)
                    bytesSent += max(0, uploadAttempt.bytesSent)
                    statusCode = uploadAttempt.response.statusCode
                    if (200..<300).contains(uploadAttempt.response.statusCode) {
                        outcome = "uploaded"
                        reason = nil
                        attemptOutcomes.append("uploaded_\(uploadAttempt.response.statusCode)")
                        break
                    }

                    outcome = "http_failure"
                    reason = "HTTP \(uploadAttempt.response.statusCode)"
                    attemptOutcomes.append("http_failure_\(uploadAttempt.response.statusCode)")
                    retryableFailure = true
                } catch is CancellationError {
                    outcome = "cancelled"
                    reason = "cancelled"
                    attemptOutcomes.append("cancelled")
                    break
                } catch let transportError as UploadTransportError {
                    bytesSent += max(0, transportError.bytesSent)
                    if Task.isCancelled || isCancellation(transportError.underlyingError) {
                        outcome = "cancelled"
                        reason = "cancelled"
                        attemptOutcomes.append("cancelled")
                        break
                    }

                    outcome = "failed"
                    reason = safeErrorDescription(
                        transportError.underlyingError,
                        recordingToken: recordingToken)
                    attemptOutcomes.append("transport_failure")
                    retryableFailure = true
                }

                guard retryableFailure, attempt < maximumAttempts else { break }
                do {
                    try await Task.sleep(nanoseconds: UInt64(retryDelay * 1_000_000_000))
                    try Task.checkCancellation()
                } catch {
                    outcome = "cancelled"
                    reason = "cancelled"
                    attemptOutcomes.append("cancelled_before_retry")
                    break
                }
            }
        } catch is CancellationError {
            outcome = "cancelled"
            reason = "cancelled"
        } catch {
            if Task.isCancelled || isCancellation(error) {
                outcome = "cancelled"
                reason = "cancelled"
            } else {
                reason = safeErrorDescription(error, recordingToken: recordingToken)
            }
        }

        let outputRemoved = removeIfPresent(at: outputURL)
        let stagedRemoved = removeIfPresent(at: stagedURL)
        var payload: [String: Any] = [
            "jobId": sessionID.uuidString,
            "outcome": outcome,
            "truncated": truncated,
            "cleanupSucceeded": outputRemoved && stagedRemoved,
            "elapsed_ms": Date().timeIntervalSince(uploadStartedAt) * 1_000,
            "bytesSent": bytesSent,
            "attempts": attempts,
            "retryAttempted": attempts > 1,
            "attemptOutcomes": attemptOutcomes
        ]
        if let statusCode {
            payload["status"] = statusCode
        }
        if let audioFormat {
            payload["audioFormat"] = audioFormat
        }
        if let reason {
            payload["reason"] = reason
        }
        let retryExhausted = attempts == maximumAttempts
            && (outcome == "http_failure" || outcome == "failed")
        FileLogger.shared.log(
            retryExhausted ? .warn : .debug,
            .network,
            "Full recording diagnostics upload",
            payload: payload)
        await backgroundTaskLease.end()
    }

    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        return false
    }

    private static func safeErrorDescription(_ error: Error, recordingToken: String) -> String {
        var description = error.localizedDescription
        if !recordingToken.isEmpty {
            description = description.replacingOccurrences(of: recordingToken, with: "<redacted>")
            let tokenCharacters = CharacterSet(
                charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
            if let encodedToken = recordingToken.addingPercentEncoding(
                withAllowedCharacters: tokenCharacters) {
                description = description.replacingOccurrences(
                    of: encodedToken,
                    with: "<redacted>",
                    options: .caseInsensitive)
            }
        }
        return String(description.prefix(120))
    }

    private static func convertedURL(for stagedURL: URL) -> URL {
        stagedURL.deletingLastPathComponent()
            .appendingPathComponent("\(stagedURL.lastPathComponent).pcm16.wav")
    }

    private static func removeIfPresent(at url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return true }
        do {
            try FileManager.default.removeItem(at: url)
            return true
        } catch {
            return false
        }
    }

    private static func sweepStaleStagingFiles(in directory: URL, preserving currentURL: URL) {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]) else { return }

        let cutoff = Date().addingTimeInterval(-staleStagingAge)
        for file in files {
            guard isStagingFile(file),
                  file.standardizedFileURL != currentURL.standardizedFileURL,
                  let values = try? file.resourceValues(forKeys: [.contentModificationDateKey]),
                  let modifiedAt = values.contentModificationDate,
                  modifiedAt < cutoff else { continue }
            try? FileManager.default.removeItem(at: file)
        }
    }

    private static func isStagingFile(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        return name.hasSuffix(".staged-upload") || name.hasSuffix(".staged-upload.pcm16.wav")
    }

    private static func convertFloat32WAV(
        sourceURL: URL,
        destinationURL: URL
    ) throws -> ConversionResult {
        let fileManager = FileManager.default
        let input = try FileHandle(forReadingFrom: sourceURL)
        defer { try? input.close() }

        let sourceFormat = try readSourceFormat(from: input, url: sourceURL)
        let outputBlockAlignValue = Int(sourceFormat.channelCount) * 2
        guard outputBlockAlignValue <= Int(UInt16.max) else {
            throw UploadError.unsupportedSourceWAV
        }
        let outputBlockAlign = UInt16(outputBlockAlignValue)
        let maximumFrames = (maximumUploadBytes - 44) / UInt64(outputBlockAlign)
        let retainedFrames = min(sourceFormat.frameCount, maximumFrames)
        let firstRetainedFrame = sourceFormat.frameCount - retainedFrames
        let outputDataSize = retainedFrames * UInt64(outputBlockAlign)
        guard outputDataSize <= UInt64(UInt32.max) else {
            throw UploadError.unsupportedSourceWAV
        }
        let outputByteRate = UInt64(sourceFormat.sampleRate) * UInt64(outputBlockAlign)
        guard outputByteRate <= UInt64(UInt32.max) else {
            throw UploadError.unsupportedSourceWAV
        }

        guard fileManager.createFile(atPath: destinationURL.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let output = try FileHandle(forWritingTo: destinationURL)
        defer { try? output.close() }

        let header = pcm16WAVHeader(
            sampleRate: sourceFormat.sampleRate,
            channelCount: sourceFormat.channelCount,
            blockAlign: outputBlockAlign,
            byteRate: UInt32(outputByteRate),
            dataSize: UInt32(outputDataSize))
        try output.write(contentsOf: header)

        let firstByteOffset = sourceFormat.dataOffset
            + firstRetainedFrame * UInt64(sourceFormat.blockAlign)
        try input.seek(toOffset: firstByteOffset)

        let framesPerChunk = max(1, conversionChunkBytes / Int(sourceFormat.blockAlign))
        var framesRemaining = retainedFrames
        while framesRemaining > 0 {
            try Task.checkCancellation()
            let frameCount = Int(min(UInt64(framesPerChunk), framesRemaining))
            let sourceByteCount = frameCount * Int(sourceFormat.blockAlign)
            let sourceBytes = try readExactly(sourceByteCount, from: input)
            let sampleCount = frameCount * Int(sourceFormat.channelCount)
            var convertedBytes = Data()
            convertedBytes.reserveCapacity(sampleCount * 2)

            for sampleIndex in 0..<sampleCount {
                let offset = sampleIndex * 4
                let bits = uint32LE(sourceBytes, at: offset)
                let sample = Float(bitPattern: bits)
                let boundedSample = sample.isFinite ? min(max(sample, -1), 1) : 0
                let scaledSample = boundedSample < 0
                    ? boundedSample * 32_768
                    : boundedSample * 32_767
                let pcmSample = Int16(scaledSample.rounded(.towardZero))
                appendUInt16LE(UInt16(bitPattern: pcmSample), to: &convertedBytes)
            }

            try output.write(contentsOf: convertedBytes)
            framesRemaining -= UInt64(frameCount)
        }
        try output.synchronize()

        return ConversionResult(
            truncated: firstRetainedFrame > 0,
            sampleRate: sourceFormat.sampleRate,
            channelCount: sourceFormat.channelCount)
    }

    private static func readSourceFormat(
        from handle: FileHandle,
        url: URL
    ) throws -> SourceWAVFormat {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let fileSizeNumber = attributes[.size] as? NSNumber else {
            throw UploadError.invalidSourceWAV
        }
        let fileSize = fileSizeNumber.uint64Value
        guard fileSize >= 12 else { throw UploadError.invalidSourceWAV }

        try handle.seek(toOffset: 0)
        let riffHeader = try readExactly(12, from: handle)
        guard fourCC(riffHeader, at: 0) == "RIFF",
              fourCC(riffHeader, at: 8) == "WAVE" else {
            throw UploadError.invalidSourceWAV
        }
        let riffEnd = UInt64(uint32LE(riffHeader, at: 4)) + 8
        guard riffEnd >= 12, riffEnd <= fileSize else {
            throw UploadError.invalidSourceWAV
        }

        var cursor: UInt64 = 12
        var formatChunk: Data?
        var dataOffset: UInt64?
        var dataSize: UInt32?
        while cursor <= riffEnd - 8 {
            try handle.seek(toOffset: cursor)
            let chunkHeader = try readExactly(8, from: handle)
            let chunkSize = uint32LE(chunkHeader, at: 4)
            let bodyOffset = cursor + 8
            let bodyEnd = bodyOffset + UInt64(chunkSize)
            guard bodyEnd <= riffEnd else { throw UploadError.invalidSourceWAV }

            switch fourCC(chunkHeader, at: 0) {
            case "fmt ":
                guard chunkSize >= 16, chunkSize <= 4_096 else {
                    throw UploadError.unsupportedSourceWAV
                }
                if formatChunk == nil {
                    try handle.seek(toOffset: bodyOffset)
                    formatChunk = try readExactly(Int(chunkSize), from: handle)
                }
            case "data":
                if dataOffset == nil {
                    dataOffset = bodyOffset
                    dataSize = chunkSize
                }
            default:
                break
            }

            cursor = bodyEnd + UInt64(chunkSize & 1)
        }

        guard let formatChunk, let dataOffset, let dataSize else {
            throw UploadError.invalidSourceWAV
        }
        let wavFormat = try parseFloat32Format(formatChunk)
        guard dataOffset + UInt64(dataSize) <= fileSize,
              dataSize % UInt32(wavFormat.blockAlign) == 0 else {
            throw UploadError.invalidSourceWAV
        }

        return SourceWAVFormat(
            sampleRate: wavFormat.sampleRate,
            channelCount: wavFormat.channelCount,
            blockAlign: wavFormat.blockAlign,
            dataOffset: dataOffset,
            dataSize: dataSize)
    }

    private static func parseFloat32Format(
        _ chunk: Data
    ) throws -> (sampleRate: UInt32, channelCount: UInt16, blockAlign: UInt16) {
        let formatTag = uint16LE(chunk, at: 0)
        let channelCount = uint16LE(chunk, at: 2)
        let sampleRate = uint32LE(chunk, at: 4)
        let byteRate = uint32LE(chunk, at: 8)
        let blockAlign = uint16LE(chunk, at: 12)
        let bitsPerSample = uint16LE(chunk, at: 14)

        let isFloatFormat: Bool
        if formatTag == 3 {
            isFloatFormat = true
        } else if formatTag == 0xFFFE, chunk.count >= 40,
                  uint16LE(chunk, at: 16) >= 22,
                  uint32LE(chunk, at: 24) == 3 {
            let guidTail: [UInt8] = [0, 0, 0x10, 0, 0x80, 0, 0, 0xAA, 0, 0x38, 0x9B, 0x71]
            isFloatFormat = Array(chunk[28..<40]) == guidTail
        } else {
            isFloatFormat = false
        }

        let expectedBlockAlign = Int(channelCount) * 4
        let expectedByteRate = UInt64(sampleRate) * UInt64(blockAlign)
        guard isFloatFormat,
              channelCount > 0,
              sampleRate > 0,
              bitsPerSample == 32,
              expectedBlockAlign == Int(blockAlign),
              expectedByteRate == UInt64(byteRate) else {
            throw UploadError.unsupportedSourceWAV
        }
        return (sampleRate, channelCount, blockAlign)
    }

    private static func pcm16WAVHeader(
        sampleRate: UInt32,
        channelCount: UInt16,
        blockAlign: UInt16,
        byteRate: UInt32,
        dataSize: UInt32
    ) -> Data {
        var header = Data()
        header.append(contentsOf: "RIFF".utf8)
        appendUInt32LE(36 + dataSize, to: &header)
        header.append(contentsOf: "WAVEfmt ".utf8)
        appendUInt32LE(16, to: &header)
        appendUInt16LE(1, to: &header)
        appendUInt16LE(channelCount, to: &header)
        appendUInt32LE(sampleRate, to: &header)
        appendUInt32LE(byteRate, to: &header)
        appendUInt16LE(blockAlign, to: &header)
        appendUInt16LE(16, to: &header)
        header.append(contentsOf: "data".utf8)
        appendUInt32LE(dataSize, to: &header)
        return header
    }

    private static func audioFormat(sampleRate: UInt32, channelCount: UInt16) -> String {
        let channels = channelCount == 1 ? "mono" : "\(channelCount)-channel"
        return "wav-pcm16-\(sampleRate)-\(channels)"
    }

    private static func post(
        fileURL: URL,
        serverURL: String,
        recordingToken: String,
        sessionID: UUID,
        truncated: Bool,
        audioFormat: String
    ) async throws -> UploadAttempt {
        guard var components = URLComponents(string: serverURL),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.host != nil else {
            throw UploadError.invalidServerURL
        }
        let basePath = components.percentEncodedPath
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let tokenCharacters = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        let tokenPath = recordingToken.addingPercentEncoding(
            withAllowedCharacters: tokenCharacters)
            ?? recordingToken
        let endpointPath = basePath.isEmpty
            ? "full_recordings/\(tokenPath)"
            : "\(basePath)/full_recordings/\(tokenPath)"
        components.percentEncodedPath = "/\(endpointPath)"
        guard let url = components.url else { throw UploadError.invalidServerURL }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = requestTimeout
        request.setValue("audio/wav", forHTTPHeaderField: "Content-Type")
        request.setValue(sessionID.uuidString, forHTTPHeaderField: "X-Client-Session-UUID")
        request.setValue(truncated ? "true" : "false", forHTTPHeaderField: "X-Recording-Truncated")
        request.setValue(audioFormat, forHTTPHeaderField: "X-Audio-Format")
        WhisperClient.applyAuth(to: &request)

        let cancellation = UploadTaskCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<UploadAttempt, Error>) in
                let task = URLSession.shared.uploadTask(
                    with: request,
                    fromFile: fileURL
                ) { _, response, error in
                    let bytesSent = cancellation.completeAndGetBytesSent()
                    if let error {
                        continuation.resume(throwing: UploadTransportError(
                            underlyingError: error,
                            bytesSent: bytesSent))
                    } else if let response = response as? HTTPURLResponse {
                        continuation.resume(returning: UploadAttempt(
                            response: response,
                            bytesSent: bytesSent))
                    } else {
                        continuation.resume(throwing: UploadTransportError(
                            underlyingError: UploadError.invalidUploadResponse,
                            bytesSent: bytesSent))
                    }
                }
                cancellation.install(task)
                task.resume()
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    private static func readExactly(_ count: Int, from handle: FileHandle) throws -> Data {
        var data = Data()
        data.reserveCapacity(count)
        while data.count < count {
            guard let chunk = try handle.read(upToCount: count - data.count), !chunk.isEmpty else {
                throw UploadError.invalidSourceWAV
            }
            data.append(chunk)
        }
        return data
    }

    private static func fourCC(_ data: Data, at offset: Int) -> String {
        String(decoding: data[offset..<(offset + 4)], as: UTF8.self)
    }

    private static func uint16LE(_ data: Data, at offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func uint32LE(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }

    private static func appendUInt16LE(_ value: UInt16, to data: inout Data) {
        data.append(UInt8(value & 0x00FF))
        data.append(UInt8(value >> 8))
    }

    private static func appendUInt32LE(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(value & 0x000000FF))
        data.append(UInt8((value >> 8) & 0x000000FF))
        data.append(UInt8((value >> 16) & 0x000000FF))
        data.append(UInt8(value >> 24))
    }
}
