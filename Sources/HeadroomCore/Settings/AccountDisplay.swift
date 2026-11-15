import Foundation

/// How the signed-in account (usually an email address) is shown in the panel.
public enum AccountDisplay: String, Codable, CaseIterable, Sendable {
    /// The full account, e.g. `name@example.com`.
    case full
    /// Only a few characters, e.g. `n•••e@e•••.com`.
    case masked
    /// Not shown at all.
    case hidden

    /// The account as it should be shown, or nil when it should not be shown.
    public func format(_ account: String?) -> String? {
        guard let account, !account.isEmpty else {
            return nil
        }
        switch self {
        case .full: return account
        case .masked: return AccountMasker.mask(account)
        case .hidden: return nil
        }
    }
}

/// Hides most of an account name while keeping it recognizable to its owner.
public enum AccountMasker {
    /// A fixed number of dots, so the masked text does not reveal the original length.
    static let dots = "•••"

    /// `name@example.com` -> `n•••e@e•••.com`; other text keeps only its first and last character.
    public static func mask(_ account: String) -> String {
        let text = account.trimmingCharacters(in: .whitespaces)
        guard let at = text.lastIndex(of: "@") else {
            return maskPart(text)
        }

        let local = String(text[..<at])
        let domain = String(text[text.index(after: at)...])
        return maskPart(local) + "@" + maskDomain(domain)
    }

    /// Keeps the top-level domain, which says little about the account: `example.com` -> `e•••.com`.
    private static func maskDomain(_ domain: String) -> String {
        guard let dot = domain.lastIndex(of: "."), dot != domain.startIndex else {
            return maskPart(domain)
        }
        return maskPart(String(domain[..<dot]), keepLast: false) + String(domain[dot...])
    }

    private static func maskPart(_ part: String, keepLast: Bool = true) -> String {
        guard let first = part.first else {
            return dots
        }
        // Short parts would be mostly revealed by their first and last character.
        guard keepLast, part.count > 3, let last = part.last else {
            return String(first) + dots
        }
        return String(first) + dots + String(last)
    }
}
