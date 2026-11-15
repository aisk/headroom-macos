import Foundation

/// A small wrapper over `NSRegularExpression` matches with named groups.
struct RegexMatch {
    let result: NSTextCheckingResult
    let text: String

    var range: Range<String.Index> { Range(result.range, in: text)! }

    func group(_ name: String) -> String? {
        let nsRange = result.range(withName: name)
        guard nsRange.location != NSNotFound, let range = Range(nsRange, in: text) else {
            return nil
        }
        return String(text[range])
    }
}

extension NSRegularExpression {
    convenience init(_ pattern: String, ignoreCase: Bool = false) {
        // The patterns are constants; an invalid one is a programming error.
        try! self.init(pattern: pattern, options: ignoreCase ? [.caseInsensitive] : [])
    }

    func firstMatch(in text: String) -> RegexMatch? {
        firstMatch(in: text, range: NSRange(text.startIndex..., in: text)).map { RegexMatch(result: $0, text: text) }
    }

    func isMatch(_ text: String) -> Bool {
        firstMatch(in: text) != nil
    }

    func replace(in text: String, with template: String) -> String {
        stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }

    /// Replaces each match with the result of `transform`.
    func replace(in text: String, transform: (RegexMatch) -> String) -> String {
        var output = ""
        var cursor = text.startIndex
        for result in matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            let match = RegexMatch(result: result, text: text)
            output += text[cursor..<match.range.lowerBound]
            output += transform(match)
            cursor = match.range.upperBound
        }
        return output + text[cursor...]
    }
}
