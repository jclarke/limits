import CryptoKit
import Foundation
import Security

/// Read-only discovery of the OAuth credential Claude Code maintains.
/// Derived from TokenRemain (Apache-2.0); see NOTICE.
struct ClaudeCredentialsReader {
    struct Credentials: Sendable {
        let accessToken: String
        let subscriptionType: String?
        let rateLimitTier: String?
    }

    struct ReadResult: Sendable {
        let credentials: Credentials?
        let keychainStatus: OSStatus?
        let hasExpiredCredentials: Bool

        var needsAuthorization: Bool {
            guard let keychainStatus else { return false }
            return keychainStatus == errSecAuthFailed
                || keychainStatus == errSecInteractionNotAllowed
                || keychainStatus == errSecUserCanceled
        }
    }

    private struct Parsed {
        let credentials: Credentials
        let expiresAt: Date?
    }

    var environment: [String: String] = ProcessInfo.processInfo.environment
    var homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    /// Managed profiles must never fall through to the user's active account.
    var fallbackToDefaultDirectory = true

    static let keychainService = "Claude Code-credentials"

    /// A token with less life left than this is treated as expired: one that
    /// would expire mid-request is worse than a clean fallback.
    static let expiryMargin: TimeInterval = 120

    func read(now: Date = .now, keychainInteraction: KeychainRead.Interaction = .disallowed) -> ReadResult {
        var foundExpired = false
        for payload in filePayloads() {
            guard let parsed = Self.decode(payload) else { continue }
            if Self.isUsable(parsed, now: now) {
                return ReadResult(credentials: parsed.credentials, keychainStatus: nil, hasExpiredCredentials: false)
            }
            foundExpired = true
        }
        // Automatic refresh must never summon the system password dialog. An
        // item already granted "Always Allow" still reads fine; anything else
        // fails silently and becomes a fixable issue in the UI.
        let outcome = KeychainRead.genericPassword(
            service: resolvedKeychainService,
            interaction: keychainInteraction
        )
        let parsed = outcome.payload.flatMap(Self.decode)
        let credentials = parsed.flatMap { Self.isUsable($0, now: now) ? $0.credentials : nil }
        return ReadResult(
            credentials: credentials,
            keychainStatus: outcome.status,
            hasExpiredCredentials: foundExpired || (parsed != nil && credentials == nil)
        )
    }

    /// The direct read is cheaper and wins whenever this app really is inside
    /// the item's partition. When it is not — the normal state for a
    /// credential a CLI wrote — retry through `/usr/bin/security`.
    func readAllowingAppleTool(
        now: Date = .now,
        keychainInteraction: KeychainRead.Interaction = .disallowed
    ) async -> ReadResult {
        let direct = read(now: now, keychainInteraction: keychainInteraction)
        guard direct.credentials == nil, direct.needsAuthorization else { return direct }

        let outcome = await KeychainRead.genericPasswordViaAppleTool(service: resolvedKeychainService)
        guard let payload = outcome.payload, let parsed = Self.decode(payload) else {
            // Keep the direct result: it already describes why the item is out
            // of reach, and the delegate adds no new recovery action.
            return direct
        }
        guard Self.isUsable(parsed, now: now) else {
            return ReadResult(credentials: nil, keychainStatus: outcome.status, hasExpiredCredentials: true)
        }
        return ReadResult(credentials: parsed.credentials, keychainStatus: outcome.status, hasExpiredCredentials: false)
    }

    private static func decode(_ payload: String) -> Parsed? {
        guard let data = payload.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let oauth = object["claudeAiOauth"] as? [String: Any],
              let accessToken = (oauth["accessToken"] as? String)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !accessToken.isEmpty else { return nil }
        return Parsed(
            credentials: Credentials(
                accessToken: accessToken,
                subscriptionType: oauth["subscriptionType"] as? String,
                rateLimitTier: oauth["rateLimitTier"] as? String
            ),
            // Claude Code writes epoch milliseconds.
            expiresAt: (oauth["expiresAt"] as? NSNumber).map {
                Date(timeIntervalSince1970: $0.doubleValue / 1000)
            }
        )
    }

    private static func isUsable(_ parsed: Parsed, now: Date) -> Bool {
        parsed.expiresAt.map { $0.timeIntervalSince(now) > expiryMargin } ?? true
    }

    /// Claude Code 2.1+ stores OAuth tokens in a Keychain item named after the
    /// configuration home. The default `~/.claude` keeps the historical
    /// unsuffixed service; any other `CLAUDE_CONFIG_DIR` gets
    /// `Claude Code-credentials-<sha256(path)[:8]>`. Hashing the path Claude
    /// itself received is exactly what stops a second account from inheriting
    /// the system login.
    static func keychainServiceName(
        configurationDirectory: String?,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> String {
        guard var path = configurationDirectory?
            .trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else {
            return keychainService
        }
        if path.hasPrefix("~") { path = homeDirectory.path + path.dropFirst() }
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        if path == homeDirectory.appending(path: ".claude").path { return keychainService }
        let digest = SHA256.hash(data: Data(path.utf8))
        let suffix = digest.prefix(4).map { String(format: "%02x", $0) }.joined()
        return "\(keychainService)-\(suffix)"
    }

    private var resolvedKeychainService: String {
        Self.keychainServiceName(
            configurationDirectory: environment["CLAUDE_CONFIG_DIR"],
            homeDirectory: homeDirectory
        )
    }

    /// Older Claude Code versions wrote `.credentials.json` next to the config.
    private func filePayloads() -> [String] {
        var directories: [URL] = []
        if let configDir = environment["CLAUDE_CONFIG_DIR"]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !configDir.isEmpty {
            let expanded = configDir.hasPrefix("~") ? homeDirectory.path + configDir.dropFirst() : configDir
            directories.append(URL(fileURLWithPath: String(expanded)))
        }
        if fallbackToDefaultDirectory {
            directories.append(homeDirectory.appending(path: ".claude"))
        }
        return directories.compactMap {
            try? String(contentsOf: $0.appending(path: ".credentials.json"), encoding: .utf8)
        }
    }
}
