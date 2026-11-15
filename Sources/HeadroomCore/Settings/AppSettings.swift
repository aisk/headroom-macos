import Foundation

/// User preferences, stored as JSON under `~/Library/Application Support/Headroom`.
public struct AppSettings: Codable, Equatable, Sendable {
    public static let defaultRefreshIntervalMinutes = 5

    /// Choices offered for automatic refresh; 0 means manual refresh only.
    public static let refreshIntervalChoices = [0, 1, 2, 5, 10, 15, 30, 60]

    /// Ids of providers the user turned off; they are hidden and never polled.
    public var disabledProviders: [String] = []

    /// Minutes between automatic refreshes; 0 turns automatic refresh off.
    public var refreshIntervalMinutes: Int = defaultRefreshIntervalMinutes

    /// Refresh data older than two minutes when the panel is opened.
    public var refreshOnOpen: Bool = true

    /// How the signed-in account (e.g. an email address) is shown in the panel.
    public var accountDisplay: AccountDisplay = .full

    public init(
        disabledProviders: [String] = [],
        refreshIntervalMinutes: Int = defaultRefreshIntervalMinutes,
        refreshOnOpen: Bool = true,
        accountDisplay: AccountDisplay = .full
    ) {
        self.disabledProviders = disabledProviders
        self.refreshIntervalMinutes = refreshIntervalMinutes
        self.refreshOnOpen = refreshOnOpen
        self.accountDisplay = accountDisplay
    }

    private enum CodingKeys: String, CodingKey {
        case disabledProviders, refreshIntervalMinutes, refreshOnOpen, accountDisplay
    }

    /// Missing, null or invalid values fall back to the defaults.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        disabledProviders = (try? container.decodeIfPresent([String].self, forKey: .disabledProviders)) ?? []
        refreshIntervalMinutes = (try? container.decodeIfPresent(Int.self, forKey: .refreshIntervalMinutes))
            ?? Self.defaultRefreshIntervalMinutes
        if refreshIntervalMinutes < 0 {
            refreshIntervalMinutes = Self.defaultRefreshIntervalMinutes
        }
        refreshOnOpen = (try? container.decodeIfPresent(Bool.self, forKey: .refreshOnOpen)) ?? true
        accountDisplay = (try? container.decodeIfPresent(AccountDisplay.self, forKey: .accountDisplay)) ?? .full
    }

    /// Seconds between automatic refreshes, or nil when only manual refreshes run.
    public var refreshInterval: TimeInterval? {
        refreshIntervalMinutes > 0 ? TimeInterval(refreshIntervalMinutes * 60) : nil
    }

    public func isProviderEnabled(_ id: String) -> Bool {
        !disabledProviders.contains { $0.caseInsensitiveCompare(id) == .orderedSame }
    }

    public mutating func setProviderEnabled(_ id: String, _ enabled: Bool) {
        disabledProviders.removeAll { $0.caseInsensitiveCompare(id) == .orderedSame }
        if !enabled {
            disabledProviders.append(id)
        }
    }

    public static func parse(_ json: String) throws -> AppSettings {
        try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
    }

    public func toJSON() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? encoder.encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }
}

/// Loads and saves `AppSettings`; a missing or corrupt file yields the defaults.
public struct SettingsStore: Sendable {
    public static var defaultURL: URL {
        AppPaths.supportDirectory.appendingPathComponent("settings.json")
    }

    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func load() -> AppSettings {
        guard let data = try? Data(contentsOf: url),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data)
        else {
            return AppSettings()
        }
        return settings
    }

    /// Saves the settings; returns false if the file could not be written.
    @discardableResult
    public func save(_ settings: AppSettings) -> Bool {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            // An atomic write never leaves a truncated settings file behind.
            try Data(settings.toJSON().utf8).write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }
}

public enum AppPaths {
    /// `~/Library/Application Support/Headroom`.
    public static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Headroom", isDirectory: true)
    }
}
