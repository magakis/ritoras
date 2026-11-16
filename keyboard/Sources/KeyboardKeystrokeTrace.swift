import Foundation

private final class KeystrokeTraceFlushScheduler: @unchecked Sendable {
    private let queue = DispatchQueue(
        label: "com.ritoras.keyboard-keystroke-trace.flush",
        qos: .utility
    )
    private let lock = NSLock()
    private var isScheduled = false
    private var followUpRequested = false

    func schedule(
        recorder: KeystrokeTraceRecorder,
        at boundary: KeystrokeTraceFlushBoundary,
        completion: @escaping (Result<KeystrokeTraceFlushResult, Error>) -> Void
    ) {
        lock.lock()
        guard !isScheduled else {
            followUpRequested = true
            lock.unlock()
            return
        }
        isScheduled = true
        lock.unlock()

        queue.async { [self, recorder] in
            var nextBoundary = boundary
            while true {
                let result: Result<KeystrokeTraceFlushResult, Error>
                do {
                    result = .success(try recorder.flush(at: nextBoundary))
                } catch {
                    result = .failure(error)
                }

                if case .failure = result {
                    lock.lock()
                    followUpRequested = false
                    isScheduled = false
                    lock.unlock()
                    completion(result)
                    return
                }

                completion(result)
                lock.lock()
                let shouldRepeat = followUpRequested
                followUpRequested = false
                if !shouldRepeat {
                    isScheduled = false
                }
                lock.unlock()
                guard shouldRepeat else { return }
                nextBoundary = .idle
            }
        }
    }

    func performSynchronously<T>(_ operation: () throws -> T) throws -> T {
        try queue.sync(execute: operation)
    }
}

final class KeyboardKeystrokeTrace {
    static let shared = KeyboardKeystrokeTrace()

    private enum CaptureError: Error {
        case documentsDirectoryUnavailable
        case eventExceedsRingCapacity(encodedByteCount: Int, capacity: Int)
    }

    private let flushScheduler = KeystrokeTraceFlushScheduler()
    private var recorder: KeystrokeTraceRecorder?
    private var idleFlushTimer: Timer?
    private var isCaptureActive = false
    private var didLogFailure = false
    private lazy var shipper = KeyboardKeystrokeTraceShipper(
        directoryURLProvider: { Self.documentsDirectoryURL }
    ) { [weak self] in
        guard let self else { return false }
        do {
            try self.clearLocalTraceData()
            return true
        } catch {
            return false
        }
    }

    private init() {}

    deinit {
        idleFlushTimer?.invalidate()
        isCaptureActive = false
        if let recorder {
            flushScheduler.schedule(recorder: recorder, at: .idle) { result in
                if case let .failure(error) = result {
                    Self.logCaptureFailure(error)
                }
            }
        }
        shipper.stop()
    }

    var isCapturing: Bool {
        isCaptureActive
    }

    /// Returns true only when this process creates its recorder.
    @discardableResult
    func startCapture() -> Bool {
        guard recorder == nil else {
            isCaptureActive = true
            startIdleFlushTimerIfNeeded()
            return false
        }

        do {
            guard let directoryURL = Self.documentsDirectoryURL else {
                throw CaptureError.documentsDirectoryUnavailable
            }

            let newRecorder = try KeystrokeTraceRecorder(directoryURL: directoryURL)
            newRecorder.prepareForCapture()
            newRecorder.onSegmentRoll = { roll in
                FileLogger.shared.info(.keyboard, "keystroke trace segment rolled", payload: [
                    "archivedBytes": roll.archivedBytes,
                    "discardedBytes": roll.discardedBytes,
                    "totalBytesAfterRoll": roll.totalBytesAfterRoll
                ])
            }
            recorder = newRecorder
            isCaptureActive = true
            startIdleFlushTimerIfNeeded()
            return true
        } catch {
            stopAfterFailure(error)
            return false
        }
    }

    func stopCapture() {
        idleFlushTimer?.invalidate()
        idleFlushTimer = nil
        isCaptureActive = false
        guard let recorder else { return }
        scheduleFlush(recorder, at: .idle)
    }

    func startShipping() {
        shipper.start()
    }

    func stopShipping() {
        shipper.stop()
    }

    func shipPending() {
        shipper.shipPending()
    }

    func append(
        _ event: KeystrokeTraceEvent,
        flushAt boundary: KeystrokeTraceFlushBoundary? = nil
    ) {
        guard isCaptureActive, let recorder else { return }

        do {
            let result = try recorder.append(event)
            switch result {
            case let .appended(_, _, shouldFlushAtHighWaterMark):
                if shouldFlushAtHighWaterMark {
                    scheduleFlush(recorder, at: .highWaterMark)
                }
            case let .eventExceedsRingCapacity(encodedByteCount, capacity):
                throw CaptureError.eventExceedsRingCapacity(
                    encodedByteCount: encodedByteCount,
                    capacity: capacity
                )
            }

            if let boundary {
                scheduleFlush(recorder, at: boundary)
            }
        } catch {
            stopAfterFailure(error)
        }
    }

    func flush(at boundary: KeystrokeTraceFlushBoundary) {
        guard let recorder else { return }
        scheduleFlush(recorder, at: boundary)
    }

    private static var documentsDirectoryURL: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
    }

    private func scheduleFlush(
        _ recorder: KeystrokeTraceRecorder,
        at boundary: KeystrokeTraceFlushBoundary
    ) {
        let shipper = self.shipper
        flushScheduler.schedule(recorder: recorder, at: boundary) { [weak self, shipper] result in
            switch result {
            case .success:
                shipper.shipPending()
            case let .failure(error):
                DispatchQueue.main.async {
                    guard let self else {
                        Self.logCaptureFailure(error)
                        return
                    }
                    self.stopAfterFailure(error)
                }
            }
        }
    }

    private func clearLocalTraceData() throws {
        if let recorder {
            try flushScheduler.performSynchronously {
                try recorder.clear()
            }
            return
        }
        guard let directoryURL = Self.documentsDirectoryURL else {
            throw CaptureError.documentsDirectoryUnavailable
        }
        let fileManager = FileManager.default
        for name in [
            KeystrokeTraceSchema.liveFileName,
            KeystrokeTraceSchema.rotatedFileName
        ] {
            let url = directoryURL.appendingPathComponent(name)
            if fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }
        }
    }

    private func startIdleFlushTimerIfNeeded() {
        guard isCaptureActive, idleFlushTimer == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            self?.flush(at: .idle)
        }
        RunLoop.main.add(timer, forMode: .common)
        idleFlushTimer = timer
    }

    private func stopAfterFailure(_ error: Error) {
        idleFlushTimer?.invalidate()
        idleFlushTimer = nil
        isCaptureActive = false
        recorder = nil

        guard !didLogFailure else { return }
        didLogFailure = true
        Self.logCaptureFailure(error)
    }

    private static func logCaptureFailure(_ error: Error) {
        FileLogger.shared.warn(.keyboard, "keystroke trace capture stopped", payload: [
            "error": String(describing: error)
        ])
    }
}
