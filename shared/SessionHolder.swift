import Foundation

/// Thread-safe, resettable URLSession holder for WhisperClient.
/// Marked @unchecked Sendable because all access is serialized via internal NSLock.
///
/// **Swap-and-release design:** `reset()` creates a new URLSession and releases the old
/// one without calling `invalidateAndCancel` or `finishTasksAndInvalidate`. In-flight
/// tasks complete normally on the old session; new requests automatically use the new
/// session. This is the single most important correctness property — invalidating the
/// old session would abort active uploads/transcriptions.
///
/// **Debounce:** resets are coalesced with a 2-second window to absorb NWPathMonitor
/// flap storms during network transitions (e.g. VPN toggle, Wi-Fi ↔ cellular).
final class SessionHolder: @unchecked Sendable {
    static let shared = SessionHolder()

    private let lock = NSLock()
    private var session: URLSession
    private var resourceTimeoutSeconds: TimeInterval
    private var lastResetAt: Date = .distantPast

    private init() {
        let resourceTimeoutSeconds = SharedConfig.AsyncTranscription.totalDeadline
        self.resourceTimeoutSeconds = resourceTimeoutSeconds
        self.session = Self.makeSession(resourceTimeoutSeconds: resourceTimeoutSeconds)
    }

    private static func makeSession(resourceTimeoutSeconds: TimeInterval) -> URLSession {
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = SharedConfig.Defaults.timeoutSeconds
        config.timeoutIntervalForResource = resourceTimeoutSeconds
        config.httpShouldUsePipelining = false // HTTP/1 pipelining deprecated in Swift 6.1; causes multipart file-upload hangs
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }

    /// Returns a session whose resource timeout can accommodate the request.
    /// If needed, swaps in a longer-lived session without cancelling tasks on the old one.
    func get(minimumResourceTimeout: TimeInterval = SharedConfig.AsyncTranscription.totalDeadline) -> URLSession {
        lock.lock()
        let requiredResourceTimeout = max(
            SharedConfig.AsyncTranscription.totalDeadline,
            minimumResourceTimeout
        )
        guard requiredResourceTimeout > resourceTimeoutSeconds else {
            let currentSession = session
            lock.unlock()
            return currentSession
        }

        let newSession = Self.makeSession(resourceTimeoutSeconds: requiredResourceTimeout)
        let old = session
        session = newSession
        resourceTimeoutSeconds = requiredResourceTimeout
        lock.unlock()
        _ = old
        return newSession
    }

    /// Creates a new URLSession and swaps it in atomically. The old session is
    /// released without invalidation — in-flight tasks complete on the old session;
    /// new requests use the new session.
    ///
    /// Coalesces call storms with a 2-second debounce. Safe to call from any thread.
    func reset() {
        lock.lock()
        let now = Date()
        guard now.timeIntervalSince(lastResetAt) >= 2.0 else {
            lock.unlock()
            return
        }
        lastResetAt = now

        let resourceTimeoutSeconds = SharedConfig.AsyncTranscription.totalDeadline
        let newSession = Self.makeSession(resourceTimeoutSeconds: resourceTimeoutSeconds)

        let old = session
        session = newSession
        self.resourceTimeoutSeconds = resourceTimeoutSeconds
        lock.unlock()
        _ = old
        // old goes out of scope — URLSession retains itself while tasks are
        // outstanding, then deallocs when they drain. Do NOT call
        // invalidateAndCancel or finishTasksAndInvalidate.
    }
}
