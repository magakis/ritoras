import Foundation

enum LogQueryEpochDecision {
    static func isCurrent(queryEpoch: UInt64, currentEpoch: UInt64) -> Bool {
        queryEpoch == currentEpoch
    }

    static func isSuperseded(queryEpoch: UInt64, currentEpoch: UInt64) -> Bool {
        !isCurrent(queryEpoch: queryEpoch, currentEpoch: currentEpoch)
    }
}

final class LogQueryHandle: @unchecked Sendable {
    let queryEpoch: UInt64 = 0

    private let lock = NSLock()
    private let onCancellation: @Sendable (Double) -> Void
    private var cancellationEpoch: UInt64 = 0
    private var cancellationStartedAt: UInt64?
    private var activeStepLoops = 0
    private var didEmitCancellation = false
    private var isFinished = false

    init(onCancellation: @escaping @Sendable (Double) -> Void) {
        self.onCancellation = onCancellation
    }

    var canRunQuery: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !isFinished
            && LogQueryEpochDecision.isCurrent(
                queryEpoch: queryEpoch,
                currentEpoch: cancellationEpoch
            )
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return LogQueryEpochDecision.isSuperseded(
            queryEpoch: queryEpoch,
            currentEpoch: cancellationEpoch
        )
    }

    func cancel() {
        let now = DispatchTime.now().uptimeNanoseconds
        var cancellationLatencyMilliseconds: Double?

        lock.lock()
        if cancellationStartedAt == nil {
            cancellationEpoch &+= 1
            cancellationStartedAt = now
            if activeStepLoops == 0 {
                didEmitCancellation = true
                cancellationLatencyMilliseconds = 0
            }
        }
        lock.unlock()

        if let cancellationLatencyMilliseconds {
            onCancellation(cancellationLatencyMilliseconds)
        }
    }

    func finish() {
        lock.lock()
        isFinished = true
        lock.unlock()
    }

    func beginStepLoop() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isFinished,
              LogQueryEpochDecision.isCurrent(
                queryEpoch: queryEpoch,
                currentEpoch: cancellationEpoch
              ) else {
            return false
        }
        activeStepLoops += 1
        return true
    }

    var shouldInterrupt: Bool {
        isCancelled
    }

    func endStepLoop() {
        let now = DispatchTime.now().uptimeNanoseconds
        var cancellationLatencyMilliseconds: Double?

        lock.lock()
        activeStepLoops -= 1
        if activeStepLoops == 0,
           !didEmitCancellation,
           let cancellationStartedAt {
            didEmitCancellation = true
            cancellationLatencyMilliseconds = Double(now - cancellationStartedAt) / 1_000_000
        }
        lock.unlock()

        if let cancellationLatencyMilliseconds {
            onCancellation(cancellationLatencyMilliseconds)
        }
    }
}
