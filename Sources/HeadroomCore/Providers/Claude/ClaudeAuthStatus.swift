import Foundation

/// Parsed output of `claude auth status --json`, which reads the local login without contacting the model.
public struct ClaudeAuthStatus: Equatable, Sendable {
    public var loggedIn: Bool
    public var authMethod: String?
    public var apiProvider: String?
    public var email: String?
    public var subscriptionType: String?

    /// Signed in with a claude.ai subscription, the only login that has /usage quotas.
    public var isSubscription: Bool {
        authMethod?.caseInsensitiveCompare("claude.ai") == .orderedSame
            && (apiProvider == nil || apiProvider?.caseInsensitiveCompare("firstParty") == .orderedSame)
    }

    public var planDisplayName: String? { capitalizeFirst(subscriptionType) }

    /// Returns nil when the output is not the expected JSON (e.g. an older CLI).
    public static func tryParse(_ output: String) -> ClaudeAuthStatus? {
        guard let text = extractJSONObject(output), let json = JSONValue.tryParse(text), json.isObject,
              let loggedIn = json["loggedIn"]?.boolValue
        else {
            return nil
        }

        func string(_ key: String) -> String? {
            guard let value = json[key]?.stringValue, !value.trimmingCharacters(in: .whitespaces).isEmpty else {
                return nil
            }
            return value
        }

        return ClaudeAuthStatus(
            loggedIn: loggedIn,
            authMethod: string("authMethod"),
            apiProvider: string("apiProvider"),
            email: string("email"),
            subscriptionType: string("subscriptionType"))
    }
}
