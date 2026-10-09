import SwiftUI
import UIKit

// MARK: - Category Filter

private extension LogComponent {
    static let allCases: [LogComponent] = [
        .keyboard,
        .app,
        .transcription,
        .audio,
        .dictionary,
        .prediction,
        .network,
        .settings,
        .lifecycle
    ]
}

private final class PendingLogExportCleanupRegistry: @unchecked Sendable {
    private enum Lifecycle {
        case creating
        case shared
        case cleanupReady
    }

    static let shared = PendingLogExportCleanupRegistry()

    private let lock = NSLock()
    private var entries: [URL: Lifecycle] = [:]

    func register(_ url: URL) {
        lock.lock()
        defer { lock.unlock() }
        entries[url] = .creating
    }

    func markShared(_ url: URL) {
        lock.lock()
        defer { lock.unlock() }
        entries[url] = .shared
    }

    func markCleanupReady(_ url: URL) {
        lock.lock()
        defer { lock.unlock() }
        entries[url] = .cleanupReady
    }

    func unregister(_ url: URL) {
        lock.lock()
        defer { lock.unlock() }
        entries.removeValue(forKey: url)
    }

    func cleanupReadyURLs() -> [URL] {
        lock.lock()
        defer { lock.unlock() }
        return entries.reduce(into: [URL]()) { urls, entry in
            if case .cleanupReady = entry.value {
                urls.append(entry.key)
            }
        }
    }
}

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

// MARK: - Raw Log File

private enum RawLogLocation {
    case appGroup
    case documentsFallback
    case unavailable

    var title: String {
        switch self {
        case .appGroup:          return "App-group container available"
        case .documentsFallback: return "Documents fallback (app-group unavailable)"
        case .unavailable:       return "No log location available"
        }
    }

    var shareNote: String? {
        switch self {
        case .appGroup:
            return nil
        case .documentsFallback:
            return "The app-group container is unavailable. " +
                "This Documents fallback is process-local and does not contain keyboard-extension log evidence."
        case .unavailable:
            return "No app-group or Documents log location is available."
        }
    }

    var isAppGroup: Bool {
        if case .appGroup = self { return true }
        return false
    }
}

private struct RawLogFileSnapshot {
    private static let fileName = "ritoras-debug.log"
    private static let maxRolledFiles = 6
    private static let maxPreviewBytes = 200 * 1024

    let location: RawLogLocation
    let fileURL: URL?
    let currentFileExists: Bool
    let currentFileSize: Int64?
    let currentFileModifiedAt: Date?
    let rolledFileCount: Int
    let previewFileName: String?
    let preview: String
    let shareContent: String
    let errors: [String]

    static var empty: RawLogFileSnapshot {
        RawLogFileSnapshot(
            location: .unavailable,
            fileURL: nil,
            currentFileExists: false,
            currentFileSize: nil,
            currentFileModifiedAt: nil,
            rolledFileCount: 0,
            previewFileName: nil,
            preview: "Reading raw log files…",
            shareContent: "Raw log files have not been loaded.",
            errors: [])
    }

    var currentFileSizeLabel: String {
        guard let currentFileSize = currentFileSize else {
            return currentFileExists ? "Size unavailable" : "Current file not present"
        }
        return ByteCountFormatter.string(fromByteCount: currentFileSize, countStyle: .file)
    }

    static func load() -> RawLogFileSnapshot {
        let resolver = AppGroupResolver.shared
        let appGroupID = SharedConfig.Defaults.appGroupId
        if resolver.containerAvailable,
           let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID
           ) {
            return load(
                fileURL: container.appendingPathComponent(fileName),
                location: .appGroup)
        }

        guard let documents = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first else {
            return unavailableSnapshot()
        }
        return load(
            fileURL: documents.appendingPathComponent(fileName),
            location: .documentsFallback)
    }

    private static func load(fileURL: URL, location: RawLogLocation) -> RawLogFileSnapshot {
        let fileManager = FileManager.default
        let currentFileExists = fileManager.fileExists(atPath: fileURL.path)
        var currentFileSize: Int64?
        var currentFileModifiedAt: Date?
        var rolledFileCount = 0
        var previewFileName: String?
        var previewData: Data?
        var fileSections: [String] = []
        var errors: [String] = []

        if currentFileExists {
            do {
                let attributes = try fileManager.attributesOfItem(atPath: fileURL.path)
                currentFileSize = (attributes[.size] as? NSNumber)?.int64Value
                currentFileModifiedAt = attributes[.modificationDate] as? Date
            } catch {
                errors.append("Could not inspect \(fileURL.lastPathComponent): \(error.localizedDescription)")
            }
            do {
                let data = try Data(contentsOf: fileURL)
                fileSections.append(fileSection(fileURL.lastPathComponent, data: data))
                if !data.isEmpty {
                    previewData = data
                    previewFileName = fileURL.lastPathComponent
                }
            } catch {
                errors.append("Could not read \(fileURL.lastPathComponent): \(error.localizedDescription)")
            }
        }

        let directory = fileURL.deletingLastPathComponent()
        for index in 1...maxRolledFiles {
            let rolledURL = directory.appendingPathComponent("\(fileName).\(index)")
            guard fileManager.fileExists(atPath: rolledURL.path) else { continue }
            rolledFileCount += 1
            do {
                let data = try Data(contentsOf: rolledURL)
                fileSections.append(fileSection(rolledURL.lastPathComponent, data: data))
                if previewData == nil, !data.isEmpty {
                    previewData = data
                    previewFileName = rolledURL.lastPathComponent
                }
            } catch {
                errors.append("Could not read \(rolledURL.lastPathComponent): \(error.localizedDescription)")
            }
        }

        var shareSections = [
            "Ritoras raw log files",
            "Location: \(location.title)",
            "Path: \(fileURL.path)"
        ]
        if let note = location.shareNote {
            shareSections.append(note)
        }
        if fileSections.isEmpty {
            shareSections.append("No raw log files were found.")
        } else {
            shareSections.append(contentsOf: fileSections)
        }
        if !errors.isEmpty {
            shareSections.append("Read errors:\n\(errors.joined(separator: "\n"))")
        }

        let preview: String
        if let previewData = previewData {
            preview = tailPreview(from: previewData)
        } else if !errors.isEmpty {
            preview = errors.joined(separator: "\n")
        } else if currentFileExists {
            preview = "The current raw log file is empty."
        } else {
            preview = "No raw log files are present."
        }

        return RawLogFileSnapshot(
            location: location,
            fileURL: fileURL,
            currentFileExists: currentFileExists,
            currentFileSize: currentFileSize,
            currentFileModifiedAt: currentFileModifiedAt,
            rolledFileCount: rolledFileCount,
            previewFileName: previewFileName,
            preview: preview,
            shareContent: shareSections.joined(separator: "\n\n"),
            errors: errors)
    }

    private static func unavailableSnapshot() -> RawLogFileSnapshot {
        let error = "No app-group or Documents directory is available."
        return RawLogFileSnapshot(
            location: .unavailable,
            fileURL: nil,
            currentFileExists: false,
            currentFileSize: nil,
            currentFileModifiedAt: nil,
            rolledFileCount: 0,
            previewFileName: nil,
            preview: error,
            shareContent: "Ritoras raw log files\n\n\(error)",
            errors: [error])
    }

    private static func fileSection(_ name: String, data: Data) -> String {
        "--- \(name) ---\n\(String(decoding: data, as: UTF8.self))"
    }

    private static func tailPreview(from data: Data) -> String {
        var preview = String(decoding: data.suffix(maxPreviewBytes), as: UTF8.self)
        guard data.count > maxPreviewBytes,
              let firstLineBreak = preview.firstIndex(of: "\n") else {
            return preview
        }
        preview = String(preview[preview.index(after: firstLineBreak)...])
        return preview
    }
}

// MARK: - Time Range Filter

private enum TimeRangeFilter: String, CaseIterable {
    case fiveMin = "5m"
    case oneHour = "1h"
    case all = "All"
    case custom = "Custom"
}

private struct CustomDateRange: Equatable {
    var start: Date
    var end: Date
}

// Keep picker bounds inside the range representable as Int64 Unix nanoseconds.
private enum CustomLogDateLimits {
    static let earliest = Date(
        timeIntervalSince1970: TimeInterval(Int64.min + 1_000_000_000) / 1_000_000_000
    )
    static let latest = Date(
        timeIntervalSince1970: TimeInterval(Int64.max - 1_000_000_000) / 1_000_000_000
    )
}

private struct CustomLogExportRequest: Sendable {
    let sinceNs: Int64
    let untilNs: Int64
    let generation: Int
    let scrubPII: Bool
}

private struct LargeCustomLogExportConfirmation {
    let request: CustomLogExportRequest
    let estimate: LocalhostLogExportEstimate
}

private enum CustomLogExportThresholds {
    static let entryCount = 10_000
    static let estimatedBytes: Int64 = 5 * 1024 * 1024
}

private enum CustomLogExportError: LocalizedError {
    case serverUnavailable

    var errorDescription: String? {
        switch self {
        case .serverUnavailable:
            return "The localhost log server could not be started. Reopen the app and try again."
        }
    }
}

// MARK: - Delete Action

private enum DeleteAction {
    case visible
    case olderThan1Day
    case olderThan1Week
    case olderThan1Month
    case all
    case crashReports
    case everything
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
    @EnvironmentObject private var dictationViewModel: DictationViewModel
    @State private var lines: [LogLine] = []
    @State private var diagnostics: [String] = []
    @State private var selectedIDs: Set<Int> = []
    @State private var selectedFilter: LevelFilter = .all
    @State private var selectedComponents: Set<LogComponent> = Set(LogComponent.allCases)
    @State private var isCategoryFilterPresented = false
    @State private var searchText: String = ""
    @State private var timeRange: TimeRangeFilter = .all
    @State private var customDateRange = CustomDateRange(
        start: Date().addingTimeInterval(-3600),
        end: Date()
    )
    @State private var didInitializeCustomDateRange = false
    @State private var scrubPII = true
    @State private var crashReports: [MetricReport] = []

    @State private var expandedReportID: Int? = nil
    @State private var editMode: EditMode = .inactive
    @State private var expandedKeys: Set<String> = []
    @State private var oldestLoadedId: Int64? = nil
    @State private var newestSeenId: Int64? = nil
    @State private var totalCount: Int = 0
    @State private var isLoadingMore = false
    @State private var showDeleteConfirmation = false
    @State private var pendingDeleteAction: DeleteAction?
    @State private var showDeleteFeedback = false
    @State private var deleteFeedbackText: String = ""
    @State private var deleteFeedbackIsError = false
    @State private var missedUpdates = false
    @State private var cachedShareText: String = ""
    @State private var rawLogSnapshot = RawLogFileSnapshot.empty
    @State private var rawLogPreviewText = ""
    @State private var rawLogShareText = ""
    @State private var rawLogReadGeneration = 0
    @State private var rawLogPresentationGeneration = 0
    @State private var isLoadingRawLog = true
    @State private var isUpdatingRawLogPresentation = false
    @State private var refreshGeneration = 0
    @State private var isLoading = false
    @State private var isViewVisible = false
    @State private var isExportingCustomRange = false
    @State private var pendingLargeExport: LargeCustomLogExportConfirmation?
    @State private var showLargeExportConfirmation = false
    @State private var rangeExportURL: URL?
    @State private var isRangeExportSheetPresented = false
    @State private var showExportError = false
    @State private var exportErrorMessage = ""
    private let pageSize = 50

    private var selectedOrFilteredLines: [LogLine] {
        selectedIDs.isEmpty ? lines : lines.filter { selectedIDs.contains($0.id) }
    }

    var body: some View {
        VStack(spacing: 0) {
            levelFilter
            categoryTimeFilter
            customRangeControls
            searchField
            if !selectedIDs.isEmpty || !expandedKeys.isEmpty {
                statusBanner
            }
            if lines.isEmpty && diagnostics.isEmpty && crashReports.isEmpty && isLoading {
                VStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
            } else {
                mainList
            }
        }
        .navigationTitle("Debug Log")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .confirmationDialog("Delete Data",
                            isPresented: $showDeleteConfirmation,
                            titleVisibility: .visible) {
            if !crashReports.isEmpty {
                Button("Clear Crash Reports", role: .destructive) {
                    pendingDeleteAction = .crashReports
                    executeDelete(.crashReports)
                }
            }
            Button("Delete Visible Logs", role: .destructive) {
                pendingDeleteAction = .visible
                executeDelete(.visible)
            }
            Button("Delete Older Than 1 Day", role: .destructive) {
                pendingDeleteAction = .olderThan1Day
                executeDelete(.olderThan1Day)
            }
            Button("Delete Older Than 1 Week", role: .destructive) {
                pendingDeleteAction = .olderThan1Week
                executeDelete(.olderThan1Week)
            }
            Button("Delete Older Than 1 Month", role: .destructive) {
                pendingDeleteAction = .olderThan1Month
                executeDelete(.olderThan1Month)
            }
            Button("Delete All Logs", role: .destructive) {
                pendingDeleteAction = .all
                executeDelete(.all)
            }
            if !crashReports.isEmpty {
                Button("Delete Everything", role: .destructive) {
                    pendingDeleteAction = .everything
                    executeDelete(.everything)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Select what to delete. Deleted data cannot be recovered.")
        }
        .alert("Log Export Failed", isPresented: $showExportError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(exportErrorMessage)
        }
        .sheet(isPresented: $isRangeExportSheetPresented, onDismiss: cleanupRangeExportFile) {
            if let url = rangeExportURL {
                ActivityShareSheet(items: [url])
            }
        }
        .onChange(of: searchText) { _, _ in refresh() }
        .onChange(of: selectedFilter) { _, _ in refresh() }
        .onChange(of: selectedComponents) { _, _ in refresh() }
        .onChange(of: timeRange) { _, newValue in
            if newValue == .custom && !didInitializeCustomDateRange {
                let now = Date()
                customDateRange = CustomDateRange(
                    start: now.addingTimeInterval(-3600),
                    end: now
                )
                didInitializeCustomDateRange = true
            } else {
                refresh()
            }
        }
        .onChange(of: customDateRange) { _, _ in
            if timeRange == .custom { refresh() }
        }
        .onChange(of: scrubPII) { _, _ in
            updateShareText()
            updateRawLogPresentation()
        }
        .onChange(of: expandedKeys) { _, newKeys in
            if newKeys.isEmpty { refreshGuard() }
        }
        .onChange(of: selectedIDs) { _, newIDs in
            if newIDs.isEmpty { refreshGuard() }
            updateShareText()
        }
        .onChange(of: expandedReportID) { _, newValue in
            if newValue == nil { refreshGuard() }
        }
        .onAppear {
            isViewVisible = true
            drainPendingCustomLogExportFiles()
            refreshAll()
        }
        .onDisappear {
            isViewVisible = false
            if !isRangeExportSheetPresented { cleanupRangeExportFile() }
        }
        .overlay(alignment: .bottom) {
            if showDeleteFeedback {
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

    private var categoryTimeFilter: some View {
        HStack(spacing: 8) {
            Button {
                isCategoryFilterPresented = true
            } label: {
                HStack(spacing: 4) {
                    Text(categoryFilterSummary)
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.caption2)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityLabel("Categories")
            .accessibilityValue(categoryFilterSummary)
            .sheet(isPresented: $isCategoryFilterPresented) {
                CategoryFilterSheet(selectedComponents: $selectedComponents)
            }

            Picker("Time", selection: $timeRange) {
                ForEach(TimeRangeFilter.allCases, id: \.self) { filter in
                    Text(filter.rawValue).tag(filter)
                }
            }
            .pickerStyle(.segmented)
        }
        .padding(.horizontal)
        .padding(.bottom, 4)
    }

    private var categoryFilterSummary: String {
        selectedComponents.count == LogComponent.allCases.count
            ? "All Categories"
            : "\(selectedComponents.count) Categories"
    }

    private var customRangeControls: some View {
        Group {
            if timeRange == .custom {
                VStack(spacing: 6) {
                    VStack(alignment: .leading, spacing: 2) {
                        DatePicker(
                            "Start",
                            selection: customStartDateBinding,
                            in: CustomLogDateLimits.earliest...customDateRange.end,
                            displayedComponents: [.date, .hourAndMinute]
                        )
                        DatePicker(
                            "End",
                            selection: customEndDateBinding,
                            in: customDateRange.start...CustomLogDateLimits.latest,
                            displayedComponents: [.date, .hourAndMinute]
                        )
                    }
                    .datePickerStyle(.compact)
                    .font(.subheadline)
                    .frame(maxWidth: .infinity, alignment: .leading)

                    HStack {
                        Spacer()
                        Button(action: beginCustomRangeExport) {
                            HStack(spacing: 6) {
                                if isExportingCustomRange {
                                    ProgressView()
                                        .controlSize(.small)
                                } else {
                                    Image(systemName: "square.and.arrow.up")
                                }
                                Text(isExportingCustomRange ? "Exporting…" : "Export Range")
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(isExportingCustomRange || isRangeExportSheetPresented)
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 4)
            }
        }
        .confirmationDialog(
            "Large Log Export",
            isPresented: $showLargeExportConfirmation,
            titleVisibility: .visible
        ) {
            if let pendingLargeExport {
                Button("Export \(pendingLargeExport.estimate.count) Entries") {
                    confirmLargeCustomExport()
                }
            }
            Button("Cancel", role: .cancel) {
                pendingLargeExport = nil
            }
        } message: {
            if let pendingLargeExport {
                Text(
                    "This range contains \(pendingLargeExport.estimate.count) entries and is estimated at "
                        + "\(pendingLargeExport.estimate.estimatedBytes) bytes. Continue?"
                )
            }
        }
    }

    private var customStartDateBinding: Binding<Date> {
        Binding(
            get: { customDateRange.start },
            set: { customDateRange.start = $0 }
        )
    }

    private var customEndDateBinding: Binding<Date> {
        Binding(
            get: { customDateRange.end },
            set: { customDateRange.end = $0 }
        )
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
            rawLogFileSection
            crashReportsSection
            diagnosticsSection
            if lines.isEmpty && diagnostics.isEmpty && crashReports.isEmpty {
                if isLoading {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                } else {
                    emptyStateRow
                }
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

    private var rawLogFileSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(rawLogSnapshot.location.title)
                        .font(.caption)
                        .foregroundColor(rawLogSnapshot.location.isAppGroup ? .green : .orange)
                    Spacer()
                    ShareLink(item: rawLogShareText) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.caption)
                    }
                    .accessibilityLabel("Share raw log files")
                    .disabled(isLoadingRawLog || isUpdatingRawLogPresentation)
                }

                Text(rawLogSnapshot.fileURL?.path ?? "Resolved path unavailable")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(3)

                if case .documentsFallback = rawLogSnapshot.location,
                   let caveat = rawLogSnapshot.location.shareNote {
                    Label(caveat, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundColor(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack {
                    Text(rawLogSnapshot.currentFileSizeLabel)
                    Spacer()
                    if let modifiedAt = rawLogSnapshot.currentFileModifiedAt {
                        Text("Modified \(modifiedAt.formatted(date: .abbreviated, time: .shortened))")
                    }
                }
                .font(.caption2)
                .foregroundColor(.secondary)

                Text("Rolled files: \(rawLogSnapshot.rolledFileCount) of 6")
                    .font(.caption2)
                    .foregroundColor(.secondary)

                Text(rawLogSnapshot.previewFileName.map { "Tail preview — \($0)" } ?? "Tail preview")
                    .font(.caption)
                    .foregroundColor(.secondary)

                if isLoadingRawLog || isUpdatingRawLogPresentation {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        Text(isLoadingRawLog ? "Reading raw log files…" : "Updating PII scrubbing…")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                } else {
                    ScrollView(.vertical) {
                        Text(rawLogPreviewText)
                            .font(.system(.caption2, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(maxHeight: 220)
                    .padding(6)
                    .background(Color(.systemGray6))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }

                if !rawLogSnapshot.errors.isEmpty {
                    let errorText = rawLogSnapshot.errors.joined(separator: "\n")
                    Text(scrubPII ? LogScrubber.scrub(errorText) : errorText)
                        .font(.caption2)
                        .foregroundColor(.orange)
                        .textSelection(.enabled)
                }
            }
            .padding(.vertical, 4)
            .listRowBackground(Color.clear)
        } header: {
            Text("Raw log file")
        }
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
        Text(selectedComponents.isEmpty ? "No categories selected" : "No database log entries yet")
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
            editModeButton
        }
        ToolbarItem(placement: .navigationBarTrailing) {
            scrubPIIButton
        }
        ToolbarItem(placement: .navigationBarTrailing) {
            shareButton
        }
        ToolbarItem(placement: .navigationBarTrailing) {
            refreshButton
        }
        ToolbarItem(placement: .navigationBarTrailing) {
            Button(action: { showDeleteConfirmation = true }) {
                Image(systemName: "trash")
            }
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
        ShareLink(item: cachedShareText) {
            Image(systemName: "square.and.arrow.up")
        }
    }

    private var refreshButton: some View {
        Button(action: refreshAll) {
            Image(systemName: "arrow.clockwise")
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

    private func refreshAll() {
        refresh()
        refreshRawLog()
    }

    private func refreshGuard() {
        let paused = !isViewVisible || !selectedIDs.isEmpty || !expandedKeys.isEmpty || expandedReportID != nil
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

    private func refreshRawLog() {
        rawLogReadGeneration += 1
        let generation = rawLogReadGeneration
        isLoadingRawLog = true

        DispatchQueue.global(qos: .userInitiated).async {
            let snapshot = RawLogFileSnapshot.load()

            DispatchQueue.main.async {
                guard generation == rawLogReadGeneration else { return }
                rawLogSnapshot = snapshot
                isLoadingRawLog = false
                updateRawLogPresentation()
            }
        }
    }

    private func refresh() {
        let componentSelection = selectedComponents
        guard !componentSelection.isEmpty else {
            clearFilteredLogResults()
            return
        }

        let levels = levelFilterToSet()
        let components = componentsForQuery(componentSelection)
        let bounds = timeRangeToBounds()
        let search = searchText.isEmpty ? nil : searchText
        let piiScrub = scrubPII

        refreshGeneration += 1
        let gen = refreshGeneration
        isLoading = true

        DispatchQueue.global(qos: .userInitiated).async {
            let newLines = LogStore.shared.recent(
                limit: pageSize,
                levels: levels,
                components: components,
                sinceNs: bounds.sinceNs,
                untilNs: bounds.untilNs,
                search: search)
            let newCount = LogStore.shared.count(
                levels: levels,
                components: components,
                sinceNs: bounds.sinceNs,
                untilNs: bounds.untilNs,
                search: search)
            let newDiagnostics = LogStore.shared.recentDiagnostics()
            let newCrashReports = MetricKitSubscriber.loadReports()

            let rawText = newLines.map(\.raw).joined(separator: "\n")
            let newShareText = piiScrub ? LogScrubber.scrub(rawText) : rawText

            DispatchQueue.main.async {
                guard gen == refreshGeneration else { return }
                lines = newLines
                newestSeenId = newLines.first?.rowId
                oldestLoadedId = newLines.last?.rowId
                totalCount = newCount
                diagnostics = newDiagnostics
                crashReports = newCrashReports
                cachedShareText = newShareText
                isLoading = false
            }
        }
    }

    private func clear() {
        try? LogStore.shared.clear()
        refresh()
    }

    private func updateShareText() {
        let rawText = selectedOrFilteredLines.map(\.raw).joined(separator: "\n")
        cachedShareText = scrubPII ? LogScrubber.scrub(rawText) : rawText
    }

    private func updateRawLogPresentation() {
        let preview = rawLogSnapshot.preview
        let shareContent = rawLogSnapshot.shareContent
        let piiScrub = scrubPII

        rawLogPresentationGeneration += 1
        let generation = rawLogPresentationGeneration
        isUpdatingRawLogPresentation = true

        DispatchQueue.global(qos: .userInitiated).async {
            let newPreview = piiScrub ? LogScrubber.scrub(preview) : preview
            let newShareContent = piiScrub ? LogScrubber.scrub(shareContent) : shareContent

            DispatchQueue.main.async {
                guard generation == rawLogPresentationGeneration else { return }
                rawLogPreviewText = newPreview
                rawLogShareText = newShareContent
                isUpdatingRawLogPresentation = false
            }
        }
    }

    @MainActor
    private func beginCustomRangeExport() {
        guard !isExportingCustomRange, !isRangeExportSheetPresented, timeRange == .custom else { return }
        drainPendingCustomLogExportFiles()
        if rangeExportURL != nil { cleanupRangeExportFile() }
        guard rangeExportURL == nil else { return }
        let bounds = timeRangeToBounds()
        guard let sinceNs = bounds.sinceNs, let untilNs = bounds.untilNs else { return }

        let request = CustomLogExportRequest(
            sinceNs: sinceNs,
            untilNs: untilNs,
            generation: refreshGeneration,
            scrubPII: scrubPII
        )
        isExportingCustomRange = true
        FileLogger.shared.info(.app, "Custom log export started")
        Task { await countAndMaybeExportCustomRange(request) }
    }

    @MainActor
    private func countAndMaybeExportCustomRange(_ request: CustomLogExportRequest) async {
        defer { isExportingCustomRange = false }

        do {
            guard isCurrentCustomExport(request) else { return }
            try await ensureLocalhostServerIsAvailable(for: request)
            guard isCurrentCustomExport(request) else { return }

            let estimate = try await LocalhostClient.countLogExport(
                sinceNs: request.sinceNs,
                untilNs: request.untilNs
            )
            guard isCurrentCustomExport(request) else { return }

            if estimate.count > CustomLogExportThresholds.entryCount
                || estimate.estimatedBytes > CustomLogExportThresholds.estimatedBytes {
                pendingLargeExport = LargeCustomLogExportConfirmation(
                    request: request,
                    estimate: estimate
                )
                showLargeExportConfirmation = true
                return
            }

            try await fetchAndShareCustomRange(request)
        } catch {
            guard isCurrentCustomExport(request) else { return }
            showCustomExportError(error)
        }
    }

    @MainActor
    private func confirmLargeCustomExport() {
        guard let pending = pendingLargeExport else { return }
        pendingLargeExport = nil
        guard isCurrentCustomExport(pending.request), !isExportingCustomRange else { return }

        isExportingCustomRange = true
        Task { await exportConfirmedLargeRange(pending.request) }
    }

    @MainActor
    private func exportConfirmedLargeRange(_ request: CustomLogExportRequest) async {
        defer { isExportingCustomRange = false }

        do {
            guard isCurrentCustomExport(request) else { return }
            try await ensureLocalhostServerIsAvailable(for: request)
            guard isCurrentCustomExport(request) else { return }
            try await fetchAndShareCustomRange(request)
        } catch {
            guard isCurrentCustomExport(request) else { return }
            showCustomExportError(error)
        }
    }

    @MainActor
    private func ensureLocalhostServerIsAvailable(for request: CustomLogExportRequest) async throws {
        let initiallyHealthy = await LocalhostClient.healthCheck()
        guard isCurrentCustomExport(request) else { return }
        guard !initiallyHealthy else { return }

        // Reuse the DictationViewModel-owned listener; a second server instance
        // would compete for the same localhost port.
        dictationViewModel.startLocalhostServer()
        for attempt in 0..<5 {
            let isHealthy = await LocalhostClient.healthCheck()
            guard isCurrentCustomExport(request) else { return }
            if isHealthy { return }
            if attempt < 4 {
                try await Task.sleep(nanoseconds: 200_000_000)
                guard isCurrentCustomExport(request) else { return }
            }
        }
        throw CustomLogExportError.serverUnavailable
    }

    @MainActor
    private func fetchAndShareCustomRange(_ request: CustomLogExportRequest) async throws {
        guard isCurrentCustomExport(request) else { return }

        let response = try await LocalhostClient.exportLogs(
            sinceNs: request.sinceNs,
            untilNs: request.untilNs
        )
        guard isCurrentCustomExport(request) else { return }

        let entries = response.entries
        let shouldScrubPII = request.scrubPII
        let url = try await Task.detached(priority: .userInitiated) {
            try Self.writeCustomLogExport(entries: entries, scrubPII: shouldScrubPII)
        }.value

        guard isCurrentCustomExport(request) else {
            PendingLogExportCleanupRegistry.shared.markCleanupReady(url)
            rangeExportURL = url
            cleanupRangeExportFile()
            return
        }

        rangeExportURL = url
        PendingLogExportCleanupRegistry.shared.markShared(url)
        isRangeExportSheetPresented = true
        FileLogger.shared.info(.app, "Custom log export completed",
                               payload: ["count": response.count])
    }

    @MainActor
    private func isCurrentCustomExport(_ request: CustomLogExportRequest) -> Bool {
        isViewVisible && request.generation == refreshGeneration
    }

    @MainActor
    private func showCustomExportError(_ error: Error) {
        FileLogger.shared.error(.app, "Custom log export failed",
                                payload: ["error": error.localizedDescription])
        exportErrorMessage = error.localizedDescription
        showExportError = true
    }

    nonisolated private static func writeCustomLogExport(entries: [LocalhostLogExportEntry],
                                                         scrubPII: Bool) throws -> URL {
        let text = entries.map(Self.formatCustomLogExportEntry).joined(separator: "\n")
        let shareText = scrubPII ? LogScrubber.scrub(text) : text
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let filename = "ritoras-log-export-\(formatter.string(from: Date()))-\(UUID().uuidString).txt"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        // Keep creation ineligible for drains until writing and handoff finish.
        PendingLogExportCleanupRegistry.shared.register(url)
        do {
            try shareText.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            PendingLogExportCleanupRegistry.shared.markCleanupReady(url)
            throw error
        }
        return url
    }

    nonisolated private static func formatCustomLogExportEntry(_ entry: LocalhostLogExportEntry) -> String {
        let timestamp = entry.timestamp ?? "—"
        let level = entry.level.map { "[\($0.uppercased())]" } ?? "[—]"
        let component = entry.component.map { "[\($0)]" } ?? "[—]"
        let message: String
        if let structuredMessage = entry.message, !structuredMessage.isEmpty {
            message = structuredMessage
        } else {
            message = entry.raw
        }

        var lines = ["\(timestamp) \(level) \(component) \(message)"]
        if let payload = entry.payload {
            for key in payload.keys.sorted() {
                if let value = payload[key] {
                    lines.append("  \(key): \(value.readableText)")
                }
            }
        }
        return lines.joined(separator: "\n")
    }

    @MainActor
    private func cleanupRangeExportFile() {
        guard let url = rangeExportURL else { return }
        PendingLogExportCleanupRegistry.shared.markCleanupReady(url)
        guard removeCustomLogExportFile(at: url, alertOnFailure: true) else { return }
        rangeExportURL = nil
    }

    @MainActor
    private func drainPendingCustomLogExportFiles() {
        for url in PendingLogExportCleanupRegistry.shared.cleanupReadyURLs() {
            _ = removeCustomLogExportFile(at: url, alertOnFailure: false)
        }
    }

    @MainActor
    private func removeCustomLogExportFile(at url: URL, alertOnFailure: Bool) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else {
            PendingLogExportCleanupRegistry.shared.unregister(url)
            return true
        }
        do {
            try FileManager.default.removeItem(at: url)
            PendingLogExportCleanupRegistry.shared.unregister(url)
            return true
        } catch {
            PendingLogExportCleanupRegistry.shared.markCleanupReady(url)
            FileLogger.shared.warn(.app, "Custom log export file cleanup failed",
                                   payload: ["error": error.localizedDescription])
            if alertOnFailure { showCustomExportError(error) }
            return false
        }
    }

    private func executeDelete(_ action: DeleteAction) {
        do {
            switch action {
            case .visible:
                if selectedComponents.isEmpty {
                    showDeleteFeedback(text: "Deleted 0 logs", isError: false)
                } else {
                    let bounds = timeRangeToBounds()
                    let count = try LogStore.shared.deleteFiltered(
                        levels: levelFilterToSet(),
                        components: componentsForQuery(selectedComponents),
                        sinceNs: bounds.sinceNs,
                        untilNs: bounds.untilNs,
                        search: searchText.isEmpty ? nil : searchText)
                    showDeleteFeedback(text: "Deleted \(count) logs", isError: false)
                }
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
            case .crashReports:
                MetricKitSubscriber.clear()
                crashReports = []
                showDeleteFeedback(text: "Cleared crash reports", isError: false)
            case .everything:
                MetricKitSubscriber.clear()
                crashReports = []
                try LogStore.shared.clear()
                showDeleteFeedback(text: "Deleted crash reports and all logs", isError: false)
            }
            refresh()
        } catch {
            showDeleteFeedback(text: "Delete failed — database may be corrupted; recovering…", isError: true)
            refresh()
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

    private func copyCrashReport(_ report: MetricReport) {
        let text = scrubPII ? LogScrubber.scrub(report.rawJSON) : report.rawJSON
        UIPasteboard.general.string = text
        UINotificationFeedbackGenerator().notificationOccurred(.success)
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
        let componentSelection = selectedComponents
        guard !componentSelection.isEmpty else {
            clearFilteredLogResults()
            return
        }
        guard !isLoadingMore else { return }
        guard !isLoading else { return }
        isLoadingMore = true
        guard let before = oldestLoadedId else {
            isLoadingMore = false
            return
        }
        let levels = levelFilterToSet()
        let components = componentsForQuery(componentSelection)
        let bounds = timeRangeToBounds()
        let search = searchText.isEmpty ? nil : searchText
        let piiScrub = scrubPII
        let gen = refreshGeneration

        DispatchQueue.global(qos: .userInitiated).async {
            let more = LogStore.shared.recent(
                limit: pageSize, beforeId: before,
                levels: levels,
                components: components,
                sinceNs: bounds.sinceNs,
                untilNs: bounds.untilNs,
                search: search)
            guard !more.isEmpty else {
                DispatchQueue.main.async {
                    isLoadingMore = false
                    guard gen == refreshGeneration else { return }
                }
                return
            }

            DispatchQueue.main.async {
                isLoadingMore = false
                guard gen == refreshGeneration else { return }
                lines.append(contentsOf: more)
                oldestLoadedId = more.last?.rowId

                let rawText = lines.map(\.raw).joined(separator: "\n")
                cachedShareText = piiScrub ? LogScrubber.scrub(rawText) : rawText
            }
        }
    }

    private func incrementalRefresh() {
        let componentSelection = selectedComponents
        guard !componentSelection.isEmpty else {
            clearFilteredLogResults()
            return
        }
        guard let newest = newestSeenId else { refresh(); return }
        let levels = levelFilterToSet()
        let components = componentsForQuery(componentSelection)
        let bounds = timeRangeToBounds()
        let search = searchText.isEmpty ? nil : searchText
        let piiScrub = scrubPII

        refreshGeneration += 1
        let gen = refreshGeneration

        DispatchQueue.global(qos: .userInitiated).async {
            let newer = LogStore.shared.recent(
                limit: pageSize,
                levels: levels,
                components: components,
                sinceNs: bounds.sinceNs,
                untilNs: bounds.untilNs,
                afterId: newest,
                search: search)

            let newCount: Int? = newer.isEmpty ? nil : LogStore.shared.count(
                levels: levels,
                components: components,
                sinceNs: bounds.sinceNs,
                untilNs: bounds.untilNs,
                search: search)

            DispatchQueue.main.async {
                guard gen == refreshGeneration else { return }
                isLoading = false

                guard !newer.isEmpty else { return }

                lines.insert(contentsOf: newer, at: 0)
                newestSeenId = newer.first?.rowId
                if let newCount = newCount {
                    totalCount = newCount
                }

                let rawText = lines.map(\.raw).joined(separator: "\n")
                cachedShareText = piiScrub ? LogScrubber.scrub(rawText) : rawText
            }
        }
    }

    // MARK: - Filter Helpers

    private func levelFilterToSet() -> Set<LogLevel>? {
        switch selectedFilter {
        case .all:   return nil
        default:     return [selectedFilter.level!]
        }
    }

    private func componentsForQuery(_ selection: Set<LogComponent>) -> Set<LogComponent>? {
        selection.count == LogComponent.allCases.count ? nil : selection
    }

    private func clearFilteredLogResults() {
        refreshGeneration += 1
        lines = []
        newestSeenId = nil
        oldestLoadedId = nil
        totalCount = 0
        cachedShareText = ""
        isLoading = false
    }

    private func timeRangeToBounds() -> (sinceNs: Int64?, untilNs: Int64?) {
        switch timeRange {
        case .fiveMin:
            return (Int64((Date().timeIntervalSince1970 - 300) * 1_000_000_000), nil)
        case .oneHour:
            return (Int64((Date().timeIntervalSince1970 - 3600) * 1_000_000_000), nil)
        case .all:
            return (nil, nil)
        case .custom:
            return (
                Int64(customDateRange.start.timeIntervalSince1970 * 1_000_000_000),
                Int64(customDateRange.end.timeIntervalSince1970 * 1_000_000_000)
            )
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

private struct CategoryFilterSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var selectedComponents: Set<LogComponent>

    private var allCategoriesSelected: Bool {
        selectedComponents.count == LogComponent.allCases.count
    }

    var body: some View {
        NavigationStack {
            List {
                Button {
                    if allCategoriesSelected {
                        selectedComponents.removeAll()
                    } else {
                        selectedComponents = Set(LogComponent.allCases)
                    }
                } label: {
                    categoryRow(title: "All", isSelected: allCategoriesSelected)
                }
                .buttonStyle(.plain)

                ForEach(LogComponent.allCases, id: \.self) { component in
                    Button {
                        if selectedComponents.contains(component) {
                            selectedComponents.remove(component)
                        } else {
                            selectedComponents.insert(component)
                        }
                    } label: {
                        categoryRow(
                            title: component.rawValue,
                            isSelected: selectedComponents.contains(component)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .navigationTitle("Categories")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func categoryRow(title: String, isSelected: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
            Text(title)
            Spacer()
        }
        .contentShape(Rectangle())
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
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
