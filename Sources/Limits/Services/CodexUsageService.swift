import CryptoKit
import Foundation
import Security

/// Reads the OAuth access token the Codex CLI already holds and calls the
/// ChatGPT backend usage endpoint. Derived from TokenRemain (Apache-2.0).
///
/// Limits never refreshes the token and never writes back `auth.json`.
struct CodexUsageService {
    private static let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

    func fetch(
        configurationDirectory: URL? = nil,
        now: Date = .now,
        keychainInteraction: KeychainRead.Interaction = .disallowed
    ) async throws -> ProviderQuota {
        var reader = CodexAuthReader()
        if let configurationDirectory {
            reader.environment["CODEX_HOME"] = configurationDirectory.path
        }
        let result = reader.read(now: now, keychainInteraction: keychainInteraction)
        guard let auth = result.auth else {
            if result.needsAuthorization { throw AccountIssue.needsKeychainAuthorization }
            throw AccountIssue.notSignedIn
        }
        // Pre-screen the JWT so a certain 401 never leaves the machine.
        if let expiry = auth.accessTokenExpiry, expiry <= now { throw AccountIssue.sessionExpired }

        var request = URLRequest(url: Self.usageURL)
        request.timeoutInterval = 15
        request.setValue("Bearer \(auth.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let accountID = auth.accountID, !accountID.isEmpty {
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AccountIssue.other("Invalid response from Codex.") }
        switch http.statusCode {
        case 200..<300: break
        case 401, 403: throw AccountIssue.tokenRejected(status: http.statusCode)
        case 429: throw AccountIssue.rateLimited(retryAfterSeconds: nil)
        default: throw AccountIssue.requestFailed(status: http.statusCode)
        }
        return try CodexUsageParser.parse(data, now: now)
    }
}

/// `wham/usage` → `ProviderQuota`. Windows live at `rate_limit.primary_window`
/// and `.secondary_window` with `used_percent`, `limit_window_seconds`, and
/// either `reset_at` (epoch seconds) or `reset_after_seconds`.
///
/// Normally primary is 5 hours and secondary 7 days, but when only a weekly
/// window remains the server moves it into the primary slot — so classify by
/// `limit_window_seconds` first and treat slot order as a fallback only.
enum CodexUsageParser {
    private static let sessionSeconds = 300 * 60
    private static let weeklySeconds = 10_080 * 60

    static func parse(_ data: Data, now: Date = .now) throws -> ProviderQuota {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw AccountIssue.other("Codex returned an unreadable response.")
        }
        let rateLimit = object["rate_limit"] as? [String: Any]
        let candidates: [(window: [String: Any], fallbackSession: Bool)] = [
            (rateLimit?["primary_window"], true),
            (rateLimit?["secondary_window"], false)
        ].compactMap { value, fallbackSession in
            guard let window = value as? [String: Any] else { return nil }
            return (window, fallbackSession)
        }

        let session = classified(candidates, seconds: sessionSeconds, fallbackSession: true,
                                 label: "5 hr window", id: "session", now: now)
        let weekly = classified(candidates, seconds: weeklySeconds, fallbackSession: false,
                                label: "7 d window", id: "weekly", now: now)

        guard let first = session ?? weekly else {
            throw AccountIssue.other("Codex reported no usage windows.")
        }
        var windows = [first]
        if session != nil, let weekly { windows.append(weekly) }

        return ProviderQuota(
            provider: .codex,
            planName: planName(object["plan_type"]),
            windows: windows,
            capturedAt: now
        )
    }

    /// "prolite" → "Pro 5x", "pro" → "Pro 20x", matching Codex's own naming.
    static func planName(_ value: Any?) -> String? {
        guard let raw = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        switch raw.lowercased() {
        case "prolite": return "Pro 5x"
        case "pro": return "Pro 20x"
        default:
            return raw.split(separator: "_")
                .map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }
                .joined(separator: " ")
        }
    }

    private static func classified(
        _ candidates: [(window: [String: Any], fallbackSession: Bool)],
        seconds: Int,
        fallbackSession: Bool,
        label: String,
        id: String,
        now: Date
    ) -> QuotaWindow? {
        let exact = candidates.first { windowSeconds($0.window) == seconds }
        let fallback = candidates.first { windowSeconds($0.window) == nil && $0.fallbackSession == fallbackSession }
        guard let candidate = exact ?? fallback,
              let used = number(candidate.window["used_percent"]) else { return nil }
        let resolvedSeconds = windowSeconds(candidate.window) ?? seconds
        let minutes = resolvedSeconds / 60
        return QuotaWindow(
            id: id,
            // A window that landed in an unexpected slot still labels itself
            // honestly from its real duration.
            label: resolvedSeconds == seconds ? label : "\(durationLabel(minutes)) window",
            usedPercent: min(100, max(0, used)),
            windowMinutes: minutes,
            resetsAt: resetDate(candidate.window, now: now)
        )
    }

    private static func durationLabel(_ minutes: Int) -> String {
        if minutes % (60 * 24) == 0 { return "\(minutes / (60 * 24)) d" }
        if minutes % 60 == 0 { return "\(minutes / 60) hr" }
        return "\(minutes) min"
    }

    private static func windowSeconds(_ window: [String: Any]) -> Int? {
        guard let seconds = number(window["limit_window_seconds"]), seconds > 0 else { return nil }
        return Int(seconds)
    }

    private static func resetDate(_ window: [String: Any], now: Date) -> Date? {
        if let resetAt = number(window["reset_at"]), resetAt > 0 {
            return Date(timeIntervalSince1970: resetAt)
        }
        if let after = number(window["reset_after_seconds"]), after >= 0 {
            return now.addingTimeInterval(after)
        }
        return nil
    }

    private static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let text = value as? String { return Double(text) }
        return nil
    }
}

/// Read-only discovery of the Codex login. Prefers `$CODEX_HOME/auth.json`,
/// then the macOS keyring item Codex maintains. Derived from TokenRemain.
struct CodexAuthReader {
    struct Auth: Sendable {
        let accessToken: String
        let accountID: String?
        let accessTokenExpiry: Date?
    }

    struct ReadResult: Sendable {
        let auth: Auth?
        let keychainStatus: OSStatus?

        var needsAuthorization: Bool {
            guard let keychainStatus else { return false }
            return keychainStatus == errSecAuthFailed
                || keychainStatus == errSecInteractionNotAllowed
                || keychainStatus == errSecUserCanceled
        }
    }

    var environment: [String: String] = ProcessInfo.processInfo.environment
    var homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    static let keychainService = "Codex Auth"

    func read(now: Date = .now, keychainInteraction: KeychainRead.Interaction = .disallowed) -> ReadResult {
        let fileAuth = (try? Data(contentsOf: authFileURL())).flatMap(Self.parse)
        if let fileAuth, !Self.isExpired(fileAuth, now: now) {
            return ReadResult(auth: fileAuth, keychainStatus: nil)
        }
        let outcome = KeychainRead.genericPassword(
            service: Self.keychainService,
            account: keychainAccount(),
            interaction: keychainInteraction
        )
        let keychainAuth = outcome.payload.flatMap { $0.data(using: .utf8) }.flatMap(Self.parse)
        if let keychainAuth, !Self.isExpired(keychainAuth, now: now) {
            return ReadResult(auth: keychainAuth, keychainStatus: outcome.status)
        }
        // Keep an expired but well-formed credential so the caller can report
        // "session expired" rather than the misleading "not signed in".
        return ReadResult(auth: fileAuth ?? keychainAuth, keychainStatus: outcome.status)
    }

    static func parse(_ data: Data) -> Auth? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let tokens = object["tokens"] as? [String: Any],
              let accessToken = (tokens["access_token"] as? String)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !accessToken.isEmpty else { return nil }
        return Auth(
            accessToken: accessToken,
            accountID: tokens["account_id"] as? String,
            accessTokenExpiry: JWT.expiry(accessToken)
        )
    }

    private static func isExpired(_ auth: Auth, now: Date) -> Bool {
        auth.accessTokenExpiry.map { $0 <= now } ?? false
    }

    private func authFileURL() -> URL { codexHomeURL().appending(path: "auth.json") }

    private func codexHomeURL() -> URL {
        guard let configured = environment["CODEX_HOME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !configured.isEmpty else {
            return homeDirectory.appending(path: ".codex")
        }
        let expanded = configured.hasPrefix("~") ? homeDirectory.path + configured.dropFirst() : configured
        return URL(fileURLWithPath: String(expanded))
    }

    /// Codex keys its keyring item by the first 16 hex characters of the
    /// SHA-256 of the canonical CODEX_HOME: `cli|<digest>`.
    func keychainAccount() -> String {
        let url = codexHomeURL()
        let canonical = FileManager.default.fileExists(atPath: url.path)
            ? url.resolvingSymlinksInPath().standardizedFileURL
            : url.standardizedFileURL
        let digest = SHA256.hash(data: Data(canonical.path.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return "cli|\(digest.prefix(16))"
    }
}
