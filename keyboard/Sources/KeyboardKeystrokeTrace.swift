import Foundation

final class KeyboardKeystrokeTrace {
    private enum CaptureError: Error {
        case documentsDirectoryUnavailable
        case eventExceedsRingCapacity(encodedByteCount: Int, capacity: Int)
    }

    private static let enabledDefaultsKey = "ritoras_keystroke_trace_enabled"
    private static let enabledAtDefaultsKey = "ritoras_keystroke_trace_enabled_at"
    private static let toggleEpochDefaultsKey = "ritoras_keystroke_trace_toggle_epoch"

    struct DiagnosticState {
        let toggleRawValue: String
        let enabledAt: Date?
        let toggleEpoch: UInt64
        let recorderEnabled: Bool
        let recorderFailed: Bool
        let recorderFailure: String?
        let pendingRingBytes: Int
        let directoryURL: URL?
        let shipper: KeyboardKeystrokeTraceShipper.DiagnosticSnapshot
    }

    private var recorder: KeystrokeTraceRecorder?
    private var idleFlushTimer: Timer?
    private var didLogFailure = false
    private var lastFailureDescription: String?
    private var lastFailurePendingRingBytes = 0
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

    deinit {
        idleFlushTimer?.invalidate()
        shipper.stop()
    }

    var isEnabled: Bool {
        recorder?.isEnabled == true
    }

    private var isConfiguredEnabled: Bool {
        UserDefaults.standard.bool(forKey: Self.enabledDefaultsKey)
    }

    func refreshConfiguration() {
        if isConfiguredEnabled {
            do {
                if recorder == nil {
                    guard let directoryURL = Self.documentsDirectoryURL else {
                        throw CaptureError.documentsDirectoryUnavailable
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

    @discardableResult
    func toggleEnabledPreference() -> Bool {
        let shouldEnable = !isConfiguredEnabled
        if !shouldEnable, recorder?.isEnabled == true {
            flush(at: .idle)
        }
        let defaults = UserDefaults.standard
        let previousEpoch = (defaults.object(forKey: Self.toggleEpochDefaultsKey) as? NSNumber)?
            .uint64Value ?? 0
        defaults.set(previousEpoch &+ 1, forKey: Self.toggleEpochDefaultsKey)
        defaults.set(shouldEnable, forKey: Self.enabledDefaultsKey)
        if shouldEnable {
            defaults.set(Date(), forKey: Self.enabledAtDefaultsKey)
        }
        return shouldEnable
    }

    func diagnosticState() -> DiagnosticState {
        let defaults = UserDefaults.standard
        let toggleRawValue = defaults.object(forKey: Self.enabledDefaultsKey) == nil
            ? "unset (effective false)"
            : String(defaults.bool(forKey: Self.enabledDefaultsKey))
        return DiagnosticState(
            toggleRawValue: toggleRawValue,
            enabledAt: defaults.object(forKey: Self.enabledAtDefaultsKey) as? Date,
            toggleEpoch: (defaults.object(forKey: Self.toggleEpochDefaultsKey) as? NSNumber)?
                .uint64Value ?? 0,
            recorderEnabled: recorder?.isEnabled == true,
            recorderFailed: didLogFailure,
            recorderFailure: lastFailureDescription,
            pendingRingBytes: recorder?.unflushedByteCount ?? lastFailurePendingRingBytes,
            directoryURL: Self.documentsDirectoryURL,
            shipper: shipper.diagnosticSnapshot()
        )
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
                    shipper.shipPending()
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
            shipper.shipPending()
        } catch {
            stopAfterFailure(error)
        }
    }

    private static var documentsDirectoryURL: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
    }

    private func clearLocalTraceData() throws {
        if let recorder {
            try recorder.clear()
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
        lastFailurePendingRingBytes = recorder?.unflushedByteCount ?? 0
        lastFailureDescription = String(describing: error)
        recorder = nil

        guard !didLogFailure else { return }
        didLogFailure = true
        FileLogger.shared.warn(.keyboard, "keystroke trace capture stopped", payload: [
            "error": String(describing: error)
        ])
    }
}
