import SwiftUI
import UIKit

// MARK: - Level Filter

private enum LevelFilter: String, CaseIterable {
    case all = "All"
    case debug = "Debug"
    case info = "Info"
    case warn = "Warn"
    case error = "Error"

    var level: LogLevel? {
        switch self {
        case .all:   return nil
        case .debug: return .debug
        case .info:  return .info
        case .warn:  return .warn
        case .error: return .error
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

// MARK: - Shared Formatting

private enum DateFormat {
    static let today: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
    static let older: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d HH:mm"
        return f
    }()
    static let daySeparator: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMMM d, yyyy"
        return f
    }()
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

private func timeFormatted(_ date: Date?) -> String {
    guard let date = date else { return "" }
    if Calendar.current.isDateInToday(date) {
        return DateFormat.today.string(from: date)
    } else {
        return DateFormat.older.string(from: date)
    }
}

private func levelLabel(_ level: LogLevel?) -> String {
    switch level {
    case .debug: return "DEBUG"
    case .info:  return "INFO"
    case .warn:  return "WARN"
    case .error: return "ERROR"
    case nil:    return "     "
    }
}

private func valueColor(_ type: PayloadValue) -> Color {
    switch type {
    case .number: return Color(.systemBlue)
    case .bool:   return Color(.systemOrange)
    case .string: return .primary
    default:      return .secondary
    }
}

private func isDifferentDay(_ a: Date?, _ b: Date?) -> Bool {
    guard let a = a, let b = b else { return false }
    return !Calendar.current.isDate(a, inSameDayAs: b)
}

private func daySeparatorView(for date: Date) -> some View {
    Text("── \(DateFormat.daySeparator.string(from: date)) ──")
        .font(.system(.caption2, design: .monospaced))
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .center)
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
    @State private var editMode: EditMode = .inactive
    @State private var expandedKeys: Set<String> = []

    private var filteredLines: [LogLine] {
        lines.filter { line in
            // 1. Level filter
            if let level = selectedFilter.level,
               line.level != level {
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
            pathDisplay
            levelFilter
            componentTimeFilter
            if !selectedIDs.isEmpty || !expandedKeys.isEmpty {
                statusBanner
            }
            mainList
        }
        .navigationTitle("Debug Log")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .searchable(text: $searchText, prompt: "Search logs")
        .confirmationDialog("Clear crash reports?",
                            isPresented: $showClearCrashConfirmation,
                            titleVisibility: .visible) {
            clearCrashConfirmationButtons
        } message: {
            clearCrashConfirmationMessage
        }
        .onReceive(Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()) { _ in
            refreshGuard()
        }
        .onAppear(perform: refresh)
        .overlay(alignment: .bottom) {
            copiedOverlay
        }
    }

    // MARK: - View Components

    private var pathDisplay: some View {
        Text(FileLogger.fileURL()?.path ?? "log destination unavailable")
            .font(.system(.caption2, design: .monospaced))
            .foregroundColor(.secondary)
            .padding(.horizontal)
            .padding(.vertical, 4)
    }

    private var levelFilter: some View {
        Picker("Level", selection: $selectedFilter) {
            ForEach(LevelFilter.allCases, id: \.self) { filter in
                Text(filter.rawValue).tag(filter)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal)
        .padding(.bottom, 4)
    }

    private var componentTimeFilter: some View {
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
    }

    private var statusBanner: some View {
        Text(!selectedIDs.isEmpty ? "Selection active — refresh paused"
                                  : "Row expanded — refresh paused")
            .font(.caption2)
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 2)
            .background(Color.accentColor)
    }

    private var mainList: some View {
        List(selection: $selectedIDs) {
            crashReportsSection
            diagnosticsSection
            if filteredLines.isEmpty && diagnostics.isEmpty && crashReports.isEmpty {
                emptyStateRow
            } else {
                logLinesList
            }
        }
        .listStyle(.plain)
        .environment(\.editMode, $editMode)
    }

    private var crashReportsSection: some View {
        Group {
            if !crashReports.isEmpty {
                Section {
                    ForEach(crashReports) { report in
                        crashReportRow(report)
                    }
                } header: {
                    crashReportsHeader
                } footer: {
                    crashReportsFooter
                }
            }
        }
    }

    private func crashReportRow(_ report: MetricReport) -> some View {
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

    private var crashReportsHeader: some View {
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
    }

    private var crashReportsFooter: some View {
        Text("Reports arrive ~24 hours after a crash. Tap a report to view details.")
            .font(.caption2)
            .foregroundColor(.secondary)
    }

    private var diagnosticsSection: some View {
        Group {
            if !diagnostics.isEmpty {
                Section {
                    ForEach(diagnostics.indices, id: \.self) { i in
                        Text(diagnostics[i])
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundColor(Color(.systemOrange))
                            .listRowBackground(Color.orange.opacity(0.08))
                    }
                } header: {
                    Text("Diagnostics")
                }
            }
        }
    }

    private var emptyStateRow: some View {
        Text("No log entries yet")
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity)
            .listRowBackground(Color.clear)
    }

    private var logLinesList: some View {
        ForEach(Array(filteredLines.enumerated()), id: \.element.id) { idx, line in
            if idx > 0, isDifferentDay(filteredLines[idx-1].timestamp, line.timestamp) {
                if let ts = line.timestamp {
                    daySeparatorView(for: ts)
                        .listRowSeparator(.hidden)
                }
            }
            logLineRow(line)
        }
    }

    private func logLineRow(_ line: LogLine) -> some View {
        LogRow(
            line: line,
            isExpanded: expandedKeys.contains(line.raw),
            isSelected: selectedIDs.contains(line.id),
            scrubPII: scrubPII,
            onToggle: { toggleExpand(line.raw) }
        )
        .listRowBackground(
            selectedIDs.contains(line.id) ? Color.accentColor.opacity(0.2) : Color.clear
        )
        .tag(line.id)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigationBarLeading) {
            if !crashReports.isEmpty {
                Button(action: { showClearCrashConfirmation = true }) {
                    Image(systemName: "trash")
                }
            }
        }
        ToolbarItem(placement: .navigationBarLeading) {
            editModeButton
        }
        ToolbarItem(placement: .navigationBarTrailing) {
            scrubPIIButton
        }
        ToolbarItem(placement: .navigationBarTrailing) {
            shareButton
        }
        ToolbarItem(placement: .navigationBarTrailing) {
            copyButton
        }
        ToolbarItem(placement: .navigationBarTrailing) {
            refreshButton
        }
        ToolbarItem(placement: .navigationBarTrailing) {
            clearButton
        }
    }

    private var editModeButton: some View {
        Button {
            withAnimation { editMode = (editMode == .active ? .inactive : .active) }
            if editMode == .inactive { selectedIDs.removeAll() }
        } label: {
            Image(systemName: editMode == .active ? "checkmark.circle.fill" : "checklist")
        }
    }

    private var scrubPIIButton: some View {
        Button(action: { scrubPII.toggle() }) {
            Image(systemName: scrubPII ? "person.crop.circle" : "person.crop.circle.badge.exclamationmark")
        }
    }

    private var shareButton: some View {
        let rawText = selectedOrFilteredLines.map(\.raw).joined(separator: "\n")
        let shareText = scrubPII ? LogScrubber.scrub(rawText) : rawText
        return ShareLink(item: shareText) {
            Image(systemName: "square.and.arrow.up")
        }
    }

    private var copyButton: some View {
        Button(action: copySelectedOrFiltered) {
            Image(systemName: "doc.on.doc")
        }
    }

    private var refreshButton: some View {
        Button(action: refresh) {
            Image(systemName: "arrow.clockwise")
        }
    }

    private var clearButton: some View {
        Button(action: clear) {
            Image(systemName: "trash")
        }
    }

    private var clearCrashConfirmationButtons: some View {
        Group {
            Button("Clear All", role: .destructive) {
                MetricKitSubscriber.clear()
                crashReports = []
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var clearCrashConfirmationMessage: some View {
        Text("This deletes all stored MetricKit crash reports. They cannot be recovered.")
    }

    @ViewBuilder
    private var copiedOverlay: some View {
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

    // MARK: - Actions

    private func refreshGuard() {
        guard selectedIDs.isEmpty, expandedKeys.isEmpty else { return }
        refresh()
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

    private func toggleExpand(_ key: String) {
        guard editMode == .inactive else { return }
        withAnimation(.easeInOut(duration: 0.15)) {
            if expandedKeys.contains(key) { expandedKeys.remove(key) }
            else { expandedKeys.insert(key) }
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

// MARK: - Log Row

private struct LogRow: View {
    let line: LogLine
    let isExpanded: Bool
    let isSelected: Bool
    let scrubPII: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(timeFormatted(line.timestamp))
                        .frame(width: 96, alignment: .leading)
                        .foregroundStyle(.secondary)
                        .fixedSize()
                    Text(levelLabel(line.level))
                        .frame(width: 48, alignment: .leading)
                        .foregroundStyle(color(for: line.level))
                        .fontWeight(.semibold)
                        .fixedSize()
                    Text((line.component?.rawValue ?? "—").padding(toLength: 13, withPad: " ", startingAt: 0))
                        .frame(width: 110, alignment: .leading)
                        .foregroundStyle(.secondary.opacity(0.8))
                        .fixedSize()
                    Text(line.message ?? line.raw)
                        .font(.system(.caption2, design: .monospaced, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .textSelection(.enabled)
                    Spacer(minLength: 4)
                    Text(isExpanded ? "⌄" : "›")
                        .foregroundStyle(.secondary)
                }
                if isExpanded {
                    expandedContent
                }
            }
            .contentShape(Rectangle())
            .font(.system(.caption2, design: .monospaced))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var expandedContent: some View {
        if let payloadLines = PayloadFormatter.render(line.payload, scrubPII: scrubPII) {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(payloadLines) { pl in
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(pl.key).foregroundStyle(.secondary).textSelection(.enabled)
                        Text(pl.value).foregroundStyle(valueColor(pl.valueType)).textSelection(.enabled)
                    }
                    .padding(.leading, 156)
                }
            }
            .padding(.top, 2)
        } else {
            Text(line.raw)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.leading, 156)
                .textSelection(.enabled)
        }
    }
}
