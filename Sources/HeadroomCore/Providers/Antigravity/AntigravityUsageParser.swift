import Foundation

/// Parses the report printed by `agy -p /usage --output-format json`.
public enum AntigravityUsageParser {
    /// - Parameters:
    ///   - exitCode: Exit code of agy, used to classify failed reports.
    ///   - stderr: Standard error of agy, used only for classification and never shown.
    public static func parse(_ json: String, now: Date, exitCode: Int32 = 0, stderr: String? = nil) throws -> UsageSnapshot {
        let root: JSONValue
        do {
            root = try JSONValue.parse(json)
        } catch {
            throw UsageProviderError("agy returned an unreadable usage report.")
        }

        guard root.isObject else {
            throw UsageProviderError("agy returned an empty usage report.")
        }

        let status = root["status"]?.stringValue
        guard status?.caseInsensitiveCompare("SUCCESS") == .orderedSame else {
            // The detail can contain account information, so it is only used for classification.
            let detail = "\(root["error"]?.text ?? "")\n\(root["response"]?.text ?? "")\n\(stderr ?? "")"
            throw AntigravityFailureClassifier.tryClassify(exitCode: exitCode, output: detail)
                ?? UsageProviderError("agy usage report failed (\(status ?? "unknown status")).")
        }

        guard let command = root["command"], command["name"]?.stringValue == "usage",
              let groups = command["data"]?["groups"]?.arrayValue
        else {
            throw UsageProviderError("agy did not return a usage report.")
        }

        var windows = [UsageWindow]()
        for group in groups where group.isObject {
            let groupName = group["name"]?.stringValue
            guard let buckets = group["buckets"]?.arrayValue else {
                continue
            }

            for bucket in buckets where bucket.isObject {
                guard let remaining = bucket["remaining_fraction"]?.doubleValue else {
                    continue
                }

                let used = min(max((1 - remaining) * 100, 0), 100)
                let label = windowLabel(bucket["window"]?.stringValue, bucket["name"]?.stringValue)
                let resetText = bucket["reset_time"]?.stringValue
                let resetsAt = resetText.flatMap(ISODate.parse)
                windows.append(UsageWindow(
                    group: groupName, label: label, usedPercent: used, resetsAt: resetsAt,
                    resetDescription: resetsAt == nil ? resetText : nil))
            }
        }

        guard !windows.isEmpty else {
            throw UsageProviderError("agy reported no quota buckets for this account.")
        }
        return UsageSnapshot(windows: windows, fetchedAt: now)
    }

    private static func windowLabel(_ window: String?, _ name: String?) -> String {
        switch window?.lowercased() {
        case "weekly": return "Weekly"
        case "5h": return "5-hour"
        case "daily": return "Daily"
        default: return name ?? window ?? "Limit"
        }
    }
}
