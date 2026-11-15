import XCTest
@testable import HeadroomCore

final class ClaudeSignInTests: XCTestCase {
    func testParsesSubscriptionLogin() throws {
        let status = try XCTUnwrap(ClaudeAuthStatus.tryParse("""
            {"loggedIn": true, "authMethod": "claude.ai", "apiProvider": "firstParty",
             "email": "me@example.com", "subscriptionType": "max"}
            """))

        XCTAssertTrue(status.loggedIn)
        XCTAssertTrue(status.isSubscription)
        XCTAssertEqual(status.planDisplayName, "Max")
        XCTAssertEqual(status.email, "me@example.com")
    }

    func testApiKeyLoginIsNotASubscription() {
        let status = ClaudeAuthStatus.tryParse(#"{"loggedIn": true, "authMethod": "apiKey", "apiProvider": "firstParty"}"#)
        XCTAssertEqual(status?.isSubscription, false)
    }

    func testSignedOutAndUnknownOutput() {
        XCTAssertEqual(ClaudeAuthStatus.tryParse(#"{"loggedIn": false}"#)?.loggedIn, false)
        XCTAssertNil(ClaudeAuthStatus.tryParse("error: unknown command 'auth'"))
    }

    func testExpiredLoginRequiresSignIn() {
        for output in [
            #"API Error: 401 {"type":"authentication_error"} · Please run /login"#,
            "OAuth token has expired. Please run /login",
        ] {
            XCTAssertThrowsError(try ClaudeUsageParser.parse(output, now: Date())) { error in
                XCTAssertEqual((error as? UsageProviderError)?.kind, .signInRequired, output)
            }
        }
    }

    func testSubscriptionNoticeWithoutQuotaIsExplained() {
        XCTAssertThrowsError(try ClaudeUsageParser.parse(
            "You are currently using your subscription to power your Claude Code usage\n", now: Date())
        ) { error in
            let error = error as? UsageProviderError
            XCTAssertEqual(error?.kind, .general)
            XCTAssertTrue(error?.message.contains("did not report session or weekly limits") ?? false)
        }
    }

    func testProbeProjectNameMatchesClaudeCode() {
        let url = URL(fileURLWithPath: "/Users/me/Library/Application Support/Headroom/ClaudeProbe")
        XCTAssertEqual(
            ClaudeUsageProvider.probeProjectName(url), "-Users-me-Library-Application-Support-Headroom-ClaudeProbe")
    }
}

final class CodexSignInTests: XCTestCase {
    func testMissingAccountRequiresSignIn() throws {
        XCTAssertThrowsError(try CodexAccountCheck.throwIfUnusable(
            JSONValue.parse(#"{"account":null,"requiresOpenaiAuth":true}"#))
        ) { error in
            XCTAssertEqual((error as? UsageProviderError)?.kind, .signInRequired)
        }
    }

    func testApiKeyAccountHasNoPlanLimits() throws {
        XCTAssertThrowsError(try CodexAccountCheck.throwIfUnusable(
            JSONValue.parse(#"{"account":{"type":"apiKey"},"requiresOpenaiAuth":true}"#))
        ) { error in
            XCTAssertEqual((error as? UsageProviderError)?.kind, .general)
        }
    }

    func testChatGptAccountIsUsable() throws {
        try CodexAccountCheck.throwIfUnusable(JSONValue.parse(#"{"account":{"type":"chatgpt","email":"a@b.c"}}"#))
        XCTAssertTrue(CodexAccountCheck.isAuthenticationFailure("unexpected status 401 Unauthorized"))
        XCTAssertFalse(CodexAccountCheck.isAuthenticationFailure("request to port 4012 failed"))
    }
}

final class GrokSignInTests: XCTestCase {
    func testLoginPromptIsAnAuthenticationFailure() {
        XCTAssertTrue(GrokUsageProvider.isAuthenticationFailure("_x.ai/billing: Authentication required. Run `grok login`."))
        XCTAssertFalse(GrokUsageProvider.isAuthenticationFailure("_x.ai/billing: internal error"))
    }
}

final class AntigravityFailureClassifierTests: XCTestCase {
    func testLoginPromptRequiresSignIn() {
        for output in ["Select login method:\n> Google", "You are not logged into Antigravity."] {
            XCTAssertEqual(AntigravityFailureClassifier.classify(exitCode: 1, output: output).kind, .signInRequired, output)
        }
    }

    func testNetworkFailureHidesRawOutput() {
        let error = AntigravityFailureClassifier.classify(
            exitCode: 1, output: #"Get "https://example.com/u/me@example.com": dial tcp: i/o timeout"#)
        XCTAssertTrue(error.message.contains("network request failed"))
        XCTAssertFalse(error.message.contains("example.com"))
    }

    func testUnknownFailureUsesFixedMessage() {
        XCTAssertEqual(
            AntigravityFailureClassifier.classify(exitCode: 2, output: "panic: something").message,
            "agy exited 2 without a usage report.")
    }
}

private final class SignedOutProvider: UsageProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    let pause: Bool

    init(pause: Bool) { self.pause = pause }

    var calls: Int { lock.withLock { count } }

    var id: String { "test-\(pause)" }
    var displayName: String { "Test" }
    var pauseAutoRefreshWhenSignedOut: Bool { pause }
    func isInstalled() -> Bool { true }

    func fetch() async throws -> UsageSnapshot {
        lock.withLock { count += 1 }
        throw UsageProviderError("signed out", kind: .signInRequired)
    }
}

@MainActor
final class UsageMonitorSignInTests: XCTestCase {
    func testSignInFailureClearsSnapshotAndPausesOnlyWhenRequested() async {
        let paused = SignedOutProvider(pause: true)
        let polled = SignedOutProvider(pause: false)
        let monitor = UsageMonitor(providers: [paused, polled])
        defer { monitor.dispose() }

        await monitor.refreshAll()
        await monitor.refreshAll()
        XCTAssertEqual(paused.calls, 1)
        XCTAssertEqual(polled.calls, 2)
        XCTAssertTrue(monitor.providers[0].isAutoRefreshPaused)
        XCTAssertNil(monitor.providers[0].snapshot)
        XCTAssertEqual(monitor.providers[0].error, "signed out")

        await monitor.refreshAll(manual: true)
        XCTAssertEqual(paused.calls, 2)
    }
}
