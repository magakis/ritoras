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
    // Reserve 4 KiB for HTTP framing under the server's 64 KiB request cap.
    private let maximumRequestBodyBytes = 60 * 1024
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
        let chunks = makeChunks(from: batch)
        guard !chunks.isEmpty else { return }
        // Ship asynchronously — don't block the queue
        Task {
            for chunk in chunks {
                await LocalhostClient.postLogs(chunk)
            }
        }
    }

    private func makeChunks(from entries: [LogShipmentEntry]) -> [[LogShipmentEntry]] {
        var chunks: [[LogShipmentEntry]] = []
        var currentChunk: [LogShipmentEntry] = []

        for entry in entries {
            let candidate = currentChunk + [entry]
            if let bodyByteCount = requestBodyByteCount(for: candidate),
               bodyByteCount <= maximumRequestBodyBytes {
                currentChunk = candidate
                continue
            }

            if !currentChunk.isEmpty {
                chunks.append(currentChunk)
                currentChunk.removeAll(keepingCapacity: true)
            }

            // Drop entries we cannot size below budget rather than risk an oversized request.
            if let bodyByteCount = requestBodyByteCount(for: [entry]),
               bodyByteCount <= maximumRequestBodyBytes {
                currentChunk.append(entry)
            }
        }

        if !currentChunk.isEmpty {
            chunks.append(currentChunk)
        }
        return chunks
    }

    private func requestBodyByteCount(for entries: [LogShipmentEntry]) -> Int? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try? encoder.encode(["entries": entries]).count
    }
}
