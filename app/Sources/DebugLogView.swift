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

// MARK: - Component Filter

private enum ComponentFilter: String, CaseIterable {
    case all = "All"
    case keyboard = "Keyboard"
    case app = "ContainerApp"
    case transcription = "Transcription"
    case audio = "Audio"
    case dictionary = "Dictionary"
    case network = "Network"
    case settings = "Settings"
    case lifecycle = "Lifecycle"

    var logComponent: LogComponent? {
        switch self {
        case .all:           return nil
        case .keyboard:      return .keyboard
        case .app:           return .app
        case .transcription: return .transcription
        case .audio:         return .audio
        case .dictionary:    return .dictionary
        case .network:       return .network
        case .settings:      return .settings
        case .lifecycle:     return .lifecycle
        }
    }
}

// MARK: - Time Range Filter

private enum TimeRangeFilter: String, CaseIterable {
    case fiveMin = "5m"
    case oneHour = "1h"
    case all = "All"
}

// MARK: - Debug Log View

struct DebugLogView: View {
    @State private var lines: [LogLine] = []
    @State private var diagnostics: [String] = []
    @State private var selectedIDs: Set<Int> = []
    @State private var selectedFilter: LevelFilter = .all
    @State private var componentFilter: ComponentFilter = .all
    @State private var searchText: String = ""
    @State private var timeRange: TimeRangeFilter = .all
    @State private var showCopiedConfirmation = false
    @State private var scrubPII = true
    @State private var crashReports: [MetricReport] = []
    @State private var showClearCrashConfirmation = false
    @State private var expandedReportID: Int? = nil

    private var filteredLines: [LogLine] {
        lines.filter { line in
            // 1. Level filter
            if let token = selectedFilter.levelToken,
               !line.raw.contains(" \(token) ") {
                return false
            }

            // 2. Component filter
            if let comp = componentFilter.logComponent,
               line.component != comp {
                return false
            }

            // 3. Search text (case-insensitive substring)
            if !searchText.isEmpty,
               !line.raw.localizedCaseInsensitiveContains(searchText) {
                return false
            }

            // 4. Time range
            switch timeRange {
            case .fiveMin:
                guard let ts = line.timestamp else { return false }
                guard ts > Date().addingTimeInterval(-300) else { return false }
            case .oneHour:
                guard let ts = line.timestamp else { return false }
                guard ts > Date().addingTimeInterval(-3600) else { return false }
            case .all:
                break
            }

            return true
        }
    }

    private var selectedOrFilteredLines: [LogLine] {
        selectedIDs.isEmpty ? filteredLines : filteredLines.filter { selectedIDs.contains($0.id) }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Path display
            Text(FileLogger.fileURL()?.path ?? "log destination unavailable")
                .font(.system(.caption2, design: .monospaced))
                .foregroundColor(.secondary)
                .padding(.horizontal)
                .padding(.vertical, 4)

            // Level filter
            Picker("Level", selection: $selectedFilter) {
                ForEach(LevelFilter.allCases, id: \.self) { filter in
                    Text(filter.rawValue).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.bottom, 4)

            // Component + Time range filters
            HStack(spacing: 8) {
                Picker("Component", selection: $componentFilter) {
                    ForEach(ComponentFilter.allCases, id: \.self) { filter in
                        Text(filter.rawValue).tag(filter)
                    }
                }
                .pickerStyle(.menu)

                Picker("Time", selection: $timeRange) {
                    ForEach(TimeRangeFilter.allCases, id: \.self) { filter in
                        Text(filter.rawValue).tag(filter)
                    }
                }
                .pickerStyle(.segmented)

                Text(scrubPII ? "PII scrubbed" : "PII: OFF")
                    .font(.caption2)
                    .foregroundColor(scrubPII ? .green : .orange)
            }
            .padding(.horizontal)
            .padding(.bottom, 4)

            // Selection hint
            if !selectedIDs.isEmpty {
                Text("Selection active — refresh paused")
                    .font(.caption2)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 2)
                    .background(Color.accentColor)
            }

            // Main list with multi-select
            List(selection: $selectedIDs) {
                // ── Crash Reports ──────────────────────────────────
                if !crashReports.isEmpty {
                    Section {
                        ForEach(crashReports) { report in
                            DisclosureGroup(
                                isExpanded: Binding(
                                    get: { expandedReportID == report.id },
                                    set: { expandedReportID = $0 ? report.id : nil }
                                )
                            ) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Raw Payload")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    ScrollView(.horizontal) {
                                        Text(LogScrubber.scrub(report.rawJSON))
                                            .font(.system(.caption2, design: .monospaced))
                                            .foregroundColor(.secondary)
                                            .textSelection(.enabled)
                                    }
                                    .frame(maxHeight: 200)
                                }
                                .padding(.leading, 4)
                            } label: {
                                HStack(spacing: 8) {
                                    Text(report.kind)
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundColor(.white)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(kindColor(report.kind))
                                        .clipShape(Capsule())

                                    Text(LogScrubber.scrub(report.summary))
                                        .font(.caption)
                                        .lineLimit(1)

                                    Spacer()

                                    Text(report.timestamp, style: .date)
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                            }
                            .listRowBackground(Color.clear)
                        }
                    } header: {
                        HStack {
                            Text("Crash Reports")
                            Spacer()
                            Text("\(crashReports.count)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.secondary.opacity(0.15))
                                .clipShape(Capsule())
                        }
                    } footer: {
                        Text("Reports arrive ~24 hours after a crash. Tap a report to view details.")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }

                // ── Diagnostics ────────────────────────────────────
                if !diagnostics.isEmpty {
                    Section {
                        ForEach(diagnostics.indices, id: \.self) { i in
                            Text(diagnostics[i])
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundColor(Color(.systemOrange))
                        }
                    } header: {
                        Text("Diagnostics")
                    }
                }

                // ── Log Lines ──────────────────────────────────────
                if filteredLines.isEmpty && diagnostics.isEmpty && crashReports.isEmpty {
                    Text("No log entries yet")
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)
                } else {
                    ForEach(filteredLines) { line in
                        Text(line.raw)
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(color(for: line.level))
                            .listRowBackground(selectedIDs.contains(line.id) ? Color.accentColor.opacity(0.2) : Color.clear)
                            .tag(line.id)
                    }
                }
            }
            .listStyle(.plain)
            .environment(\.editMode, .constant(.active))
        }
        .navigationTitle("Debug Log")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                if !crashReports.isEmpty {
                    Button(action: { showClearCrashConfirmation = true }) {
                        Image(systemName: "trash")
                    }
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(action: { scrubPII.toggle() }) {
                    Image(systemName: scrubPII ? "person.crop.circle" : "person.crop.circle.badge.exclamationmark")
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                let rawText = selectedOrFilteredLines.map(\.raw).joined(separator: "\n")
                let shareText = scrubPII ? LogScrubber.scrub(rawText) : rawText
                ShareLink(item: shareText) {
                    Image(systemName: "square.and.arrow.up")
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(action: copySelectedOrFiltered) {
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
        .searchable(text: $searchText, prompt: "Search logs")
        .confirmationDialog("Clear crash reports?",
                            isPresented: $showClearCrashConfirmation,
                            titleVisibility: .visible) {
            Button("Clear All", role: .destructive) {
                MetricKitSubscriber.clear()
                crashReports = []
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deletes all stored MetricKit crash reports. They cannot be recovered.")
        }
        .onReceive(Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()) { _ in
            guard selectedIDs.isEmpty else { return }
            refresh()
        }
        .onAppear(perform: refresh)
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
        lines = FileLogger.parsedLinesAllFiles()
        diagnostics = FileLogger.shared.recentDiagnostics()
        crashReports = MetricKitSubscriber.loadReports()
    }

    private func clear() {
        FileLogger.clear()
        refresh()
    }

    private func copySelectedOrFiltered() {
        var text = selectedOrFilteredLines.map(\.raw).joined(separator: "\n")
        if scrubPII {
            text = LogScrubber.scrub(text)
        }
        UIPasteboard.general.string = text
        withAnimation { showCopiedConfirmation = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation { showCopiedConfirmation = false }
        }
    }

    // MARK: - Crash Reports

    private func kindColor(_ kind: String) -> Color {
        switch kind {
        case "crash": return .red
        case "hang":  return .orange
        default:      return .secondary
        }
    }
}
