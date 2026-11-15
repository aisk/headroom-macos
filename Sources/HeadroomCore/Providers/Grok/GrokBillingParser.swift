import Foundation

/// Parses the result of the `_x.ai/billing` ACP extension of `grok agent stdio`.
/// Monetary amounts are reported as `{ "val": cents }`.
public enum GrokBillingParser {
    public static func parse(_ result: JSONValue?, now: Date) throws -> UsageSnapshot {
        guard let billing = result, billing.isObject, let config = billing["config"], config.isObject else {
            throw UsageProviderError("Grok returned no billing data.")
        }

        let period = config["currentPeriod"]
        let start = readDate(period?["start"]) ?? readDate(config["billingPeriodStart"])
        let end = readDate(period?["end"]) ?? readDate(config["billingPeriodEnd"])
        let label = periodLabel(type: period?["type"]?.text, start: start, end: end)

        var windows = [UsageWindow]()
        var used = readDouble(config["creditUsagePercent"])
        if used == nil, let cap = cents(config["onDemandCap"]), cap > 0, let spent = cents(config["onDemandUsed"]) {
            used = spent / cap * 100
        }
        if let used {
            windows.append(UsageWindow(group: nil, label: label, usedPercent: min(max(used, 0), 100), resetsAt: end))
        }

        var notes = [String]()
        if let balance = cents(config["prepaidBalance"]), balance > 0 {
            notes.append("Prepaid balance: \(formatDollars(balance / 100))")
        }

        if windows.isEmpty {
            // Some plans (e.g. Free) publish only the billing period. Never invent a percentage.
            if let end {
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.dateFormat = "MMM d HH:mm"
                notes.append("Grok does not report a usage percentage for this plan. \(label) period ends \(formatter.string(from: end)).")
            } else {
                notes.append("Grok does not report a usage percentage for this plan.")
            }
        }

        return UsageSnapshot(
            windows: windows,
            fetchedAt: now,
            plan: billing["subscription_tier"].flatMap { $0 == .null ? nil : $0.text },
            note: notes.isEmpty ? nil : notes.joined(separator: " "))
    }

    private static func periodLabel(type: String?, start: Date?, end: Date?) -> String {
        if let type = type?.uppercased() {
            if type.contains("WEEK") { return "Weekly" }
            if type.contains("MONTH") { return "Monthly" }
            if type.contains("DAY") || type.contains("DAILY") { return "Daily" }
        }

        if let start, let end {
            let days = end.timeIntervalSince(start) / 86_400
            switch days {
            case 6.5...7.5: return "Weekly"
            case 27...32: return "Monthly"
            case 0.9...1.1: return "Daily"
            default: return "Credits"
            }
        }
        return "Credits"
    }

    private static func cents(_ node: JSONValue?) -> Double? {
        readDouble(node?.isObject == true ? node?["val"] : node)
    }

    private static func readDouble(_ node: JSONValue?) -> Double? {
        switch node {
        case .number(let number): return number
        // Some int64 fields are serialized as strings.
        case .string(let text): return Double(text.trimmingCharacters(in: .whitespaces))
        default: return nil
        }
    }

    private static func readDate(_ node: JSONValue?) -> Date? {
        guard let node, node != .null else { return nil }
        return ISODate.parse(node.text)
    }

    private static func formatDollars(_ amount: Double) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.numberStyle = .currency
        return formatter.string(from: NSNumber(value: amount)) ?? String(format: "$%.2f", amount)
    }
}
