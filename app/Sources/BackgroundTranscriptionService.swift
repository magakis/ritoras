import Foundation
import UIKit

/// Transcribes audio via a **background `URLSession`** so the upload to the
/// Whisper server completes even when iOS suspends or kills the container app
/// mid-flight (Scenario B: the user switches away before transcription finishes).
///
/// `nsurlsessiond` performs the transfer out-of-process. When it finishes, iOS
/// relaunches/foregrounds the app and delivers the result to this service's
/// delegate, which writes the transcription to the clipboard (the tagged payload
/// the keyboard auto-reads), the App Group payload, history, posts a Darwin
/// notification (wakes a live keyboard), and an in-process notification (updates
/// the foreground UI via `DictationViewModel`).
///
/// This is decoupled from the `DictationViewModel` so it works even if the app
/// is relaunched cold in the background to deliver a result.
final class BackgroundTranscriptionService: NSObject {

    static let shared = BackgroundTranscriptionService()

    /// Stable identifier for the background session (must be constant across
    /// launches so nsurlsessiond reconnects and delivers pending callbacks).
    static let identifier = "com.ritoras.whisper-background"

    private static let pasteboardType = "org.ritoras.dictation"

    /// Captured by the AppDelegate when iOS relaunches the app; called once all
    /// background session events have been delivered.
    var backgroundCompletionHandler: (() -> Void)?

    private var session: URLSession!
    /// Response bytes per task (keyed by `taskIdentifier`). Touched only on the
    /// session's serial delegate queue, so no locking is needed.
    private var responseData: [Int: Data] = [:]

    private override init() {
        super.init()
        let config = URLSessionConfiguration.background(withIdentifier: Self.identifier)
        config.isDiscretionary = false          // don't defer, even when foreground
        config.sessionSendsLaunchEvents = true   // allow system to relaunch the app
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    /// Reconnect the background session after the system relaunches the app to
    /// deliver pending events. Accessing the lazy session re-binds it.
    func reconnect() { _ = session }

    /// Starts a background upload of `audioURL` to the Whisper server. Returns
    /// immediately; the result is delivered via the delegate callbacks.
    func transcribe(audioURL: URL, id: UUID, config: SharedConfig) {
        // Background URLSession transfers run inside nsurlsessiond, which does NOT
        // route through Tailscale — so it cannot reach Tailscale-only hosts
        // (100.64.0.0/10 CGNAT). Prefer the first configured server that isn't a
        // Tailscale address; fall back to the first configured server otherwise.
        // The server list is user-configurable in Settings.
        let server = config.servers.first(where: { !Self.isTailscaleAddress($0) })
            ?? config.servers.first
        guard let server else {
            deliver(id: id, status: "error", text: nil, errorMessage: "No server configured.")
            return
        }
        let base = server.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let boundary = "Boundary-\(UUID().uuidString)"

        let bodyURL: URL
        do {
            bodyURL = try WhisperClient.writeMultipartBodyToFile(
                baseURL: base, audioURL: audioURL, boundary: boundary
            )
        } catch {
            deliver(id: id, status: "error", text: nil, errorMessage: error.localizedDescription)
            return
        }

        guard let url = URL(string: "\(base)/transcribe") else {
            deliver(id: id, status: "error", text: nil, errorMessage: "Invalid server URL.")
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = config.timeoutSeconds

        print("🌐 [BG] starting background upload for \(id.uuidString) -> \(url.absoluteString)")
        let task = session.uploadTask(with: request, fromFile: bodyURL)
        task.taskDescription = id.uuidString
        task.resume()
    }

    /// Tailscale uses the 100.64.0.0/10 CGNAT range, which nsurlsessiond cannot
    /// route to. Used to pick a background-upload target nsurlsessiond can reach.
    private static func isTailscaleAddress(_ server: String) -> Bool {
        guard let host = URL(string: server)?.host else { return false }
        return host.hasPrefix("100.")
    }
}

// MARK: - URLSessionDataDelegate

extension BackgroundTranscriptionService: URLSessionDataDelegate {

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        responseData[dataTask.taskIdentifier, default: Data()].append(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let id = UUID(uuidString: task.taskDescription ?? "") ?? UUID()
        let data = responseData.removeValue(forKey: task.taskIdentifier) ?? Data()

        if let error = error {
            print("🌐 [BG] \(id.uuidString) failed: \(error.localizedDescription)")
            deliver(id: id, status: "error", text: nil, errorMessage: error.localizedDescription)
            return
        }
        guard let http = task.response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (task.response as? HTTPURLResponse)?.statusCode ?? -1
            print("🌐 [BG] \(id.uuidString) HTTP \(code)")
            deliver(id: id, status: "error", text: nil, errorMessage: "Server returned HTTP \(code).")
            return
        }

        let text = Self.parse(data: data)
        if text.isEmpty {
            print("🌐 [BG] \(id.uuidString) empty result")
            deliver(id: id, status: "error", text: nil, errorMessage: "Nothing was heard. Try again.")
        } else {
            print("🌐 [BG] \(id.uuidString) transcribed: \(text)")
            deliver(id: id, status: "completed", text: text, errorMessage: nil)
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async { [weak self] in
            self?.backgroundCompletionHandler?()
            self?.backgroundCompletionHandler = nil
        }
    }

    // MARK: - Result delivery

    /// Writes the result to every delivery channel. Runs on the main thread
    /// (UIPasteboard requires it), blocking the delegate queue via `main.sync`
    /// so the write completes before iOS is allowed to suspend us again.
    private func deliver(id: UUID, status: String, text: String?, errorMessage: String?) {
        func work() {
            var payload: [String: Any] = [
                "source": "ritoras",
                "id": id.uuidString,
                "status": status,
                "timestamp": Date().timeIntervalSince1970,
            ]
            if let text = text { payload["text"] = text }
            if let errorMessage = errorMessage { payload["errorMessage"] = errorMessage }

            // Clipboard (tagged multi-type) — primary channel under SideStore.
            if let jsonData = try? JSONSerialization.data(withJSONObject: payload) {
                var item: [String: Any] = [Self.pasteboardType: jsonData]
                if status == "completed", let text = text, !text.isEmpty {
                    item["public.utf8-plain-text"] = text
                }
                UIPasteboard.general.setItems([item], options: [:])
            }

            // App Group payload (for App Store builds where the group is shared).
            let st: DictationPayload.Status = (status == "completed") ? .completed
                : (status == "error") ? .error : .cancelled
            DictationPayload(id: id, status: st, text: text, errorMessage: errorMessage, timestamp: Date()).save()

            // History (app-local).
            if status == "completed", let text = text, !text.isEmpty {
                TranscriptionHistory.shared.add(text: text)
            }

            // Darwin notification — wakes a live keyboard immediately.
            DarwinNotifier.post(SharedConfig.Defaults.darwinNotificationName)

            // In-process notification — updates the foreground DictationView UI.
            NotificationCenter.default.post(name: .dictationResultReady, object: nil, userInfo: [
                "id": id,
                "status": status,
                "text": text ?? "",
                "errorMessage": errorMessage ?? "",
            ])
        }
        if Thread.isMainThread { work() } else { DispatchQueue.main.sync(execute: work) }
    }

    private static func parse(data: Data) -> String {
        if let decoded = try? JSONDecoder().decode(WhisperResponse.self, from: data), decoded.success {
            return decoded.transcription
        }
        if let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !text.isEmpty
        {
            return text
        }
        return ""
    }
}

extension Notification.Name {
    static let dictationResultReady = Notification.Name("ritoras.dictationResultReady")
}
