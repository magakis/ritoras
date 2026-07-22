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

// MARK: - Delete Action

private enum DeleteAction {
    case visible
    case olderThan1Day
    case olderThan1Week
    case olderThan1Month
    case all
}

// MARK: - Shared Formatting

private enum DateFormat {
    static let today: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
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
    @State private var oldestLoadedId: Int64? = nil
    @State private var newestSeenId: Int64? = nil
    @State private var totalCount: Int = 0
    @State private var showDeleteConfirmation = false
    @State private var pendingDeleteAction: DeleteAction?
    @State private var pendingDeleteCount: Int = 0
    @State private var showDeleteFeedback = false
    @State private var deleteFeedbackText: String = ""
    @State private var deleteFeedbackIsError = false
    @State private var missedUpdates = false
    private let pageSize = 200

    private var selectedOrFilteredLines: [LogLine] {
        selectedIDs.isEmpty ? lines : lines.filter { selectedIDs.contains($0.id) }
    }

    var body: some View {
        VStack(spacing: 0) {
            levelFilter
            componentTimeFilter
            searchField
            if !selectedIDs.isEmpty || !expandedKeys.isEmpty {
                statusBanner
            }
            mainList
        }
        .navigationTitle("Debug Log")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .confirmationDialog("Clear crash reports?",
                            isPresented: $showClearCrashConfirmation,
                            titleVisibility: .visible) {
            clearCrashConfirmationButtons
        } message: {
            clearCrashConfirmationMessage
        }
        .confirmationDialog("Delete Logs",
                            isPresented: $showDeleteConfirmation,
                            titleVisibility: .visible) {
            if let action = pendingDeleteAction {
                Button("Delete", role: .destructive) {
                    executeDelete(action)
                }
                Button("Cancel", role: .cancel) {}
            }
        } message: {
            if let action = pendingDeleteAction {
                Text(deleteConfirmationMessage(for: action))
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .logStoreDidChange)) { _ in
            refreshGuard()
        }
        .onChange(of: searchText) { _, _ in refresh() }
        .onChange(of: selectedFilter) { _, _ in refresh() }
        .onChange(of: componentFilter) { _, _ in refresh() }
        .onChange(of: timeRange) { _, _ in refresh() }
        .onChange(of: expandedKeys) { _, newKeys in
            if newKeys.isEmpty { refreshGuard() }
        }
        .onChange(of: selectedIDs) { _, newIDs in
            if newIDs.isEmpty { refreshGuard() }
        }
        .onChange(of: expandedReportID) { _, newValue in
            if newValue == nil { refreshGuard() }
        }
        .onAppear(perform: refresh)
        .overlay(alignment: .bottom) {
            if showCopiedConfirmation {
                copiedOverlay
            } else if showDeleteFeedback {
                deleteFeedbackOverlay
            }
        }
    }

    // MARK: - View Components

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

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
            TextField("Search logs", text: $searchText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal)
        .padding(.vertical, 4)
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
            if lines.isEmpty && diagnostics.isEmpty && crashReports.isEmpty {
                emptyStateRow
            } else {
                logLinesList
                if lines.count < totalCount {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .listRowSeparator(.hidden)
                        .onAppear { loadMore() }
                }
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
                HStack {
                    Text("Raw Payload")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Button {
                        copyCrashReport(report)
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    ShareLink(item: scrubPII ? LogScrubber.scrub(report.rawJSON) : report.rawJSON) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                }
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
        ForEach(Array(lines.enumerated()), id: \.element.id) { idx, line in
            if idx > 0, isDifferentDay(lines[idx-1].timestamp, line.timestamp) {
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
            onToggle: { toggleExpand(line.raw) },
            onLongPress: {
                withAnimation {
                    editMode = .active
                    selectedIDs.insert(line.id)
                }
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            }
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
            deleteMenu
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

    private var deleteMenu: some View {
        Menu {
            Button("Delete Visible Logs", role: .destructive) {
                pendingDeleteCount = LogStore.shared.count(
                    levels: levelFilterToSet(),
                    components: componentFilterToSet(),
                    sinceNs: timeRangeToSinceNs(),
                    search: searchText.isEmpty ? nil : searchText)
                pendingDeleteAction = .visible
                showDeleteConfirmation = true
            }
            Button("Delete Older Than 1 Day", role: .destructive) {
                pendingDeleteAction = .olderThan1Day
                showDeleteConfirmation = true
            }
            Button("Delete Older Than 1 Week", role: .destructive) {
                pendingDeleteAction = .olderThan1Week
                showDeleteConfirmation = true
            }
            Button("Delete Older Than 1 Month", role: .destructive) {
                pendingDeleteAction = .olderThan1Month
                showDeleteConfirmation = true
            }
            Button("Delete All Logs", role: .destructive) {
                pendingDeleteAction = .all
                showDeleteConfirmation = true
            }
        } label: {
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
            Text("Copied \(selectedOrFilteredLines.count) entries")
                .font(.system(.subheadline, design: .monospaced))
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(Color.secondary.opacity(0.9))
                .foregroundColor(.white)
                .clipShape(Capsule())
                .padding(.bottom, 24)
                .transition(.opacity)
        }
    }

    @ViewBuilder
    private var deleteFeedbackOverlay: some View {
        if showDeleteFeedback {
            Text(deleteFeedbackText)
                .font(.system(.subheadline, design: .monospaced))
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(deleteFeedbackIsError ? Color.red.opacity(0.9) : Color.secondary.opacity(0.9))
                .foregroundColor(.white)
                .clipShape(Capsule())
                .padding(.bottom, 24)
                .transition(.opacity)
        }
    }

    // MARK: - Actions

    private func refreshGuard() {
        let paused = !selectedIDs.isEmpty || !expandedKeys.isEmpty || expandedReportID != nil
        guard !paused else {
            missedUpdates = true
            return
        }
        if missedUpdates {
            missedUpdates = false
            refresh()
        } else {
            incrementalRefresh()
        }
    }

    private func refresh() {
        let levels = levelFilterToSet()
        let components = componentFilterToSet()
        let since = timeRangeToSinceNs()
        let search = searchText.isEmpty ? nil : searchText
        lines = LogStore.shared.recent(
            limit: pageSize,
            levels: levels,
            components: components,
            sinceNs: since,
            search: search)
        newestSeenId = lines.first?.rowId
        oldestLoadedId = lines.last?.rowId
        totalCount = LogStore.shared.count(
            levels: levels,
            components: components,
            sinceNs: since,
            search: search)
        diagnostics = LogStore.shared.recentDiagnostics()
        crashReports = MetricKitSubscriber.loadReports()
    }

    private func clear() {
        try? LogStore.shared.clear()
        refresh()
    }

    private func executeDelete(_ action: DeleteAction) {
        do {
            switch action {
            case .visible:
                let count = try LogStore.shared.deleteFiltered(
                    levels: levelFilterToSet(),
                    components: componentFilterToSet(),
                    sinceNs: timeRangeToSinceNs(),
                    search: searchText.isEmpty ? nil : searchText)
                showDeleteFeedback(text: "Deleted \(count) logs", isError: false)
            case .olderThan1Day:
                let cutoff = Int64((Date().addingTimeInterval(-86400)).timeIntervalSince1970 * 1_000_000_000)
                let count = try LogStore.shared.deleteOlderThan(tsNs: cutoff)
                showDeleteFeedback(text: "Deleted \(count) logs", isError: false)
            case .olderThan1Week:
                let cutoff = Int64((Date().addingTimeInterval(-604800)).timeIntervalSince1970 * 1_000_000_000)
                let count = try LogStore.shared.deleteOlderThan(tsNs: cutoff)
                showDeleteFeedback(text: "Deleted \(count) logs", isError: false)
            case .olderThan1Month:
                let cutoff = Int64((Date().addingTimeInterval(-2592000)).timeIntervalSince1970 * 1_000_000_000)
                let count = try LogStore.shared.deleteOlderThan(tsNs: cutoff)
                showDeleteFeedback(text: "Deleted \(count) logs", isError: false)
            case .all:
                try LogStore.shared.clear()
                showDeleteFeedback(text: "Deleted all logs", isError: false)
            }
            refresh()
        } catch {
            showDeleteFeedback(text: "Delete failed — database may be corrupted; recovering…", isError: true)
            refresh()
        }
    }

    private func deleteConfirmationMessage(for action: DeleteAction) -> String {
        switch action {
        case .visible:
            return "Delete \(pendingDeleteCount) visible logs? They cannot be recovered."
        case .olderThan1Day:
            return "Delete all logs older than 1 day? They cannot be recovered."
        case .olderThan1Week:
            return "Delete all logs older than 1 week? They cannot be recovered."
        case .olderThan1Month:
            return "Delete all logs older than 1 month? They cannot be recovered."
        case .all:
            return "Delete all logs? They cannot be recovered."
        }
    }

    private func showDeleteFeedback(text: String, isError: Bool = false) {
        deleteFeedbackText = text
        deleteFeedbackIsError = isError
        withAnimation { showDeleteFeedback = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            withAnimation { showDeleteFeedback = false }
        }
    }

    private func copySelectedOrFiltered() {
        var text = selectedOrFilteredLines.map(\.raw).joined(separator: "\n")
        if scrubPII {
            text = LogScrubber.scrub(text)
        }
        UIPasteboard.general.string = text
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        withAnimation { showCopiedConfirmation = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            withAnimation { showCopiedConfirmation = false }
        }
    }

    private func copyCrashReport(_ report: MetricReport) {
        let text = scrubPII ? LogScrubber.scrub(report.rawJSON) : report.rawJSON
        UIPasteboard.general.string = text
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        withAnimation { showCopiedConfirmation = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
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

    // MARK: - Pagination

    private func loadMore() {
        guard let before = oldestLoadedId else { return }
        let more = LogStore.shared.recent(
            limit: pageSize, beforeId: before,
            levels: levelFilterToSet(),
            components: componentFilterToSet(),
            sinceNs: timeRangeToSinceNs(),
            search: searchText.isEmpty ? nil : searchText)
        guard !more.isEmpty else { return }
        lines.append(contentsOf: more)
        oldestLoadedId = more.last?.rowId
    }

    private func incrementalRefresh() {
        guard let newest = newestSeenId else { refresh(); return }
        let newer = LogStore.shared.recent(
            limit: pageSize,
            levels: levelFilterToSet(),
            components: componentFilterToSet(),
            sinceNs: timeRangeToSinceNs(),
            afterId: newest,
            search: searchText.isEmpty ? nil : searchText)
        guard !newer.isEmpty else { return }
        lines.insert(contentsOf: newer, at: 0)
        newestSeenId = newer.first?.rowId
        totalCount = LogStore.shared.count(
            levels: levelFilterToSet(),
            components: componentFilterToSet(),
            sinceNs: timeRangeToSinceNs(),
            search: searchText.isEmpty ? nil : searchText)
    }

    // MARK: - Filter Helpers

    private func levelFilterToSet() -> Set<LogLevel>? {
        switch selectedFilter {
        case .all:   return nil
        default:     return [selectedFilter.level!]
        }
    }

    private func componentFilterToSet() -> Set<LogComponent>? {
        switch componentFilter {
        case .all:   return nil
        default:     return [componentFilter.logComponent!]
        }
    }

    private func timeRangeToSinceNs() -> Int64? {
        switch timeRange {
        case .fiveMin:
            return Int64((Date().timeIntervalSince1970 - 300) * 1_000_000_000)
        case .oneHour:
            return Int64((Date().timeIntervalSince1970 - 3600) * 1_000_000_000)
        case .all:
            return nil
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
    let onLongPress: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(timeFormatted(line.timestamp))
                    .frame(width: 80, alignment: .leading)
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
        .onTapGesture { onToggle() }
        .onLongPressGesture(minimumDuration: 0.5) { onLongPress() }
    }

    @ViewBuilder
    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 1) {
            fieldRow(label: "Category", value: line.component?.rawValue ?? "—")
            fieldRow(label: "Level", value: line.level?.rawValue ?? "—")
            fieldRow(label: "Message", value: line.message ?? "", multiline: true)

            if let payloadLines = PayloadFormatter.render(line.payload, scrubPII: scrubPII) {
                Divider().padding(.vertical, 4)
                ForEach(payloadLines) { pl in
                    fieldRow(label: pl.key, value: pl.value, color: valueColor(pl.valueType))
                }
            }
        }
        .padding(.leading, 16)
        .padding(.top, 4)
    }

    @ViewBuilder
    private func fieldRow(label: String, value: String, color: Color = .primary, multiline: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("\(label):")
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .trailing)
                .fixedSize()
            Text(value)
                .foregroundStyle(color)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(multiline ? nil : 1)
                .truncationMode(.tail)
        }
    }
}
