import SwiftUI
import UIKit

// MARK: - Level Filter

private enum LevelFilter: String, CaseIterable {
    case all = "All"
    case debug = "Debug"
    case info = "Info"
    case warn = "Warn"
    case error = "Error"

    var levelToken: String? {
        switch self {
        case .all:   return nil
        case .debug: return "[DEBUG]"
        case .info:  return "[INFO]"
        case .warn:  return "[WARN]"
        case .error: return "[ERROR]"
        }
    }
}

struct DebugLogView: View {
    @State private var logContents: String = ""
    @State private var showShareSheet = false
    @State private var selectedFilter: LevelFilter = .all
    @State private var showCopiedConfirmation = false

    private var filteredContents: String {
        guard let token = selectedFilter.levelToken else { return logContents }
        return logContents
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { $0.contains(" \(token) ") }
            .joined(separator: "\n")
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Level", selection: $selectedFilter) {
                ForEach(LevelFilter.allCases, id: \.self) { filter in
                    Text(filter.rawValue).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 8)

            Group {
                if filteredContents.isEmpty {
                    Text("No log entries yet")
                        .foregroundColor(.secondary)
                } else {
                    TextEditor(text: .constant(filteredContents))
                        .font(.caption)
                        .disableAutocorrection(true)
                        .textSelection(.enabled)
                }
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
                Button(action: copyAll) {
                    Image(systemName: "doc.on.doc")
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
        .overlay(alignment: .bottom) {
            if showCopiedConfirmation {
                Text("Copied")
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color.secondary.opacity(0.9))
                    .foregroundColor(.white)
                    .clipShape(Capsule())
                    .padding(.bottom, 24)
                    .transition(.opacity)
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

    private func copyAll() {
        UIPasteboard.general.string = filteredContents
        withAnimation { showCopiedConfirmation = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation { showCopiedConfirmation = false }
        }
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
