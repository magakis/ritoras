import Foundation

/// Buffers log entries from the keyboard's FileLogger.broadcast hook and ships
/// them to the container app's LocalhostServer every 2 seconds (and immediately
/// on .warn/.error entries). Best-effort: drops entries on connection failure,
/// caps buffer at 100 entries to bound memory.
final class KeyboardLogShipper {
    static let shared = KeyboardLogShipper()
    private init() {}

    private let queue = DispatchQueue(label: "com.ritoras.log-shipper")
    private var buffer: [LogShipmentEntry] = []
    private let maxBuffer = 100
    private var timer: DispatchSourceTimer?

    func start() {
        queue.async {
            guard self.timer == nil else { return }
            let t = DispatchSource.makeTimerSource(queue: self.queue)
            t.schedule(deadline: .now() + 2.0, repeating: 2.0, leeway: .seconds(1))
            t.setEventHandler { [weak self] in self?.flush() }
            t.resume()
            self.timer = t
        }
    }

    func stop() {
        queue.async {
            self.timer?.cancel()
            self.timer = nil
            self.flush()  // final flush
        }
    }

    /// Append a new entry. Called from FileLogger.broadcast (on FileLogger's queue).
    func append(_ entry: LogShipmentEntry) {
        queue.async {
            self.buffer.append(entry)
            if self.buffer.count > self.maxBuffer {
                self.buffer.removeFirst(self.buffer.count - self.maxBuffer)
            }
            // Immediate flush on warn/error (don't wait for timer)
            if entry.level == "warn" || entry.level == "error" {
                self.flush()
            }
        }
    }

    private func flush() {
        guard !buffer.isEmpty else { return }
        let batch = buffer
        buffer.removeAll()
        // Ship asynchronously — don't block the queue
        Task { await LocalhostClient.postLogs(batch) }
    }
}
