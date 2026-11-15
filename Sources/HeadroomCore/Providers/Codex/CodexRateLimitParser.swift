import Foundation

/// Maps the `account/rateLimits/read` and `account/read` results of `codex app-server`.
public enum CodexRateLimitParser {
    private static let defaultLimitId = "codex"

    public static func parse(_ rateLimitsResult: JSONValue?, account accountResult: JSONValue?, now: Date) throws -> UsageSnapshot {
        guard let result = rateLimitsResult, result.isObject else {
            throw UsageProviderError("Codex returned no rate limit data.")
        }

        var windows = [UsageWindow]()
        let primaryLimit = result["rateLimits"].flatMap { $0.isObject ? $0 : nil }
        let primaryLimitId = primaryLimit?["limitId"]?.stringValue ?? defaultLimitId
        if let primaryLimit {
            addWindows(&windows, primaryLimit, group: nil)
        }

        // Additional limits (e.g. model-specific pools) are grouped under their name.
        if let byId = result["rateLimitsByLimitId"]?.objectValue {
            // JSON objects are unordered here; sort for a stable display order.
            for (limitId, limit) in byId.sorted(by: { $0.key < $1.key }) where limitId != primaryLimitId && limit.isObject {
                addWindows(&windows, limit, group: limit["limitName"]?.stringValue ?? limitId)
            }
        }

        guard !windows.isEmpty else {
            throw UsageProviderError("Codex reported no usage windows for this account.")
        }

        let account = accountResult?["account"]
        var plan = primaryLimit?["planType"]?.stringValue
        if plan?.trimmingCharacters(in: .whitespaces).isEmpty ?? true {
            plan = account?["planType"]?.stringValue
        }

        return UsageSnapshot(
            windows: windows,
            fetchedAt: now,
            account: account?["email"]?.stringValue,
            plan: capitalizeFirst(plan),
            note: primaryLimit.flatMap(describeCredits))
    }

    private static func addWindows(_ windows: inout [UsageWindow], _ limit: JSONValue, group: String?) {
        for key in ["primary", "secondary"] {
            guard let window = limit[key], window.isObject, let used = window["usedPercent"]?.doubleValue else {
                continue
            }

            let minutes = window["windowDurationMins"]?.intValue
            let resetsAt = window["resetsAt"]?.intValue.map { Date(timeIntervalSince1970: TimeInterval($0)) }
            windows.append(UsageWindow(
                group: group, label: windowLabel(minutes: minutes, fallbackKey: key),
                usedPercent: min(max(used, 0), 100), resetsAt: resetsAt))
        }
    }

    static func windowLabel(minutes: Int?, fallbackKey: String) -> String {
        guard let minutes else {
            return fallbackKey == "primary" ? "Session" : "Weekly"
        }
        switch minutes {
        case 10080: return "Weekly"
        case 1440: return "Daily"
        case _ where minutes % 1440 == 0: return "\(minutes / 1440)-day"
        case _ where minutes % 60 == 0: return "\(minutes / 60)-hour"
        default: return "\(minutes)-minute"
        }
    }

    private static func describeCredits(_ limit: JSONValue) -> String? {
        guard let credits = limit["credits"], credits.isObject else {
            return nil
        }
        if credits["unlimited"]?.boolValue == true {
            return "Credits: unlimited"
        }
        if credits["hasCredits"]?.boolValue == true {
            return "Credits: \(credits["balance"]?.text ?? "")"
        }
        return nil
    }
}
