import Foundation
import Darwin

/// Observes a directory for file-system write events using a `DispatchSource`
/// file-system object source configured with the `.write` event mask.
///
/// ## Why directory-watch, not per-file watch
/// Atomic writes (`.atomic`) replace the file via temp + rename, which
/// invalidates any per-file file descriptor. Watching the parent directory
/// is immune to this — the rename event fires on the directory's FD.
///
/// ## Memory footprint
/// This watcher holds one directory FD (via `O_EVTONLY`), one `DispatchSource`,
/// and a closure reference. Total overhead is ~1 KB. Combined with a
/// `TranscriptionInbox` instance, the pair remains well under the keyboard
/// extension's 48 MB Jetsam cap.
///
/// ## Important: file presenters prohibited
/// This uses `DispatchSource`, NOT `NSFilePresenter`. Apple documents that an
/// extension may be terminated to prevent deadlock if backgrounded with an
/// active file presenter. `DispatchSource` is safe for extension use.
///
/// ## Usage
/// ```swift
/// let watcher = InboxWatcher(directoryURL: inbox.inboxDirectoryURL) {
///     // Something changed in the inbox directory
/// }
/// watcher.start()
/// // ... later ...
/// watcher.stop()
/// ```
public final class InboxWatcher {
    private let directoryURL: URL
    private let onChange: () -> Void
    private let queue: DispatchQueue

    private var fd: Int32 = -1
    private var source: DispatchSourceFileSystemObject?
    private var isStarted: Bool = false
    private let lock = NSLock()

    /// Creates a watcher that monitors `directoryURL` for write events.
    ///
    /// - Parameters:
    ///   - directoryURL: The directory to watch (typically the inbox directory).
    ///   - onChange: Closure invoked on the internal serial queue when a write
    ///     event is observed. This closure must be thread-safe and should not
    ///     block for extended periods.
    public init(directoryURL: URL, onChange: @escaping () -> Void) {
        self.directoryURL = directoryURL
        self.onChange = onChange
        self.queue = DispatchQueue(label: "com.ritoras.inbox-watcher", qos: .utility)
    }

    deinit {
        stop()
    }

    /// Opens the directory FD and begins delivering events.
    ///
    /// Calling `start()` multiple times is safe — only the first call has effect.
    public func start() {
        lock.lock()
        defer { lock.unlock() }
        guard !isStarted else { return }
        isStarted = true

        let path = directoryURL.path
        fd = open(path, O_EVTONLY)
        guard fd >= 0 else {
            FileLogger.shared.error(.transcription, "InboxWatcher: failed to open directory \(path) (errno=\(errno))")
            isStarted = false
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: .write,
            queue: queue
        )
        self.source = source

        source.setEventHandler { [weak self] in
            self?.onChange()
        }

        source.setCancelHandler { [fd] in
            close(fd)
        }

        source.resume()
    }

    /// Cancels the dispatch source (which triggers the cancel handler closing
    /// the FD). Safe to call multiple times or before `start()`.
    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        guard isStarted, let source = source, !source.isCancelled else { return }
        isStarted = false
        source.cancel()
        self.source = nil
        fd = -1
    }
}
