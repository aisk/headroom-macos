import Foundation

/// Maps a failed `agy` usage report to a fixed message. Raw CLI output is never shown because it can
/// contain account-identifying URLs, proxy details, or local paths. Markers follow CodexBar's classifier.
public enum AntigravityFailureClassifier {
    // A blocking login prompt or an explicit logout. A transient "not signed in" line alone is not
    // enough evidence because agy prints it briefly before silently refreshing an existing login.
    private static let authenticationPrompts = [
        #"select\s+login\s+method\s*:?"#,
        #"you\s+are\s+not\s+logged\s+into\s+antigravity"#,
        #"keyring\s*auth\s*:\s*timed\s+out\b"#,
    ].map { NSRegularExpression($0, ignoreCase: true) }

    private static let signInMarkers = [
        "not logged in", "not signed in", "unauthenticated", "authentication required", "login required",
        "please log in", "please sign in", "sign in required", "sign-in required",
    ]

    private static let eligibilityMarkers = [
        "eligibility check failed", "not eligible", "does not support google tos", "unsupported country", "unsupported region",
    ]

    private static let networkMarkers = [
        #"\beof\b"#, #"\btimed out\b"#, #"\btimeout\b"#, #"\bdeadline exceeded\b"#, #"\bi/o timeout\b"#,
        #"\bno such host\b"#, #"\bdns\b"#, #"\bconnection refused\b"#, #"\bconnection reset\b"#,
        #"\bnetwork is unreachable\b"#, #"\bunreachable\b"#, #"\bproxy\b"#, #"\bcertificate\b"#, #"\btls\b"#,
        #"\bssl\b"#, #"get "http"#, #"post "http"#,
    ].map { NSRegularExpression($0, ignoreCase: true) }

    public static func classify(exitCode: Int32, output: String) -> UsageProviderError {
        tryClassify(exitCode: exitCode, output: output)
            ?? UsageProviderError("agy exited \(exitCode) without a usage report.")
    }

    /// Returns nil when the output matches no known failure.
    public static func tryClassify(exitCode: Int32, output: String) -> UsageProviderError? {
        let lower = output.lowercased()
        if authenticationPrompts.contains(where: { $0.isMatch(output) }) || signInMarkers.contains(where: lower.contains) {
            return UsageProviderError(
                "Antigravity is not signed in. Run `agy` in a terminal to sign in, then refresh.",
                kind: .signInRequired)
        }

        let networkFailed = networkMarkers.contains { $0.isMatch(output) }
        if eligibilityMarkers.contains(where: lower.contains) {
            return UsageProviderError(networkFailed
                ? "agy exited \(exitCode); the eligibility check failed on a network request (check network or proxy settings)."
                : "agy exited \(exitCode); the account is not eligible for Antigravity.")
        }

        if networkFailed {
            return UsageProviderError("agy exited \(exitCode); a network request failed (check network or proxy settings).")
        }
        return nil
    }
}
