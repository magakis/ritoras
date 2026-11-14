import Foundation

final class KeyboardKeystrokeTrace {
    private enum CaptureError: Error {
        case appGroupContainerUnavailable
        case eventExceedsRingCapacity(encodedByteCount: Int, capacity: Int)
    }

    private var recorder: KeystrokeTraceRecorder?
    private var idleFlushTimer: Timer?
    private var didLogFailure = false

    deinit {
        idleFlushTimer?.invalidate()
    }

    var isEnabled: Bool {
        recorder?.isEnabled == true
    }

    func refreshConfiguration() {
        if SharedConfig.keystrokeTraceEnabled() {
            do {
                if recorder == nil {
                    guard let directoryURL = FileManager.default.containerURL(
                        forSecurityApplicationGroupIdentifier: SharedConfig.Defaults.appGroupId
                    ) else {
                        throw CaptureError.appGroupContainerUnavailable
                    }

                    let newRecorder = try KeystrokeTraceRecorder(directoryURL: directoryURL)
                    newRecorder.onSegmentRoll = { roll in
                        FileLogger.shared.info(.keyboard, "keystroke trace segment rolled", payload: [
                            "archivedBytes": roll.archivedBytes,
                            "discardedBytes": roll.discardedBytes,
                            "totalBytesAfterRoll": roll.totalBytesAfterRoll
                        ])
                    }
                    recorder = newRecorder
                }

                try recorder?.setEnabled(true)
                startIdleFlushTimerIfNeeded()
            } catch {
                stopAfterFailure(error)
            }
            return
        }

        guard let recorder, recorder.isEnabled else { return }
        idleFlushTimer?.invalidate()
        idleFlushTimer = nil
        do {
            try recorder.setEnabled(false)
        } catch {
            stopAfterFailure(error)
        }
    }

    func append(
        _ event: KeystrokeTraceEvent,
        flushAt boundary: KeystrokeTraceFlushBoundary? = nil
    ) {
        guard let recorder, recorder.isEnabled else { return }

        do {
            let result = try recorder.append(event)
            switch result {
            case .disabled:
                return
            case let .appended(_, _, shouldFlushAtHighWaterMark):
                if shouldFlushAtHighWaterMark {
                    refreshConfiguration()
                    guard let currentRecorder = self.recorder,
                          currentRecorder.isEnabled else { return }
                    try currentRecorder.flush(at: .highWaterMark)
                }
            case let .eventExceedsRingCapacity(encodedByteCount, capacity):
                throw CaptureError.eventExceedsRingCapacity(
                    encodedByteCount: encodedByteCount,
                    capacity: capacity
                )
            }

            if let boundary {
                flush(at: boundary)
            }
        } catch {
            stopAfterFailure(error)
        }
    }

    func flush(at boundary: KeystrokeTraceFlushBoundary) {
        refreshConfiguration()
        guard let recorder, recorder.isEnabled else { return }

        do {
            try recorder.flush(at: boundary)
        } catch {
            stopAfterFailure(error)
        }
    }

    private func startIdleFlushTimerIfNeeded() {
        guard idleFlushTimer == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            self?.flush(at: .idle)
        }
        RunLoop.main.add(timer, forMode: .common)
        idleFlushTimer = timer
    }

    private func stopAfterFailure(_ error: Error) {
        idleFlushTimer?.invalidate()
        idleFlushTimer = nil
        recorder = nil

        guard !didLogFailure else { return }
        didLogFailure = true
        FileLogger.shared.warn(.keyboard, "keystroke trace capture stopped", payload: [
            "error": String(describing: error)
        ])
    }
}
