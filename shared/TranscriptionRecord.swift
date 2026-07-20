import Foundation

/// Represents the lifecycle status of a transcription job.
///
/// The state machine transitions are:
///   requested → recording → uploaded → transcribing → ready | failed | cancelled
///
/// Terminal states (ready, failed, cancelled) are eligible for consumption by
/// both the keyboard extension and the container app. Non-terminal states
/// (requested, recording, uploaded, transcribing) represent in-flight work.
public enum TranscriptionStatus: String, Codable, CaseIterable {
    case requested
    case recording
    case uploaded
    case transcribing
    case ready
    case failed
    case cancelled

    public var isTerminal: Bool {
        switch self {
        case .ready, .failed, .cancelled: return true
        case .requested, .recording, .uploaded, .transcribing: return false
        }
    }

    public var isInFlight: Bool { !isTerminal }
}

/// A single transcription job record persisted in the inbox directory.
///
/// Each record is identified by a UUID `jobId` and carries a monotonically
/// increasing `revision` for high-water-mark stale detection. Only terminal
/// records are eligible for consumption (see `TranscriptionStatus.isTerminal`).
///
/// - NOTE: This record is read and written by both the keyboard extension and
///   the container app via the shared app-group container. All mutations use
///   atomic file writes (`Data.write(to:options:.atomic)`) to prevent partial
///   reads across processes. Consumers track consumption via separate marker
///   files, not by mutating this struct.
public struct TranscriptionRecord: Codable, Equatable {
    public let jobId: UUID
    public var revision: Int
    public var status: TranscriptionStatus
    public var text: String?
    public var errorMessage: String?
    public let createdAt: Date
    public var updatedAt: Date
    public var completedAt: Date?

    public init(
        jobId: UUID,
        revision: Int,
        status: TranscriptionStatus,
        text: String?,
        errorMessage: String?,
        createdAt: Date,
        updatedAt: Date,
        completedAt: Date?
    ) {
        self.jobId = jobId
        self.revision = revision
        self.status = status
        self.text = text
        self.errorMessage = errorMessage
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.completedAt = completedAt
    }
}
