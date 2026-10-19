import Foundation

enum BackgroundUploadTerminal: Equatable, Sendable {
    case accepted(jobID: String, statusEndpoint: String)
    case transportFailure(reason: String)
    case httpFailure(status: Int)
    case malformedResponse
    case responseTooLarge
}

enum BackgroundUploadRules {
    enum HTTPFailureMapping: Equatable {
        case unauthorized
        case asyncUnsupported
        case httpError(Int)
    }
    static let maximumResponseBytes = 64 * 1024
    static let serverTTL: TimeInterval = 600
    static let idempotencyTTL: TimeInterval = 600
    static let terminalWaiterTimeout: TimeInterval = 600

    enum TerminalPersistenceDecision: Equatable, Sendable {
        case publishDurableTerminal
        case retainUnknownAndWakeWaiter
    }

    enum WaiterState: Equatable, Sendable {
        case pendingRegistration
        case waiting
        case terminal
        case timedOut
        case cancelled
        case replaced
    }

    enum WaiterEvent: Sendable {
        case register
        case terminal
        case timeout
        case cancel
        case replace
    }

    static func terminalPersistenceDecision(didPersist: Bool) -> TerminalPersistenceDecision {
        didPersist ? .publishDurableTerminal : .retainUnknownAndWakeWaiter
    }

    static func shouldRecordTerminal(existingTerminal: Bool) -> Bool {
        !existingTerminal
    }

    static func shouldNotifyDurableUpdate(didPersist: Bool, existingTerminal: Bool) -> Bool {
        didPersist && !existingTerminal
    }

    static func mapHTTPFailure(_ status: Int) -> HTTPFailureMapping {
        switch status {
        case 401: return .unauthorized
        case 404: return .asyncUnsupported
        default: return .httpError(status)
        }
    }

    static func transitionWaiter(_ state: WaiterState, on event: WaiterEvent) -> WaiterState {
        switch (state, event) {
        case (.pendingRegistration, .register):
            return .waiting
        case (.pendingRegistration, .cancel), (.waiting, .cancel):
            return .cancelled
        case (.waiting, .terminal):
            return .terminal
        case (.waiting, .timeout):
            return .timedOut
        case (.waiting, .replace):
            return .replaced
        default:
            return state
        }
    }

    static func isWithinIdempotencyTTL(submittedAt: Date, now: Date) -> Bool {
        now.timeIntervalSince(submittedAt) <= idempotencyTTL
    }

    struct PendingSnapshot: Equatable {
        let id: UUID
        let audioFilePath: String
        let createdAt: Date
        let submittedAt: Date?
        let acceptedAt: Date?
        let terminalAt: Date?
        let state: PendingJobState
    }

    struct DurableTerminal: Equatable {
        let id: UUID
        let terminal: BackgroundUploadTerminal
        let recordedAt: Date
        let notifiedAt: Date?
    }

    enum ReconcileDecision: Equatable {
        case awaitTerminal(id: UUID)
        case keepDurable(id: UUID, terminal: BackgroundUploadTerminal)
        case notifyWaiter(id: UUID, terminal: BackgroundUploadTerminal)
        case routeSavedAudioRetry(id: UUID, reason: String)
        case dropExpired(id: UUID, audioFilePath: String)
        case retainUnknown(id: UUID)
    }

    static func classifyResponse(status: Int, body: Data) -> BackgroundUploadTerminal {
        guard body.count <= maximumResponseBytes else { return .responseTooLarge }
        guard status == 202 else { return .httpFailure(status: status) }
        guard
            let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
            let jobID = object["job_id"] as? String, !jobID.isEmpty,
            let endpoint = object["status_endpoint"] as? String, !endpoint.isEmpty
        else { return .malformedResponse }
        return .accepted(jobID: jobID, statusEndpoint: endpoint)
    }

    static func classifyTransportFailure(_ reason: String) -> BackgroundUploadTerminal {
        .transportFailure(reason: reason)
    }

    static func reconcile(
        pendingRecords: [PendingSnapshot],
        liveTaskIDs: Set<UUID>,
        durableTerminals: [DurableTerminal],
        waiterIDs: Set<UUID>,
        status404IDs: Set<UUID>,
        now: Date
    ) -> [ReconcileDecision] {
        let terminalsByID = Dictionary(durableTerminals.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        return pendingRecords.map { record in
            if liveTaskIDs.contains(record.id) { return .awaitTerminal(id: record.id) }
            if let durable = terminalsByID[record.id] {
                switch durable.terminal {
                case .accepted:
                    return waiterIDs.contains(record.id) && durable.notifiedAt == nil
                        ? .notifyWaiter(id: record.id, terminal: durable.terminal)
                        : .keepDurable(id: record.id, terminal: durable.terminal)
                case .transportFailure, .httpFailure, .malformedResponse, .responseTooLarge:
                    return .routeSavedAudioRetry(id: record.id, reason: "terminal upload failure")
                }
            }
            if status404IDs.contains(record.id), let submittedAt = record.submittedAt,
               now.timeIntervalSince(submittedAt) > serverTTL {
                return .routeSavedAudioRetry(id: record.id, reason: "404 after server TTL")
            }
            // A missing task or uncertain response is not evidence that POST is safe to repeat.
            return .retainUnknown(id: record.id)
        }
    }
}
