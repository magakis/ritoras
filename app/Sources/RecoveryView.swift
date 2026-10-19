import SwiftUI
import UIKit

struct RecoveryView: View {
    @EnvironmentObject private var dictationViewModel: DictationViewModel
    @State private var records: [RecoveryRecord] = []
    @State private var retryingJobIds: Set<UUID> = []
    @State private var toastMessage: String?
    @State private var toastIsError = false
    @State private var resultText: String?
    @State private var showResult = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            Group {
                if records.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "checkmark.circle")
                            .font(.system(size: 48))
                            .foregroundColor(.green)
                        Text("No transcriptions to recover")
                            .font(.headline)
                            .foregroundColor(.secondary)
                    }
                } else {
                    List {
                        ForEach(records, id: \.jobId) { record in
                            RecoveryRow(
                                record: record.failedRecord,
                                pendingState: record.pendingState,
                                isRetrying: retryingJobIds.contains(record.jobId),
                                onRetry: { startRetry(jobId: record.jobId) },
                                onDelete: { deleteRecord(jobId: record.jobId) }
                            )
                        }
                    }
                }
            }
            .navigationTitle("Transcription Recovery")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear(perform: refreshRecords)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done") { dismiss() }
                }
                if !records.isEmpty {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("Clear Failed") {
                            for record in records where record.pendingState == nil {
                                FailedJobStore.shared.remove(jobId: record.jobId)
                                RecordingStore.shared.delete(jobId: record.jobId)
                            }
                            refreshRecords()
                        }
                        .disabled(!retryingJobIds.isEmpty)
                    }
                }
            }
        }
        .overlay(alignment: .bottom) {
            if let toast = toastMessage {
                Text(toast)
                    .padding()
                    .background(toastIsError ? Color.red.opacity(0.8) : Color.green.opacity(0.8))
                    .foregroundColor(.white)
                    .cornerRadius(8)
                    .padding(.bottom, 20)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .sheet(isPresented: $showResult) {
            if let text = resultText {
                TranscriptionResultView(text: text) {
                    showResult = false
                    resultText = nil
                }
            }
        }
    }

    // MARK: - Actions

    private func refreshRecords() {
        let failed = FailedJobStore.shared.list()
        let failedByID = Dictionary(uniqueKeysWithValues: failed.map { ($0.jobId, $0) })
        let pending = FailedJobStore.shared.listPending()
        let pendingByID = Dictionary(uniqueKeysWithValues: pending.map { ($0.jobId, $0) })
        let visibleIDs = PendingJobRecoveryRules.visibleRecoveryIDs(
            failedIDs: failed.map(\.jobId), pendingIDs: pending.map(\.jobId))
        records = visibleIDs.compactMap { id in
            if let item = pendingByID[id] {
                return RecoveryRecord(
                    failedRecord: failedByID[id] ?? FailedJobRecord(
                        jobId: item.jobId,
                        audioFilePath: item.audioFilePath,
                        errorMessage: Self.pendingMessage(for: item.state),
                        recordedDurationSeconds: 0,
                        createdAt: item.createdAt,
                        retryCount: 0,
                        lastRetriedAt: nil,
                        server: item.resolvedServer ?? item.candidateServer),
                    pendingState: item.state)
            }
            guard let failedRecord = failedByID[id] else { return nil }
            return RecoveryRecord(failedRecord: failedRecord, pendingState: nil)
        }
        FileLogger.shared.debug(.app, "RecoveryView loaded", payload: ["recordCount": records.count])
    }

    private static func pendingMessage(for state: PendingJobState) -> String {
        switch state {
        case .recorded: return "Audio saved; transcription has not started."
        case .submitting: return "Checking whether the server accepted this transcription."
        case .accepted: return "The server accepted this transcription; its result is being checked."
        case .syncFallback: return "A synchronous transcription may still be completing."
        case .ready: return "Transcription is ready; restoring its saved result."
        case .failed: return "Transcription failed; saved audio is available for retry."
        }
    }

    private func startRetry(jobId: UUID) {
        guard !retryingJobIds.contains(jobId) else { return }
        retryingJobIds.insert(jobId)

        Task {
            let text = await dictationViewModel.retry(jobId: jobId)
            await MainActor.run {
                retryingJobIds.remove(jobId)
                if let text = text {
                    resultText = text
                    showResult = true
                } else {
                    toastMessage = "Retry failed — see updated error below"
                    toastIsError = true
                }
                refreshRecords()
                Task {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    await MainActor.run { toastMessage = nil }
                }
            }
        }
    }

    private func deleteRecord(jobId: UUID) {
        FailedJobStore.shared.remove(jobId: jobId)
        RecordingStore.shared.delete(jobId: jobId)
        refreshRecords()
    }
}

// MARK: - Recovery Row

private struct RecoveryRow: View {
    let record: FailedJobRecord
    let pendingState: PendingJobState?
    let isRetrying: Bool
    let onRetry: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(durationLabel)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(record.errorMessage)
                    .font(.body)
                    .lineLimit(2)
                if let pendingState {
                    Text("Status: \(pendingState.label)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                HStack(spacing: 4) {
                    if record.retryCount > 0 {
                        Label("Auto-retried \(record.retryCount)×", systemImage: "arrow.triangle.2.circlepath")
                            .font(.caption2)
                            .foregroundColor(.orange)
                    }
                    Text(formatDate(record.createdAt))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            if isRetrying {
                ProgressView()
                    .progressViewStyle(.circular)
            } else {
                Button(retryButtonTitle, action: onRetry)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                if pendingState == nil {
                    Button("Delete", action: onDelete)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(.red)
                }
            }
        }
        .padding(.vertical, 4)
        .opacity(isRetrying ? 0.6 : 1)
    }

    private var durationLabel: String {
        let mins = Int(record.recordedDurationSeconds) / 60
        let secs = Int(record.recordedDurationSeconds) % 60
        if mins > 0 {
            return "\(mins)m \(secs)s recorded"
        }
        return "\(secs)s recorded"
    }

    private var retryButtonTitle: String {
        switch pendingState {
        case .submitting, .accepted, .syncFallback, .ready:
            return "Check Status"
        case .recorded, .failed, nil:
            return "Retry"
        }
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

private extension PendingJobState {
    var label: String {
        switch self {
        case .recorded: return "saved, not submitted"
        case .submitting: return "checking submission"
        case .accepted: return "accepted by server"
        case .syncFallback: return "synchronous fallback may be running"
        case .ready: return "result ready"
        case .failed: return "failed"
        }
    }
}

private struct RecoveryRecord {
    let failedRecord: FailedJobRecord
    let pendingState: PendingJobState?

    var jobId: UUID { failedRecord.jobId }
}
