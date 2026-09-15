import Foundation

/// Cursor billing-cycle usage. Reads the access token Cursor itself maintains
/// (`state.vscdb` first, Keychain second) and calls the dashboard endpoint.
/// Derived from TokenRemain (Apache-2.0); see NOTICE.
///
/// Limits never uses the refresh token: Cursor's auth server may rotate
/// refresh tokens and detect reuse, so renewing on Cursor's behalf could
/// invalidate the user's IDE session. The cost is that an expired token stops
/// updating until Cursor runs again, which surfaces as a fixable issue.
struct CursorUsageService {
    private static let usageURL = URL(
        string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage"
    )!

    func fetch(token routedToken: String? = nil, now: Date = .now) async throws -> ProviderQuota {
        let auth: CursorAuthReader.Auth
        if let routedToken, !routedToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            auth = CursorAuthReader.Auth(
                accessToken: routedToken.trimmingCharacters(in: .whitespacesAndNewlines),
                membershipType: nil
            )
        } else if let discovered = await CursorAuthReader().load() {
            auth = discovered
        } else {
            throw AccountIssue.notSignedIn
        }
        if let expiry = JWT.expiry(auth.accessToken), expiry <= now {
            throw AccountIssue.sessionExpired
        }

        var request = URLRequest(url: Self.usageURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("Bearer \(auth.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("{}".utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AccountIssue.other("Invalid response from Cursor.") }
        switch http.statusCode {
        case 200..<300: break
        case 401, 403: throw AccountIssue.sessionExpired
        case 429: throw AccountIssue.rateLimited(retryAfterSeconds: nil)
        default: throw AccountIssue.requestFailed(status: http.statusCode)
        }
        return try CursorUsageParser.parse(data, membershipType: auth.membershipType, now: now)
    }
}

/// Cursor splits one billing cycle into named pools, each with its own
/// percentage over the same period:
///
///   {"billingCycleStart":"1788098891000","billingCycleEnd":"1790777291000",
///    "planUsage":{"autoPercentUsed":17.5,"apiPercentUsed":0.7, ...}}
///
/// `autoPercentUsed` covers Cursor's own models, `apiPercentUsed` the
/// pass-through API models. Cycle bounds are epoch milliseconds *as strings*.
enum CursorUsageParser {
    /// The two pools Cursor reports, in the order its own dashboard shows them.
    private static let poolKeys: [(key: String, id: String, name: String)] = [
        ("autoPercentUsed", "cursor-models", "Cursor Models"),
        ("apiPercentUsed", "other-models", "Other Models")
    ]

    static func parse(_ data: Data, membershipType: String?, now: Date = .now) throws -> ProviderQuota {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw AccountIssue.other("Cursor returned an unreadable response.")
        }
        let start = date(object["billingCycleStart"])
        let end = date(object["billingCycleEnd"])
        // Use the real cycle length when both ends are known rather than
        // assuming a 30-day month; Cursor's cycles are commonly 31 days.
        let minutes: Int = {
            guard let start, let end, end > start else { return 31 * 24 * 60 }
            return max(60, Int(end.timeIntervalSince(start) / 60))
        }()

        let planUsage = (object["planUsage"] as? [String: Any]) ?? object
        var windows: [QuotaWindow] = []
        for pool in poolKeys {
            // A pool Cursor omits is absent, not zero.
            guard let used = number(planUsage[pool.key]) else { continue }
            windows.append(
                QuotaWindow(
                    id: pool.id,
                    label: "\(pool.name) · \(durationLabel(minutes)) window",
                    usedPercent: min(100, max(0, used)),
                    windowMinutes: minutes,
                    resetsAt: end
                )
            )
        }

        // Older responses carried a single combined percentage instead.
        if windows.isEmpty, let total = number(planUsage["totalPercentUsed"]) {
            windows.append(
                QuotaWindow(
                    id: "included",
                    label: "Included Usage · \(durationLabel(minutes)) window",
                    usedPercent: min(100, max(0, total)),
                    windowMinutes: minutes,
                    resetsAt: end
                )
            )
        }
        guard !windows.isEmpty else {
            throw AccountIssue.other("Cursor reported no usage for this billing period.")
        }

        return ProviderQuota(
            provider: .cursor,
            planName: membershipType.map { ClaudeUsageParser.titleCased($0) },
            windows: windows,
            capturedAt: now
        )
    }

    private static func durationLabel(_ minutes: Int) -> String {
        if minutes % (60 * 24) == 0 { return "\(minutes / (60 * 24)) d" }
        if minutes % 60 == 0 { return "\(minutes / 60) hr" }
        return "\(minutes) min"
    }

    /// Cursor sends epoch milliseconds, sometimes quoted as a string.
    private static func date(_ value: Any?) -> Date? {
        guard let seconds = number(value), seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: seconds > 1e11 ? seconds / 1000 : seconds)
    }

    private static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let text = value as? String { return Double(text) }
        return nil
    }
}

/// Read-only discovery of Cursor's own access token.
struct CursorAuthReader {
    struct Auth: Sendable {
        let accessToken: String
        let membershipType: String?
    }

    var stateDBURL = URL(fileURLWithPath: NSString(
        string: "~/Library/Application Support/Cursor/User/globalStorage/state.vscdb"
    ).expandingTildeInPath)

    func load() async -> Auth? {
        if let token = await stateValue(key: "cursorAuth/accessToken") {
            return Auth(accessToken: token, membershipType: await stateValue(key: "cursorAuth/stripeMembershipType"))
        }
        let outcome = KeychainRead.genericPassword(service: "cursor-access-token", interaction: .disallowed)
        guard let token = Self.normalized(outcome.payload) else { return nil }
        return Auth(accessToken: token, membershipType: nil)
    }

    /// Opened read-only so Limits can never disturb Cursor's own database,
    /// even while Cursor is running.
    private func stateValue(key: String) async -> String? {
        guard FileManager.default.fileExists(atPath: stateDBURL.path) else { return nil }
        let sql = "SELECT value FROM ItemTable WHERE key = '\(key)' LIMIT 1;"
        guard let data = try? await ProcessRunner.run(
            "/usr/bin/sqlite3",
            arguments: ["-readonly", stateDBURL.path, sql]
        ) else { return nil }
        return Self.normalized(String(data: data, encoding: .utf8))
    }

    /// `state.vscdb` values come back either bare or JSON-quoted.
    static func normalized(_ value: String?) -> String? {
        guard var text = value?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return nil
        }
        if text.count >= 2, text.hasPrefix("\""), text.hasSuffix("\"") {
            text = String(text.dropFirst().dropLast())
        }
        return text.isEmpty ? nil : text
    }
}
