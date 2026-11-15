import XCTest
@testable import HeadroomCore

final class AppSettingsTests: XCTestCase {
    func testRoundTripsThroughJSON() throws {
        var settings = AppSettings(refreshIntervalMinutes: 15, refreshOnOpen: false)
        settings.setProviderEnabled("grok", false)

        let loaded = try AppSettings.parse(settings.toJSON())

        XCTAssertEqual(loaded.refreshIntervalMinutes, 15)
        XCTAssertEqual(loaded.refreshInterval, 15 * 60)
        XCTAssertFalse(loaded.refreshOnOpen)
        XCTAssertFalse(loaded.isProviderEnabled("Grok"))
        XCTAssertTrue(loaded.isProviderEnabled("claude"))
    }

    func testUsesCamelCaseKeys() {
        let json = AppSettings().toJSON()
        XCTAssertTrue(json.contains("\"refreshIntervalMinutes\""))
        XCTAssertTrue(json.contains("\"disabledProviders\""))
        XCTAssertTrue(json.contains("\"refreshOnOpen\""))
    }

    func testMissingAndInvalidValuesUseDefaults() throws {
        let settings = try AppSettings.parse(#"{"refreshIntervalMinutes": -3, "disabledProviders": null}"#)

        XCTAssertEqual(settings.refreshIntervalMinutes, AppSettings.defaultRefreshIntervalMinutes)
        XCTAssertTrue(settings.refreshOnOpen)
        XCTAssertTrue(settings.disabledProviders.isEmpty)
    }

    func testZeroIntervalMeansManualOnly() {
        XCTAssertNil(AppSettings(refreshIntervalMinutes: 0).refreshInterval)
    }

    func testReenablingRemovesEveryEntry() {
        var settings = AppSettings(disabledProviders: ["codex", "Codex"])
        settings.setProviderEnabled("codex", true)
        XCTAssertTrue(settings.disabledProviders.isEmpty)
    }

    func testStoreFallsBackToDefaultsForCorruptFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("headroom-\(UUID().uuidString)")
        let url = directory.appendingPathComponent("settings.json")
        let store = SettingsStore(url: url)
        defer { try? FileManager.default.removeItem(at: directory) }

        XCTAssertEqual(store.load().refreshIntervalMinutes, AppSettings.defaultRefreshIntervalMinutes)

        XCTAssertTrue(store.save(AppSettings(refreshIntervalMinutes: 30)))
        XCTAssertEqual(store.load().refreshIntervalMinutes, 30)

        try "{ not json".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(store.load().refreshIntervalMinutes, AppSettings.defaultRefreshIntervalMinutes)
    }
}

private final class CountingProvider: UsageProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var calls: Int { lock.withLock { count } }

    var id: String { "test" }
    var displayName: String { "Test" }
    func isInstalled() -> Bool { true }

    func fetch() async throws -> UsageSnapshot {
        lock.withLock { count += 1 }
        return UsageSnapshot(windows: [], fetchedAt: Date())
    }
}

private struct MissingProvider: UsageProvider {
    var id: String { "missing" }
    var displayName: String { "Missing" }
    func isInstalled() -> Bool { false }
    func fetch() async throws -> UsageSnapshot { fatalError("never fetched") }
}

@MainActor
final class UsageMonitorEnabledTests: XCTestCase {
    func testDisabledProviderIsNeverPolled() async {
        let provider = CountingProvider()
        let monitor = UsageMonitor(providers: [provider])
        defer { monitor.dispose() }
        await monitor.setEnabled(monitor.providers[0], false).value

        await monitor.refreshAll()
        await monitor.refreshAll(manual: true)
        XCTAssertEqual(provider.calls, 0)

        await monitor.setEnabled(monitor.providers[0], true).value
        XCTAssertEqual(provider.calls, 1)
    }

    func testMaxAgeSkipsFreshData() async {
        let provider = CountingProvider()
        let monitor = UsageMonitor(providers: [provider])
        defer { monitor.dispose() }

        await monitor.refreshAll()
        await monitor.refreshAll(maxAge: 120)
        XCTAssertEqual(provider.calls, 1)
        XCTAssertNotNil(monitor.providers[0].snapshot)
        XCTAssertFalse(monitor.providers[0].isRefreshing)
    }

    func testMissingCliIsHiddenAndNotFetched() async {
        let monitor = UsageMonitor(providers: [MissingProvider()])
        defer { monitor.dispose() }
        var changes = 0
        monitor.onStateChanged = { _ in changes += 1 }

        await monitor.refreshAll()
        XCTAssertFalse(monitor.providers[0].isInstalled)
        XCTAssertNotNil(monitor.providers[0].lastAttempt)
        XCTAssertEqual(changes, 1)
    }
}
