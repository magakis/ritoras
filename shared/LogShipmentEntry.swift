import Foundation

/// Wire format for shipping log entries from the keyboard to the container
/// app's FileLogger via LocalhostServer's POST /logs endpoint.
public struct LogShipmentEntry: Codable {
    public let level: String          // "debug" | "info" | "warn" | "error"
    public let component: String      // LogComponent raw value (e.g., "Keyboard")
    public let message: String
    public let payload: [String: String]?  // stringified values (Any → String)
    public let timestamp: Date

    public init(level: LogLevel, component: LogComponent, message: String, payload: [String: Any]?) {
        self.level = level.rawValue
        self.component = component.rawValue
        self.message = message
        if let payload = payload {
            // Stringify all values — keeps wire format Codable-simple.
            self.payload = payload.mapValues { String(describing: $0) }
        } else {
            self.payload = nil
        }
        self.timestamp = Date()
    }
}
