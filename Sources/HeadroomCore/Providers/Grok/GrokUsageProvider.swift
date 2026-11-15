import Foundation

/// Reads Grok Build billing through the CLI's Agent Client Protocol server (`grok agent stdio`)
/// and its `_x.ai/billing` extension. No session is created and no prompt is sent.
public struct GrokUsageProvider: UsageProvider {
    private static let initializeTimeout: TimeInterval = 30
    private static let requestTimeout: TimeInterval = 20

    public init() {}

    public var id: String { "grok" }

    public var displayName: String { "Grok" }

    public func isInstalled() -> Bool {
        CliLocator.find("grok") != nil
    }

    public func fetch() async throws -> UsageSnapshot {
        guard let executable = CliLocator.find("grok") else {
            throw UsageProviderError("Grok CLI not found. Install Grok Build and run `grok login`.")
        }

        return try await withJsonRpcProcess(executable, ["agent", "stdio"], displayName: "grok agent") { rpc in
            do {
                _ = try await rpc.request(
                    "initialize", ["protocolVersion": 1, "clientCapabilities": [:]], timeout: Self.initializeTimeout)

                let billing: JSONValue?
                do {
                    billing = try await rpc.request("_x.ai/billing", [:], timeout: Self.requestTimeout)
                } catch let error as JsonRpcError where error.code == JsonRpcError.methodNotFound {
                    throw UsageProviderError("This Grok CLI version does not expose billing; run `grok update`.")
                } catch let error as JsonRpcError where Self.isAuthenticationFailure(error.message) {
                    throw UsageProviderError("Not signed in to Grok. Run `grok login`.", kind: .signInRequired)
                }

                return try GrokBillingParser.parse(billing, now: Date())
            } catch let error as JsonRpcError {
                throw error.asProviderError
            }
        }
    }

    // Grok's billing handler asks for `grok login` verbatim when no credentials are cached.
    static func isAuthenticationFailure(_ message: String) -> Bool {
        let lower = message.lowercased()
        return ["authentication required", "grok login", "not authenticated", "unauthenticated", "unauthorized", "not logged in"]
            .contains(where: lower.contains)
    }
}
