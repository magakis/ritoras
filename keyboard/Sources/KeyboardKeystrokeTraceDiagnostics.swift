import Foundation
import UIKit

enum KeyboardKeystrokeTraceDiagnostics {
    private enum ClipboardWriteError: Error {
        case pasteboardDidNotChange
    }

    private static let header = "=== RITORAS KEYBOARD DIAGNOSTICS ==="

    static func copyToClipboard(_ snapshot: String) throws {
        let pasteboard = UIPasteboard.general
        let previousChangeCount = pasteboard.changeCount
        pasteboard.string = snapshot
        guard pasteboard.changeCount != previousChangeCount else {
            throw ClipboardWriteError.pasteboardDidNotChange
        }
    }

    static func makeSnapshot(
        trace: KeyboardKeystrokeTrace,
        hasFullAccess: Bool
    ) -> String {
        let now = ISO8601DateFormatter()
        now.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let state = trace.diagnosticState()
        let store = localStoreSummary(directoryURL: state.directoryURL)
        let shipper = state.shipper
        let cursorOffsets = shipper.cursorOffsets.isEmpty
            ? "none"
            : shipper.cursorOffsets.keys.sorted().map {
                "\($0)=\(shipper.cursorOffsets[$0] ?? 0)"
            }.joined(separator: ", ")
        let attemptAt = shipper.lastAttemptAt.map { now.string(from: $0) } ?? "none"
        let enabledAt = state.enabledAt.map { now.string(from: $0) } ?? "not tracked"
        let lastError = shipper.lastUploadErrorKind ?? "none"
        let httpStatus = shipper.lastUploadHTTPStatus.map { String($0) } ?? "none"
        let originalGroupId = SharedConfig.Defaults.originalAppGroupId
        let originalContainer = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: originalGroupId
        )
        let resolvedGroupId = SharedConfig.Defaults.appGroupId
        let resolvedContainer = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: resolvedGroupId
        )
        let suiteWritable = probeSuiteWritability(groupId: resolvedGroupId)
        let bundle = Bundle.main
        let version = bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = bundle.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
        let failure = state.recorderFailure.map(oneLine) ?? "none"

        return [
            header,
            "Snapshot time: \(now.string(from: Date()))",
            "",
            "Tracing:",
            "  Toggle raw value: \(state.toggleRawValue)",
            "  Enable timestamp: \(enabledAt)",
            "  Toggle epoch: \(state.toggleEpoch)",
            "",
            "Recorder:",
            "  Enabled: \(state.recorderEnabled)",
            "  Failure recorded: \(state.recorderFailed)",
            "  Last failure: \(failure)",
            "  Pending ring bytes: \(state.pendingRingBytes)",
            "",
            "Local store:",
            "  Documents trace directory: \(store.directoryPath)",
            "  \(KeystrokeTraceSchema.rotatedFileName): \(store.rotatedSize)",
            "  \(KeystrokeTraceSchema.liveFileName): \(store.liveSize)",
            "  Total bytes: \(store.totalSize)",
            "",
            "Shipper:",
            "  Cadence timer running: \(shipper.timerRunning)",
            "  Upload attempts: \(shipper.uploadAttemptCount)",
            "  Request in flight: \(shipper.requestInFlight)",
            "  Cursor epoch: \(shipper.cursorEpoch)",
            "  Cursor offsets (segment identity=byte offset): \(cursorOffsets)",
            "  Last upload error kind: \(lastError)",
            "  Last HTTP status: \(httpStatus)",
            "  Last attempt: \(attemptAt)",
            "",
            "Keyboard environment:",
            "  Original app-group id: \(originalGroupId)",
            "  Original app-group container: \(originalContainer?.path ?? "nil")",
            "  Resolved app-group id: \(resolvedGroupId)",
            "  Resolved container available: \(AppGroupResolver.shared.containerAvailable)",
            "  Resolved app-group container: \(resolvedContainer?.path ?? "nil")",
            "  App-group suite writable: \(suiteWritable)",
            "  Full Access: \(hasFullAccess)",
            "  OS: \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "  Bundle: \(bundle.bundleIdentifier ?? "unknown")",
            "  Version/build: \(version) (\(build))"
        ].joined(separator: "\n")
    }

    private static func localStoreSummary(directoryURL: URL?) -> (
        directoryPath: String,
        rotatedSize: String,
        liveSize: String,
        totalSize: String
    ) {
        guard let directoryURL else {
            return ("unavailable", "unavailable", "unavailable", "unavailable")
        }

        let rotatedSize = fileSize(
            at: directoryURL.appendingPathComponent(KeystrokeTraceSchema.rotatedFileName)
        )
        let liveSize = fileSize(
            at: directoryURL.appendingPathComponent(KeystrokeTraceSchema.liveFileName)
        )
        guard let rotatedBytes = rotatedSize.bytes,
              let liveBytes = liveSize.bytes else {
            return (
                directoryURL.path,
                rotatedSize.description,
                liveSize.description,
                "unavailable"
            )
        }
        return (
            directoryURL.path,
            rotatedSize.description,
            liveSize.description,
            String(rotatedBytes + liveBytes)
        )
    }

    private static func fileSize(at url: URL) -> (bytes: UInt64?, description: String) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return (0, "0 (missing)")
        }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber else {
            return (nil, "unavailable")
        }
        return (size.uint64Value, String(size.uint64Value))
    }

    private static func probeSuiteWritability(groupId: String) -> Bool {
        guard let defaults = UserDefaults(suiteName: groupId) else { return false }
        let key = "ritoras_trace_diagnostics_probe.\(UUID().uuidString)"
        let value = UUID().uuidString
        defaults.set(value, forKey: key)
        let isWritable = defaults.string(forKey: key) == value
        defaults.removeObject(forKey: key)
        return isWritable
    }

    private static func oneLine(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
    }
}
