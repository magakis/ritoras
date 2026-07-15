import SwiftUI
import UIKit

struct HistoryView: View {
    @StateObject private var history = TranscriptionHistory.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            Group {
                if history.entries.isEmpty {
                    Text("No transcriptions yet")
                        .foregroundColor(.secondary)
                } else {
                    List {
                        ForEach(history.entries) { entry in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(entry.text)
                                    .font(.body)
                                Text(entry.timestamp, style: .date)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .contextMenu {
                                Button {
                                    UIPasteboard.general.string = entry.text
                                } label: {
                                    Label("Copy", systemImage: "doc.on.doc")
                                }
                            }
                        }
                        .onDelete(perform: history.delete)
                    }
                }
            }
            .navigationTitle("History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done") { dismiss() }
                }
                if !history.entries.isEmpty {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("Clear") {
                            history.clear()
                        }
                    }
                }
            }
        }
    }
}
