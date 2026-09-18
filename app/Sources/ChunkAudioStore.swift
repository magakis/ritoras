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

        let dataByteCount = samples.count * MemoryLayout<Int16>.size
        guard let dataSize = UInt32(exactly: dataByteCount),
              let chunkSize = UInt32(exactly: 36 + dataByteCount) else {
            FileLogger.shared.warn(.audio, "Chunk audio write failed")
            return nil
        }

        // AVAudioFile(forWriting:) traps in AudioToolboxCore/caulk on device (builds 316/319/321, symbolicated at ChunkAudioStore.write); this path uses plain byte I/O only.
        var wavData = Data(repeating: 0, count: 44 + dataByteCount)
        wavData.withUnsafeMutableBytes { rawBytes in
            let bytes = rawBytes.bindMemory(to: UInt8.self)

            bytes[0] = 0x52
            bytes[1] = 0x49
            bytes[2] = 0x46
            bytes[3] = 0x46
            bytes[4] = UInt8(truncatingIfNeeded: chunkSize)
            bytes[5] = UInt8(truncatingIfNeeded: chunkSize >> 8)
            bytes[6] = UInt8(truncatingIfNeeded: chunkSize >> 16)
            bytes[7] = UInt8(truncatingIfNeeded: chunkSize >> 24)
            bytes[8] = 0x57
            bytes[9] = 0x41
            bytes[10] = 0x56
            bytes[11] = 0x45
            bytes[12] = 0x66
            bytes[13] = 0x6D
            bytes[14] = 0x74
            bytes[15] = 0x20
            bytes[16] = 16
            bytes[20] = 1
            bytes[22] = 1
            bytes[24] = 0x80
            bytes[25] = 0x3E
            bytes[28] = 0x00
            bytes[29] = 0x7D
            bytes[32] = 2
            bytes[34] = 16
            bytes[36] = 0x64
            bytes[37] = 0x61
            bytes[38] = 0x74
            bytes[39] = 0x61
            bytes[40] = UInt8(truncatingIfNeeded: dataSize)
            bytes[41] = UInt8(truncatingIfNeeded: dataSize >> 8)
            bytes[42] = UInt8(truncatingIfNeeded: dataSize >> 16)
            bytes[43] = UInt8(truncatingIfNeeded: dataSize >> 24)

            for (index, sample) in samples.enumerated() {
                let clampedSample = max(-1.0, min(1.0, sample.isFinite ? sample : 0))
                let pcmSample = Int16(clampedSample * Float(Int16.max))
                let byteIndex = 44 + index * 2
                bytes[byteIndex] = UInt8(truncatingIfNeeded: pcmSample)
                bytes[byteIndex + 1] = UInt8(truncatingIfNeeded: pcmSample >> 8)
            }
        }

        let url = sessionDirectory.appendingPathComponent("\(chunkId).wav")
        do {
            try wavData.write(to: url, options: .atomic)
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
