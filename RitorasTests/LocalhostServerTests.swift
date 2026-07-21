import XCTest
import Network
@testable import Ritoras

final class LocalhostServerTests: XCTestCase {

    private var server: LocalhostServer!

    // Stub providers
    private let stubStateSnapshot = DictationStateSnapshot(
        phase: "recording",
        activeID: "E621E1F8-C36C-495A-93FC-0C247A3E6E5F",
        startedAt: Date()
    )
    private let stubResultSnapshot = DictationResultSnapshot(
        id: "E621E1F8-C36C-495A-93FC-0C247A3E6E5F",
        status: "completed",
        text: "hello world",
        errorMessage: nil,
        timestamp: Date()
    )
    private let stubActiveID = UUID(uuidString: "E621E1F8-C36C-495A-93FC-0C247A3E6E5F")!

    override func setUp() {
        super.setUp()
        server = LocalhostServer(
            port: 0,
            stateProvider: { [weak self] in
                self?.stubStateSnapshot ?? DictationStateSnapshot(phase: "idle", activeID: nil, startedAt: nil)
            },
            resultProvider: { [weak self] id in
                id == self?.stubActiveID ? self?.stubResultSnapshot : nil
            }
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

    /// Waits for the server to bind its port (listener enters `.ready`).
    private func waitForServerReady() {
        let exp = expectation(description: "server ready")
        // Poll on the serial queue: enough for localhost binding
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
            exp.fulfill()
        }
        wait(for: [exp], timeout: 5.0)
        XCTAssertNotNil(server.actualPort, "Server should have a port after starting")
    }

    /// Sends an HTTP GET to the local server and returns status + body.
    private func fetch(_ path: String) -> (status: Int, body: Data) {
        let port = server.actualPort ?? 0
        precondition(port > 0, "Server is not bound to a port")

        let exp = expectation(description: "HTTP GET \(path)")

        let requestStr = "GET \(path) HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nConnection: close\r\n\r\n"

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
                connection.send(content: Data(requestStr.utf8), completion: .contentProcessed { _ in
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, error in
                        if let data = data, !data.isEmpty {
                            let raw = String(data: data, encoding: .utf8) ?? ""
                            let lines = raw.components(separatedBy: "\r\n")
                            // Parse status code from first line
                            if let statusLine = lines.first {
                                let parts = statusLine.components(separatedBy: " ")
                                if parts.count >= 2 {
                                    resultStatus = Int(parts[1]) ?? -1
                                }
                            }
                            // Extract body after "\r\n\r\n"
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

    func testHealthEndpointReturnsOK() throws {
        let (status, body) = fetch("/health")
        XCTAssertEqual(status, 200)
        let dict = try XCTUnwrap(json(body))
        XCTAssertEqual(dict["status"] as? String, "ok")
        XCTAssertNotNil(dict["port"] as? UInt16 ?? dict["port"] as? Int)
    }

    func testStateEndpointReturnsSnapshot() throws {
        let (status, body) = fetch("/state?id=E621E1F8-C36C-495A-93FC-0C247A3E6E5F")
        XCTAssertEqual(status, 200)
        let dict = try XCTUnwrap(json(body))
        XCTAssertEqual(dict["phase"] as? String, "recording")
        XCTAssertEqual(dict["activeID"] as? String, "E621E1F8-C36C-495A-93FC-0C247A3E6E5F")
    }

    func testStateEndpointWithoutIdReturnsActive() throws {
        let (status, body) = fetch("/state")
        XCTAssertEqual(status, 200)
        let dict = try XCTUnwrap(json(body))
        XCTAssertEqual(dict["phase"] as? String, "recording")
    }

    func testStateEndpointReturns404ForWrongId() throws {
        let (status, body) = fetch("/state?id=11111111-1111-4111-8111-111111111111")
        XCTAssertEqual(status, 404)
        let dict = try XCTUnwrap(json(body))
        XCTAssertNotNil(dict["error"])
    }

    func testResultEndpointReturnsResult() throws {
        let (status, body) = fetch("/result?id=E621E1F8-C36C-495A-93FC-0C247A3E6E5F")
        XCTAssertEqual(status, 200)
        let dict = try XCTUnwrap(json(body))
        XCTAssertEqual(dict["status"] as? String, "completed")
        XCTAssertEqual(dict["text"] as? String, "hello world")
        XCTAssertEqual(dict["id"] as? String, "E621E1F8-C36C-495A-93FC-0C247A3E6E5F")
    }

    func testResultEndpointUnknownIdReturns404() throws {
        let (status, body) = fetch("/result?id=00000000-0000-4000-8000-000000000000")
        XCTAssertEqual(status, 404)
        let dict = try XCTUnwrap(json(body))
        XCTAssertNotNil(dict["error"])
    }

    func testResultEndpointMissingIdReturns400() throws {
        let (status, body) = fetch("/result")
        XCTAssertEqual(status, 400)
        let dict = try XCTUnwrap(json(body))
        XCTAssertNotNil(dict["error"])
    }

    func testUnknownPathReturns404() throws {
        let (status, body) = fetch("/unknown")
        XCTAssertEqual(status, 404)
        let dict = try XCTUnwrap(json(body))
        XCTAssertEqual(dict["error"] as? String, "not found")
        XCTAssertEqual(dict["path"] as? String, "/unknown")
    }

    func testMalformedRequestReturns400() throws {
        let port = server.actualPort ?? 0
        precondition(port > 0)

        let exp = expectation(description: "malformed request")

        var resultStatus = -1

        let connection = NWConnection(
            host: "127.0.0.1",
            port: NWEndpoint.Port(integerLiteral: port),
            using: .tcp
        )

        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                // Send garbage — not a valid HTTP request
                connection.send(content: Data("NOT HTTP\r\n".utf8), completion: .contentProcessed { _ in
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, error in
                        if let data = data, !data.isEmpty {
                            let raw = String(data: data, encoding: .utf8) ?? ""
                            if let statusLine = raw.components(separatedBy: "\r\n").first {
                                let parts = statusLine.components(separatedBy: " ")
                                if parts.count >= 2 {
                                    resultStatus = Int(parts[1]) ?? -1
                                }
                            }
                        }
                        exp.fulfill()
                    }
                })
            case .failed:
                exp.fulfill()
            default:
                break
            }
        }

        connection.start(queue: .global())
        wait(for: [exp], timeout: 5.0)
        XCTAssertEqual(resultStatus, 400)
    }

    func testServerStopsCleanly() throws {
        // Already started in setUp — test that health works first
        let (preStatus, _) = fetch("/health")
        XCTAssertEqual(preStatus, 200)

        // Stop the server
        server.stop()

        // Wait for teardown
        Thread.sleep(forTimeInterval: 0.2)

        // After stop, connection should fail
        let port = server.actualPort ?? 0
        let exp = expectation(description: "connection refused after stop")
        var connectionSucceeded = false

        let connection = NWConnection(
            host: "127.0.0.1",
            port: NWEndpoint.Port(integerLiteral: port),
            using: .tcp
        )

        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                connectionSucceeded = true
                exp.fulfill()
            case .failed:
                connectionSucceeded = false
                exp.fulfill()
            case .waiting:
                // The listener is gone so connection will fail
                break
            default:
                break
            }
        }

        connection.start(queue: .global())
        wait(for: [exp], timeout: 5.0)
        XCTAssertFalse(connectionSucceeded, "Connecting to a stopped server should fail")
    }
}
