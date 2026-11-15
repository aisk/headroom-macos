import Foundation

/// Parses the text report printed by Claude Code's `/usage` command, e.g.
/// `Current week (all models): 7% used · resets Nov 5, 7pm (Asia/Tokyo)`.
public enum ClaudeUsageParser {
    private static let ansiEscape = NSRegularExpression(
        #"\x1B\[[0-?]*[ -/]*[@-~]|\x1B\][^\x07\x1B]*(?:\x07|\x1B\\)|\x1B[@-Z\\-_]"#)

    // Single-line form: "Current session: 23% used · resets 11pm (Asia/Tokyo)".
    private static let inlineWindow = NSRegularExpression(
        #"^\s*(?<label>Current [^:]+?)\s*:\s*(?<pct>\d+(?:\.\d+)?)\s*%\s*(?<kind>used|left)\b(?:\s*[·•|-]\s*(?<reset>.+?))?\s*$"#,
        ignoreCase: true)

    // Panel form used by the interactive TUI: a header line, then a percentage line, then a reset line.
    private static let headerLine = NSRegularExpression(
        #"^\s*(?<label>Current (?:session|week)[^:]*?)\s*:?\s*$"#, ignoreCase: true)

    private static let percentLine = NSRegularExpression(
        #"(?<pct>\d+(?:\.\d+)?)\s*%\s*(?<kind>used|left)\b"#, ignoreCase: true)

    private static let resetLine = NSRegularExpression(#"^\s*resets?\b.*$"#, ignoreCase: true)

    private static let labelParts = NSRegularExpression(
        #"^Current\s+(?<kind>\w+)\s*(?:\((?<scope>[^)]+)\))?"#, ignoreCase: true)

    // Mirrors the authentication markers CodexBar uses for Claude CLI failures.
    private static let authenticationMarkers = [
        "authentication_error", "permission_error", "token_expired", "token expired", "token has expired",
        "oauth account information not found", "does not have access to claude code", "run /login",
        "run `claude login`", "run claude login", "api error: 401", "api error: 403", "forbidden",
        "invalid api key", "invalid_api_key", "invalid credential", "not authenticated", "not authorized",
        "not logged in", "token revoked", "unauthorized",
    ]

    private static let rateLimitMarkers = ["rate_limit_error", "rate limited", "ratelimited"]

    public static func stripAnsi(_ text: String) -> String {
        ansiEscape.replace(in: text, with: "")
    }

    public static func parse(_ output: String, now: Date) throws -> UsageSnapshot {
        var lines = stripAnsi(output)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r" })
            .map { String($0).replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression) }

        // Usage insights below this header contain percentages that are not quotas.
        if let insights = lines.firstIndex(where: {
            $0.range(of: "What's contributing", options: .caseInsensitive) != nil
                || $0.range(of: "What’s contributing", options: .caseInsensitive) != nil
        }) {
            lines = Array(lines[..<insights])
        }

        var windows = [UsageWindow]()
        for i in lines.indices {
            if let inline = inlineWindow.firstMatch(in: lines[i]) {
                windows.append(makeWindow(
                    label: inline.group("label")!, pct: inline.group("pct")!, kind: inline.group("kind")!,
                    reset: inline.group("reset"), now: now))
                continue
            }

            guard let header = headerLine.firstMatch(in: lines[i]) else {
                continue
            }

            var pct: String?
            var kind: String?
            var reset: String?
            for j in (i + 1)..<min(lines.count, i + 5) {
                if headerLine.isMatch(lines[j]) {
                    break
                }
                if pct == nil, let match = percentLine.firstMatch(in: lines[j]) {
                    pct = match.group("pct")
                    kind = match.group("kind")
                } else if reset == nil, resetLine.isMatch(lines[j]) {
                    reset = lines[j].trimmingCharacters(in: .whitespaces)
                }
            }

            if let pct, let kind {
                windows.append(makeWindow(label: header.group("label")!, pct: pct, kind: kind, reset: reset, now: now))
            }
        }

        guard windows.isEmpty else {
            return UsageSnapshot(windows: windows, fetchedAt: now)
        }
        throw classifyFailure(lines.joined(separator: "\n"))
    }

    /// Maps a /usage report without quota values to a user-facing error.
    static func classifyFailure(_ text: String) -> UsageProviderError {
        let lower = text.lowercased()
        if authenticationMarkers.contains(where: lower.contains) {
            return UsageProviderError(
                "Claude Code is signed out or its login expired. Run `claude` and use /login.",
                kind: .signInRequired)
        }

        if rateLimitMarkers.contains(where: lower.contains) {
            return UsageProviderError("Claude's usage endpoint is rate limited right now; try again later.")
        }

        if lower.contains("failed to load usage data") {
            return UsageProviderError("Claude Code could not load usage data; try again later.")
        }

        let compact = String(lower.filter { !$0.isWhitespace })
        if compact.contains("currentlyusingyoursubscription") {
            // Some subscriptions (e.g. Education or organization-managed) report no session/weekly quota.
            return UsageProviderError("Claude did not report session or weekly limits for this subscription.")
        }

        guard let firstLine = CliProcess.firstLine(text) else {
            return UsageProviderError("Claude printed an empty usage report.")
        }
        return UsageProviderError("Claude: \(firstLine)")
    }

    private static func makeWindow(label rawLabel: String, pct: String, kind: String, reset: String?, now: Date) -> UsageWindow {
        let value = Double(pct) ?? 0
        let used = kind.caseInsensitiveCompare("left") == .orderedSame ? 100 - value : value
        let (group, label) = splitLabel(rawLabel.trimmingCharacters(in: .whitespaces))
        let resetText = reset?.trimmingCharacters(in: .whitespaces)
        let resetsAt = resetText.flatMap { ClaudeResetParser.tryParse($0, now: now) }
        return UsageWindow(
            group: group, label: label, usedPercent: min(max(used, 0), 100), resetsAt: resetsAt,
            resetDescription: resetsAt == nil ? resetText : nil)
    }

    /// "Current week (all models)" -> ("All models", "Weekly"); "Current session" -> (nil, "Session").
    private static func splitLabel(_ raw: String) -> (group: String?, label: String) {
        guard let match = labelParts.firstMatch(in: raw), let kind = match.group("kind") else {
            return (nil, raw)
        }

        let label: String
        switch kind.lowercased() {
        case "session": label = "Session"
        case "week": label = "Weekly"
        case "day": label = "Daily"
        case let other: label = other.prefix(1).uppercased() + other.dropFirst()
        }

        let scope = match.group("scope")?.trimmingCharacters(in: .whitespaces)
        return (capitalizeFirst(scope), label)
    }
}

/// Parses reset descriptions such as "resets Nov 5, 7pm (Asia/Tokyo)" or "Resets 11:30pm (Europe/Paris)".
public enum ClaudeResetParser {
    private static let timeZoneSuffix = NSRegularExpression(#"\((?<tz>[A-Za-z_]+(?:/[A-Za-z0-9_+\-]+)*)\)\s*$"#)
    private static let resetPrefix = NSRegularExpression(#"^resets?\s*"#, ignoreCase: true)
    private static let separators = NSRegularExpression(#"\s+at\s+|,"#, ignoreCase: true)
    private static let meridiem = NSRegularExpression(#"(?<=\d)\s*(?<meridiem>am|pm)\b"#, ignoreCase: true)

    private static let dateTimeFormats = [
        "MMM d h:mma", "MMM d ha", "MMM d yyyy h:mma", "MMM d yyyy ha",
        "MMMM d h:mma", "MMMM d ha", "MMM d", "MMMM d", "MMM d yyyy",
    ]

    private static let timeOnlyFormats = ["h:mma", "ha", "H:mm"]

    public static func tryParse(_ text: String, now: Date) -> Date? {
        var value = resetPrefix.replace(in: text.trimmingCharacters(in: .whitespaces), with: "")
        var zone = TimeZone.current
        if let match = timeZoneSuffix.firstMatch(in: value) {
            if let identifier = match.group("tz"), let found = TimeZone(identifier: identifier) {
                zone = found
            }
            value = String(value[..<match.range.lowerBound])
        }

        value = separators.replace(in: value, with: " ")
        value = value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        value = meridiem.replace(in: value) { ($0.group("meridiem") ?? "").uppercased() }
        guard !value.isEmpty else {
            return nil
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let today = calendar.dateComponents([.year, .month, .day], from: now)

        if let time = parse(value, formats: timeOnlyFormats) {
            var components = today
            components.hour = time.hour
            components.minute = time.minute
            guard let candidate = calendar.date(from: components) else { return nil }
            return candidate <= now ? calendar.date(byAdding: .day, value: 1, to: candidate) : candidate
        }

        if let parsed = parse(value, formats: dateTimeFormats) {
            let hasYear = value.split(separator: " ").contains { $0.count == 4 && $0.allSatisfy(\.isNumber) }
            var components = DateComponents(
                year: hasYear ? parsed.year : today.year, month: parsed.month, day: parsed.day,
                hour: parsed.hour, minute: parsed.minute)
            guard var result = calendar.date(from: components) else { return nil }
            if !hasYear && result < now.addingTimeInterval(-86_400) {
                components.year = (components.year ?? 0) + 1
                result = calendar.date(from: components) ?? result
            }
            return result
        }
        return nil
    }

    /// Parses with the first matching format and returns the wall-clock components.
    private static func parse(_ value: String, formats: [String]) -> DateComponents? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.isLenient = false
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        for format in formats {
            formatter.dateFormat = format
            if let date = formatter.date(from: value) {
                return utc.dateComponents([.year, .month, .day, .hour, .minute], from: date)
            }
        }
        return nil
    }
}
