import Foundation

/// Owns app-process background file uploads for asynchronous transcription.
final class BackgroundTranscriptionUploader: NSObject, URLSessionDataDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = BackgroundTranscriptionUploader()
    static let durableUpdateNotification = Notification.Name("RitorasBackgroundUploadDurableUpdate")

    static let backgroundSessionIdentifier = "com.ritoras.app.background-transcription-upload"
    private static let requestTimeout: TimeInterval = 600
    private static let resourceTimeout: TimeInterval = 600

    private struct TaskState {
        var statusCode: Int?
        var responseData = Data()
        var responseTooLarge = false
    }

    struct TaskSnapshot: Sendable {
        let taskIdentifier: Int
        let taskDescription: String?
    }

    private struct TerminalWaiter {
        let token: WaiterToken
        let continuation: CheckedContinuation<BackgroundUploadTerminal, Error>
        let timeout: DispatchWorkItem
    }

    private final class WaiterToken: @unchecked Sendable {
        private let lock = NSLock()
        private var state = BackgroundUploadRules.WaiterState.pendingRegistration

        func transition(on event: BackgroundUploadRules.WaiterEvent) -> BackgroundUploadRules.WaiterState {
            lock.lock(); defer { lock.unlock() }
            state = BackgroundUploadRules.transitionWaiter(state, on: event)
            return state
        }
    }

    private let stateQueue = DispatchQueue(label: "com.ritoras.background-transcription-uploader")
    private var taskStates: [Int: TaskState] = [:]
    private var waiters: [UUID: TerminalWaiter] = [:]
    private var onDurableUpdate: [UUID: @MainActor @Sendable (UUID, BackgroundUploadTerminal) -> Void] = [:]
    private var session: URLSession?
    private var backgroundEventsCompletionHandler: (@MainActor @Sendable () -> Void)?

    private override init() {
        super.init()
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.backgroundSessionIdentifier)
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        configuration.timeoutIntervalForRequest = Self.requestTimeout
        configuration.timeoutIntervalForResource = Self.resourceTimeout

        let delegateQueue = OperationQueue()
        delegateQueue.name = "com.ritoras.background-transcription-uploader.delegate"
        delegateQueue.maxConcurrentOperationCount = 1
        return URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)
    }

    /// Saves the app-delegate completion callback before restoring the session.
    func setBackgroundEventsCompletionHandler(_ handler: @escaping @MainActor @Sendable () -> Void) {
        stateQueue.sync { backgroundEventsCompletionHandler = handler }
    }

    /// Recreates the stable session and returns its current task mapping for reconciliation.
    func restore(completion: @escaping @MainActor @Sendable ([TaskSnapshot]) -> Void) {
        let restoredSession = stateQueue.sync { () -> URLSession in
            if let existingSession = self.session { return existingSession }
            let newSession = makeSession()
            self.session = newSession
            return newSession
        }
        restoredSession.getAllTasks { tasks in
            let snapshots = tasks.map {
                TaskSnapshot(taskIdentifier: $0.taskIdentifier, taskDescription: $0.taskDescription)
            }
            Task { @MainActor in completion(snapshots) }
        }
    }

    func liveUploadIDs() async -> Set<UUID> {
        await withCheckedContinuation { continuation in
            restore { snapshots in
                self.stateQueue.sync {}
                let ids = Set(snapshots.compactMap { snapshot -> UUID? in
                    guard let description = snapshot.taskDescription else { return nil }
                    return UUID(uuidString: description)
                })
                continuation.resume(returning: ids)
            }
        }
    }

    /// Reconnects the stable session before the app's pending-job recovery sweep.
    /// Live transfers and uncertain mappings are deliberately retained; startup
    /// must never infer that an absent task is safe to submit again.
    func reconcileStartupTasks() async {
        await withCheckedContinuation { continuation in
            restore { snapshots in
                // Drain delegate work already enqueued by restored-session callbacks
                // before allowing the ordinary pending-job recovery sweep to start.
                self.stateQueue.sync {}
                let liveIDs = Set(snapshots.compactMap { snapshot -> UUID? in
                    guard let description = snapshot.taskDescription else { return nil }
                    return UUID(uuidString: description)
                })
                let pendingRecords = FailedJobStore.shared.listPending()
                let knownIDs = Set(pendingRecords.map(\.jobId))
                let durableTerminalIDs = Set(pendingRecords.compactMap { pending -> UUID? in
                    Self.terminal(from: pending) == nil ? nil : pending.jobId
                })
                let unmatchedLiveIDs = liveIDs.subtracting(knownIDs)
                if !unmatchedLiveIDs.isEmpty {
                    FileLogger.shared.warn(.network, "background upload task has no pending record", payload: [
                        "count": unmatchedLiveIDs.count
                    ])
                }
                let missingUnresolvedIDs = knownIDs
                    .subtracting(liveIDs)
                    .subtracting(durableTerminalIDs)
                if !missingUnresolvedIDs.isEmpty {
                    FileLogger.shared.warn(.network, "background upload outcome remains unknown", payload: [
                        "count": missingUnresolvedIDs.count
                    ])
                }
                continuation.resume()
            }
        }
    }

    /// Writes and submits the background upload using the existing multipart format.
    /// The body and pending mapping are durable before the task is resumed.
    func submit(
        dictationID: UUID,
        server: URL,
        audioURL: URL,
        language: String? = nil,
        onDurableUpdate: (@MainActor @Sendable (UUID, BackgroundUploadTerminal) -> Void)? = nil
    ) throws {
        guard let directory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first?.appendingPathComponent("BackgroundUploads", isDirectory: true) else {
            throw BackgroundTranscriptionUploaderError.applicationSupportUnavailable
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let bodyURL = directory.appendingPathComponent("\(dictationID.uuidString)-\(UUID().uuidString).multipart")
        let boundary: String
        do {
            boundary = try WhisperClient.writeMultipartBody(
                audioFile: audioURL,
                destination: bodyURL,
                language: language
            )
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: bodyURL.path
            )
        } catch {
            try? FileManager.default.removeItem(at: bodyURL)
            throw error
        }
        let base = server.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let submitURL = URL(string: "\(base)/transcriptions") else {
            try? FileManager.default.removeItem(at: bodyURL)
            throw BackgroundTranscriptionUploaderError.invalidServerURL
        }
        var request = URLRequest(url: submitURL)
        request.httpMethod = "POST"
        request.timeoutInterval = Self.requestTimeout
        request.setValue(dictationID.uuidString.lowercased(), forHTTPHeaderField: "Idempotency-Key")
        WhisperClient.applyAuth(to: &request)
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        do {
            try stateQueue.sync {
                let store = FailedJobStore.shared
                guard let existing = store.listPending().first(where: { $0.jobId == dictationID }) else {
                    throw BackgroundTranscriptionUploaderError.pendingJobNotFound
                }
                guard existing.uploadTerminalKind == nil,
                      existing.uploadBodyFilePath == nil,
                      existing.state == .recorded else {
                    throw BackgroundTranscriptionUploaderError.uploadAlreadyExists
                }

                var pending = existing
                pending.candidateServer = server.absoluteString
                pending.resolvedServer = server.absoluteString
                pending.submittedAt = Date()
                pending.state = .submitting
                pending.uploadBodyFilePath = bodyURL.path
                guard store.updatePending(pending) else {
                    throw BackgroundTranscriptionUploaderError.pendingJobPersistenceFailed
                }

                let activeSession: URLSession
                if let existingSession = self.session {
                    activeSession = existingSession
                } else {
                    activeSession = makeSession()
                    self.session = activeSession
                }
                let task = activeSession.uploadTask(with: request, fromFile: bodyURL)
                task.taskDescription = dictationID.uuidString
                taskStates[task.taskIdentifier] = TaskState()
                if let onDurableUpdate {
                    self.onDurableUpdate[dictationID] = onDurableUpdate
                }
                task.resume()
            }
        } catch {
            try? FileManager.default.removeItem(at: bodyURL)
            throw error
        }
    }

    /// Waits at most ten minutes; timeout or cancellation detaches only this waiter.
    func terminal(for dictationID: UUID) async throws -> BackgroundUploadTerminal {
        let token = WaiterToken()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                stateQueue.async {
                    guard token.transition(on: .register) == .waiting else {
                        continuation.resume(throwing: BackgroundUploadWaitError.cancelled)
                        return
                    }

                    if let previous = self.waiters.removeValue(forKey: dictationID) {
                        previous.timeout.cancel()
                        Self.resolve(previous, event: .replace)
                    }

                    let store = FailedJobStore.shared
                    if let pending = store.listPending().first(where: { $0.jobId == dictationID }),
                        let terminal = Self.terminal(from: pending) {
                        if self.markNotified(pending),
                           let update = self.onDurableUpdate.removeValue(forKey: dictationID) {
                            Task { @MainActor in update(dictationID, terminal) }
                        }
                        Self.resolve(token: token, continuation: continuation, event: .terminal,
                                     result: .success(terminal))
                        return
                    }

                    let timeout = DispatchWorkItem { [weak self] in
                        self?.finishWaiter(dictationID, token: token, event: .timeout)
                    }
                    self.waiters[dictationID] = TerminalWaiter(
                        token: token,
                        continuation: continuation,
                        timeout: timeout
                    )
                    self.stateQueue.asyncAfter(
                        deadline: .now() + BackgroundUploadRules.terminalWaiterTimeout,
                        execute: timeout
                    )
                }
            }
        } onCancel: {
            guard token.transition(on: .cancel) == .cancelled else { return }
            self.stateQueue.async {
                self.finishWaiter(dictationID, token: token, event: .cancel)
            }
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        stateQueue.async {
            if let response = response as? HTTPURLResponse {
                self.taskStates[dataTask.taskIdentifier, default: TaskState()].statusCode = response.statusCode
            }
            completionHandler(.allow)
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        stateQueue.async {
            guard let handler = self.backgroundEventsCompletionHandler else { return }
            self.backgroundEventsCompletionHandler = nil
            Task { @MainActor in handler() }
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        stateQueue.async {
            var state = self.taskStates[dataTask.taskIdentifier] ?? TaskState()
            guard !state.responseTooLarge else { return }
            guard data.count <= BackgroundUploadRules.maximumResponseBytes - state.responseData.count else {
                state.responseTooLarge = true
                self.taskStates[dataTask.taskIdentifier] = state
                dataTask.cancel()
                return
            }
            state.responseData.append(data)
            self.taskStates[dataTask.taskIdentifier] = state
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        stateQueue.async {
            guard let idString = task.taskDescription, let id = UUID(uuidString: idString) else { return }
            let state = self.taskStates[task.taskIdentifier] ?? TaskState()
            let terminal: BackgroundUploadTerminal
            if state.responseTooLarge {
                terminal = .responseTooLarge
            } else if let error {
                terminal = .transportFailure(reason: error.localizedDescription)
            } else if let status = state.statusCode {
                terminal = BackgroundUploadRules.classifyResponse(status: status, body: state.responseData)
            } else {
                terminal = .transportFailure(reason: "Upload completed without an HTTP response")
            }
            if self.persistTerminal(terminal, for: id) {
                self.taskStates.removeValue(forKey: task.taskIdentifier)
            }
        }
    }

    @discardableResult
    private func persistTerminal(_ terminal: BackgroundUploadTerminal, for id: UUID) -> Bool {
        let store = FailedJobStore.shared
        guard var pending = store.listPending().first(where: { $0.jobId == id }) else { return false }
        let existingTerminal = Self.terminal(from: pending) != nil
        guard BackgroundUploadRules.shouldRecordTerminal(existingTerminal: existingTerminal) else {
            if let terminal = Self.terminal(from: pending),
               onDurableUpdate[id] != nil,
               markNotified(pending),
               let update = onDurableUpdate.removeValue(forKey: id) {
                Task { @MainActor in update(id, terminal) }
            }
            return true
        }
        switch terminal {
        case .accepted(let jobID, let statusEndpoint):
            pending.uploadTerminalKind = "accepted"
            pending.serverJobId = jobID
            pending.statusEndpoint = statusEndpoint
            pending.acceptedAt = Date()
            pending.state = .accepted
        case .transportFailure(let reason):
            pending.uploadTerminalKind = "transportFailure"
            pending.uploadTerminalReason = reason
            pending.state = .failed
            pending.terminalAt = Date()
        case .httpFailure(let status):
            pending.uploadTerminalKind = "httpFailure"
            pending.uploadTerminalStatus = status
            pending.state = .failed
            pending.terminalAt = Date()
        case .malformedResponse:
            pending.uploadTerminalKind = "malformedResponse"
            pending.state = .failed
            pending.terminalAt = Date()
        case .responseTooLarge:
            pending.uploadTerminalKind = "responseTooLarge"
            pending.state = .failed
            pending.terminalAt = Date()
        }
        pending.uploadTerminalRecordedAt = Date()
        let didPersist = store.updatePending(pending)
        guard BackgroundUploadRules.terminalPersistenceDecision(didPersist: didPersist)
            == .publishDurableTerminal else {
            FileLogger.shared.error(.network, "background upload terminal persistence failed", payload: [
                "jobId": id.uuidString
            ])
            if let waiter = waiters[id] {
                finishWaiter(
                    id,
                    token: waiter.token,
                    event: .terminal,
                    result: .failure(.persistenceFailure)
                )
            }
            return false
        }
        if let bodyPath = pending.uploadBodyFilePath {
            try? FileManager.default.removeItem(atPath: bodyPath)
        }
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: Self.durableUpdateNotification,
                object: id)
        }
        let waiter = waiters[id]
        let hasDurableUpdate = onDurableUpdate[id] != nil
        let notificationIsDurable = !(hasDurableUpdate || waiter != nil) || markNotified(pending)
        if notificationIsDurable,
           BackgroundUploadRules.shouldNotifyDurableUpdate(didPersist: didPersist, existingTerminal: existingTerminal),
           let update = onDurableUpdate.removeValue(forKey: id) {
            Task { @MainActor in update(id, terminal) }
        }
        if let waiter {
            waiters.removeValue(forKey: id)
            Self.resolve(waiter, event: .terminal, result: .success(terminal))
        }
        return true
    }

    private func finishWaiter(
        _ id: UUID,
        token: WaiterToken,
        event: BackgroundUploadRules.WaiterEvent,
        result: Result<BackgroundUploadTerminal, BackgroundUploadWaitError>? = nil
    ) {
        guard let waiter = waiters[id], waiter.token === token else { return }
        waiters.removeValue(forKey: id)
        waiter.timeout.cancel()
        Self.resolve(waiter, event: event, result: result)
    }

    private static func resolve(
        _ waiter: TerminalWaiter,
        event: BackgroundUploadRules.WaiterEvent,
        result: Result<BackgroundUploadTerminal, BackgroundUploadWaitError>? = nil
    ) {
        resolve(token: waiter.token, continuation: waiter.continuation, event: event, result: result)
    }

    private static func resolve(
        token: WaiterToken,
        continuation: CheckedContinuation<BackgroundUploadTerminal, Error>,
        event: BackgroundUploadRules.WaiterEvent,
        result: Result<BackgroundUploadTerminal, BackgroundUploadWaitError>? = nil
    ) {
        let state = token.transition(on: event)
        switch state {
        case .terminal:
            guard let result else {
                continuation.resume(throwing: BackgroundUploadWaitError.persistenceFailure)
                return
            }
            switch result {
            case .success(let terminal): continuation.resume(returning: terminal)
            case .failure(let error): continuation.resume(throwing: error)
            }
        case .timedOut:
            continuation.resume(throwing: BackgroundUploadWaitError.timedOut)
        case .cancelled:
            continuation.resume(throwing: BackgroundUploadWaitError.cancelled)
        case .replaced:
            continuation.resume(throwing: BackgroundUploadWaitError.replaced)
        case .pendingRegistration, .waiting:
            break
        }
    }

    @discardableResult
    private func markNotified(_ pending: PendingJobRecord) -> Bool {
        guard pending.uploadTerminalNotifiedAt == nil else { return true }
        var updated = pending
        updated.uploadTerminalNotifiedAt = Date()
        return FailedJobStore.shared.updatePending(updated)
    }

    private static func terminal(from pending: PendingJobRecord) -> BackgroundUploadTerminal? {
        switch pending.uploadTerminalKind {
        case "accepted":
            guard let jobID = pending.serverJobId, let endpoint = pending.statusEndpoint else { return nil }
            return .accepted(jobID: jobID, statusEndpoint: endpoint)
        case "transportFailure":
            return .transportFailure(reason: pending.uploadTerminalReason ?? "Background upload failed")
        case "httpFailure":
            return .httpFailure(status: pending.uploadTerminalStatus ?? 0)
        case "malformedResponse":
            return .malformedResponse
        case "responseTooLarge":
            return .responseTooLarge
        default:
            return nil
        }
    }
}

extension BackgroundTranscriptionUploader: WhisperBackgroundSubmitter {
    func submit(
        audioURL: URL,
        serverURL: String,
        jobId: UUID,
        language: String?,
        onDurableAcceptance: (@MainActor @Sendable (UUID, String, String) -> Void)?
    ) async throws -> AsyncSubmitResponse {
        guard let server = URL(string: serverURL) else {
            throw WhisperError.invalidURL
        }
        try submit(
            dictationID: jobId,
            server: server,
            audioURL: audioURL,
            language: language,
            onDurableUpdate: { id, terminal in
                guard case .accepted(let serverJobID, let endpoint) = terminal else { return }
                onDurableAcceptance?(id, serverJobID, endpoint)
            })
        switch try await terminal(for: jobId) {
        case .accepted(let serverJobID, let endpoint):
            return AsyncSubmitResponse(jobId: serverJobID, statusEndpoint: endpoint)
        case .httpFailure(let status) where BackgroundUploadRules.mapHTTPFailure(status) == .asyncUnsupported:
            throw WhisperError.asyncUnsupported
        case .httpFailure(let status) where BackgroundUploadRules.mapHTTPFailure(status) == .unauthorized:
            throw WhisperError.unauthorized
        case .httpFailure(let status):
            throw WhisperError.httpError(status, "Background upload rejected")
        case .transportFailure(let reason):
            throw WhisperError.jobFailed("Background upload failed: \(reason)")
        case .malformedResponse:
            throw WhisperError.jobFailed("Background upload returned an invalid acceptance response")
        case .responseTooLarge:
            throw WhisperError.jobFailed("Background upload response exceeded its size limit")
        }
    }
}

enum BackgroundUploadWaitError: Equatable, Sendable, LocalizedError {
    case timedOut
    case cancelled
    case replaced
    case persistenceFailure

    var errorDescription: String? {
        switch self {
        case .timedOut:
            return "The upload is still running; check the durable job status before retrying."
        case .cancelled:
            return "Waiting for the upload was cancelled; the background upload continues."
        case .replaced:
            return "This upload waiter was replaced by a newer waiter."
        case .persistenceFailure:
            return "The upload outcome could not be saved; its status is unknown and retry is unsafe."
        }
    }
}

private enum BackgroundTranscriptionUploaderError: Error {
    case applicationSupportUnavailable
    case invalidServerURL
    case pendingJobNotFound
    case pendingJobPersistenceFailed
    case uploadAlreadyExists
}
