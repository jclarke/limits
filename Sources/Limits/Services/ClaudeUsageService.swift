import CryptoKit
import Foundation
import Security

/// Reads the OAuth access token Claude Code already holds and calls the
/// official usage endpoint. Derived from TokenRemain (Apache-2.0); see NOTICE.
///
/// Limits never refreshes and never writes back a credential. Renewal always
/// stays with Claude Code itself, so the two never race over a refresh token
/// and Limits can't trigger third-party renewal throttling. An expired token
/// surfaces as an issue for the user instead.
struct ClaudeUsageService {
    private static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    func fetch(
        configurationDirectory: URL? = nil,
        now: Date = .now,
        keychainInteraction: KeychainRead.Interaction = .disallowed
    ) async throws -> ProviderQuota {
        var reader = ClaudeCredentialsReader()
        if let configurationDirectory {
            reader.environment["CLAUDE_CONFIG_DIR"] = configurationDirectory.path
            // A managed profile must never fall through to the user's own
            // account — that would silently show one account's numbers twice.
            reader.fallbackToDefaultDirectory = false
        }
        let result = await reader.readAllowingAppleTool(now: now, keychainInteraction: keychainInteraction)
        guard let credentials = result.credentials else {
            if result.needsAuthorization { throw AccountIssue.needsKeychainAuthorization }
            if result.hasExpiredCredentials { throw AccountIssue.sessionExpired }
            throw AccountIssue.notSignedIn
        }

        var request = URLRequest(url: Self.usageURL)
        request.timeoutInterval = 15
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        // The endpoint admits requests shaped like the Claude Code client; a
        // bare user agent is refused by some gateways.
        request.setValue("claude-code/2.1.69", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AccountIssue.other("Invalid response from Claude.") }
        switch http.statusCode {
        case 200..<300: break
        case 401, 403: throw AccountIssue.tokenRejected(status: http.statusCode)
        case 429: throw AccountIssue.rateLimited(retryAfterSeconds: Self.retryAfterSeconds(http, now: now))
        default: throw AccountIssue.requestFailed(status: http.statusCode)
        }
        return try ClaudeUsageParser.parse(
            data,
            subscriptionType: credentials.subscriptionType,
            rateLimitTier: credentials.rateLimitTier,
            now: now
        )
    }

    static func retryAfterSeconds(_ response: HTTPURLResponse, now: Date = .now) -> Int? {
        guard let raw = response.value(forHTTPHeaderField: "Retry-After")?
            .trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        if let seconds = Int(raw), seconds >= 0 { return seconds }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss zzz"
        guard let date = formatter.date(from: raw) else { return nil }
        return max(0, Int(ceil(date.timeIntervalSince(now))))
    }
}

/// `oauth/usage` response → `ProviderQuota`. Handles both the older
/// `five_hour` / `seven_day` / `seven_day_<scope>` fields and the newer
/// structured `limits` array. Old windows report `utilization`, new ones
/// `percent`; both are 0–100 *used*.
enum ClaudeUsageParser {
    static func parse(
        _ data: Data,
        subscriptionType: String? = nil,
        rateLimitTier: String? = nil,
        now: Date = .now
    ) throws -> ProviderQuota {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw AccountIssue.other("Claude returned an unreadable response.")
        }
        let structured = structuredLimits(object, now: now)

        // Require a real session window from one schema or the other. Some
        // tokens are inference-only and carry no subscription quota at all;
        // those must fall through as an issue rather than invent a number.
        guard let session = window(object["five_hour"], label: "5 hr window", windowMinutes: 300, id: "session")
            ?? structured.session else {
            throw AccountIssue.other("This Claude account reports no subscription limits.")
        }
        var windows = [session]
        if let weekly = window(object["seven_day"], label: "7 d window", windowMinutes: 10_080, id: "weekly")
            ?? structured.weekly {
            windows.append(weekly)
        }

        var scoped = structured.scoped
        let legacyPrefix = "seven_day_"
        for key in object.keys.sorted() where key.hasPrefix(legacyPrefix) && key.count > legacyPrefix.count {
            let scopeID = String(key.dropFirst(legacyPrefix.count)).lowercased()
            guard !isGeneralWeeklyLabel(scopeID),
                  !scoped.contains(where: { $0.id == scopeID }),
                  let value = window(
                      object[key],
                      label: "\(titleCased(scopeID)) · 7 d window",
                      windowMinutes: 10_080,
                      id: scopeID,
                      isScoped: true
                  ) else { continue }
            scoped.append(value)
        }
        windows.append(contentsOf: scoped)

        return ProviderQuota(
            provider: .claude,
            planName: planName(subscriptionType: subscriptionType, rateLimitTier: rateLimitTier),
            windows: windows,
            capturedAt: now
        )
    }

    private struct Structured {
        var session: QuotaWindow?
        var weekly: QuotaWindow?
        var scoped: [QuotaWindow] = []
    }

    /// The current API represents a model-scoped cap (Fable, for example) as a
    /// `weekly_scoped` row whose model ID may be null; derive a stable ID from
    /// the display name when it is. Banner and help rows are not limits.
    private static func structuredLimits(_ object: [String: Any], now: Date) -> Structured {
        guard let rows = object["limits"] as? [[String: Any]] else { return Structured() }
        var result = Structured()
        for row in rows {
            switch (row["kind"] as? String)?.lowercased() {
            case "session":
                result.session = limitWindow(row, label: "5 hr window", windowMinutes: 300, id: "session")
            case "weekly_all":
                result.weekly = limitWindow(row, label: "7 d window", windowMinutes: 10_080, id: "weekly")
            case "weekly_scoped":
                guard let scope = row["scope"] as? [String: Any],
                      let model = scope["model"] as? [String: Any] else { continue }
                let rawID = (model["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                let rawName = (model["display_name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                let name = rawName.flatMap { $0.isEmpty ? nil : $0 }
                    ?? rawID.flatMap { $0.isEmpty ? nil : titleCased($0) }
                guard let name, !isGeneralWeeklyLabel(name) else { continue }
                let scopeID = (rawID.flatMap { $0.isEmpty ? nil : $0 } ?? name).lowercased()
                guard let value = limitWindow(
                    row,
                    label: "\(name) · 7 d window",
                    windowMinutes: 10_080,
                    id: scopeID,
                    isScoped: true
                ) else { continue }
                result.scoped.append(value)
            default:
                continue
            }
        }
        return result
    }

    /// Claude names the general weekly cap "Current week (all models)". It is
    /// the same value as the account-wide weekly window, so a row carrying
    /// that label must never become an extra scoped card.
    static func isGeneralWeeklyLabel(_ name: String) -> Bool {
        let normalized = name.lowercased().filter { $0.isASCII && $0.isLetter }
        return normalized.contains("allmodels")
    }

    private static func limitWindow(
        _ object: [String: Any],
        label: String,
        windowMinutes: Int,
        id: String,
        isScoped: Bool = false
    ) -> QuotaWindow? {
        guard let used = number(object["percent"]) ?? number(object["utilization"]) else { return nil }
        return QuotaWindow(
            id: id,
            label: label,
            usedPercent: min(100, max(0, used)),
            windowMinutes: windowMinutes,
            resetsAt: resetDate(object["resets_at"]),
            isScoped: isScoped
        )
    }

    private static func window(
        _ value: Any?,
        label: String,
        windowMinutes: Int,
        id: String,
        isScoped: Bool = false
    ) -> QuotaWindow? {
        guard let object = value as? [String: Any] else { return nil }
        return limitWindow(object, label: label, windowMinutes: windowMinutes, id: id, isScoped: isScoped)
    }

    private static func resetDate(_ value: Any?) -> Date? {
        if let seconds = number(value), seconds > 0 {
            return Date(timeIntervalSince1970: seconds)
        }
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    static func planName(subscriptionType: String?, rateLimitTier: String?) -> String? {
        let raw = [subscriptionType, rateLimitTier]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        guard let raw else { return nil }
        return titleCased(raw)
    }

    static func titleCased(_ raw: String) -> String {
        raw.split(whereSeparator: { $0 == "_" || $0 == "-" })
            .map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }
            .joined(separator: " ")
    }

    private static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let text = value as? String { return Double(text) }
        return nil
    }
}
