import CryptoKit
import Foundation

/// Stable local identity for one provider account. Provider credentials, email
/// addresses and server-side account IDs never become dictionary keys, cache
/// filenames or Keychain accounts.
struct AccountID: RawRepresentable, Codable, Hashable, Identifiable, Sendable {
    let rawValue: String
    var id: String { rawValue }

    init(rawValue: String) { self.rawValue = rawValue }

    /// The account the provider's own tools are already logged into.
    static func system(_ provider: Provider) -> AccountID {
        AccountID(rawValue: "system.\(provider.rawValue)")
    }

    static func managed(_ uuid: UUID) -> AccountID {
        AccountID(rawValue: "managed.\(uuid.uuidString.lowercased())")
    }

    /// An account the provider's own tools already hold, identified by that
    /// provider's key for it. Hashed so a provider-side identifier never
    /// becomes a filename or a Keychain account.
    static func discovered(_ provider: Provider, key: String) -> AccountID {
        AccountID(rawValue: "discovered.\(provider.rawValue).\(Self.digest(key))")
    }

    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .prefix(8)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

struct AccountProfile: Codable, Hashable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable {
        /// Reads whatever the provider's normal install is logged into.
        case system
        /// An app-owned account: an isolated CLI home, or a stored credential.
        case managed
        /// One of several accounts the provider's own CLI already holds.
        /// Limits does not own the credential and cannot remove it.
        case discovered
    }

    let id: AccountID
    let provider: Provider
    var displayName: String
    let kind: Kind
    /// App-owned isolated provider home. Always nil for system accounts and
    /// for `keychainSecret` providers, which get no filesystem home.
    let configurationDirectory: String?
    /// Fetched and shown on the Limits screen.
    var isEnabled: Bool
    /// Contributes to the menu bar title. Independent of `isEnabled` so the
    /// user can track an account without crowding the menu bar.
    var showsInMenuBar: Bool
    let createdAt: Date
    /// The provider's own identifier for a discovered account. Nil otherwise.
    var providerAccountKey: String?
    /// User override for the menu bar's two-character label. Nil derives one
    /// from the account name.
    var menuBarLabel: String?

    var isSystem: Bool { kind == .system }
    var isDiscovered: Bool { kind == .discovered }
    var credentialKind: AccountCredentialKind { provider.credentialKind }

    /// Only an app-owned CLI home can renew its OAuth session in place. A
    /// system account's session belongs to the user's own install, and Limits
    /// will not log that in or out from underneath them.
    var canSignInAgain: Bool {
        // Providers whose own CLI Limits can drive are renewable from here,
        // including accounts the user's tools already own.
        if provider.supportsInAppSignIn { return true }
        return !isSystem
            && credentialKind == .isolatedCLI
            && configurationDirectory != nil
    }

    var configurationDirectoryURL: URL? {
        configurationDirectory.map { URL(fileURLWithPath: $0) }
    }

    /// Two characters that tell this account apart from its siblings in the
    /// menu bar, where there is no room for a full name.
    ///
    /// Initials when the name reads as words ("Joe Clarke" → JC), otherwise
    /// the first two letters ("ezHomeSearch" → EZ). Only ever shown when a
    /// provider has more than one account in the menu bar, so single-account
    /// setups are unchanged.
    func resolvedMenuBarLabel(provider: Provider) -> String {
        if let menuBarLabel, !menuBarLabel.isEmpty { return menuBarLabel }
        return Self.derivedLabel(from: resolvedDisplayName(provider: provider))
    }

    /// Two-character labels that tell a set of same-provider names apart.
    ///
    /// "joe@ezhomesearch.com" and "joemclarke@gmail.com" both reduce to JO,
    /// which is useless. Keeping the first letter and taking the second from
    /// the first position where the names actually diverge gives JE and JM —
    /// still recognisable as the account, and now distinct.
    static func distinctLabels(for names: [String]) -> [String] {
        let letters = names.map { name in
            Array(name.filter { $0.isLetter || $0.isNumber }.uppercased())
        }
        guard let shortest = letters.map(\.count).min(), shortest > 0 else {
            return names.map { derivedLabel(from: $0) }
        }
        // First position where they are not all the same character.
        let divergence = (1..<max(shortest, 1)).first { index in
            Set(letters.map { $0[index] }).count > 1
        }
        guard let divergence else { return names.map { derivedLabel(from: $0) } }
        return letters.map { String([$0[0], $0[divergence]]) }
    }

    static func derivedLabel(from name: String) -> String {
        let words = name
            .split(whereSeparator: { $0.isWhitespace || $0 == "-" || $0 == "_" })
            .filter { $0.contains(where: \.isLetter) }
        if words.count >= 2 {
            let initials = words.prefix(2).compactMap { $0.first(where: \.isLetter) }
            if initials.count == 2 { return String(initials).uppercased() }
        }
        let letters = name.filter { $0.isLetter || $0.isNumber }
        guard !letters.isEmpty else { return "??" }
        return String(letters.prefix(2)).uppercased()
    }

    /// Falls back to the provider name so a row is never blank.
    func resolvedDisplayName(provider: Provider) -> String {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return isSystem ? "Current Account" : provider.displayName
    }

    /// A profile for an account read out of the provider's own credential
    /// store. Visibility settings are Limits'; the credential is not.
    static func discovered(
        _ provider: Provider,
        key: String,
        name: String,
        createdAt: Date = .distantPast
    ) -> AccountProfile {
        AccountProfile(
            id: .discovered(provider, key: key),
            provider: provider,
            displayName: name,
            kind: .discovered,
            configurationDirectory: nil,
            isEnabled: true,
            showsInMenuBar: true,
            createdAt: createdAt,
            providerAccountKey: key
        )
    }

    static func system(_ provider: Provider) -> AccountProfile {
        AccountProfile(
            id: .system(provider),
            provider: provider,
            displayName: "Current Account",
            kind: .system,
            configurationDirectory: nil,
            isEnabled: true,
            showsInMenuBar: true,
            createdAt: .distantPast
        )
    }
}

/// Live state for one account. `quota` is retained across a failed refresh so
/// a transient error shows last-known numbers next to the warning rather than
/// blanking the row.
struct AccountState: Hashable, Sendable {
    var quota: ProviderQuota?
    var issue: AccountIssue?
    var isRefreshing: Bool = false
    var lastRefreshedAt: Date?
    /// Set while a provider is rate limiting this account. Automatic refreshes
    /// skip the account until it passes, so a 429 is not answered with more
    /// requests to the endpoint that just sent it.
    var retryAt: Date?

    var hasAuthProblem: Bool { issue?.isAuthProblem == true }

    func isRateLimited(at now: Date = .now) -> Bool {
        guard let retryAt else { return false }
        return retryAt > now
    }

    /// Whether this account should raise a warning rather than just sit idle.
    ///
    /// "Not signed in" on a *system* account means the user simply does not
    /// use that provider on this Mac — there is nothing broken to fix, so it
    /// must not nag from the menu bar. An account the user explicitly added,
    /// or one whose session actually lapsed, does need attention.
    func needsAttention(isSystem: Bool) -> Bool {
        guard let issue, issue.isAuthProblem else { return false }
        if isSystem, issue == .notSignedIn { return false }
        return true
    }
}

/// An account paired with its state, ready to render.
struct AccountSnapshot: Identifiable, Hashable, Sendable {
    let profile: AccountProfile
    var state: AccountState

    var id: AccountID { profile.id }
    var provider: Provider { profile.provider }
    var quota: ProviderQuota? { state.quota }
    var issue: AccountIssue? { state.issue }
    var name: String { profile.resolvedDisplayName(provider: provider) }
    var needsAttention: Bool { state.needsAttention(isSystem: profile.isSystem) }
}
