import Foundation

enum StreamFormatNegotiationError: Error {
    case unsupportedSourceSampleRate(Int)
}

/// Pure Protocol v2 codec for streaming audio-format negotiation.
enum StreamFormatNegotiation {
    enum AudioMode: Equatable, Sendable {
        case float32PCM
        case aacM4A
    }

    enum Decision: Equatable {
        case wait
        case select(AudioMode)
        case fallbackInPlaceAndPinLegacy
        case closeConnectionAndPinLegacy
    }

    static let legacyFormat = "f32le"
    static let aacFormat = "aac-m4a"
    static let reservedPCM16Format = "pcm16"
    static let supportedSourceSampleRates = [16_000, 48_000]

    static func configMessage(sampleRate: Int) -> String? {
        guard supportedSourceSampleRates.contains(sampleRate) else { return nil }
        return "{\"type\":\"CONFIG\",\"format\":\"aac-m4a\","
            + "\"sampleRate\":\(sampleRate),\"channels\":1,"
            + "\"bitrate\":64000,\"protocol\":2}"
    }

    static func initialMode(aacEnabled: Bool) -> AudioMode? {
        aacEnabled ? nil : .float32PCM
    }

    static func shouldSendConfig(aacEnabled: Bool, sessionLegacyPinned: Bool) -> Bool {
        aacEnabled && !sessionLegacyPinned
    }

    static func timeoutDecision() -> Decision {
        .closeConnectionAndPinLegacy
    }

    static func decision(
        forServerMessage text: String,
        aacEnabled: Bool,
        deadlineExpired: Bool = false
    ) -> Decision {
        guard aacEnabled else { return .select(.float32PCM) }
        guard let data = text.data(using: .utf8),
              let message = try? JSONDecoder().decode(ServerMessage.self, from: data) else {
            return deadlineExpired ? .closeConnectionAndPinLegacy : .wait
        }

        if message.type == "error" {
            return .fallbackInPlaceAndPinLegacy
        }
        if deadlineExpired { return .closeConnectionAndPinLegacy }

        switch message.type {
        case "CONFIG_ACK":
            guard message.format == aacFormat,
                  message.protocolVersion == 2 else {
                return .wait
            }
            return .select(.aacM4A)
        default:
            return .wait
        }
    }

    private struct ServerMessage: Decodable {
        let type: String
        let format: String?
        let protocolVersion: Int?

        enum CodingKeys: String, CodingKey {
            case type
            case format
            case protocolVersion = "protocol"
        }
    }
}
