import Foundation

/// The single routing point from an account profile to live numbers. Each
/// provider client receives an explicit credential or an explicit isolated
/// home, so one account can never accidentally fall back to another account's
/// environment, config file or Keychain item.
struct QuotaFetcher: Sendable {
    func fetch(
        _ profile: AccountProfile,
        now: Date = .now,
        keychainInteraction: KeychainRead.Interaction = .disallowed
    ) async throws -> ProviderQuota {
        do {
            return try await route(profile, now: now, keychainInteraction: keychainInteraction)
        } catch let issue as AccountIssue {
            throw issue
        } catch let error as URLError {
            throw AccountIssue.network(Self.describe(error))
        } catch {
            throw AccountIssue.other(error.localizedDescription)
        }
    }

    private func route(
        _ profile: AccountProfile,
        now: Date,
        keychainInteraction: KeychainRead.Interaction
    ) async throws -> ProviderQuota {
        switch profile.provider {
        case .claude:
            return try await ClaudeUsageService().fetch(
                configurationDirectory: try isolatedDirectory(profile),
                now: now,
                keychainInteraction: keychainInteraction
            )
        case .codex:
            return try await CodexUsageService().fetch(
                configurationDirectory: try isolatedDirectory(profile),
                now: now,
                keychainInteraction: keychainInteraction
            )
        case .cursor:
            return try await CursorUsageService().fetch(token: try storedSecret(profile), now: now)
        case .grok:
            return try await GrokUsageService().fetch(token: try storedSecret(profile), now: now)
        case .antigravity:
            return try await AntigravityUsageService().fetch(
                now: now,
                keychainInteraction: keychainInteraction
            )
        }
    }

    /// A system account reads the provider's default home, so it passes `nil`.
    /// A managed account must have its own directory, and a missing one is a
    /// distinct, repairable failure rather than a silent fallback.
    private func isolatedDirectory(_ profile: AccountProfile) throws -> URL? {
        guard !profile.isSystem else { return nil }
        guard let directory = profile.configurationDirectoryURL else { throw AccountIssue.profileMissing }
        guard FileManager.default.fileExists(atPath: directory.path) else { throw AccountIssue.profileMissing }
        return directory
    }

    /// Managed accounts for credential-only providers must use their stored
    /// secret. System accounts pass `nil` so the service discovers the token
    /// the provider's own app maintains.
    private func storedSecret(_ profile: AccountProfile) throws -> String? {
        guard !profile.isSystem else { return nil }
        guard let secret = AccountSecretStore.load(for: profile.id), !secret.isEmpty else {
            throw AccountIssue.noCredentialStored
        }
        return secret
    }

    private static func describe(_ error: URLError) -> String {
        switch error.code {
        case .notConnectedToInternet: "No internet connection."
        case .timedOut: "The request timed out."
        case .cannotFindHost, .cannotConnectToHost: "Could not reach the provider."
        default: error.localizedDescription
        }
    }
}
