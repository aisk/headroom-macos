import Foundation

/// Reads Codex rate limits from the CLI's own JSON-RPC server (`codex app-server`),
/// the same channel the official IDE integrations use. No model turn is started.
public struct CodexUsageProvider: UsageProvider {
    private static let initializeTimeout: TimeInterval = 30
    private static let requestTimeout: TimeInterval = 20

    public init() {}

    public var id: String { "codex" }

    public var displayName: String { "Codex" }

    public func isInstalled() -> Bool {
        CliLocator.find("codex") != nil
    }

    public func fetch() async throws -> UsageSnapshot {
        guard let executable = CliLocator.find("codex") else {
            throw UsageProviderError("Codex CLI not found. Install it and run `codex login`.")
        }

        // Read-only sandbox and no approvals: the server is only used for account queries.
        return try await withJsonRpcProcess(
            executable, ["-s", "read-only", "-a", "never", "app-server"], displayName: "codex app-server"
        ) { rpc in
            do {
                _ = try await rpc.request(
                    "initialize", ["clientInfo": ["name": "headroom", "version": "0.1.0"]],
                    timeout: Self.initializeTimeout)
                try rpc.notify("initialized")

                var account: JSONValue?
                do {
                    account = try await rpc.request("account/read", [:], timeout: Self.requestTimeout)
                } catch is UsageProviderError {
                    // Identity is optional; rate limits are what matter.
                } catch is JsonRpcError {
                    // Same as above.
                }

                try CodexAccountCheck.throwIfUnusable(account)

                let limits: JSONValue?
                do {
                    limits = try await rpc.request("account/rateLimits/read", timeout: Self.requestTimeout)
                } catch let error as JsonRpcError where CodexAccountCheck.isAuthenticationFailure(error.message) {
                    throw UsageProviderError("Codex login expired or is invalid. Run `codex login`.", kind: .signInRequired)
                }

                return try CodexRateLimitParser.parse(limits, account: account, now: Date())
            } catch let error as JsonRpcError {
                throw error.asProviderError
            }
        }
    }
}
