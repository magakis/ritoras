import Foundation

public struct PayloadLine: Identifiable, Equatable {
    public let id: Int
    public let key: String
    public let value: String
    public let valueType: PayloadValue

    public init(id: Int, key: String, value: String, valueType: PayloadValue) {
        self.id = id
        self.key = key
        self.value = value
        self.valueType = valueType
    }
}

public enum PayloadValue {
    case string, number, bool, array, object, null
}

public enum PayloadFormatter {

    /// Render a `[String: Any]?` payload into an array of `PayloadLine` items.
    ///
    /// - Returns: `nil` when the payload is nil or empty.
    public static func render(_ payload: [String: Any]?, scrubPII: Bool) -> [PayloadLine]? {
        guard let payload = payload, !payload.isEmpty else { return nil }

        let sortedKeys = payload.keys.sorted()
        var lines: [PayloadLine] = []

        for (index, key) in sortedKeys.enumerated() {
            let value = payload[key]!
            let (formatted, type) = format(value: value, scrubPII: scrubPII)
            lines.append(PayloadLine(id: index, key: key, value: formatted, valueType: type))
        }

        // Large-payload truncation: >12 lines OR total characters >500.
        let totalChars = lines.reduce(0) { $0 + $1.key.count + $1.value.count }
        if lines.count > 12 || totalChars > 500 {
            let truncated = Array(lines.prefix(8))
            let remaining = lines.count - 8
            guard remaining > 0 else { return lines }
            let footer = PayloadLine(
                id: 8,
                key: "\u{2026}",
                value: "\(remaining) more keys \u{2014} tap to copy full payload",
                valueType: .null
            )
            return truncated + [footer]
        }

        return lines
    }

    // MARK: - Value Formatting

    /// Format a single `Any` value into its display string and type tag.
    ///
    /// **Important:** Check `Bool` *before* `NSNumber` — Bool bridges to NSNumber
    /// on iOS, so the Bool-first check prevents `true` from rendering as `1`.
    private static func format(value: Any, scrubPII: Bool) -> (String, PayloadValue) {
        if value is Bool {
            return ((value as! Bool) ? "true" : "false", .bool)
        }

        if let num = value as? NSNumber {
            let doubleVal = num.doubleValue
            if doubleVal.truncatingRemainder(dividingBy: 1) == 0 {
                return ("\(num.intValue)", .number)
            } else {
                return ("\(num.doubleValue)", .number)
            }
        }

        if let str = value as? String {
            var processed = str
            if scrubPII {
                processed = LogScrubber.scrub(processed)
            }
            if processed.count > 120 {
                let prefix = processed.prefix(120)
                processed = "\(prefix)\u{2026}"
            }
            return (processed, .string)
        }

        if let arr = value as? [Any] {
            return (formatArray(arr), .array)
        }

        if let dict = value as? [String: Any] {
            return (formatObject(dict), .object)
        }

        if value is NSNull {
            return ("null", .null)
        }

        return (String(describing: value), .string)
    }

    /// Compact single-line array representation, recursively formatted.
    private static func formatArray(_ arr: [Any]) -> String {
        guard !arr.isEmpty else { return "[]" }
        let items = arr.map { formatValueForArray($0) }
        return "[\(items.joined(separator: ", "))]"
    }

    /// Recursive helper for formatting individual array elements.
    private static func formatValueForArray(_ value: Any) -> String {
        if value is Bool {
            return (value as! Bool) ? "true" : "false"
        }
        if let num = value as? NSNumber {
            if num.doubleValue.truncatingRemainder(dividingBy: 1) == 0 {
                return "\(num.intValue)"
            }
            return "\(num.doubleValue)"
        }
        if value is String {
            return "\(value)"
        }
        if let arr = value as? [Any] {
            return formatArray(arr)
        }
        if let dict = value as? [String: Any] {
            return formatObject(dict)
        }
        if value is NSNull {
            return "null"
        }
        return String(describing: value)
    }

    /// Compact sorted-keys JSON string for object values.
    /// Truncated at 200 characters.
    private static func formatObject(_ dict: [String: Any]) -> String {
        guard !dict.isEmpty else { return "{}" }
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]),
              let jsonString = String(data: data, encoding: .utf8) else {
            return "{...}"
        }
        if jsonString.count > 200 {
            return String(jsonString.prefix(200)) + "\u{2026}"
        }
        return jsonString
    }
}
