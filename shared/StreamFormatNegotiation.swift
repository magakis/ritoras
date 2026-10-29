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

    static func configMessage(
        sampleRate: Int,
        aacEnabled: Bool,
        cleanupPreferences: LLMCleanupPreferences
    ) -> String? {
        if aacEnabled, !supportedSourceSampleRates.contains(sampleRate) {
            return nil
        }

        var message = "{\"type\":\"CONFIG\",\"format\":\""
        message += (aacEnabled ? aacFormat : legacyFormat)
        message += "\""
        if aacEnabled {
            message += ",\"sampleRate\":\(sampleRate),\"channels\":1,"
                + "\"bitrate\":64000"
        }
        message += ",\"protocol\":2"
        cleanupPreferences.forEachWireField { field, value in
            message += ",\"\(field)\":\"\(value)\""
        }
        return message + "}"
    }

    static func initialMode(configSent: Bool) -> AudioMode? {
        configSent ? nil : .float32PCM
    }

    static func shouldSendConfig(
        aacEnabled: Bool,
        sessionLegacyPinned: Bool,
        cleanupPreferences: LLMCleanupPreferences
    ) -> Bool {
        guard !sessionLegacyPinned else { return false }
        return aacEnabled || hasSelectedCleanupPreferences(cleanupPreferences)
    }

    static func timeoutDecision() -> Decision {
        .closeConnectionAndPinLegacy
    }

    static func decision(
        forServerMessage text: String,
        aacEnabled: Bool,
        deadlineExpired: Bool = false
    ) -> Decision {
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
            let requestedFormat = aacEnabled ? aacFormat : legacyFormat
            guard message.format == requestedFormat,
                  message.protocolVersion == 2 else {
                return .wait
            }
            return .select(aacEnabled ? .aacM4A : .float32PCM)
        default:
            return .wait
        }
    }

    private static func hasSelectedCleanupPreferences(
        _ preferences: LLMCleanupPreferences
    ) -> Bool {
        var hasSelectedValue = false
        preferences.forEachWireField { _, _ in
            hasSelectedValue = true
        }
        return hasSelectedValue
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
