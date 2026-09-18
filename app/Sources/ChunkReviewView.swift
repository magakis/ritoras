import AVFoundation
import Foundation
import SwiftUI
import UIKit

struct ChunkReviewView: View {
    let records: [ChunkReviewRecord]

    @Environment(\.dismiss) private var dismiss
    @StateObject private var audioPlayer = ChunkAudioPlayer()

    var body: some View {
        NavigationStack {
            List {
                ForEach(records, id: \.id) { record in
                    let index = records.firstIndex(where: { $0.id == record.id }) ?? 0

                    ChunkReviewCard(record: record, audioPlayer: audioPlayer)
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)

                    if index < records.count - 1 {
                        ChunkSeamPreview(
                            previousText: record.responseText,
                            nextText: records[index + 1].responseText)
                            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 4, trailing: 16))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle("Chunks")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                    .accessibilityLabel("Close chunk review")
                }
            }
            .onDisappear {
                audioPlayer.stop()
            }
        }
    }
}

@MainActor
final class ChunkAudioPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var playingID: UInt32?

    private var audioPlayer: AVAudioPlayer?

    // The player is a TRANSIENT owner of the shared AVAudioSession — configure on
    // play, deactivate on every end path. The recorder assumes an inactive session
    // at start; leaving .playback active traps AudioToolboxCore on the record
    // transition (crash build 316).

    func toggle(recordID: UInt32, url: URL) {
        if playingID == recordID {
            stop()
            return
        }

        stop()

        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.delegate = self
            audioPlayer = player
            playingID = recordID

            guard player.prepareToPlay() else {
                stop()
                return
            }

            guard configureAudioSession() else {
                stop()
                return
            }

            guard player.play() else {
                stop()
                return
            }
        } catch {
            stop()
        }
    }

    func stop() {
        audioPlayer?.stop()
        audioPlayer = nil
        playingID = nil
        deactivateAudioSession()
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        MainActor.assumeIsolated { [weak self] in
            guard let self, self.audioPlayer === player else { return }

            self.audioPlayer = nil
            self.playingID = nil
            self.deactivateAudioSession()
        }
    }

    private func configureAudioSession() -> Bool {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setActive(true)
            return true
        } catch {
            return false
        }
    }

    private func deactivateAudioSession() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    deinit {
        audioPlayer?.stop()
        if audioPlayer != nil {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }
}

private struct ChunkReviewCard: View {
    let record: ChunkReviewRecord
    @ObservedObject var audioPlayer: ChunkAudioPlayer

    private var responseText: String? {
        guard let responseText = record.responseText,
              !responseText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return responseText
    }

    private var audioURL: URL? {
        guard let url = record.audioURL,
              FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        return url
    }

    private var reasonLabel: String {
        record.reason.isEmpty ? "unknown" : record.reason
    }

    private var reasonColor: Color {
        switch record.reason.lowercased() {
        case "endpoint":
            return .green
        case "flush", "stop":
            return .secondary
        case "pause":
            return .orange
        default:
            return .secondary
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("Chunk \(record.index + 1)")
                    .font(.headline)

                Text(reasonLabel)
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundStyle(reasonColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(reasonColor.opacity(0.16), in: Capsule())
                    .accessibilityLabel("Dispatch reason \(reasonLabel)")

                Spacer(minLength: 4)

                if record.sentAt == nil {
                    Text("not sent")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color(.systemGray5), in: Capsule())
                        .accessibilityLabel("Not sent")
                }
            }

            HStack(spacing: 8) {
                statItem(title: "duration", value: millisecondsString(record.totalMs))

                Spacer(minLength: 4)

                statItem(title: "silence at cut", value: millisecondsString(record.silenceMs))

                Spacer(minLength: 4)

                statItem(title: "ends at", value: offsetString(record.offsetMsFromStart))
            }

            HStack(alignment: .top, spacing: 12) {
                Text(responseText ?? "no response yet")
                    .font(.body)
                    .foregroundColor(responseText == nil ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if let audioURL {
                    Button {
                        audioPlayer.toggle(recordID: record.id, url: audioURL)
                    } label: {
                        Image(systemName: audioPlayer.playingID == record.id ? "stop.fill" : "play.fill")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityLabel(
                        audioPlayer.playingID == record.id
                            ? "Stop Chunk \(record.index + 1)"
                            : "Play Chunk \(record.index + 1)"
                    )
                }
            }
        }
        .padding(14)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    private func statItem(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Text(value)
                .font(.caption)
                .fontWeight(.medium)
                .monospacedDigit()
                .lineLimit(1)
        }
    }

    private func millisecondsString(_ milliseconds: Double) -> String {
        String(format: "%.0f ms", milliseconds)
    }

    private func offsetString(_ milliseconds: Double) -> String {
        let totalSeconds = max(0, Int(milliseconds / 1000.0))
        return String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
    }
}

private struct ChunkSeamPreview: View {
    let previousText: String?
    let nextText: String?

    private var previousWords: String {
        seamWords(previousText, takingLast: true)
    }

    private var nextWords: String {
        seamWords(nextText, takingLast: false)
    }

    var body: some View {
        Text("…\(previousWords) → \(nextWords)…")
            .font(.caption)
            .italic()
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .accessibilityLabel("Seam preview: \(previousWords) to \(nextWords)")
    }
}

private func seamWords(_ text: String?, takingLast: Bool) -> String {
    guard let text,
          !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return "—"
    }

    let words = text.split { character in
        character.isWhitespace
    }
    let edgeWords = takingLast ? words.suffix(3) : words.prefix(3)
    return edgeWords.joined(separator: " ")
}
