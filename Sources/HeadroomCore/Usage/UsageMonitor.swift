import Foundation

@MainActor
public final class ProviderState: Identifiable {
    public nonisolated let provider: any UsageProvider

    public nonisolated var id: String { provider.id }

    public internal(set) var snapshot: UsageSnapshot?

    public internal(set) var error: String?

    /// The last refresh found the CLI signed out or its credentials expired.
    public internal(set) var needsSignIn = false

    /// Automatic refreshes are suspended until the user refreshes manually.
    public var isAutoRefreshPaused: Bool { needsSignIn && provider.pauseAutoRefreshWhenSignedOut }

    public internal(set) var isRefreshing = false

    public internal(set) var isInstalled = true

    /// Turned off by the user: never polled and not shown.
    public internal(set) var isEnabled = true

    public internal(set) var lastAttempt: Date?

    init(provider: any UsageProvider) {
        self.provider = provider
    }
}

/// Periodically refreshes every enabled provider. Refreshes of the same provider never overlap.
@MainActor
public final class UsageMonitor {
    public let providers: [ProviderState]

    /// Called on the main actor whenever a provider state changes.
    public var onStateChanged: ((ProviderState) -> Void)?

    /// Seconds between automatic refreshes, or nil when only manual refreshes run.
    public private(set) var interval: TimeInterval?

    private var gates = Set<String>()
    private var fetches = [String: Task<UsageSnapshot, Error>]()
    private var loop: Task<Void, Never>?
    private var isDisposed = false

    public init(providers: [any UsageProvider]) {
        self.providers = providers.map(ProviderState.init)
    }

    /// Starts automatic refreshes, or changes their interval. The first round refreshes providers
    /// not attempted within the new interval; nil stops automatic refreshes.
    public func setInterval(_ interval: TimeInterval?) {
        loop?.cancel()
        loop = nil
        self.interval = interval
        guard let period = interval, !isDisposed else {
            return
        }

        loop = Task { [weak self] in
            // After an interval change, data that is still fresh under the new interval is kept.
            await self?.refreshAll(maxAge: period)
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(period * 1_000_000_000))
                if Task.isCancelled { break }
                await self?.refreshAll()
            }
        }
    }

    /// Turns a provider on or off. A provider turned on is refreshed if its data is stale; await the
    /// result to wait for that refresh.
    @discardableResult
    public func setEnabled(_ state: ProviderState, _ enabled: Bool) -> Task<Void, Never> {
        guard state.isEnabled != enabled else {
            return Task {}
        }

        state.isEnabled = enabled
        onStateChanged?(state)
        guard enabled else {
            return Task {}
        }
        let maxAge = interval
        return Task { await refresh(state, maxAge: maxAge) }
    }

    /// - Parameters:
    ///   - maxAge: Skip providers attempted more recently than this many seconds.
    ///   - manual: A user-initiated refresh; also retries providers whose auto-refresh is paused.
    public func refreshAll(maxAge: TimeInterval? = nil, manual: Bool = false) async {
        await withTaskGroup(of: Void.self) { group in
            for state in providers {
                group.addTask { await self.refresh(state, maxAge: maxAge, manual: manual) }
            }
        }
    }

    public func refresh(_ state: ProviderState, maxAge: TimeInterval? = nil, manual: Bool = false) async {
        guard state.isEnabled, !isDisposed else {
            return
        }
        if !manual && state.isAutoRefreshPaused {
            return
        }
        if let maxAge, let last = state.lastAttempt, Date().timeIntervalSince(last) < maxAge {
            return
        }

        let provider = state.provider
        guard gates.insert(provider.id).inserted else {
            return // Already refreshing.
        }
        defer { gates.remove(provider.id) }

        state.isInstalled = await Task.detached { provider.isInstalled() }.value
        guard state.isInstalled else {
            state.error = nil
            state.needsSignIn = false
            state.snapshot = nil
            state.lastAttempt = Date()
            onStateChanged?(state)
            return
        }

        state.isRefreshing = true
        onStateChanged?(state)

        let fetch = Task.detached { try await provider.fetch() }
        fetches[provider.id] = fetch
        defer { fetches[provider.id] = nil }
        do {
            state.snapshot = try await fetch.value
            state.error = nil
            state.needsSignIn = false
        } catch is CancellationError where isDisposed {
            return
        } catch let error as UsageProviderError {
            state.error = error.message
            state.needsSignIn = error.kind == .signInRequired
            if state.needsSignIn {
                // The account may have changed or signed out; never keep showing its old quota.
                state.snapshot = nil
            }
        } catch let error as JsonRpcError {
            state.error = error.message
            state.needsSignIn = false
        } catch {
            if isDisposed { return }
            state.error = "Unexpected error: \(error.localizedDescription)"
            state.needsSignIn = false
        }

        state.lastAttempt = Date()
        state.isRefreshing = false
        onStateChanged?(state)
    }

    /// Stops automatic refreshes and cancels every refresh in flight.
    public func dispose() {
        isDisposed = true
        loop?.cancel()
        loop = nil
        for fetch in fetches.values {
            fetch.cancel()
        }
    }
}
