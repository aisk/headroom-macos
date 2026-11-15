import Foundation

/// One quota window, e.g. "5-hour" or "Weekly".
public struct UsageWindow: Equatable, Sendable {
    /// Optional group the window belongs to (e.g. a model family).
    public var group: String?
    /// Short window label.
    public var label: String
    /// Used share of the quota, 0...100.
    public var usedPercent: Double
    /// When the window resets, if known.
    public var resetsAt: Date?
    /// Raw reset text reported by the CLI, used when no timestamp could be parsed.
    public var resetDescription: String?

    public init(group: String?, label: String, usedPercent: Double, resetsAt: Date?, resetDescription: String? = nil) {
        self.group = group
        self.label = label
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
        self.resetDescription = resetDescription
    }

    public var remainingPercent: Double { min(max(100 - usedPercent, 0), 100) }
}

public struct UsageSnapshot: Equatable, Sendable {
    public var windows: [UsageWindow]
    public var fetchedAt: Date
    public var account: String?
    public var plan: String?
    public var note: String?

    public init(windows: [UsageWindow], fetchedAt: Date, account: String? = nil, plan: String? = nil, note: String? = nil) {
        self.windows = windows
        self.fetchedAt = fetchedAt
        self.account = account
        self.plan = plan
        self.note = note
    }

    /// The window with the least remaining quota, used for compact summaries.
    public var mostConstrained: UsageWindow? {
        // Like MinBy, the first window wins on ties.
        windows.reduce(nil) { best, window in
            guard let best else { return window }
            return window.remainingPercent < best.remainingPercent ? window : best
        }
    }
}

public enum UsageErrorKind: Sendable {
    case general
    /// The CLI is signed out or its credentials expired; the user has to sign in again.
    case signInRequired
}

/// A user-presentable failure while reading usage from a CLI.
public struct UsageProviderError: Error, LocalizedError, Equatable, Sendable {
    public var message: String
    public var kind: UsageErrorKind

    public init(_ message: String, kind: UsageErrorKind = .general) {
        self.message = message
        self.kind = kind
    }

    public var errorDescription: String? { message }
}

public protocol UsageProvider: Sendable {
    var id: String { get }

    var displayName: String { get }

    /// When signed out, stop automatic refreshes until the user refreshes manually. Used for CLIs
    /// whose usage probe may start an interactive (browser) sign-in when no login is available.
    var pauseAutoRefreshWhenSignedOut: Bool { get }

    /// Whether the backing CLI can be found on this machine.
    func isInstalled() -> Bool

    func fetch() async throws -> UsageSnapshot
}

extension UsageProvider {
    public var pauseAutoRefreshWhenSignedOut: Bool { false }
}

/// Uppercases the first character, leaving the rest as is ("max" -> "Max").
func capitalizeFirst(_ text: String?) -> String? {
    guard let text, let first = text.first, !text.trimmingCharacters(in: .whitespaces).isEmpty else {
        return nil
    }
    return first.uppercased() + text.dropFirst()
}
