import SwiftUI

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

struct RawLogFileView: View {
    @State private var rawLogSnapshot = RawLogFileSnapshot.empty
    @State private var rawLogPreviewText = ""
    @State private var rawLogShareText = ""
    @State private var rawLogReadGeneration = 0
    @State private var rawLogPresentationGeneration = 0
    @State private var isLoadingRawLog = true
    @State private var isUpdatingRawLogPresentation = false
    @State private var scrubPII = true

    var body: some View {
        List {
            rawLogFileSection
        }
        .listStyle(.plain)
        .navigationTitle("Raw Log File")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(action: { scrubPII.toggle() }) {
                    Image(systemName: scrubPII
                        ? "person.crop.circle"
                        : "person.crop.circle.badge.exclamationmark")
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(action: refreshRawLog) {
                    Image(systemName: "arrow.clockwise")
                }
            }
        }
        .onChange(of: scrubPII) { _, _ in
            updateRawLogPresentation()
        }
        .onAppear {
            refreshRawLog()
        }
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
}
