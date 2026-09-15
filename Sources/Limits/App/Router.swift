import SwiftUI

/// Shared navigation intent. The popover and the dashboard both raise the same
/// requests, so a fix started in the menu bar lands on the right screen.
@MainActor
final class Router: ObservableObject {
    enum Tab: String, CaseIterable, Identifiable {
        case limits
        case providers

        var id: String { rawValue }
        var title: String { self == .limits ? "Limits" : "Providers" }
        var symbolName: String { self == .limits ? "gauge.with.dots.needle.67percent" : "person.2.badge.key" }
    }

    /// The one sheet the dashboard can be showing.
    ///
    /// Stacking several `.sheet` modifiers on a single view is unreliable —
    /// SwiftUI honors only one and can present the wrong content — so every
    /// modal routes through this single value instead.
    enum Sheet: Identifiable, Equatable {
        /// Carries the provider whose "Add another…" row was used, so the
        /// sheet opens on that provider instead of making the user re-pick
        /// what they just clicked. Nil when opened from the toolbar, where
        /// there is no provider context.
        case addAccount(Provider?)
        /// Enter or replace a stored credential.
        case credential(AccountProfile)
        /// Explain how to repair an account Limits deliberately does not own.
        case guidance(AccountProfile)
        /// Antigravity's sign-in needs a code pasted back mid-flight, so it
        /// gets its own screen rather than the one-shot CLI login.
        case antigravitySignIn(AccountProfile)

        var id: String {
            switch self {
            case .addAccount(let provider): "add.\(provider?.rawValue ?? "any")"
            case .credential(let profile): "credential.\(profile.id.rawValue)"
            case .guidance(let profile): "guidance.\(profile.id.rawValue)"
            case .antigravitySignIn(let profile): "antigravity.\(profile.id.rawValue)"
            }
        }
    }

    @Published var tab: Tab = .limits
    @Published var sheet: Sheet?
    /// Set when the Providers screen should scroll to and highlight an account.
    @Published var highlighted: AccountID?

    /// Set by `AppDelegate`. The popover lives outside the scene graph, so it
    /// cannot use SwiftUI's `openWindow` to reach the dashboard.
    var presentDashboard: ((Tab) -> Void)?
    var presentSettings: (() -> Void)?

    func openDashboard(_ tab: Tab, sheet: Sheet? = nil) {
        self.sheet = sheet
        presentDashboard?(tab)
    }
}
