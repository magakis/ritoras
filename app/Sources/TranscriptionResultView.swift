import SwiftUI
import UIKit

/// Reusable transcription-result surface. Shown after a fresh recording
/// completes (DictationView `.done` phase) and after a successful retry from
/// RecoveryView. Owns the checkmark, the transcribed-text scroll view, and the
/// Copy Text + Done actions.
struct TranscriptionResultView: View {
    let text: String
    var onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 72))
                .foregroundColor(.green)

            Text("Done!")
                .font(.largeTitle)
                .fontWeight(.bold)

            ScrollView {
                Text(text)
                    .font(.body)
                    .textSelection(.enabled)
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .frame(maxHeight: 250)

            Button {
                UIPasteboard.general.string = text
            } label: {
                Label("Copy Text", systemImage: "doc.on.doc")
            }
            .buttonStyle(.bordered)

            Button("Done") {
                onDismiss()
            }
            .buttonStyle(.borderedProminent)
        }
    }
}
