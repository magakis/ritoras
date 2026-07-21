import XCTest
@testable import Ritoras

// MARK: - Mock URLProtocol

final class MockURLProtocol: URLProtocol {
    static var handler: ((URLRequest) -> (HTTPURLResponse, Data)?)?

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler,
              let (response, data) = handler(request) else {
            // No handler set or handler returned nil → simulate connection refused
            let error = URLError(.cannotConnectToHost)
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

// MARK: - Test Helpers

extension HTTPURLResponse {
    convenience init(statusCode: Int) {
        self.init(
            url: URL(string: "http://127.0.0.1:47321/test")!,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
    }
}

// MARK: - Tests

final class LocalhostClientTests: XCTestCase {

    private let testID = UUID(uuidString: "E621E1F8-C36C-495A-93FC-0C247A3E6E5F")!
    private let testIDString = "E621E1F8-C36C-495A-93FC-0C247A3E6E5F"

    /// Creates a mock URLSession with `MockURLProtocol` registered.
    /// Optionally configures a short timeout for timeout tests.
    private func makeMockSession(timeout: TimeInterval = 60) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout + 1
        return URLSession(configuration: config)
    }

    override func setUp() {
        super.setUp()
        MockURLProtocol.handler = nil
    }

    override func tearDown() {
        MockURLProtocol.handler = nil
        LocalhostClient._testSession = nil
        super.tearDown()
    }

    // MARK: - Happy Path

    func testGetStateHappyPath() async throws {
        let snapshot = DictationStateSnapshot(
            phase: "recording",
            activeID: testIDString,
            startedAt: Date()
        )
        let data = try JSONEncoder().encode(snapshot)

        MockURLProtocol.handler = { request in
            XCTAssertTrue(request.url?.absoluteString.contains("/state") == true)
            return (HTTPURLResponse(statusCode: 200), data)
        }

        LocalhostClient._testSession = makeMockSession()
        let result = try await LocalhostClient.getState(id: testID)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.phase, "recording")
        XCTAssertEqual(result?.activeID, testIDString)
    }

    func testGetResultHappyPath() async throws {
        let resultSnapshot = DictationResultSnapshot(
            id: testIDString,
            status: "completed",
            text: "hello world",
            errorMessage: nil,
            timestamp: Date()
        )
        let data = try JSONEncoder().encode(resultSnapshot)

        MockURLProtocol.handler = { request in
            XCTAssertTrue(request.url?.absoluteString.contains("/result") == true)
            return (HTTPURLResponse(statusCode: 200), data)
        }

        LocalhostClient._testSession = makeMockSession()
        let result = try await LocalhostClient.getResult(id: testID)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.status, "completed")
        XCTAssertEqual(result?.text, "hello world")
        XCTAssertEqual(result?.id, testIDString)
    }

    // MARK: - Health Check

    func testHealthCheckTrue() async {
        MockURLProtocol.handler = { request in
            XCTAssertTrue(request.url?.absoluteString.contains("/health") == true)
            let data = Data("{\"status\":\"ok\"}".utf8)
            return (HTTPURLResponse(statusCode: 200), data)
        }

        LocalhostClient._testSession = makeMockSession()
        let healthy = await LocalhostClient.healthCheck()
        XCTAssertTrue(healthy)
    }

    func testHealthCheckFalse() async {
        // No handler → connection refused
        LocalhostClient._testSession = makeMockSession()
        let healthy = await LocalhostClient.healthCheck()
        XCTAssertFalse(healthy)
    }

    // MARK: - Connection Errors

    func testGetStateConnectionRefused() async {
        // No handler → connection refused
        LocalhostClient._testSession = makeMockSession()
        do {
            _ = try await LocalhostClient.getState(id: testID)
            XCTFail("Expected connectionRefused error")
        } catch LocalhostClient.LocalhostError.connectionRefused {
            // Expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testGetResultConnectionRefused() async {
        LocalhostClient._testSession = makeMockSession()
        do {
            _ = try await LocalhostClient.getResult(id: testID)
            XCTFail("Expected connectionRefused error")
        } catch LocalhostClient.LocalhostError.connectionRefused {
            // Expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testGetStateTimeout() async {
        MockURLProtocol.handler = { _ in
            // Simulate timeout by sleeping past the short request timeout
            Thread.sleep(forTimeInterval: 0.5)
            return nil
        }

        LocalhostClient._testSession = makeMockSession(timeout: 0.1)
        do {
            _ = try await LocalhostClient.getState(id: testID)
            XCTFail("Expected timeout error")
        } catch LocalhostClient.LocalhostError.timeout {
            // Expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // MARK: - HTTP Errors

    func testGetResultNotFound() async {
        MockURLProtocol.handler = { request in
            XCTAssertTrue(request.url?.absoluteString.contains("/result") == true)
            let data = Data("{\"error\":\"not found\"}".utf8)
            return (HTTPURLResponse(statusCode: 404), data)
        }

        LocalhostClient._testSession = makeMockSession()
        do {
            _ = try await LocalhostClient.getResult(id: testID)
            XCTFail("Expected notFound error")
        } catch LocalhostClient.LocalhostError.notFound {
            // Expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testInvalidResponse500() async {
        MockURLProtocol.handler = { request in
            XCTAssertTrue(request.url?.absoluteString.contains("/state") == true)
            let data = Data("{\"error\":\"internal\"}".utf8)
            return (HTTPURLResponse(statusCode: 500), data)
        }

        LocalhostClient._testSession = makeMockSession()
        do {
            _ = try await LocalhostClient.getState(id: testID)
            XCTFail("Expected invalidResponse error")
        } catch LocalhostClient.LocalhostError.invalidResponse {
            // Expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // MARK: - Decode Errors

    func testMalformedJSON() async {
        MockURLProtocol.handler = { request in
            XCTAssertTrue(request.url?.absoluteString.contains("/state") == true)
            let data = Data("{invalid json}".utf8)
            return (HTTPURLResponse(statusCode: 200), data)
        }

        LocalhostClient._testSession = makeMockSession()
        do {
            _ = try await LocalhostClient.getState(id: testID)
            XCTFail("Expected malformedJSON error")
        } catch LocalhostClient.LocalhostError.malformedJSON {
            // Expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // MARK: - Idempotency & nil ID

    func testGetStateWithoutId() async {
        let snapshot = DictationStateSnapshot(
            phase: "idle",
            activeID: nil,
            startedAt: nil
        )
        let data = try! JSONEncoder().encode(snapshot)

        MockURLProtocol.handler = { request in
            // No id query param
            XCTAssertFalse(request.url?.query?.contains("id=") == true)
            return (HTTPURLResponse(statusCode: 200), data)
        }

        LocalhostClient._testSession = makeMockSession()
        let result = try await LocalhostClient.getState(id: nil)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.phase, "idle")
        XCTAssertNil(result?.activeID)
    }

    func testGetStateNotFoundReturnsNil() async {
        // 404 from /state should return nil, not throw
        MockURLProtocol.handler = { request in
            XCTAssertTrue(request.url?.absoluteString.contains("/state") == true)
            let data = Data("{\"error\":\"not found\"}".utf8)
            return (HTTPURLResponse(statusCode: 404), data)
        }

        LocalhostClient._testSession = makeMockSession()
        let result = try await LocalhostClient.getState(id: testID)
        XCTAssertNil(result)
    }

    // MARK: - Error property checks

    func testErrorEquality() {
        XCTAssertNotEqual(
            LocalhostClient.LocalhostError.connectionRefused,
            LocalhostClient.LocalhostError.timeout
        )
        XCTAssertEqual(
            LocalhostClient.LocalhostError.notFound,
            LocalhostClient.LocalhostError.notFound
        )
    }
}
