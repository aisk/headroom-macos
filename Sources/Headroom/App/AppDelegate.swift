import AppKit
import HeadroomCore

/// A menu bar app without a Dock icon: the only UI is the status item, its popover and Settings.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Posted by a second instance to ask the running one to open its panel.
    private static let showPanelNotification = Notification.Name("Headroom.ShowPanel")

    private let settingsStore = SettingsStore(url: SettingsStore.defaultURL)
    private var settings = AppSettings()
    private var monitor: UsageMonitor!
    private var model: MainViewModel!
    private var statusItem: StatusItemController!
    private var settingsWindow: SettingsWindowController?

    func applicationWillFinishLaunching(_ notification: Notification) {
        if signalRunningInstance() {
            // Opening the app again shows the running instance's panel instead.
            exit(0)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Writing to a JSON-RPC server that just exited must fail the write, not kill the app.
        signal(SIGPIPE, SIG_IGN)
        NSApp.setActivationPolicy(.accessory)

        settings = settingsStore.load()
        monitor = UsageMonitor(providers: [
            AntigravityUsageProvider(), ClaudeUsageProvider(), CodexUsageProvider(), GrokUsageProvider(),
        ])
        model = MainViewModel(monitor: monitor)
        statusItem = StatusItemController(model: model)
        statusItem.onSettings = { [weak self] in self?.showSettings() }
        statusItem.onQuit = { [weak self] in self?.quit() }
        model.onChange = { [weak self] in self?.statusItem?.update() }
        applySettings()
        statusItem.update()

        if settings.refreshInterval == nil {
            // Automatic refresh is off; still load the data once at startup.
            Task { await monitor.refreshAll() }
        }

        DistributedNotificationCenter.default().addObserver(
            forName: Self.showPanelNotification, object: Bundle.main.bundleIdentifier, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.statusItem.showPanel() }
        }

        // A launch by the user shows the panel right away; a login launch stays in the menu bar.
        if !LaunchAtLogin.isLoginLaunch() {
            DispatchQueue.main.async { self.statusItem.showPanel() }
        }
    }

    /// Opening the app again from Finder or Spotlight shows the panel.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        statusItem?.showPanel()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor?.dispose()
    }

    /// Returns true when another instance is already running and was asked to show its panel.
    private func signalRunningInstance() -> Bool {
        guard let bundleId = Bundle.main.bundleIdentifier else {
            return false
        }
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        guard !others.isEmpty else {
            return false
        }
        DistributedNotificationCenter.default().postNotificationName(
            Self.showPanelNotification, object: bundleId, userInfo: nil, deliverImmediately: true)
        return true
    }

    /// Applies the current settings to the monitor and the panel.
    private func applySettings() {
        for state in monitor.providers {
            monitor.setEnabled(state, settings.isProviderEnabled(state.id))
        }
        if monitor.interval != settings.refreshInterval {
            monitor.setInterval(settings.refreshInterval)
        }
        model.refreshOnOpen = settings.refreshOnOpen
    }

    private func showSettings() {
        statusItem.closePanel()
        if settingsWindow == nil {
            let tools = monitor.providers.map { SettingsModel.Tool(id: $0.id, name: $0.provider.displayName) }
            let settingsModel = SettingsModel(settings: settings, tools: tools)
            settingsModel.onChange = { [weak self] updated in
                guard let self else { return }
                settings = updated
                applySettings()
                settingsStore.save(settings)
            }
            settingsWindow = SettingsWindowController(model: settingsModel)
        }
        settingsWindow?.bringToFront()
    }

    private func quit() {
        monitor.dispose()
        settingsWindow?.close()
        NSApp.terminate(nil)
    }
}
