import Foundation

/// One quota window as the provider reports it. Limits keeps a flat, ordered
/// list of these rather than a primary/secondary pair: Cursor splits a billing
/// cycle into named pools and Claude adds model-scoped weekly caps, and both
/// render identically once the window carries its own label.
struct QuotaWindow: Codable, Hashable, Sendable, Identifiable {
    /// Stable within one provider snapshot; used for diffing and ForEach.
    let id: String
    /// "5 hr window", "Cursor Models · 31 d window", "Fable · 7 d window".
    let label: String
    /// 0–100, as reported. Never inferred.
    let usedPercent: Double
    let windowMinutes: Int
    /// A provider can report a freshly-reset window before it knows the next
    /// reset time. Keep that honest `nil` instead of carrying a stale date.
    let resetsAt: Date?
    /// Model- or pool-scoped rather than account-wide. Scoped windows never
    /// represent the provider in compact summaries.
    var isScoped: Bool = false

    var remainingPercent: Double { max(0, min(100, 100 - usedPercent)) }

    /// Human duration for the window, e.g. "5 hr", "7 d", "31 d".
    var windowDescription: String {
        let minutes = windowMinutes
        if minutes % (60 * 24) == 0 { return "\(minutes / (60 * 24)) d" }
        if minutes % 60 == 0 { return "\(minutes / 60) hr" }
        return "\(minutes) min"
    }
}

/// A provider account's quota snapshot. Only values the provider actually
/// reported are present; Limits never fills a gap with a zero.
struct ProviderQuota: Codable, Hashable, Sendable {
    let provider: Provider
    var planName: String?
    var windows: [QuotaWindow]
    var capturedAt: Date

    /// Account-wide windows, in the order the provider reported them.
    var generalWindows: [QuotaWindow] { windows.filter { !$0.isScoped } }
    var scopedWindows: [QuotaWindow] { windows.filter(\.isScoped) }

    /// The window that represents this account on compact surfaces: the
    /// account-wide window with the least left. Scoped caps are excluded —
    /// one exhausted model cap does not mean the account is out.
    var headlineWindow: QuotaWindow? {
        generalWindows.min { $0.remainingPercent < $1.remainingPercent }
    }

    var lowestRemainingPercent: Double? { headlineWindow?.remainingPercent }
}
