import AVFoundation
import Foundation

final class ChunkAudioStore: @unchecked Sendable {
    private static let rootDirectoryName = "chunk-audio"

    private let fileManager = FileManager.default
    private let sessionDirectory: URL
    private let lock = NSLock()

    init(sessionID: UUID) {
        let rootDirectory = fileManager.temporaryDirectory
            .appendingPathComponent(Self.rootDirectoryName, isDirectory: true)
        sessionDirectory = rootDirectory
            .appendingPathComponent(sessionID.uuidString, isDirectory: true)

        sweepStaleDirectories(in: rootDirectory)

        do {
            try fileManager.createDirectory(
                at: sessionDirectory,
                withIntermediateDirectories: true)
        } catch {
            FileLogger.shared.warn(.audio, "Chunk audio directory unavailable")
        }
    }

    func write(chunkId: UInt32, samples: [Float]) -> URL? {
        lock.lock()
        defer { lock.unlock() }

        guard !samples.isEmpty,
              fileManager.fileExists(atPath: sessionDirectory.path) else {
            FileLogger.shared.warn(.audio, "Chunk audio write unavailable")
            return nil
        }

        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        ) else {
            FileLogger.shared.warn(.audio, "Chunk audio format unavailable")
            return nil
        }

        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(samples.count)
        ), let channelData = buffer.int16ChannelData?[0] else {
            FileLogger.shared.warn(.audio, "Chunk audio buffer unavailable")
            return nil
        }

        buffer.frameLength = AVAudioFrameCount(samples.count)
        for (index, sample) in samples.enumerated() {
            let clampedSample = max(-1.0, min(1.0, sample))
            channelData[index] = Int16(clampedSample * Float(Int16.max))
        }

        let url = sessionDirectory.appendingPathComponent("\(chunkId).wav")
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
            return url
        } catch {
            FileLogger.shared.warn(.audio, "Chunk audio write failed")
            return nil
        }
    }

    func removeSessionDirectory() {
        lock.lock()
        defer { lock.unlock() }

        guard fileManager.fileExists(atPath: sessionDirectory.path) else { return }
        do {
            try fileManager.removeItem(at: sessionDirectory)
        } catch {
            FileLogger.shared.warn(.audio, "Chunk audio cleanup failed")
        }
    }

    private func sweepStaleDirectories(in rootDirectory: URL) {
        do {
            try fileManager.createDirectory(
                at: rootDirectory,
                withIntermediateDirectories: true)
            let entries = try fileManager.contentsOfDirectory(
                at: rootDirectory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles])

            for entry in entries {
                guard let values = try? entry.resourceValues(forKeys: [.isDirectoryKey]),
                      values.isDirectory == true else {
                    continue
                }

                do {
                    try fileManager.removeItem(at: entry)
                } catch {
                    FileLogger.shared.warn(.audio, "Stale chunk audio cleanup failed")
                }
            }
        } catch {
            FileLogger.shared.warn(.audio, "Stale chunk audio sweep failed")
        }
    }
}
