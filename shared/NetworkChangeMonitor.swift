import Foundation
import Network

/// Process-lifetime network path monitor that resets the Whisper URLSession
/// on network changes (VPN toggle, Wi-Fi ↔ cellular, etc.). Uses a lock-guarded
/// singleton to avoid MainActor isolation hazards — the NWPathMonitor callback
/// touches only `SessionHolder` (Sendable), never a `@MainActor`-isolated object.
///
/// This is the fix for the stuck-transcribing bug where the user must toggle VPN
/// to recover: the old URLSession's connections stall on the defunct path, and
/// a fresh session establishes connections on the new path.
final class NetworkChangeMonitor {
    static let shared = NetworkChangeMonitor()

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "ritoras.network-monitor", qos: .utility)
    private var started = false
    private let startedLock = NSLock()

    /// Last path signature for change detection: (status, sorted unique interface types).
    /// Read and written only on the monitor's serial queue — no lock needed.
    private var lastPathSignature: (NWPath.Status, [NWInterface.InterfaceType])?

    private init() {}

    /// Starts the monitor. Idempotent — safe to call multiple times (e.g. from
    /// both the keyboard and container app launch hooks). The singleton is
    /// process-lifetime; do NOT tear down on hide/deinit.
    func start() {
        startedLock.lock(); defer { startedLock.unlock() }
        guard !started else { return }
        started = true

        monitor.pathUpdateHandler = { [weak self] path in
            self?.handle(path)
        }
        monitor.start(queue: queue)

        FileLogger.shared.info(.network, "network change monitor started", payload: [
            "footprintBytes": MemoryMonitor.currentFootprint()
        ])
    }

    private func handle(_ path: NWPath) {
        let interfaceTypes = Set(path.availableInterfaces.map { $0.type })
            .sorted { $0.rawValue < $1.rawValue }
        let signature = (path.status, interfaceTypes)

        if let previous = lastPathSignature, previous == signature {
            return
        }
        lastPathSignature = signature

        SessionHolder.shared.reset()
        FileLogger.shared.info(.network, "network path changed, session reset", payload: [
            "status": String(describing: path.status),
            "interfaces": path.availableInterfaces.map { String(describing: $0.type) }
        ])
    }
}
