import SwiftUI
import UIKit

struct RecoveryView: View {
    @EnvironmentObject private var dictationViewModel: DictationViewModel
    @State private var records: [FailedJobRecord] = []
    @State private var retryingJobIds: Set<UUID> = []
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            Group {
                if records.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "checkmark.circle")
                            .font(.system(size: 48))
                            .foregroundColor(.green)
                        Text("No failed transcriptions")
                            .font(.headline)
                            .foregroundColor(.secondary)
                    }
                } else {
                    List {
                        ForEach(records, id: \.jobId) { record in
                            RecoveryRow(
                                record: record,
                                isRetrying: retryingJobIds.contains(record.jobId),
                                onRetry: { startRetry(jobId: record.jobId) },
                                onDelete: { deleteRecord(jobId: record.jobId) }
                            )
                        }
                    }
                }
            }
            .navigationTitle("Failed Transcriptions")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear(perform: refreshRecords)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done") { dismiss() }
                }
                if !records.isEmpty {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("Clear All") {
                            for record in records {
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
    }

    // MARK: - Actions

    private func refreshRecords() {
        records = FailedJobStore.shared.list()
    }

    private func startRetry(jobId: UUID) {
        guard !retryingJobIds.contains(jobId) else { return }
        retryingJobIds.insert(jobId)

        Task {
            await dictationViewModel.retry(jobId: jobId)
            await MainActor.run {
                retryingJobIds.remove(jobId)
                refreshRecords()
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
                Button("Retry", action: onRetry)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                Button("Delete", action: onDelete)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(.red)
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

    private func formatDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
