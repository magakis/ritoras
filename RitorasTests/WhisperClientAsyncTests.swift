import XCTest
@testable import Ritoras

// MARK: - Async Transcription Tests

final class WhisperClientAsyncTests: XCTestCase {

    private let testJobId = UUID(uuidString: "E621E1F8-C36C-495A-93FC-0C247A3E6E5F")!
    private let mockServer = "http://mock.ritoras"

    /// Temporary audio file used by buildBody in async tests.
    private var tempAudioURL: URL!

    override func setUp() {
        super.setUp()
        MockURLProtocol.handler = nil
        WhisperClient._testSession = nil

        // Create a minimal valid audio file for buildBody to read.
        let tempDir = FileManager.default.temporaryDirectory
        tempAudioURL = tempDir.appendingPathComponent("\(UUID().uuidString).m4a")
        // Write at least one byte so Data(contentsOf:) succeeds.
        FileManager.default.createFile(atPath: tempAudioURL.path, contents: Data("test audio".utf8))
    }

    override func tearDown() {
        MockURLProtocol.handler = nil
        WhisperClient._testSession = nil
        try? FileManager.default.removeItem(at: tempAudioURL)
        super.tearDown()
    }

    private func makeMockSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 60
        return URLSession(configuration: config)
    }

    private var defaultConfig: SharedConfig {
        SharedConfig(servers: [mockServer], timeoutSeconds: 30)
    }

    // MARK: - Happy Path

    func test_transcribeAsync_happyPath_returnsText() async throws {
        let jobId = testJobId
        var pollCount = 0

        MockURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            let method = request.httpMethod ?? "GET"

            // Health check — selectFirstHealthyServer calls checkHealth.
            if path == "/health" || path == "/" {
                return (HTTPURLResponse(statusCode: 200), Data())
            }

            // Submit
            if method == "POST" && path == "/transcriptions" {
                let body = """
                {"job_id": "\(jobId.uuidString)", "status_endpoint": "/jobs/\(jobId.uuidString)"}
                """
                return (HTTPURLResponse(statusCode: 202), Data(body.utf8))
            }

            // Poll
            if path == "/jobs/\(jobId.uuidString)" {
                pollCount += 1
                let response: String
                if pollCount <= 2 {
                    response = """
                    {"status": "pending", "text": null, "revision": \(pollCount)}
                    """
                } else {
                    response = """
                    {"status": "ready", "text": "hello world this is a test transcription. ", "revision": \(pollCount)}
                    """
                }
                return (HTTPURLResponse(statusCode: 200), Data(response.utf8))
            }

            return nil
        }

        WhisperClient._testSession = makeMockSession()
        let text = try await WhisperClient.transcribeAsync(
            audioURL: tempAudioURL,
            jobId: jobId,
            config: defaultConfig,
            correlationId: jobId
        )
        XCTAssertEqual(text, "hello world this is a test transcription. ")
        XCTAssertGreaterThanOrEqual(pollCount, 3, "Expected at least 3 polls (pending→pending→ready)")
    }

    // MARK: - Job Failed

    func test_transcribeAsync_jobFailed_throws() async {
        let jobId = testJobId

        MockURLProtocol.handler = { request in
            let path = request.url?.path ?? ""

            if path == "/health" || path == "/" {
                return (HTTPURLResponse(statusCode: 200), Data())
            }

            if request.httpMethod == "POST" && path == "/transcriptions" {
                let body = """
                {"job_id": "\(jobId.uuidString)", "status_endpoint": "/jobs/\(jobId.uuidString)"}
                """
                return (HTTPURLResponse(statusCode: 202), Data(body.utf8))
            }

            if path == "/jobs/\(jobId.uuidString)" {
                let response = """
                {"status": "failed", "text": "model failed to load", "revision": 1}
                """
                return (HTTPURLResponse(statusCode: 200), Data(response.utf8))
            }

            return nil
        }

        WhisperClient._testSession = makeMockSession()
        do {
            _ = try await WhisperClient.transcribeAsync(
                audioURL: tempAudioURL,
                jobId: jobId,
                config: defaultConfig,
                correlationId: jobId
            )
            XCTFail("Expected jobFailed error")
        } catch WhisperError.jobFailed(let reason) {
            XCTAssertEqual(reason, "model failed to load")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // MARK: - Legacy Server (async unsupported)

    func test_transcribeAsync_legacyServer_throwsAsyncUnsupported() async {
        let jobId = testJobId

        MockURLProtocol.handler = { request in
            let path = request.url?.path ?? ""

            if path == "/health" || path == "/" {
                return (HTTPURLResponse(statusCode: 200), Data())
            }

            // Simulate legacy server: POST /transcriptions returns 404.
            if request.httpMethod == "POST" && path == "/transcriptions" {
                return (HTTPURLResponse(statusCode: 404), Data("{\"detail\":\"Not Found\"}".utf8))
            }

            return nil
        }

        WhisperClient._testSession = makeMockSession()
        do {
            _ = try await WhisperClient.transcribeAsync(
                audioURL: tempAudioURL,
                jobId: jobId,
                config: defaultConfig,
                correlationId: jobId
            )
            XCTFail("Expected asyncUnsupported error")
        } catch WhisperError.asyncUnsupported {
            // Expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // MARK: - Job Eviction

    func test_transcribeAsync_jobEvicted_throws() async {
        let jobId = testJobId

        MockURLProtocol.handler = { request in
            let path = request.url?.path ?? ""

            if path == "/health" || path == "/" {
                return (HTTPURLResponse(statusCode: 200), Data())
            }

            if request.httpMethod == "POST" && path == "/transcriptions" {
                let body = """
                {"job_id": "\(jobId.uuidString)", "status_endpoint": "/jobs/\(jobId.uuidString)"}
                """
                return (HTTPURLResponse(statusCode: 202), Data(body.utf8))
            }

            if path == "/jobs/\(jobId.uuidString)" {
                return (HTTPURLResponse(statusCode: 404), Data("{\"detail\":\"Job not found\"}".utf8))
            }

            return nil
        }

        WhisperClient._testSession = makeMockSession()
        do {
            _ = try await WhisperClient.transcribeAsync(
                audioURL: tempAudioURL,
                jobId: jobId,
                config: defaultConfig,
                correlationId: jobId
            )
            XCTFail("Expected jobFailed error for evicted job")
        } catch WhisperError.jobFailed(let reason) {
            XCTAssertEqual(reason, "job evicted")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // MARK: - Idempotency Key Header

    func test_transcribeAsync_idempotencyKeyHeader() async throws {
        let jobId = testJobId
        var capturedIdempotencyKey: String?

        MockURLProtocol.handler = { request in
            let path = request.url?.path ?? ""

            if path == "/health" || path == "/" {
                return (HTTPURLResponse(statusCode: 200), Data())
            }

            if request.httpMethod == "POST" && path == "/transcriptions" {
                capturedIdempotencyKey = request.value(forHTTPHeaderField: "Idempotency-Key")
                let body = """
                {"job_id": "\(jobId.uuidString)", "status_endpoint": "/jobs/\(jobId.uuidString)"}
                """
                // Return ready immediately to complete the test quickly.
                return (HTTPURLResponse(statusCode: 202), Data(body.utf8))
            }

            // Return ready on first poll so the test completes in one iteration.
            if path == "/jobs/\(jobId.uuidString)" {
                let response = """
                {"status": "ready", "text": "hello world", "revision": 1}
                """
                return (HTTPURLResponse(statusCode: 200), Data(response.utf8))
            }

            return nil
        }

        WhisperClient._testSession = makeMockSession()
        _ = try await WhisperClient.transcribeAsync(
            audioURL: tempAudioURL,
            jobId: jobId,
            config: defaultConfig,
            correlationId: jobId
        )

        XCTAssertNotNil(capturedIdempotencyKey, "Idempotency-Key header was not sent")
        XCTAssertEqual(capturedIdempotencyKey, jobId.uuidString.lowercased(),
                       "Idempotency-Key must be the lowercase canonical UUID")
    }

    // MARK: - Cancellation

    func test_transcribeAsync_cancellation_stopsPolling() async {
        let jobId = testJobId
        let pollStarted = expectation(description: "first poll started")

        MockURLProtocol.handler = { request in
            let path = request.url?.path ?? ""

            if path == "/health" || path == "/" {
                return (HTTPURLResponse(statusCode: 200), Data())
            }

            if request.httpMethod == "POST" && path == "/transcriptions" {
                let body = """
                {"job_id": "\(jobId.uuidString)", "status_endpoint": "/jobs/\(jobId.uuidString)"}
                """
                return (HTTPURLResponse(statusCode: 202), Data(body.utf8))
            }

            if path == "/jobs/\(jobId.uuidString)" {
                // Signal that the poll loop has been entered.
                pollStarted.fulfill()
                // Keep returning pending so the task loops indefinitely.
                let response = """
                {"status": "pending", "text": null, "revision": 1}
                """
                return (HTTPURLResponse(statusCode: 200), Data(response.utf8))
            }

            return nil
        }

        WhisperClient._testSession = makeMockSession()

        let task = Task {
            try await WhisperClient.transcribeAsync(
                audioURL: tempAudioURL,
                jobId: jobId,
                config: defaultConfig,
                correlationId: jobId
            )
        }

        // Wait for the first poll to fire (confirm the task entered the poll loop).
        await fulfillment(of: [pollStarted], timeout: 10)
        // Cancel the task — it should stop within one poll iteration.
        task.cancel()

        let result = await task.result
        switch result {
        case .success:
            XCTFail("Expected cancellation to throw an error")
        case .failure(let error):
            // Cancellation should produce a WhisperError (the .timeout at end of loop).
            XCTAssertTrue(error is WhisperError, "Expected WhisperError, got \(type(of: error))")
        }
    }
}
}
