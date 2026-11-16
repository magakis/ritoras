import CoreFoundation
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
        .lifecycle,
        .performance
    ]
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

// MARK: - Time Range Filter

private enum TimeRangeFilter: String, CaseIterable {
    case fiveMin = "5m"
    case fifteenMin = "15m"
    case oneHour = "1h"
    case all = "All"
    case custom = "Custom"
}

private enum DebugLogPageDirection {
    case older
    case newer
}

private struct DebugLogWindowResult {
    let rowIDs: [Int64]
    let evictedRowIDs: Set<Int64>
    let newestCursor: Int64?
    let oldestCursor: Int64?
    let loadedCount: Int
    let matchingTotalCount: Int
}

private enum DebugLogWindowPolicy {
    static let maximumResidentRows = 200

    static func merging(
        loadedIDs: [Int64],
        pageIDs: [Int64],
        direction: DebugLogPageDirection,
        matchingTotalCount: Int
    ) -> DebugLogWindowResult {
        var seenIDs = Set<Int64>()
        let mergedIDs = (loadedIDs + pageIDs)
            .filter { seenIDs.insert($0).inserted }
            .sorted(by: >)
        let residentIDs: [Int64]
        if mergedIDs.count > maximumResidentRows {
            switch direction {
            case .older:
                residentIDs = Array(mergedIDs.suffix(maximumResidentRows))
            case .newer:
                residentIDs = Array(mergedIDs.prefix(maximumResidentRows))
            }
        } else {
            residentIDs = mergedIDs
        }

        let residentIDSet = Set(residentIDs)
        let evictedRowIDs = Set(mergedIDs.filter { !residentIDSet.contains($0) })
        return DebugLogWindowResult(
            rowIDs: residentIDs,
            evictedRowIDs: evictedRowIDs,
            newestCursor: residentIDs.first,
            oldestCursor: residentIDs.last,
            loadedCount: residentIDs.count,
            matchingTotalCount: matchingTotalCount
        )
    }
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
    let estimate: CustomLogExportEstimate
}

private struct CustomLogExportEstimate: Sendable {
    let count: Int
    let estimatedBytes: Int64
}

private struct PreparedCustomLogExport: Sendable {
    var text: String
    let entryCount: Int
    let byteCount: Int
    let fetchDurationMilliseconds: Double
    let footprintBeforeBytes: UInt64
}

private enum CustomLogExportThresholds {
    static let entryCount = 10_000
    static let estimatedBytes: Int64 = 5 * 1024 * 1024
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

// MARK: - Query Performance

private struct DebugLogQueryPerformance {
    let action: String
    let durationMilliseconds: Double
    let footprintDeltaBytes: Double?
}

private func measureDebugLogQuery<Value>(
    action: String,
    includesFootprintDelta: Bool = false,
    operation: () -> Value
) -> (value: Value, performance: DebugLogQueryPerformance) {
    let footprintBefore = includesFootprintDelta ? MemoryMonitor.currentFootprint() : nil
    let start = DispatchTime.now().uptimeNanoseconds
    let value = operation()
    let end = DispatchTime.now().uptimeNanoseconds
    let footprintDeltaBytes = footprintBefore.map { before in
        Double(MemoryMonitor.currentFootprint()) - Double(before)
    }

    return (
        value: value,
        performance: DebugLogQueryPerformance(
            action: action,
            durationMilliseconds: Double(end - start) / 1_000_000,
            footprintDeltaBytes: footprintDeltaBytes
        )
    )
}

private func logDebugLogQueryPerformance(_ performance: DebugLogQueryPerformance) {
    var payload: [String: Any] = [
        "action": performance.action,
        "duration_ms": performance.durationMilliseconds
    ]
    if let footprintDeltaBytes = performance.footprintDeltaBytes {
        payload["phys_footprint_delta_bytes"] = footprintDeltaBytes
    }
    FileLogger.shared.info(.performance, "Debug log query", payload: payload)
}

private func makeDebugLogQueryHandle() -> LogQueryHandle {
    LogStore.shared.makeQueryCancellationHandle { durationMilliseconds in
        logDebugLogQueryPerformance(
            DebugLogQueryPerformance(
                action: "cancel",
                durationMilliseconds: durationMilliseconds,
                footprintDeltaBytes: nil
            )
        )
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
    @State private var newestLoadedId: Int64? = nil
    @State private var oldestLoadedId: Int64? = nil
    @State private var newestSeenId: Int64? = nil
    @State private var hasNewerRows = false
    @State private var hasOlderRows = false
    @State private var totalCount: Int = 0
    @State private var isLoadingMore = false
    @State private var showDeleteConfirmation = false
    @State private var pendingDeleteAction: DeleteAction?
    @State private var showActionFeedback = false
    @State private var actionFeedbackText: String = ""
    @State private var actionFeedbackIsError = false
    @State private var missedUpdates = false
    @State private var shareSheetText: String?
    @State private var isShareSheetPresented = false
    @State private var refreshGeneration = 0
    @State private var isLoading = false
    @State private var isViewVisible = false
    @State private var activeQueryHandle: LogQueryHandle?
    @State private var activeDeleteHandle: LogQueryHandle?
    @State private var isExportingCustomRange = false
    @State private var activeCustomExportHandle: LogQueryHandle?
    @State private var activeCustomExportID: UUID?
    @State private var pendingLargeExport: LargeCustomLogExportConfirmation?
    @State private var showLargeExportConfirmation = false
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
        .sheet(isPresented: $isShareSheetPresented, onDismiss: {
            shareSheetText = nil
        }) {
            if let shareSheetText {
                ActivityShareSheet(items: [shareSheetText])
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
        .onChange(of: expandedKeys) { _, newKeys in
            if newKeys.isEmpty { refreshGuard() }
        }
        .onChange(of: selectedIDs) { _, newIDs in
            if newIDs.isEmpty { refreshGuard() }
        }
        .onChange(of: expandedReportID) { _, newValue in
            if newValue == nil { refreshGuard() }
        }
        .onChange(of: showLargeExportConfirmation) { _, isPresented in
            if !isPresented, pendingLargeExport != nil, !isExportingCustomRange {
                cancelActiveCustomRangeExport()
            }
        }
        .onAppear {
            isViewVisible = true
            refresh()
        }
        .onDisappear {
            isViewVisible = false
            cancelActiveQuery()
            cancelActiveDelete()
            cancelActiveCustomRangeExport()
            clearLoadedLogState()
        }
        .overlay(alignment: .bottom) {
            if showActionFeedback {
                actionFeedbackOverlay
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
                    .controlSize(.small)
                    .font(.caption)
                    .frame(maxWidth: .infinity, alignment: .leading)

                    HStack {
                        Spacer()
                        Button(action: beginCustomRangeExport) {
                            HStack(spacing: 6) {
                                if isExportingCustomRange {
                                    ProgressView()
                                        .controlSize(.small)
                                } else {
                                    Image(systemName: "doc.on.doc")
                                }
                                Text(isExportingCustomRange ? "Copying…" : "Copy Range")
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .font(.caption)
                        .disabled(isExportingCustomRange || showLargeExportConfirmation)
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
                Button("Copy \(pendingLargeExport.estimate.count) Entries") {
                    confirmLargeCustomExport()
                }
            }
            Button("Cancel", role: .cancel, action: cancelActiveCustomRangeExport)
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
                if !lines.isEmpty {
                    Text("Loaded \(lines.count) in the window · \(totalCount) matching logs total")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity)
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }
                if hasOlderRows {
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
                .onAppear {
                    if idx == 0 { loadNewer() }
                }
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
        Button(action: presentLogShareSheet) {
            Image(systemName: "square.and.arrow.up")
        }
    }

    private var refreshButton: some View {
        Button(action: refresh) {
            Image(systemName: "arrow.clockwise")
        }
    }

    @ViewBuilder
    private var actionFeedbackOverlay: some View {
        if showActionFeedback {
            Text(actionFeedbackText)
                .font(.system(.subheadline, design: .monospaced))
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(actionFeedbackIsError ? Color.red.opacity(0.9) : Color.secondary.opacity(0.9))
                .foregroundColor(.white)
                .clipShape(Capsule())
                .padding(.bottom, 24)
                .transition(.opacity)
        }
    }

    // MARK: - Actions

    private func beginQuery() -> LogQueryHandle {
        cancelActiveQuery()
        let handle = makeDebugLogQueryHandle()
        activeQueryHandle = handle
        return handle
    }

    private func beginDelete() -> LogQueryHandle {
        cancelActiveQuery()
        cancelActiveDelete()
        let handle = makeDebugLogQueryHandle()
        activeDeleteHandle = handle
        return handle
    }

    private func cancelActiveQuery() {
        guard let handle = activeQueryHandle else { return }
        activeQueryHandle = nil
        handle.cancel()
    }

    private func cancelActiveDelete() {
        guard let handle = activeDeleteHandle else { return }
        activeDeleteHandle = nil
        handle.cancel()
    }

    private func clearLoadedLogState() {
        lines = []
        diagnostics = []
        crashReports = []
        selectedIDs = []
        expandedKeys = []
        newestLoadedId = nil
        newestSeenId = nil
        oldestLoadedId = nil
        hasNewerRows = false
        hasOlderRows = false
        totalCount = 0
        isLoading = false
        isLoadingMore = false
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

    private func refresh() {
        cancelActiveCustomRangeExport()
        let componentSelection = selectedComponents
        guard !componentSelection.isEmpty else {
            clearFilteredLogResults()
            return
        }

        let levels = levelFilterToSet()
        let components = componentsForQuery(componentSelection)
        let bounds = timeRangeToBounds()
        let search = searchText.isEmpty ? nil : searchText

        let handle = beginQuery()
        refreshGeneration += 1
        let gen = refreshGeneration
        isLoading = true
        isLoadingMore = false

        DispatchQueue.global(qos: .userInitiated).async {
            defer { handle.finish() }

            let recentQuery = measureDebugLogQuery(
                action: "refresh_page",
                includesFootprintDelta: true
            ) {
                LogStore.shared.recent(
                    limit: pageSize,
                    levels: levels,
                    components: components,
                    sinceNs: bounds.sinceNs,
                    untilNs: bounds.untilNs,
                    search: search,
                    cancellation: handle)
            }
            logDebugLogQueryPerformance(recentQuery.performance)
            guard !handle.isCancelled else { return }

            let countQuery = measureDebugLogQuery(action: "refresh_count") {
                LogStore.shared.count(
                    levels: levels,
                    components: components,
                    sinceNs: bounds.sinceNs,
                    untilNs: bounds.untilNs,
                    search: search,
                    cancellation: handle)
            }
            logDebugLogQueryPerformance(countQuery.performance)
            guard !handle.isCancelled else { return }

            let diagnosticsQuery = measureDebugLogQuery(action: "refresh_diagnostics") {
                LogStore.shared.recentDiagnostics(cancellation: handle)
            }
            logDebugLogQueryPerformance(diagnosticsQuery.performance)
            guard !handle.isCancelled else { return }

            let newLines = recentQuery.value
            let newCount = countQuery.value
            let newDiagnostics = diagnosticsQuery.value
            let newCrashReports = MetricKitSubscriber.loadReports()

            DispatchQueue.main.async {
                guard activeQueryHandle === handle,
                      !handle.isCancelled,
                      isViewVisible,
                      gen == refreshGeneration else {
                    if activeQueryHandle === handle {
                        activeQueryHandle = nil
                        isLoading = false
                    }
                    return
                }
                activeQueryHandle = nil
                let window = applyLogPage(
                    newLines,
                    direction: .newer,
                    replacingCurrentWindow: true,
                    matchingTotalCount: newCount
                )
                newestSeenId = window.newestCursor
                hasNewerRows = false
                hasOlderRows = newCount > window.loadedCount
                diagnostics = newDiagnostics
                crashReports = newCrashReports
                isLoading = false
            }
        }
    }

    private func presentLogShareSheet() {
        let rawText = selectedOrFilteredLines.map(\.raw).joined(separator: "\n")
        shareSheetText = scrubPII ? LogScrubber.scrub(rawText) : rawText
        isShareSheetPresented = true
    }

    private func applyLogPage(
        _ page: [LogLine],
        direction: DebugLogPageDirection,
        replacingCurrentWindow: Bool = false,
        matchingTotalCount: Int? = nil
    ) -> DebugLogWindowResult {
        let loadedLines = replacingCurrentWindow ? [] : lines
        let result = DebugLogWindowPolicy.merging(
            loadedIDs: loadedLines.compactMap(\.rowId),
            pageIDs: page.compactMap(\.rowId),
            direction: direction,
            matchingTotalCount: matchingTotalCount ?? totalCount
        )
        let residentIDSet = Set(result.rowIDs)
        let evictedLines = lines.filter {
            guard let rowId = $0.rowId else { return false }
            return !residentIDSet.contains(rowId)
        }
        for line in evictedLines {
            selectedIDs.remove(line.id)
            expandedKeys.remove(line.raw)
        }

        var linesByRowID: [Int64: LogLine] = [:]
        for line in loadedLines + page {
            if let rowId = line.rowId {
                linesByRowID[rowId] = line
            }
        }
        lines = result.rowIDs.compactMap { linesByRowID[$0] }
        newestLoadedId = result.newestCursor
        oldestLoadedId = result.oldestCursor
        totalCount = result.matchingTotalCount
        return result
    }

    @MainActor
    private func beginCustomRangeExport() {
        guard !isExportingCustomRange,
              activeCustomExportHandle == nil,
              timeRange == .custom else { return }
        let bounds = timeRangeToBounds()
        guard let sinceNs = bounds.sinceNs, let untilNs = bounds.untilNs else { return }

        let request = CustomLogExportRequest(
            sinceNs: sinceNs,
            untilNs: untilNs,
            generation: refreshGeneration,
            scrubPII: scrubPII
        )
        let handle = makeDebugLogQueryHandle()
        let exportID = UUID()
        activeCustomExportHandle = handle
        activeCustomExportID = exportID
        isExportingCustomRange = true
        DispatchQueue.global(qos: .userInitiated).async {
            let estimate: CustomLogExportEstimate
            do {
                let result = try LogStore.shared.rangeCountAndRawBytes(
                    sinceNs: request.sinceNs,
                    untilNs: request.untilNs,
                    cancellation: handle
                )
                estimate = CustomLogExportEstimate(
                    count: result.count,
                    estimatedBytes: result.estimatedBytes
                )
            } catch {
                DispatchQueue.main.async {
                    guard isCurrentCustomExport(request, exportID: exportID, handle: handle) else {
                        handle.finish()
                        return
                    }
                    finishCustomRangeExport(handle, exportID: exportID)
                    guard !handle.isCancelled else { return }
                    showCustomExportError(error)
                }
                return
            }

            DispatchQueue.main.async {
                guard isCurrentCustomExport(request, exportID: exportID, handle: handle) else {
                    handle.finish()
                    return
                }
                if estimate.count > CustomLogExportThresholds.entryCount
                    || estimate.estimatedBytes > CustomLogExportThresholds.estimatedBytes {
                    pendingLargeExport = LargeCustomLogExportConfirmation(
                        request: request,
                        estimate: estimate
                    )
                    isExportingCustomRange = false
                    showLargeExportConfirmation = true
                    return
                }
                fetchAndCopyCustomRange(request, exportID: exportID, handle: handle)
            }
        }
    }

    @MainActor
    private func confirmLargeCustomExport() {
        guard let pending = pendingLargeExport,
              let handle = activeCustomExportHandle,
              let exportID = activeCustomExportID,
              isCurrentCustomExport(pending.request, exportID: exportID, handle: handle),
              !isExportingCustomRange else { return }
        pendingLargeExport = nil
        isExportingCustomRange = true
        fetchAndCopyCustomRange(pending.request, exportID: exportID, handle: handle)
    }

    @MainActor
    private func cancelActiveCustomRangeExport() {
        let handle = activeCustomExportHandle
        activeCustomExportHandle = nil
        activeCustomExportID = nil
        pendingLargeExport = nil
        isExportingCustomRange = false
        showLargeExportConfirmation = false
        handle?.cancel()
        handle?.finish()
    }

    @MainActor
    private func fetchAndCopyCustomRange(_ request: CustomLogExportRequest,
                                         exportID: UUID,
                                         handle: LogQueryHandle) {
        DispatchQueue.global(qos: .userInitiated).async {
            var prepared: PreparedCustomLogExport
            do {
                prepared = try Self.prepareCustomLogExport(request, handle: handle)
            } catch {
                DispatchQueue.main.async {
                    guard isCurrentCustomExport(request, exportID: exportID, handle: handle) else {
                        handle.finish()
                        return
                    }
                    finishCustomRangeExport(handle, exportID: exportID)
                    guard !handle.isCancelled else { return }
                    showCustomExportError(error)
                }
                return
            }

            handle.finish()
            DispatchQueue.main.async {
                guard isCurrentCustomExport(request, exportID: exportID, handle: handle) else {
                    prepared.text.removeAll(keepingCapacity: false)
                    return
                }
                guard !handle.isCancelled else {
                    prepared.text.removeAll(keepingCapacity: false)
                    finishCustomRangeExport(handle, exportID: exportID)
                    return
                }
                copyAndDiscardCustomLogExport(&prepared)
                finishCustomRangeExport(handle, exportID: exportID)
            }
        }
    }

    @MainActor
    private func isCurrentCustomExport(_ request: CustomLogExportRequest,
                                      exportID: UUID,
                                      handle: LogQueryHandle) -> Bool {
        isViewVisible
            && request.generation == refreshGeneration
            && activeCustomExportID == exportID
            && activeCustomExportHandle === handle
            && !handle.isCancelled
    }

    nonisolated private static func prepareCustomLogExport(
        _ request: CustomLogExportRequest,
        handle: LogQueryHandle
    ) throws -> PreparedCustomLogExport {
        let footprintBeforeBytes = MemoryMonitor.currentFootprint()
        // Only the final text escapes; row and formatting intermediates drain here.
        let result = try autoreleasepool {
            let fetchStartedAt = DispatchTime.now().uptimeNanoseconds
            let entries = try LogStore.shared.exportRange(
                sinceNs: request.sinceNs,
                untilNs: request.untilNs,
                cancellation: handle
            )
            let fetchEndedAt = DispatchTime.now().uptimeNanoseconds
            guard !handle.isCancelled else { throw LogStoreError.cancelled }

            let dateFormatter = ISO8601DateFormatter()
            dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let rawText = entries
                .map { formatCustomLogExportEntry($0, dateFormatter: dateFormatter) }
                .joined(separator: "\n")
            let text = request.scrubPII ? LogScrubber.scrub(rawText) : rawText
            return (
                text: text,
                entryCount: entries.count,
                byteCount: text.utf8.count,
                fetchDurationMilliseconds: Double(fetchEndedAt - fetchStartedAt) / 1_000_000
            )
        }

        return PreparedCustomLogExport(
            text: result.text,
            entryCount: result.entryCount,
            byteCount: result.byteCount,
            fetchDurationMilliseconds: result.fetchDurationMilliseconds,
            footprintBeforeBytes: footprintBeforeBytes
        )
    }

    nonisolated private static func formatCustomLogExportEntry(
        _ entry: LogLine,
        dateFormatter: ISO8601DateFormatter
    ) -> String {
        let timestamp = entry.timestamp.map { dateFormatter.string(from: $0) } ?? "—"
        let level = entry.level.map { "[\($0.rawValue.uppercased())]" } ?? "[—]"
        let component = entry.component.map { "[\($0.rawValue)]" } ?? "[—]"
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
                    lines.append("  \(key): \(readableExportValue(value))")
                }
            }
        }
        return lines.joined(separator: "\n")
    }

    nonisolated private static func readableExportValue(_ value: Any) -> String {
        if let object = value as? [String: Any] {
            let fields = object.keys.sorted().compactMap { key in
                object[key].map { "\(key): \(readableExportValue($0))" }
            }
            return "{\(fields.joined(separator: ", "))}"
        }
        if let array = value as? [Any] {
            return "[\(array.map(readableExportValue).joined(separator: ", "))]"
        }
        if value is NSNull {
            return "null"
        }
        if let string = value as? String {
            return string
        }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return number.boolValue ? "true" : "false"
            }
            return number.stringValue
        }
        return String(describing: value)
    }

    @MainActor
    private func copyAndDiscardCustomLogExport(_ prepared: inout PreparedCustomLogExport) {
        UIPasteboard.general.string = prepared.text
        prepared.text.removeAll(keepingCapacity: false)

        let footprintAfterBytes = MemoryMonitor.currentFootprint()
        FileLogger.shared.info(.performance, "Debug log range export", payload: [
            "action": "range_export",
            "duration_ms": prepared.fetchDurationMilliseconds,
            "entry_count": prepared.entryCount,
            "byte_count": prepared.byteCount,
            "phys_footprint_before_bytes": Double(prepared.footprintBeforeBytes),
            "phys_footprint_after_bytes": Double(footprintAfterBytes),
            "phys_footprint_delta_bytes": Double(footprintAfterBytes)
                - Double(prepared.footprintBeforeBytes)
        ])
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        showActionFeedback(text: "Copied \(prepared.entryCount) entries to clipboard")
    }

    @MainActor
    private func finishCustomRangeExport(_ handle: LogQueryHandle, exportID: UUID) {
        handle.finish()
        guard activeCustomExportHandle === handle,
              activeCustomExportID == exportID else { return }
        activeCustomExportHandle = nil
        activeCustomExportID = nil
        isExportingCustomRange = false
    }

    @MainActor
    private func showCustomExportError(_ error: Error) {
        FileLogger.shared.error(.app, "Custom log export failed",
                                payload: ["error": error.localizedDescription])
        exportErrorMessage = error.localizedDescription
        showExportError = true
    }

    private func executeDelete(_ action: DeleteAction) {
        if case .crashReports = action {
            MetricKitSubscriber.clear()
            crashReports = []
            showActionFeedback(text: "Cleared crash reports", isError: false)
            return
        }

        if case .everything = action {
            MetricKitSubscriber.clear()
            crashReports = []
        }
        if case .visible = action, selectedComponents.isEmpty {
            showActionFeedback(text: "Deleted 0 logs", isError: false)
            refresh()
            return
        }

        let handle = beginDelete()
        let levels = levelFilterToSet()
        let components = componentsForQuery(selectedComponents)
        let bounds = timeRangeToBounds()
        let search = searchText.isEmpty ? nil : searchText

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let feedbackText: String
                switch action {
                case .visible:
                    let count = try LogStore.shared.deleteFiltered(
                        levels: levels,
                        components: components,
                        sinceNs: bounds.sinceNs,
                        untilNs: bounds.untilNs,
                        search: search,
                        cancellation: handle)
                    feedbackText = "Deleted \(count) logs"
                case .olderThan1Day:
                    let cutoff = Int64(
                        (Date().addingTimeInterval(-86400)).timeIntervalSince1970 * 1_000_000_000
                    )
                    let count = try LogStore.shared.deleteOlderThan(
                        tsNs: cutoff,
                        cancellation: handle
                    )
                    feedbackText = "Deleted \(count) logs"
                case .olderThan1Week:
                    let cutoff = Int64(
                        (Date().addingTimeInterval(-604800)).timeIntervalSince1970 * 1_000_000_000
                    )
                    let count = try LogStore.shared.deleteOlderThan(
                        tsNs: cutoff,
                        cancellation: handle
                    )
                    feedbackText = "Deleted \(count) logs"
                case .olderThan1Month:
                    let cutoff = Int64(
                        (Date().addingTimeInterval(-2592000)).timeIntervalSince1970 * 1_000_000_000
                    )
                    let count = try LogStore.shared.deleteOlderThan(
                        tsNs: cutoff,
                        cancellation: handle
                    )
                    feedbackText = "Deleted \(count) logs"
                case .all:
                    try LogStore.shared.clear(cancellation: handle)
                    feedbackText = "Deleted all logs"
                case .crashReports:
                    feedbackText = "Cleared crash reports"
                case .everything:
                    try LogStore.shared.clear(cancellation: handle)
                    feedbackText = "Deleted crash reports and all logs"
                }
                handle.finish()

                DispatchQueue.main.async {
                    guard activeDeleteHandle === handle else { return }
                    activeDeleteHandle = nil
                    showActionFeedback(text: feedbackText)
                    refresh()
                }
            } catch {
                handle.finish()
                DispatchQueue.main.async {
                    guard activeDeleteHandle === handle else { return }
                    activeDeleteHandle = nil
                    guard !handle.isCancelled else { return }
                    showActionFeedback(
                        text: "Delete failed — database may be corrupted; recovering…",
                        isError: true
                    )
                    refresh()
                }
            }
        }
    }

    private func showActionFeedback(text: String, isError: Bool = false) {
        actionFeedbackText = text
        actionFeedbackIsError = isError
        withAnimation { showActionFeedback = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            withAnimation { showActionFeedback = false }
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
        guard hasOlderRows else { return }
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
        let gen = refreshGeneration
        let handle = beginQuery()

        DispatchQueue.global(qos: .userInitiated).async {
            defer { handle.finish() }

            let pageQuery = measureDebugLogQuery(
                action: "load_page",
                includesFootprintDelta: true
            ) {
                LogStore.shared.recent(
                    limit: pageSize, beforeId: before,
                    levels: levels,
                    components: components,
                    sinceNs: bounds.sinceNs,
                    untilNs: bounds.untilNs,
                    search: search,
                    cancellation: handle)
            }
            let more = pageQuery.value
            logDebugLogQueryPerformance(pageQuery.performance)
            guard !handle.isCancelled else { return }

            guard !more.isEmpty else {
                DispatchQueue.main.async {
                    guard activeQueryHandle === handle else { return }
                    activeQueryHandle = nil
                    isLoadingMore = false
                    hasOlderRows = false
                }
                return
            }

            DispatchQueue.main.async {
                guard activeQueryHandle === handle,
                      !handle.isCancelled,
                      isViewVisible,
                      gen == refreshGeneration else {
                    if activeQueryHandle === handle {
                        activeQueryHandle = nil
                        isLoadingMore = false
                    }
                    return
                }
                activeQueryHandle = nil
                isLoadingMore = false
                let window = applyLogPage(more, direction: .older)
                hasOlderRows = more.count == pageSize
                hasNewerRows = hasNewerRows || !window.evictedRowIDs.isEmpty
            }
        }
    }

    private func loadNewer() {
        guard hasNewerRows else { return }
        guard !isLoadingMore, !isLoading else { return }
        guard let after = newestLoadedId else { return }

        let componentSelection = selectedComponents
        guard !componentSelection.isEmpty else {
            clearFilteredLogResults()
            return
        }
        isLoadingMore = true
        let levels = levelFilterToSet()
        let components = componentsForQuery(componentSelection)
        let bounds = timeRangeToBounds()
        let search = searchText.isEmpty ? nil : searchText
        let gen = refreshGeneration
        let handle = beginQuery()

        DispatchQueue.global(qos: .userInitiated).async {
            defer { handle.finish() }

            let pageQuery = measureDebugLogQuery(
                action: "load_newer_page",
                includesFootprintDelta: true
            ) {
                LogStore.shared.recent(
                    limit: pageSize,
                    levels: levels,
                    components: components,
                    sinceNs: bounds.sinceNs,
                    untilNs: bounds.untilNs,
                    afterId: after,
                    search: search,
                    ascending: true,
                    cancellation: handle)
            }
            let more = pageQuery.value
            logDebugLogQueryPerformance(pageQuery.performance)
            guard !handle.isCancelled else { return }

            guard !more.isEmpty else {
                DispatchQueue.main.async {
                    guard activeQueryHandle === handle else { return }
                    activeQueryHandle = nil
                    isLoadingMore = false
                    hasNewerRows = false
                }
                return
            }

            DispatchQueue.main.async {
                guard activeQueryHandle === handle,
                      !handle.isCancelled,
                      isViewVisible,
                      gen == refreshGeneration else {
                    if activeQueryHandle === handle {
                        activeQueryHandle = nil
                        isLoadingMore = false
                    }
                    return
                }
                activeQueryHandle = nil
                isLoadingMore = false
                let window = applyLogPage(more, direction: .newer)
                if let newestId = more.last?.rowId {
                    newestSeenId = max(newestSeenId ?? newestId, newestId)
                }
                hasNewerRows = more.count == pageSize
                hasOlderRows = hasOlderRows || !window.evictedRowIDs.isEmpty
            }
        }
    }

    private func incrementalRefresh() {
        cancelActiveCustomRangeExport()
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

        let handle = beginQuery()
        refreshGeneration += 1
        let gen = refreshGeneration

        DispatchQueue.global(qos: .userInitiated).async {
            defer { handle.finish() }

            let recentQuery = measureDebugLogQuery(
                action: "incremental_page",
                includesFootprintDelta: true
            ) {
                LogStore.shared.recent(
                    limit: pageSize,
                    levels: levels,
                    components: components,
                    sinceNs: bounds.sinceNs,
                    untilNs: bounds.untilNs,
                    afterId: newest,
                    search: search,
                    ascending: true,
                    cancellation: handle)
            }
            let newer = recentQuery.value
            logDebugLogQueryPerformance(recentQuery.performance)
            guard !handle.isCancelled else { return }

            var newCount: Int?
            if !newer.isEmpty {
                let countQuery = measureDebugLogQuery(action: "incremental_count") {
                    LogStore.shared.count(
                        levels: levels,
                        components: components,
                        sinceNs: bounds.sinceNs,
                        untilNs: bounds.untilNs,
                        search: search,
                        cancellation: handle)
                }
                newCount = countQuery.value
                logDebugLogQueryPerformance(countQuery.performance)
                guard !handle.isCancelled else { return }
            }

            DispatchQueue.main.async {
                guard activeQueryHandle === handle,
                      !handle.isCancelled,
                      isViewVisible,
                      gen == refreshGeneration else {
                    if activeQueryHandle === handle {
                        activeQueryHandle = nil
                        isLoading = false
                    }
                    return
                }
                activeQueryHandle = nil
                isLoading = false

                guard !newer.isEmpty else { return }

                let window = applyLogPage(
                    newer,
                    direction: .newer,
                    matchingTotalCount: newCount
                )
                if let newestId = newer.last?.rowId {
                    newestSeenId = max(newestSeenId ?? newestId, newestId)
                }
                hasNewerRows = hasNewerRows || newer.count == pageSize
                hasOlderRows = hasOlderRows || !window.evictedRowIDs.isEmpty
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
        cancelActiveQuery()
        refreshGeneration += 1
        lines = []
        newestLoadedId = nil
        newestSeenId = nil
        oldestLoadedId = nil
        hasNewerRows = false
        hasOlderRows = false
        totalCount = 0
        isLoading = false
        isLoadingMore = false
    }

    private func timeRangeToBounds() -> (sinceNs: Int64?, untilNs: Int64?) {
        switch timeRange {
        case .fiveMin:
            return (Int64((Date().timeIntervalSince1970 - 300) * 1_000_000_000), nil)
        case .fifteenMin:
            return (Int64((Date().timeIntervalSince1970 - 900) * 1_000_000_000), nil)
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
