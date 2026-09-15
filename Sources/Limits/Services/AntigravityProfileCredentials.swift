import Foundation

/// Reads the OAuth credential Antigravity's CLI keeps inside an app-owned
/// profile, and asks the CLI to renew it when it has lapsed.
///
/// Limits still never mints or refreshes a token itself. Renewal is done by
/// running `agy` against the profile so Antigravity's own code performs the
/// exchange with its own client credentials — the same principle as leaving
/// Claude Code and Codex to renew their sessions, applied to a profile that
/// happens to belong to Limits.
enum AntigravityProfileCredentials {
    /// `agy models` needs a signed-in profile but runs no model turn, so it
    /// refreshes the stored token without spending any quota.
    private static let refreshArguments = ["models"]

    static func read(
        configurationDirectory: URL,
        now: Date = .now
    ) async throws -> AntigravityTokenReader.Token {
        guard FileManager.default.fileExists(atPath: configurationDirectory.path) else {
            throw AccountIssue.profileMissing
        }
        let credentialURL = AntigravityEnvironment.credentialURL(
            configurationDirectory: configurationDirectory
        )

        if let token = load(credentialURL), !isExpired(token, now: now) {
            return token
        }

        // Either nothing is stored yet or it lapsed. A profile with no
        // credential at all has never completed sign-in.
        guard load(credentialURL) != nil else { throw AccountIssue.notSignedIn }

        await refresh(configurationDirectory: configurationDirectory)

        guard let renewed = load(credentialURL) else { throw AccountIssue.sessionExpired }
        guard !isExpired(renewed, now: now) else { throw AccountIssue.sessionExpired }
        return renewed
    }

    /// Runs the CLI against this profile so it renews its own token in place.
    /// Failures are silent: the caller re-reads the file and reports
    /// "session expired" if nothing changed, which is the useful message.
    private static func refresh(configurationDirectory: URL) async {
        guard let executable = AccountLoginService.executable(for: .antigravity) else { return }
        _ = try? await ProcessRunner.run(
            executable.path,
            arguments: refreshArguments,
            environment: AntigravityEnvironment.build(
                configurationDirectory: configurationDirectory,
                executable: executable
            ),
            timeout: 45
        )
    }

    /// `oauth_creds.json` is Google's standard credential shape:
    /// `{access_token, refresh_token, scope, token_type, id_token, expiry_date}`
    /// with `expiry_date` in epoch milliseconds.
    static func load(_ url: URL) -> AntigravityTokenReader.Token? {
        guard let data = try? Data(contentsOf: url),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let accessToken = (object["access_token"] as? String)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !accessToken.isEmpty else { return nil }
        let expiry = (object["expiry_date"] as? NSNumber).map {
            Date(timeIntervalSince1970: $0.doubleValue / 1000)
        }
        return AntigravityTokenReader.Token(
            accessToken: accessToken,
            expiry: expiry ?? JWT.expiry(accessToken)
        )
    }

    /// True once a signed-in profile exists, which is how a completed sign-in
    /// is confirmed — the CLI's exit code cannot be used, since Limits kills it
    /// mid-prompt as soon as authentication resolves.
    static func hasCredential(configurationDirectory: URL) -> Bool {
        load(AntigravityEnvironment.credentialURL(configurationDirectory: configurationDirectory)) != nil
    }

    private static func isExpired(_ token: AntigravityTokenReader.Token, now: Date) -> Bool {
        // A token about to lapse mid-request is no more useful than an expired
        // one, so renew slightly early.
        guard let expiry = token.expiry else { return false }
        return expiry.timeIntervalSince(now) <= 60
    }
}
