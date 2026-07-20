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
    @State private var lines: [LogLine] = []
    @State private var diagnostics: [String] = []
    @State private var scrollAnchor: Int?
    @State private var showShareSheet = false
    @State private var selectedFilter: LevelFilter = .all
    @State private var showCopiedConfirmation = false

    private var filteredLines: [LogLine] {
        guard let token = selectedFilter.levelToken else { return lines }
        return lines.filter { $0.raw.contains(" \(token) ") }
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

            Text(FileLogger.fileURL()?.path ?? "log destination unavailable")
                .font(.system(.caption2, design: .monospaced))
                .foregroundColor(.secondary)
                .padding(.horizontal)
                .padding(.vertical, 4)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if !diagnostics.isEmpty {
                            ForEach(diagnostics.indices, id: \.self) { i in
                                Text(diagnostics[i])
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundColor(Color(.systemOrange))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 8).padding(.vertical, 2)
                            }
                            Divider().padding(.vertical, 4)
                        }
                        if filteredLines.isEmpty && diagnostics.isEmpty {
                            Text("No log entries yet")
                                .foregroundColor(.secondary)
                                .frame(maxWidth: .infinity)
                                .padding(.top, 40)
                        } else {
                            ForEach(filteredLines) { line in
                                Text(line.raw)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundColor(color(for: line.level))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 8).padding(.vertical, 1)
                                    .id(line.id)
                            }
                        }
                    }
                }
                .background(Color(.secondarySystemBackground))
                .onChange(of: scrollAnchor) { _, newValue in
                    guard let id = newValue else { return }
                    withAnimation { proxy.scrollTo(id, anchor: .bottom) }
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
        .onReceive(Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()) { _ in
            refresh()
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

    private func color(for level: LogLevel?) -> Color {
        switch level {
        case .debug: return .secondary
        case .info:  return Color(.systemGreen)
        case .warn:  return Color(.systemOrange)
        case .error: return Color(.systemRed)
        case nil:    return .primary
        }
    }

    private func refresh() {
        lines = FileLogger.parsedLines()
        diagnostics = FileLogger.shared.recentDiagnostics()
        if let last = filteredLines.last?.id { scrollAnchor = last }
    }

    private func clear() {
        FileLogger.clear()
        refresh()
    }

    private func copyAll() {
        UIPasteboard.general.string = filteredLines.map(\.raw).joined(separator: "\n")
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
