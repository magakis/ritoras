import Foundation

/// Shared `/trace` route and payload-size limit for keyboard uploads and the
/// container app receiver.
public enum KeystrokeTraceWireContract {
    public static let route = "/trace"
    // Leaves 4 KiB for HTTP framing inside the server's unchanged 64 KiB cap.
    public static let maximumRequestBodyBytes = 60 * 1024

    static func encode(_ request: KeystrokeTraceUploadRequest) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return try encoder.encode(request)
    }
}

/// One line-aligned NDJSON chunk and the local segment position it came from.
///
/// `payload` is encoded as base64 by `JSONEncoder`. Its decoded bytes always
/// begin and end on LF boundaries, so the app can append them without rewriting
/// the schema-v1 records. `offset` is the byte offset of the first payload byte
/// in `segmentIdentity`; the server must reject a request whose epoch is stale.
public struct KeystrokeTraceUploadRequest: Codable, Equatable, Sendable {
    public let segmentName: String
    public let segmentIdentity: String
    public let offset: UInt64
    public let epoch: UInt64
    public let payload: Data

    public init(
        segmentName: String,
        segmentIdentity: String,
        offset: UInt64,
        epoch: UInt64,
        payload: Data
    ) {
        self.segmentName = segmentName
        self.segmentIdentity = segmentIdentity
        self.offset = offset
        self.epoch = epoch
        self.payload = payload
    }
}

/// Acknowledgment and delete-coordination epoch returned by `POST /trace`.
///
/// `acknowledged` is true only when the payload was appended or content-hash
/// deduplicated. The keyboard advances its cursor only when this is true and
/// the returned epoch still matches the request epoch. The response epoch is
/// always the server's current value; a stale request is rejected without
/// appending its payload.
public struct KeystrokeTraceUploadResponse: Codable, Equatable, Sendable {
    public let acknowledged: Bool
    public let epoch: UInt64

    public init(acknowledged: Bool, epoch: UInt64) {
        self.acknowledged = acknowledged
        self.epoch = epoch
    }
}

enum KeystrokeTraceUploadError: Error {
    case requestBodyTooLarge(Int)
    case invalidResponse
    case httpStatus(Int)
}
