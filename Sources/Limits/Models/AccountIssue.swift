import Foundation

/// Why an account has no fresh numbers, paired with the one action that fixes
/// it. Every surface that shows an account — menu bar, popover, Limits,
/// Providers — renders the same remedy, so a broken login is repairable from
/// wherever the user happens to notice it.
enum AccountIssue: Codable, Hashable, Sendable {
    case notSignedIn
    case sessionExpired
    /// The credential exists but this app may not read the Keychain item yet.
    case needsKeychainAuthorization
    case tokenRejected(status: Int)
    case rateLimited(retryAfterSeconds: Int?)
    case requestFailed(status: Int)
    case cliMissing(executable: String)
    /// The isolated profile directory is gone or unreadable.
    case profileMissing
    case noCredentialStored
    case network(String)
    case other(String)

    /// Drives the warning glyph in the menu bar and the "needs attention"
    /// grouping. A rate limit or a flaky network is not the user's to fix.
    var isAuthProblem: Bool {
        switch self {
        case .notSignedIn, .sessionExpired, .needsKeychainAuthorization,
             .tokenRejected, .cliMissing, .profileMissing, .noCredentialStored:
            true
        case .rateLimited, .requestFailed, .network, .other:
            false
        }
    }

    var title: String {
        switch self {
        case .notSignedIn: "Not signed in"
        case .sessionExpired: "Session expired"
        case .needsKeychainAuthorization: "Keychain access needed"
        case .tokenRejected: "Sign-in rejected"
        case .rateLimited: "Rate limited"
        case .requestFailed: "Couldn't reach provider"
        case .cliMissing: "CLI not found"
        case .profileMissing: "Profile missing"
        case .noCredentialStored: "No credential saved"
        case .network: "Network error"
        case .other: "Unavailable"
        }
    }

    func message(provider: Provider) -> String {
        switch self {
        case .notSignedIn:
            return "No \(provider.displayName) session was found for this account."
        case .sessionExpired:
            return expiryGuidance(provider)
        case .needsKeychainAuthorization:
            return "\(provider.displayName) stored its login in the Keychain and Limits has not been allowed to read it yet."
        case .tokenRejected(let status):
            return "\(provider.displayName) rejected the saved session (HTTP \(status))."
        case .rateLimited(let seconds):
            if let seconds {
                let minutes = max(1, Int(ceil(Double(seconds) / 60)))
                return "\(provider.displayName) is rate limiting usage checks. Retrying in about \(minutes) min."
            }
            return "\(provider.displayName) is rate limiting usage checks. Limits will retry shortly."
        case .requestFailed(let status):
            return "\(provider.displayName) returned HTTP \(status)."
        case .cliMissing(let executable):
            return "The `\(executable)` command isn't installed where Limits can find it. Install it, then try again."
        case .profileMissing:
            return "This account's isolated profile folder is gone. Sign in again to recreate it."
        case .noCredentialStored:
            return "This account has no saved credential yet."
        case .network(let detail):
            return detail
        case .other(let detail):
            return detail
        }
    }

    /// Limits never refreshes a provider's token, so an expired session is
    /// repaired by the provider itself — by signing in again where there is a
    /// CLI login, or by letting the app renew its own token where there isn't.
    private func expiryGuidance(_ provider: Provider) -> String {
        switch provider.credentialKind {
        case .isolatedCLI:
            return "This \(provider.displayName) session has expired. Sign in again to renew it."
        case .keychainSecret:
            return "This \(provider.displayName) session has expired. Open \(provider.displayName) once so it renews its own login, or paste a fresh token."
        }
    }

    /// The single action offered next to the message.
    func remedy(for account: AccountProfile) -> Remedy {
        switch self {
        case .rateLimited, .requestFailed, .network, .other:
            return .retry
        case .needsKeychainAuthorization:
            return .authorizeKeychain
        case .cliMissing(let executable):
            return .installCLI(executable: executable)
        case .notSignedIn, .sessionExpired, .tokenRejected,
             .profileMissing, .noCredentialStored:
            break
        }
        // A remedy must match how the account authenticates, not just what
        // broke: a system account has no app-owned session to replace.
        switch account.credentialKind {
        case .isolatedCLI:
            return account.isSystem ? .signInWithProviderApp : .signInAgain
        case .keychainSecret:
            return account.isSystem ? .signInWithProviderApp : .replaceToken
        }
    }

    enum Remedy: Hashable, Sendable {
        /// Re-run the provider CLI's OAuth login into this account's home.
        case signInAgain
        /// System accounts: the user logs in through the provider itself.
        case signInWithProviderApp
        /// Replace the pasted credential held in the Keychain.
        case replaceToken
        /// Prompt once, with interaction allowed, to unlock the Keychain item.
        case authorizeKeychain
        case installCLI(executable: String)
        case retry

        var actionLabel: String {
            switch self {
            case .signInAgain: "Sign in again"
            case .signInWithProviderApp: "How to fix"
            case .replaceToken: "Update token"
            case .authorizeKeychain: "Allow access"
            case .installCLI: "Learn more"
            case .retry: "Retry"
            }
        }
    }
}

/// Services throw issues directly so the routing layer never has to translate
/// a provider-specific error into a remedy a second time.
extension AccountIssue: Error {}
