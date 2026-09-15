import Foundation
import OSLog

/// Antigravity (Google's agentic IDE) quota pools. Derived from TokenRemain
/// (Apache-2.0); see NOTICE.
///
/// Prefers the language server the running Antigravity app already exposes on
/// loopback — that reuses the app's live session and never touches the shared
/// `gemini` Keychain item. Only when the local service is unavailable does it
/// fall back to an already-authorized Keychain read. Limits never performs a
/// Google OAuth refresh and never raises an authorization dialog in the
/// background.
struct AntigravityUsageService {
    private static let quotaSummaryURLs = [
        URL(string: "https://daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary")!,
        URL(string: "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary")!
    ]
    private static let logger = Logger(subsystem: "com.josephclarke.limits", category: "Antigravity")

    /// Antigravity keeps one credential for one account, so there is no
    /// per-account routing to do here.
    func fetch(
        now: Date = .now,
        keychainInteraction: KeychainRead.Interaction = .disallowed
    ) async throws -> ProviderQuota {

        var localProbeFoundApp = false
        do {
            let quota = try await AntigravityLocalUsageProbe().fetch(now: now)
            Self.logger.info("Antigravity quota served by local language server")
            return quota
        } catch let error as AntigravityLocalUsageProbe.ProbeError {
            // "App is running but wouldn't answer" is a different message from
            // "Antigravity isn't running", so keep them apart.
            localProbeFoundApp = error != .processUnavailable
        } catch {
            localProbeFoundApp = false
        }

        guard let token = await AntigravityTokenReader().load(keychainInteraction: keychainInteraction) else {
            throw localProbeFoundApp
                ? AccountIssue.other("Antigravity is running but did not report quota. Try again in a moment.")
                : AccountIssue.notSignedIn
        }
        return try await fetch(token: token, now: now)
    }

    private func fetch(token: AntigravityTokenReader.Token, now: Date) async throws -> ProviderQuota {
        if let expiry = token.expiry ?? JWT.expiry(token.accessToken), expiry <= now {
            throw AccountIssue.sessionExpired
        }
        var lastStatus = 0
        for url in Self.quotaSummaryURLs {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 15
            request.httpBody = Data("{}".utf8)
            request.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("antigravity", forHTTPHeaderField: "User-Agent")

            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  let http = response as? HTTPURLResponse else { continue }
            switch http.statusCode {
            case 200..<300:
                return try AntigravityUsageParser.parse(data, now: now)
            case 401, 403:
                // The same token will fail against the other base too.
                throw AccountIssue.sessionExpired
            default:
                lastStatus = http.statusCode
                continue
            }
        }
        throw lastStatus > 0
            ? AccountIssue.requestFailed(status: lastStatus)
            : AccountIssue.other("Antigravity returned no usable response.")
    }
}

/// `RetrieveUserQuotaSummary` → `ProviderQuota`. The response is
/// `{"groups": [{"buckets": [{bucketId, remainingFraction, resetTime}]}]}`,
/// possibly wrapped in `response`. Four buckets are known: `gemini-5h` and
/// `gemini-weekly` are the account's own pools; `3p-5h` and `3p-weekly` are
/// the shared third-party (Claude) pools, carried as scoped windows.
/// `remainingFraction` is 0…1 remaining, inverted here to percent used.
enum AntigravityUsageParser {
    /// Any other bucket ID has unknown semantics. Log it and skip rather than
    /// render a number whose meaning is a guess.
    private static let knownBucketIDs: Set<String> = ["gemini-5h", "gemini-weekly", "3p-5h", "3p-weekly"]
    private static let logger = Logger(subsystem: "com.josephclarke.limits", category: "Antigravity")

    static func parse(_ data: Data, now: Date = .now) throws -> ProviderQuota {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw AccountIssue.other("Antigravity returned an unreadable response.")
        }
        let container = (root["response"] as? [String: Any]) ?? root
        guard let groups = container["groups"] as? [[String: Any]] else {
            throw AccountIssue.other("Antigravity returned an unreadable response.")
        }

        var pools: [String: (used: Double, resetsAt: Date?)] = [:]
        for group in groups {
            for bucket in group["buckets"] as? [[String: Any]] ?? [] {
                guard let id = bucket["bucketId"] as? String,
                      pools[id] == nil,
                      let fraction = number(bucket["remainingFraction"]), fraction.isFinite else {
                    continue
                }
                guard knownBucketIDs.contains(id) else {
                    logger.info("Skipping unknown Antigravity quota bucket \(id, privacy: .public)")
                    continue
                }
                pools[id] = (min(100, max(0, (1 - fraction) * 100)), isoDate(bucket["resetTime"]))
            }
        }

        func window(_ id: String, label: String, minutes: Int, scoped: Bool) -> QuotaWindow? {
            guard let pool = pools[id] else { return nil }
            return QuotaWindow(
                id: id,
                label: label,
                usedPercent: pool.used,
                windowMinutes: minutes,
                resetsAt: pool.resetsAt,
                isScoped: scoped
            )
        }

        var windows: [QuotaWindow] = []
        if let session = window("gemini-5h", label: "5 hr window", minutes: 300, scoped: false) {
            windows.append(session)
            if let weekly = window("gemini-weekly", label: "7 d window", minutes: 10_080, scoped: false) {
                windows.append(weekly)
            }
        } else if let weekly = window("gemini-weekly", label: "7 d window", minutes: 10_080, scoped: false) {
            windows.append(weekly)
        } else {
            throw AccountIssue.other("Antigravity reported no quota buckets.")
        }

        if let third = window("3p-5h", label: "Claude / Third-party · 5 hr window", minutes: 300, scoped: true) {
            windows.append(third)
        }
        if let third = window("3p-weekly", label: "Claude / Third-party · 7 d window", minutes: 10_080, scoped: true) {
            windows.append(third)
        }

        return ProviderQuota(provider: .antigravity, planName: nil, windows: windows, capturedAt: now)
    }

    private static func isoDate(_ value: Any?) -> Date? {
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }

    private static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let text = value as? String { return Double(text) }
        return nil
    }
}

/// Read-only discovery of Antigravity's Google OAuth token: Keychain service
/// `gemini`, account `antigravity`. The value may be go-keyring base64-wrapped
/// JSON `{token: {access_token, expiry}}`, or a bare token / `Bearer x`.
struct AntigravityTokenReader {
    struct Token: Sendable {
        let accessToken: String
        let expiry: Date?
    }

    static let keychainService = "gemini"
    static let keychainAccount = "antigravity"

    /// The Antigravity CLI writes this item through the legacy keychain, which
    /// stamps it `apple-tool:` and admits no GUI app into its partition — the
    /// same situation as Claude Code's credential. So try the direct read
    /// first and fall back to `/usr/bin/security`, the one path that partition
    /// actually allows. Without the fallback a signed-in user reads as
    /// "not signed in".
    func load(keychainInteraction: KeychainRead.Interaction = .disallowed) async -> Token? {
        let direct = KeychainRead.genericPassword(
            service: Self.keychainService,
            account: Self.keychainAccount,
            interaction: keychainInteraction
        )
        if let raw = direct.payload, let text = GoKeyring.unwrap(raw), let token = Self.parse(text) {
            return token
        }
        guard direct.payload == nil else { return nil }
        let delegated = await KeychainRead.genericPasswordViaAppleTool(
            service: Self.keychainService,
            account: Self.keychainAccount
        )
        guard let raw = delegated.payload, let text = GoKeyring.unwrap(raw) else { return nil }
        return Self.parse(text)
    }

    static func parse(_ text: String) -> Token? {
        if let data = text.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data) {
            if let object = json as? [String: Any] { return token(fromObject: object) }
            if let string = (json as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !string.isEmpty {
                return Token(accessToken: string, expiry: nil)
            }
            return nil
        }
        // Structured content that failed to parse is corrupt, not a bare token.
        if text.hasPrefix("{") || text.hasPrefix("[") { return nil }
        if text.hasPrefix("Bearer ") {
            let token = String(text.dropFirst("Bearer ".count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return token.isEmpty ? nil : Token(accessToken: token, expiry: nil)
        }
        return Token(accessToken: text, expiry: nil)
    }

    private static func token(fromObject object: [String: Any]) -> Token? {
        let source = (object["token"] as? [String: Any]) ?? object
        let accessToken = ["access_token", "accessToken", "id_token"]
            .lazy
            .compactMap { (source[$0] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        guard let accessToken else { return nil }
        var expiry: Date?
        if let raw = (source["expiry"] as? String) ?? (source["expires_at"] as? String) {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            expiry = formatter.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
        } else if let epoch = number(source["expiry"]) ?? number(source["expires_at"]) {
            expiry = Date(timeIntervalSince1970: epoch > 1e10 ? epoch / 1000 : epoch)
        }
        return Token(accessToken: accessToken, expiry: expiry ?? JWT.expiry(accessToken))
    }

    private static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let text = value as? String { return Double(text) }
        return nil
    }
}

/// go-keyring (the Keychain library used by Go tools) wraps longer values as
/// `go-keyring-base64:<b64>` and stores short ones verbatim.
enum GoKeyring {
    static let base64Prefix = "go-keyring-base64:"

    static func unwrap(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(base64Prefix) else { return trimmed.isEmpty ? nil : trimmed }
        guard let data = Data(base64Encoded: String(trimmed.dropFirst(base64Prefix.count))),
              let text = String(data: data, encoding: .utf8) else { return nil }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
