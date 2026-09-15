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
}

struct AccountProfile: Codable, Hashable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable {
        /// Reads whatever the provider's normal install is logged into.
        case system
        /// An app-owned account: an isolated CLI home, or a stored credential.
        case managed
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

    var isSystem: Bool { kind == .system }
    var credentialKind: AccountCredentialKind { provider.credentialKind }

    /// Only an app-owned CLI home can renew its OAuth session in place. A
    /// system account's session belongs to the user's own install, and Limits
    /// will not log that in or out from underneath them.
    var canSignInAgain: Bool {
        // Antigravity is the exception: Limits can drive its CLI's browser
        // sign-in directly, so even the account the user's own tools use can
        // be renewed from here rather than from a terminal.
        if provider.supportsInAppSignIn { return true }
        return !isSystem
            && credentialKind == .isolatedCLI
            && configurationDirectory != nil
    }

    var configurationDirectoryURL: URL? {
        configurationDirectory.map { URL(fileURLWithPath: $0) }
    }

    /// Falls back to the provider name so a row is never blank.
    func resolvedDisplayName(provider: Provider) -> String {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return isSystem ? "Current Account" : provider.displayName
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

    var hasAuthProblem: Bool { issue?.isAuthProblem == true }

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
