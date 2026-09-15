import Foundation

/// Grok (xAI) shared credit pool. Reads the credential the Grok CLI already
/// holds in `~/.grok/auth.json` and calls the same billing endpoint the CLI
/// uses. Derived from TokenRemain (Apache-2.0); see NOTICE.
///
/// Limits never refreshes the token. An expired one becomes a fixable issue
/// telling the user to run `grok` once.
struct GrokUsageService {
    private static let creditsURL = URL(string: "https://cli-chat-proxy.grok.com/v1/billing?format=credits")!
    private static let settingsURL = URL(string: "https://cli-chat-proxy.grok.com/v1/settings")!

    /// `accountKey` selects one of the accounts `auth.json` already holds.
    func fetch(accountKey: String? = nil, now: Date = .now) async throws -> ProviderQuota {
        guard let account = GrokAuthReader().load(key: accountKey) else {
            throw AccountIssue.notSignedIn
        }
        let token = account.token
        if let expiry = account.expiry, expiry <= now { throw AccountIssue.sessionExpired }

        let (data, http) = try await Self.get(Self.creditsURL, token: token)
        switch http.statusCode {
        case 200..<300: break
        case 401, 403: throw AccountIssue.sessionExpired
        case 429: throw AccountIssue.rateLimited(retryAfterSeconds: nil)
        default: throw AccountIssue.requestFailed(status: http.statusCode)
        }

        // Plan name is best-effort: failing to read it must not cost us the
        // quota we already have.
        var planName: String?
        if let (settingsData, settingsHTTP) = try? await Self.get(Self.settingsURL, token: token),
           (200..<300).contains(settingsHTTP.statusCode) {
            planName = GrokUsageParser.planName(settingsData)
        }
        return try GrokUsageParser.parse(data, planName: planName, now: now)
    }

    private static func get(_ url: URL, token: String) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        // The billing endpoint admits requests shaped like the Grok CLI and
        // needs its identity header.
        request.setValue("xai-grok-cli", forHTTPHeaderField: "X-XAI-Token-Auth")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AccountIssue.other("Invalid response from Grok.")
        }
        return (data, http)
    }
}

/// `billing?format=credits` → `ProviderQuota`. The payload is proto-JSON:
/// `config.creditUsagePercent` is the share of the pool already spent, and
/// `config.currentPeriod {start, end}` bounds the billing window.
///
/// Proto-JSON omits zero-valued fields, so a missing `creditUsagePercent`
/// means a genuine 0% used — not missing data.
enum GrokUsageParser {
    static func parse(_ data: Data, planName: String? = nil, now: Date = .now) throws -> ProviderQuota {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let config = root["config"] as? [String: Any],
              let period = config["currentPeriod"] as? [String: Any],
              let start = isoDate(period["start"]),
              let end = isoDate(period["end"]),
              end > start else {
            throw AccountIssue.other("Grok returned an unreadable billing response.")
        }

        let usedPercent: Double
        if let raw = config["creditUsagePercent"] {
            // Present but unparseable is corruption, and must not read as 0%.
            guard let value = number(raw), value.isFinite else {
                throw AccountIssue.other("Grok reported an unreadable credit balance.")
            }
            usedPercent = value
        } else {
            usedPercent = 0
        }

        // Report the period Grok actually bills on rather than assuming weekly.
        let minutes = max(1, Int(end.timeIntervalSince(start) / 60))
        return ProviderQuota(
            provider: .grok,
            planName: planName,
            windows: [
                QuotaWindow(
                    id: "credits",
                    label: "\(durationLabel(minutes)) window",
                    usedPercent: min(100, max(0, usedPercent)),
                    windowMinutes: minutes,
                    resetsAt: end
                )
            ],
            capturedAt: now
        )
    }

    /// `/v1/settings` carries `subscription_tier_display`, e.g. "SuperGrok".
    static func planName(_ data: Data) -> String? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let plan = (root["subscription_tier_display"] as? String)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !plan.isEmpty else { return nil }
        return plan
    }

    private static func durationLabel(_ minutes: Int) -> String {
        if minutes % (60 * 24) == 0 { return "\(minutes / (60 * 24)) d" }
        if minutes % 60 == 0 { return "\(minutes / 60) hr" }
        return "\(minutes) min"
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

/// Read-only discovery of the Grok CLI's credentials.
///
/// `~/.grok/auth.json` is a dictionary keyed by `<issuer>::<principal id>`, so
/// the CLI already holds every account the user has signed into and a new
/// `grok login` adds an entry rather than replacing one. That makes Grok the
/// one provider where multiple accounts need no app-owned profile at all —
/// Limits just reads what is already there.
struct GrokAuthReader {
    struct Account: Sendable, Identifiable {
        /// The `auth.json` key. Stable across logins for the same account.
        let key: String
        let token: String
        let expiry: Date?
        let email: String?
        let displayName: String?

        var id: String { key }

        /// Best label for this account, preferring what the provider knows.
        var resolvedName: String {
            if let displayName, !displayName.isEmpty { return displayName }
            if let email, !email.isEmpty { return email }
            return "Grok account"
        }
    }

    var authFileURL = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".grok/auth.json")

    /// Every signed-in account, ordered stably so rows never reshuffle.
    func loadAll() -> [Account] {
        guard let data = try? Data(contentsOf: authFileURL) else { return [] }
        return Self.parseAll(data)
    }

    /// The account matching `key`, or the first one when no key is given.
    func load(key: String? = nil) -> Account? {
        let accounts = loadAll()
        guard let key else { return accounts.first }
        return accounts.first { $0.key == key }
    }

    static func parseAll(_ data: Data) -> [Account] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return []
        }
        return root.keys.sorted().compactMap { key -> Account? in
            guard let entry = root[key] as? [String: Any],
                  let token = (entry["key"] as? String)?
                      .trimmingCharacters(in: .whitespacesAndNewlines),
                  !token.isEmpty else { return nil }
            let first = (entry["first_name"] as? String) ?? ""
            let last = (entry["last_name"] as? String) ?? ""
            let full = [first, last]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            return Account(
                key: key,
                token: token,
                expiry: JWT.expiry(token) ?? entryExpiry(entry),
                email: (entry["email"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                displayName: full.isEmpty ? nil : full
            )
        }
    }

    private static func entryExpiry(_ entry: [String: Any]) -> Date? {
        if let epoch = (entry["expires_at"] as? NSNumber)?.doubleValue {
            return Date(timeIntervalSince1970: epoch > 1e10 ? epoch / 1000 : epoch)
        }
        let raw = (entry["expires_at"] as? String) ?? (entry["expires"] as? String)
        guard let text = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return nil
        }
        return ISO8601DateFormatter().date(from: text)
    }
}
