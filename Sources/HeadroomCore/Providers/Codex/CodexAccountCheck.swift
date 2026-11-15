import Foundation

/// Interprets the `account/read` result before rate limits are requested.
public enum CodexAccountCheck {
    private static let authenticationMarkers = [
        "unauthorized", "token expired", "token_expired", "invalid token", "refresh token",
        "not logged in", "not signed in", "codex login",
    ]

    private static let status401 = NSRegularExpression(#"\b401\b"#)

    public static func throwIfUnusable(_ accountResult: JSONValue?) throws {
        guard let result = accountResult, result.isObject else {
            return // account/read is optional; let the rate limit request decide.
        }

        guard let account = result["account"], account.isObject else {
            if result["requiresOpenaiAuth"]?.boolValue == true {
                throw UsageProviderError("Codex is not signed in. Run `codex login`.", kind: .signInRequired)
            }
            return
        }

        if account["type"]?.stringValue?.caseInsensitiveCompare("apiKey") == .orderedSame {
            throw UsageProviderError(
                "Codex is signed in with an API key; ChatGPT plan limits are only available after `codex login` with ChatGPT.")
        }
    }

    public static func isAuthenticationFailure(_ message: String) -> Bool {
        let lower = message.lowercased()
        return status401.isMatch(message) || authenticationMarkers.contains(where: lower.contains)
    }
}
