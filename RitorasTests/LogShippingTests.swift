import XCTest
import Network
@testable import Ritoras

final class LogShippingTests: XCTestCase {

    private var server: LocalhostServer!

    // Stub providers (unused by POST /logs but required by init)
    private let stubStateSnapshot = DictationStateSnapshot(
        phase: "idle",
        activeID: nil,
        startedAt: nil
    )
    private let stubResultSnapshot = DictationResultSnapshot(
        id: "00000000-0000-4000-8000-000000000000",
        status: "idle",
        text: nil,
        errorMessage: nil,
        timestamp: Date()
    )

    override func setUp() {
        super.setUp()
        server = LocalhostServer(
            port: 0,
            stateProvider: { [weak self] in
                self?.stubStateSnapshot ?? DictationStateSnapshot(phase: "idle", activeID: nil, startedAt: nil)
            },
            resultProvider: { _ in nil }
        )
        try? server.start()
        waitForServerReady()
    }

    override func tearDown() {
        server?.stop()
        server = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func waitForServerReady() {
        let exp = expectation(description: "server ready")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
            exp.fulfill()
        }
        wait(for: [exp], timeout: 5.0)
        XCTAssertNotNil(server.actualPort, "Server should have a port after starting")
    }

    /// Sends an HTTP POST to the local server and returns status + body.
    private func post(_ path: String, contentType: String, body: Data) -> (status: Int, body: Data) {
        let port = server.actualPort ?? 0
        precondition(port > 0, "Server is not bound to a port")

        let exp = expectation(description: "HTTP POST \(path)")

        let headerStr = "POST \(path) HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        var allData = Data(headerStr.utf8)
        allData.append(body)

        var resultStatus = -1
        var resultBody = Data()

        let connection = NWConnection(
            host: "127.0.0.1",
            port: NWEndpoint.Port(integerLiteral: port),
            using: .tcp
        )

        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                connection.send(content: allData, completion: .contentProcessed { _ in
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, error in
                        if let data = data, !data.isEmpty {
                            let raw = String(data: data, encoding: .utf8) ?? ""
                            let lines = raw.components(separatedBy: "\r\n")
                            if let statusLine = lines.first {
                                let parts = statusLine.components(separatedBy: " ")
                                if parts.count >= 2 {
                                    resultStatus = Int(parts[1]) ?? -1
                                }
                            }
                            if let bodyRange = raw.range(of: "\r\n\r\n") {
                                let bodyStr = raw[bodyRange.upperBound...]
                                resultBody = Data(bodyStr.utf8)
                            }
                        }
                        exp.fulfill()
                    }
                })
            case .failed:
                resultStatus = -1
                exp.fulfill()
            default:
                break
            }
        }

        connection.start(queue: .global())
        wait(for: [exp], timeout: 5.0)
        return (resultStatus, resultBody)
    }

    /// Decodes the response body as a JSON dictionary.
    private func json(_ data: Data) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    // MARK: - Tests

    func testLogShipmentEntryEncodingDecoding() throws {
        let entry = LogShipmentEntry(
            level: .warn,
            component: .keyboard,
            message: "test warning",
            payload: ["key": "value"]
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(entry)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(LogShipmentEntry.self, from: data)

        XCTAssertEqual(decoded.level, "warn")
        XCTAssertEqual(decoded.component, "Keyboard")
        XCTAssertEqual(decoded.message, "test warning")
        XCTAssertEqual(decoded.payload?["key"], "value")
        // Timestamps should be within 1 second
        XCTAssertLessThan(abs(decoded.timestamp.timeIntervalSince(entry.timestamp)), 1.0)
    }

    func testPostLogsEndpointAcceptsEntries() throws {
        let entries: [[String: Any]] = [
            ["level": "info", "component": "Keyboard", "message": "entry 1", "timestamp": ISO8601DateFormatter().string(from: Date())],
            ["level": "warn", "component": "Keyboard", "message": "entry 2", "timestamp": ISO8601DateFormatter().string(from: Date())]
        ]
        let wrapper: [String: Any] = ["entries": entries]
        let body = try JSONSerialization.data(withJSONObject: wrapper)

        let (status, responseBody) = post("/logs", contentType: "application/json", body: body)
        XCTAssertEqual(status, 200)
        let dict = try XCTUnwrap(json(responseBody))
        XCTAssertEqual(dict["received"] as? Int, 2)
    }

    func testPostLogsEndpointMalformedBodyReturns400() throws {
        let body = Data("not valid json".utf8)
        let (status, responseBody) = post("/logs", contentType: "application/json", body: body)
        XCTAssertEqual(status, 400)
        let dict = try XCTUnwrap(json(responseBody))
        XCTAssertNotNil(dict["error"])
    }

    func testPostLogsEndpointEmptyArrayReturns200() throws {
        let wrapper: [String: Any] = ["entries": []]
        let body = try JSONSerialization.data(withJSONObject: wrapper)

        let (status, responseBody) = post("/logs", contentType: "application/json", body: body)
        XCTAssertEqual(status, 200)
        let dict = try XCTUnwrap(json(responseBody))
        XCTAssertEqual(dict["received"] as? Int, 0)
    }

    func testLogShipmentEntryStringifiesNonStringPayloadValues() throws {
        // Mixed payload: Int, Bool, String
        let payload: [String: Any] = [
            "intValue": 42,
            "boolValue": true,
            "stringValue": "hello"
        ]
        let entry = LogShipmentEntry(
            level: .info,
            component: .app,
            message: "mixed payload test",
            payload: payload
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(entry)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(LogShipmentEntry.self, from: data)

        // All values should be strings after encoding
        XCTAssertEqual(decoded.payload?["intValue"], "42")
        XCTAssertEqual(decoded.payload?["boolValue"], "true")
        XCTAssertEqual(decoded.payload?["stringValue"], "hello")
        XCTAssertEqual(decoded.component, "ContainerApp")
    }

    func testPostLogsUnknownPathReturns404() throws {
        let body = Data("{\"entries\":[]}".utf8)
        let (status, responseBody) = post("/unknown", contentType: "application/json", body: body)
        XCTAssertEqual(status, 404)
        let dict = try XCTUnwrap(json(responseBody))
        XCTAssertEqual(dict["error"] as? String, "not found")
    }
}
