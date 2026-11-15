import Combine
import Foundation
import HeadroomCore

/// What the panel shows for one provider, copied from its `ProviderState` after every change.
struct ProviderRow: Identifiable, Equatable {
    var id: String
    var name: String
    /// Providers turned off in Settings or whose CLI is not installed are hidden.
    var isVisible: Bool
    var isRefreshing: Bool
    var needsSignIn: Bool
    var error: String?
    var snapshot: UsageSnapshot?

    @MainActor
    init(_ state: ProviderState) {
        id = state.id
        name = state.provider.displayName
        isVisible = state.isEnabled && state.isInstalled
        isRefreshing = state.isRefreshing
        needsSignIn = state.needsSignIn
        error = state.isAutoRefreshPaused
            ? "\(state.error ?? "") Automatic refresh is paused; use Refresh after signing in."
            : state.error
        snapshot = state.snapshot
    }

    /// Remaining percent of the most constrained window, for the menu bar icon.
    var remaining: Double? { snapshot?.mostConstrained?.remainingPercent }

    func subtitle(now: Date, accountDisplay: AccountDisplay) -> String {
        var parts = [String]()
        if let plan = snapshot?.plan, !plan.isEmpty {
            parts.append(plan)
        }
        if let account = accountDisplay.format(snapshot?.account) {
            parts.append(account)
        }
        if isRefreshing {
            parts.append("Refreshing…")
        } else if let snapshot {
            parts.append(Formatting.updated(snapshot.fetchedAt, now: now))
        }
        return parts.joined(separator: " · ")
    }
}

@MainActor
final class MainViewModel: ObservableObject {
    private let monitor: UsageMonitor

    @Published private(set) var providers: [ProviderRow] = []

    /// The time relative texts ("Resets in 2h") are computed against.
    @Published private(set) var now = Date()

    /// Opening the panel refreshes data older than two minutes.
    var refreshOnOpen = true

    /// How the signed-in account is shown; set from Settings.
    @Published var accountDisplay = AccountDisplay.full

    /// Called after any provider changes.
    var onChange: (() -> Void)?

    init(monitor: UsageMonitor) {
        self.monitor = monitor
        monitor.onStateChanged = { [weak self] _ in self?.update() }
        update()
    }

    private func update() {
        now = Date()
        providers = monitor.providers.map(ProviderRow.init)
        onChange?()
    }

    var visibleProviders: [ProviderRow] { providers.filter(\.isVisible) }

    var noProvidersText: String {
        monitor.providers.contains { $0.isInstalled && !$0.isEnabled }
            ? "All installed tools are turned off. Open Settings from the Headroom menu to show them."
            : "No supported CLI found. Install Antigravity (agy), Claude Code, Codex, or Grok and sign in."
    }

    func refreshTexts() {
        now = Date()
    }

    /// - Parameter manual: User-initiated: also retries providers whose automatic refresh is paused.
    func refresh(maxAge: TimeInterval? = nil, manual: Bool = false) {
        Task { await monitor.refreshAll(maxAge: maxAge, manual: manual) }
    }

    var statusBars: [Double?] {
        visibleProviders.map(\.remaining)
    }

    var statusTooltip: String {
        var lines = ["Headroom"]
        for provider in visibleProviders {
            let line: String
            if let constrained = provider.snapshot?.mostConstrained {
                line = "\(provider.name): \(Int(constrained.remainingPercent.rounded()))% left"
            } else if provider.needsSignIn {
                line = "\(provider.name): sign-in required"
            } else if provider.error?.isEmpty == false {
                line = "\(provider.name): error"
            } else if let snapshot = provider.snapshot {
                line = "\(provider.name): \(snapshot.plan ?? "no quota data")"
            } else {
                line = "\(provider.name): …"
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }
}
