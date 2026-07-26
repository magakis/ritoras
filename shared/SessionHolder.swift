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
    private var lastResetAt: Date = .distantPast

    private init() {
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = SharedConfig.Defaults.timeoutSeconds
        config.timeoutIntervalForResource = SharedConfig.Defaults.timeoutSeconds * 2
        config.httpShouldUsePipelining = true
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: config)
    }

    /// Returns the current active session.
    func get() -> URLSession {
        lock.lock(); defer { lock.unlock() }
        return session
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

        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = SharedConfig.Defaults.timeoutSeconds
        config.timeoutIntervalForResource = SharedConfig.Defaults.timeoutSeconds * 2
        config.httpShouldUsePipelining = true
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let newSession = URLSession(configuration: config)

        let old = session
        session = newSession
        lock.unlock()
        // old goes out of scope — URLSession retains itself while tasks are
        // outstanding, then deallocs when they drain. Do NOT call
        // invalidateAndCancel or finishTasksAndInvalidate.
    }
}
