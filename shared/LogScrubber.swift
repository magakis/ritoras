import Foundation

enum LogScrubber {

    // MARK: - Rule

    private struct Rule {
        let name: String
        let regex: NSRegularExpression
        /// Optional extra validation; return false to skip redaction for this match.
        let validate: ((NSTextCheckingResult, NSString) -> Bool)?
    }

    // MARK: - Compiled Patterns

    private static let rules: [Rule] = {
        let email = try! NSRegularExpression(
            pattern: "[A-Z0-9._%+-]+@[A-Z0-9.-]+\\.[A-Z]{2,}",
            options: [.caseInsensitive]
        )

        let phone = try! NSRegularExpression(
            pattern: "\\+?[0-9]{1,3}?[-.\\s]?\\(?[0-9]{1,4}?\\)?[-.\\s]?[0-9]{1,4}[-.\\s]?[0-9]{1,9}"
        )

        let ipv4 = try! NSRegularExpression(
            pattern: "\\b(?:\\d{1,3}\\.){3}\\d{1,3}\\b"
        )

        let ipv6 = try! NSRegularExpression(
            pattern: "(?:[A-F0-9]{1,4}:){7}[A-F0-9]{1,4}",
            options: [.caseInsensitive]
        )

        let jwt = try! NSRegularExpression(
            pattern: "eyJ[A-Za-z0-9_-]+\\.eyJ[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+"
        )

        let base64 = try! NSRegularExpression(
            pattern: "[A-Za-z0-9+/]{120,}={0,2}"
        )

        let cc = try! NSRegularExpression(
            pattern: "\\b(?:\\d[ -]*?){13,19}\\b"
        )

        return [
            Rule(name: "email", regex: email, validate: nil),
            Rule(name: "phone", regex: phone, validate: { match, nsString in
                let substring = nsString.substring(with: match.range)
                let digitCount = substring.reduce(0) { $0 + ($1.isNumber ? 1 : 0) }
                return digitCount >= 7
            }),
            Rule(name: "ipv4", regex: ipv4, validate: nil),
            Rule(name: "ipv6", regex: ipv6, validate: nil),
            Rule(name: "jwt", regex: jwt, validate: nil),
            Rule(name: "base64", regex: base64, validate: nil),
            Rule(name: "cc", regex: cc, validate: nil),
        ]
    }()

    // MARK: - URL Detector

    private static let urlDetector = try! NSDataDetector(
        types: NSTextCheckingResult.CheckingType.link.rawValue
    )

    // MARK: - Public API

    /// Scrub PII from the given text.
    ///
    /// Applies URL-stripping first (removes query and fragment components),
    /// then replaces known PII patterns with `[REDACTED:<kind>]` tokens.
    static func scrub(_ text: String) -> String {
        let urlScrubbed = scrubURLs(in: text)
        return scrubDenylist(in: urlScrubbed)
    }

    // MARK: - URL Stripping

    private static func scrubURLs(in text: String) -> String {
        let nsString = text as NSString
        let fullRange = NSRange(location: 0, length: nsString.length)

        var replacements: [(NSRange, String)] = []

        urlDetector.enumerateMatches(in: text, range: fullRange) { match, _, _ in
            guard let match = match, let url = match.url else { return }
            let range = match.range
            guard range.location != NSNotFound, range.length > 0 else { return }

            let original = nsString.substring(with: range)
            guard let comps = URLComponents(string: original) else { return }

            var stripped = ""
            if let scheme = comps.scheme, !scheme.isEmpty {
                stripped += scheme + "://"
            }
            if let host = comps.host, !host.isEmpty {
                stripped += host
                if let port = comps.port {
                    stripped += ":\(port)"
                }
            }
            stripped += comps.path

            if comps.query != nil || comps.fragment != nil {
                stripped += "[?]"
            }

            replacements.append((range, stripped))
        }

        // Apply in reverse order to preserve indices.
        var result = text
        for (range, replacement) in replacements.sorted(by: { $0.0.location > $1.0.location }) {
            guard let swiftRange = Range(range, in: result) else { continue }
            result.replaceSubrange(swiftRange, with: replacement)
        }
        return result
    }

    // MARK: - Denylist Replacement

    private static func scrubDenylist(in text: String) -> String {
        var result = text

        for rule in rules {
            let nsCurrent = result as NSString
            let fullRange = NSRange(location: 0, length: nsCurrent.length)

            var replacements: [(NSRange, String)] = []

            rule.regex.enumerateMatches(in: result, range: fullRange) { match, _, _ in
                guard let match = match else { return }
                let matchRange = match.range
                guard matchRange.location != NSNotFound, matchRange.length > 0 else { return }

                if let validate = rule.validate {
                    guard validate(match, nsCurrent) else { return }
                }

                replacements.append((matchRange, "[REDACTED:\(rule.name)]"))
            }

            // Apply in reverse order.
            for (range, replacement) in replacements.sorted(by: { $0.0.location > $1.0.location }) {
                guard let swiftRange = Range(range, in: result) else { continue }
                result.replaceSubrange(swiftRange, with: replacement)
            }
        }

        return result
    }
}
