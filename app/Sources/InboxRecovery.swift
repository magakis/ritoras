import Foundation

@MainActor
final class InboxRecovery {
    static let shared = InboxRecovery()

    private let inbox = TranscriptionInbox(consumer: .containerApp)
    private var watcher: InboxWatcher?

    private init() {}

    /// Called on app launch and on scenePhase=.active.
    /// Scans the inbox for terminal records not yet consumed by the container app,
    /// adds their text to TranscriptionHistory, and marks them consumed.
    func recoverMissedTranscriptions() {
        // 1. Mark stale in-flight records as failed (app killed mid-transcription)
        do {
            try inbox.markStale(olderThan: SharedConfig.Inbox.staleRecordTTL)
        } catch {
            FileLogger.shared.error(.app, "InboxRecovery: markStale failed: \(error)")
        }

        // 2. Bound archive size on every recovery
        do {
            try inbox.gcArchive(keepingLast: SharedConfig.Inbox.archiveRetentionCount)
        } catch {
            FileLogger.shared.error(.app, "InboxRecovery: gcArchive failed: \(error)")
        }

        // 3. Read unconsumed terminal records
        let unconsumed = inbox.listUnconsumed()
        guard !unconsumed.isEmpty else { return }

        FileLogger.shared.info(.app, "InboxRecovery: found unconsumed records", payload: [
            "count": unconsumed.count
        ])

        // 4. For each: add text to history (if any), mark consumed, archive if both done
        for record in unconsumed {
            if record.status == .ready, let text = record.text, !text.isEmpty {
                TranscriptionHistory.shared.add(text: text)
                FileLogger.shared.info(.app, "InboxRecovery: recovered transcription", payload: [
                    "jobId": record.jobId.uuidString,
                    "textLength": text.count
                ])
            } else if record.status == .failed {
                FileLogger.shared.info(.app, "InboxRecovery: consuming failed record", payload: [
                    "jobId": record.jobId.uuidString,
                    "errorMessage": record.errorMessage ?? "unknown"
                ])
            }

            do {
                try inbox.markConsumed(jobId: record.jobId)
                try inbox.archiveIfBothConsumed(jobId: record.jobId)
            } catch {
                FileLogger.shared.error(.app, "InboxRecovery: mark/archive failed for \(record.jobId): \(error)")
            }
        }
    }

    /// Start watching the inbox directory for live updates while the app is foregrounded.
    func startWatching() {
        guard watcher == nil else { return }
        watcher = InboxWatcher(directoryURL: inbox.inboxDirectoryURL) { [weak self] in
            // InboxWatcher fires on a background serial queue. Hop to main actor.
            Task { @MainActor in
                self?.recoverMissedTranscriptions()
            }
        }
        watcher?.start()
        FileLogger.shared.info(.app, "InboxRecovery: watcher started")
    }

    /// Stop watching when the app backgrounds.
    func stopWatching() {
        watcher?.stop()
        watcher = nil
    }
}
