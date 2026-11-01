import Foundation

enum UnifiedStreamProtocolError: Error, Equatable, Sendable {
    case invalidAudioFrame
    case chunkIDExhausted
    case invalidMessage
}

struct UnifiedStreamAudioFrame: Equatable, Sendable {
    let chunkID: UInt32
    let samples: [Float]
}

struct UnifiedStreamChunkIDSequence {
    private var nextValue: UInt64

    init(startingAt: UInt32 = 0) {
        nextValue = UInt64(startingAt)
    }

    mutating func next() throws -> UInt32 {
        guard nextValue <= UInt64(UInt32.max) else {
            throw UnifiedStreamProtocolError.chunkIDExhausted
        }
        let chunkID = UInt32(nextValue)
        nextValue += 1
        return chunkID
    }
}

enum UnifiedStreamFrameCodec {
    static func encode(chunkID: UInt32, samples: [Float]) throws -> Data {
        let (payloadByteCount, overflow) = samples.count.multipliedReportingOverflow(by: 4)
        guard !samples.isEmpty, !overflow, payloadByteCount <= Int.max - 4 else {
            throw UnifiedStreamProtocolError.invalidAudioFrame
        }

        var data = Data()
        data.reserveCapacity(4 + payloadByteCount)
        data.append(UInt8(truncatingIfNeeded: chunkID >> 24))
        data.append(UInt8(truncatingIfNeeded: chunkID >> 16))
        data.append(UInt8(truncatingIfNeeded: chunkID >> 8))
        data.append(UInt8(truncatingIfNeeded: chunkID))

        for sample in samples {
            let bits = sample.bitPattern
            data.append(UInt8(truncatingIfNeeded: bits))
            data.append(UInt8(truncatingIfNeeded: bits >> 8))
            data.append(UInt8(truncatingIfNeeded: bits >> 16))
            data.append(UInt8(truncatingIfNeeded: bits >> 24))
        }
        return data
    }

    static func decode(_ data: Data) throws -> UnifiedStreamAudioFrame {
        guard data.count >= 8, (data.count - 4).isMultiple(of: 4) else {
            throw UnifiedStreamProtocolError.invalidAudioFrame
        }

        let bytes = [UInt8](data)
        let chunkID = UInt32(bytes[0]) << 24
            | UInt32(bytes[1]) << 16
            | UInt32(bytes[2]) << 8
            | UInt32(bytes[3])
        var samples: [Float] = []
        samples.reserveCapacity((bytes.count - 4) / 4)

        for offset in stride(from: 4, to: bytes.count, by: 4) {
            let bits = UInt32(bytes[offset])
                | UInt32(bytes[offset + 1]) << 8
                | UInt32(bytes[offset + 2]) << 16
                | UInt32(bytes[offset + 3]) << 24
            samples.append(Float(bitPattern: bits))
        }
        return UnifiedStreamAudioFrame(chunkID: chunkID, samples: samples)
    }
}

struct UnifiedStreamInterim: Decodable, Equatable, Sendable {
    let segmentIndex: Int
    let transcription: String
    let startS: Double
    let audioEndS: Double

    enum CodingKeys: String, CodingKey {
        case segmentIndex = "segment_index"
        case transcription
        case startS = "start_s"
        case audioEndS = "audio_end_s"
    }
}

struct UnifiedStreamFinalSegment: Decodable, Equatable, Sendable {
    let segmentIndex: Int
    let transcription: String
    let startS: Double
    let endS: Double
    let emittedAtS: Double
    let reason: String

    enum CodingKeys: String, CodingKey {
        case segmentIndex = "segment_index"
        case transcription
        case startS = "start_s"
        case endS = "end_s"
        case emittedAtS = "emitted_at_s"
        case reason
    }
}

struct UnifiedStreamFinal: Decodable, Equatable, Sendable {
    let transcription: String
    let segments: [UnifiedStreamFinalSegment]
    let reason: String
}

enum UnifiedStreamServerMessage: Sendable {
    case interim(UnifiedStreamInterim)
    case finalSegment(UnifiedStreamFinalSegment)
    case final(UnifiedStreamFinal)
    case pong
    case error(String)
    case cancelled
    case unknown(String)
}

enum UnifiedStreamMessageParser {
    static func parse(_ text: String) throws -> UnifiedStreamServerMessage {
        guard let data = text.data(using: .utf8) else {
            throw UnifiedStreamProtocolError.invalidMessage
        }
        let decoder = JSONDecoder()
        let header = try decoder.decode(MessageType.self, from: data)

        switch header.type {
        case "interim":
            return .interim(try decoder.decode(UnifiedStreamInterim.self, from: data))
        case "final_segment":
            return .finalSegment(try decoder.decode(UnifiedStreamFinalSegment.self, from: data))
        case "final":
            return .final(try decoder.decode(UnifiedStreamFinal.self, from: data))
        case "PONG":
            return .pong
        case "error":
            return .error(try decoder.decode(ErrorMessage.self, from: data).message)
        case "cancelled":
            return .cancelled
        default:
            return .unknown(header.type)
        }
    }

    private struct MessageType: Decodable {
        let type: String
    }

    private struct ErrorMessage: Decodable {
        let message: String
    }
}

struct UnifiedStreamTranscriptSnapshot: Equatable, Sendable {
    let displayText: String
    let terminalAggregate: String?
    let degradedAggregate: String?
}

struct UnifiedStreamTranscriptAccumulator {
    private var committedSegments: [Int: String] = [:]
    private var interimSegmentIndex: Int?
    private var interimText: String?
    private var finalText: String?

    var displayText: String {
        let committedText = committedSegments.keys.sorted().compactMap {
            committedSegments[$0]
        }
        let visibleText = committedText + [interimText].compactMap { $0 }
        return visibleText.filter { !$0.isEmpty }.joined(separator: " ")
    }

    var terminalAggregate: String? {
        finalText
    }

    var degradedAggregate: String? {
        finalText == nil ? displayText : nil
    }

    mutating func consume(_ message: UnifiedStreamServerMessage) {
        switch message {
        case .interim(let interim):
            guard committedSegments[interim.segmentIndex] == nil else { return }
            interimSegmentIndex = interim.segmentIndex
            interimText = interim.transcription

        case .finalSegment(let segment):
            committedSegments[segment.segmentIndex] = segment.transcription
            if interimSegmentIndex == segment.segmentIndex {
                interimSegmentIndex = nil
                interimText = nil
            }

        case .final(let final):
            for segment in final.segments {
                committedSegments[segment.segmentIndex] = segment.transcription
            }
            interimSegmentIndex = nil
            interimText = nil
            finalText = final.transcription

        case .pong, .error, .cancelled, .unknown:
            break
        }
    }

    func snapshot() -> UnifiedStreamTranscriptSnapshot {
        UnifiedStreamTranscriptSnapshot(
            displayText: displayText,
            terminalAggregate: terminalAggregate,
            degradedAggregate: degradedAggregate)
    }
}
