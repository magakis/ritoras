import XCTest
@testable import Ritoras

final class PayloadFormatterTests: XCTestCase {

    // MARK: - Nil / Empty

    func test_renders_nil_payload_returns_nil() {
        let result = PayloadFormatter.render(nil, scrubPII: false)
        XCTAssertNil(result)
    }

    func test_renders_empty_payload_returns_nil() {
        let result = PayloadFormatter.render([:], scrubPII: false)
        XCTAssertNil(result)
    }

    // MARK: - String

    func test_renders_single_string() {
        let result = PayloadFormatter.render(["key": "hello"], scrubPII: false)
        let lines = try XCTUnwrap(result)
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].key, "key")
        XCTAssertEqual(lines[0].value, "hello")
        assertValueType(lines[0].valueType, .string)
    }

    func test_renders_long_string_truncated() {
        let longString = String(repeating: "x", count: 200)
        let result = PayloadFormatter.render(["msg": longString], scrubPII: false)
        let lines = try XCTUnwrap(result)
        XCTAssertEqual(lines.count, 1)
        let expectedValue = String(repeating: "x", count: 120) + "\u{2026}"
        XCTAssertEqual(lines[0].value, expectedValue)
        assertValueType(lines[0].valueType, .string)
    }

    // MARK: - Number

    func test_renders_integer_value() {
        let result = PayloadFormatter.render(["statusCode": 200], scrubPII: false)
        let lines = try XCTUnwrap(result)
        XCTAssertEqual(lines[0].value, "200")
        assertValueType(lines[0].valueType, .number)
    }

    func test_renders_double_value() {
        let result = PayloadFormatter.render(["elapsed_ms": 1456.78], scrubPII: false)
        let lines = try XCTUnwrap(result)
        XCTAssertEqual(lines[0].value, "1456.78")
        assertValueType(lines[0].valueType, .number)
    }

    func test_renders_integer_valued_double_without_trailing_zero() {
        let result = PayloadFormatter.render(["x": 1456.0], scrubPII: false)
        let lines = try XCTUnwrap(result)
        XCTAssertEqual(lines[0].value, "1456")
        assertValueType(lines[0].valueType, .number)
    }

    // MARK: - Bool

    func test_renders_boolean_true() {
        let result = PayloadFormatter.render(["flag": true], scrubPII: false)
        let lines = try XCTUnwrap(result)
        XCTAssertEqual(lines[0].value, "true")
        assertValueType(lines[0].valueType, .bool)
    }

    func test_renders_boolean_false() {
        let result = PayloadFormatter.render(["flag": false], scrubPII: false)
        let lines = try XCTUnwrap(result)
        XCTAssertEqual(lines[0].value, "false")
        assertValueType(lines[0].valueType, .bool)
    }

    // MARK: - Array

    func test_renders_string_array_compact() {
        let result = PayloadFormatter.render(["candidates": ["a", "b", "c"]], scrubPII: false)
        let lines = try XCTUnwrap(result)
        XCTAssertEqual(lines[0].value, "[a, b, c]")
        assertValueType(lines[0].valueType, .array)
    }

    func test_renders_number_array_compact() {
        let result = PayloadFormatter.render(["codes": [200, 404, 500]], scrubPII: false)
        let lines = try XCTUnwrap(result)
        XCTAssertEqual(lines[0].value, "[200, 404, 500]")
        assertValueType(lines[0].valueType, .array)
    }

    func test_renders_empty_array() {
        let result = PayloadFormatter.render(["items": [Any]()], scrubPII: false)
        let lines = try XCTUnwrap(result)
        XCTAssertEqual(lines[0].value, "[]")
        assertValueType(lines[0].valueType, .array)
    }

    // MARK: - Object

    func test_renders_nested_object_as_compact_json() {
        let result = PayloadFormatter.render(["nested": ["key": "value"]], scrubPII: false)
        let lines = try XCTUnwrap(result)
        XCTAssertEqual(lines[0].value, "{\"key\":\"value\"}")
        assertValueType(lines[0].valueType, .object)
    }

    // MARK: - Null

    func test_renders_null_value() {
        let result = PayloadFormatter.render(["x": NSNull()], scrubPII: false)
        let lines = try XCTUnwrap(result)
        XCTAssertEqual(lines[0].value, "null")
        assertValueType(lines[0].valueType, .null)
    }

    // MARK: - Key Order

    func test_renders_mixed_payload_preserves_alphabetical_key_order() {
        let result = PayloadFormatter.render(["z": 1, "a": 2, "m": 3], scrubPII: false)
        let lines = try XCTUnwrap(result)
        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(lines[0].key, "a")
        XCTAssertEqual(lines[1].key, "m")
        XCTAssertEqual(lines[2].key, "z")
    }

    // MARK: - PII Scrubbing

    func test_scrubs_string_values_when_enabled() {
        let result = PayloadFormatter.render(["email": "user@example.com"], scrubPII: true)
        let lines = try XCTUnwrap(result)
        XCTAssertTrue(lines[0].value.contains("[REDACTED:email]"),
                      "Email value should be redacted when scrubPII is true")
    }

    func test_does_not_scrub_when_flag_false() {
        let result = PayloadFormatter.render(["email": "user@example.com"], scrubPII: false)
        let lines = try XCTUnwrap(result)
        XCTAssertEqual(lines[0].value, "user@example.com",
                       "Email value should not be redacted when scrubPII is false")
    }

    func test_does_not_scrub_keys() {
        let result = PayloadFormatter.render(["email": "user@example.com"], scrubPII: true)
        let lines = try XCTUnwrap(result)
        XCTAssertEqual(lines[0].key, "email",
                       "Keys must not be scrubbed regardless of scrubPII flag")
    }

    // MARK: - Large Payload Truncation

    func test_truncates_large_payload_with_synthetic_footer() {
        var payload: [String: Any] = [:]
        for i in 0..<15 {
            payload["k\(i)"] = true
        }
        let result = PayloadFormatter.render(payload, scrubPII: false)
        let lines = try XCTUnwrap(result)
        XCTAssertEqual(lines.count, 9, "15 keys should truncate to 8 + 1 footer")
        XCTAssertEqual(lines[0].key, "k0")
        XCTAssertEqual(lines[7].key, "k7")
        XCTAssertEqual(lines[8].key, "\u{2026}")
        XCTAssertEqual(lines[8].value, "7 more keys \u{2014} tap to copy full payload")
        assertValueType(lines[8].valueType, .null)
    }

    func test_truncates_long_total_payload_with_synthetic_footer() {
        var payload: [String: Any] = [:]
        for i in 0..<10 {
            payload["k\(i)"] = String(repeating: "x", count: 60)
        }
        let result = PayloadFormatter.render(payload, scrubPII: false)
        let lines = try XCTUnwrap(result)
        // 10 keys with ~60-char values → total > 500 chars, triggers truncation.
        XCTAssertEqual(lines.count, 9, "long payload should truncate to 8 + 1 footer")
        XCTAssertEqual(lines[8].key, "\u{2026}")
        XCTAssertEqual(lines[8].value, "2 more keys \u{2014} tap to copy full payload")
        assertValueType(lines[8].valueType, .null)
    }

    // MARK: - Helpers

    private func assertValueType(_ actual: PayloadValue, _ expected: PayloadValue,
                                 file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual, expected, file: file, line: line)
    }
}
