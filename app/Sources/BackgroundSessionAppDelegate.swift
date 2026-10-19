import UIKit

final class BackgroundSessionAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        guard identifier == BackgroundTranscriptionUploader.backgroundSessionIdentifier else {
            DispatchQueue.main.async(execute: completionHandler)
            return
        }

        BackgroundTranscriptionUploader.shared.setBackgroundEventsCompletionHandler {
            completionHandler()
        }
        BackgroundTranscriptionUploader.shared.restore { _ in }
    }
}
