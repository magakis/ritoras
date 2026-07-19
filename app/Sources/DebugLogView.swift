import SwiftUI
import UIKit

struct DebugLogView: View {
    @State private var logContents: String = ""
    @State private var showShareSheet = false

    var body: some View {
        Group {
            if logContents.isEmpty {
                Text("No log entries yet")
                    .foregroundColor(.secondary)
            } else {
                TextEditor(text: .constant(logContents))
                    .font(.caption)
                    .disableAutocorrection(true)
                    .textSelection(.enabled)
            }
        }
        .navigationTitle("Debug Log")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(action: { showShareSheet = true }) {
                    Image(systemName: "square.and.arrow.up")
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(action: refresh) {
                    Image(systemName: "arrow.clockwise")
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(action: clear) {
                    Image(systemName: "trash")
                }
            }
        }
        .onAppear(perform: refresh)
        .sheet(isPresented: $showShareSheet) {
            if let url = FileLogger.fileURL() {
                ActivityViewController(activityItems: [url])
            }
        }
    }

    private func refresh() {
        logContents = FileLogger.contents() ?? ""
    }

    private func clear() {
        FileLogger.clear()
        refresh()
    }
}

// MARK: - Share Sheet

private struct ActivityViewController: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
