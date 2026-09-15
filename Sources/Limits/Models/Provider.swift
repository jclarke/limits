import AppKit
import SwiftUI

/// The providers Limits knows how to read. Adding one means adding a credential
/// reader and a usage service; the UI is driven entirely off this enum.
enum Provider: String, Codable, CaseIterable, Identifiable, Sendable {
    case claude
    case codex
    case cursor
    case grok
    case antigravity

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        case .cursor: "Cursor"
        case .grok: "Grok"
        case .antigravity: "Antigravity"
        }
    }

    /// SF Symbol used wherever the provider needs a compact mark.
    var symbolName: String {
        switch self {
        case .claude: "sparkle"
        case .codex: "cube.transparent"
        case .cursor: "cursorarrow.rays"
        case .grok: "circle.hexagongrid"
        case .antigravity: "arrow.up.forward.circle"
        }
    }

    var tint: Color {
        switch self {
        case .claude: Color(red: 0.85, green: 0.47, blue: 0.29)
        case .codex: Color(red: 0.36, green: 0.55, blue: 0.94)
        case .cursor: Color(red: 0.60, green: 0.45, blue: 0.92)
        case .grok: Color(red: 0.90, green: 0.76, blue: 0.29)
        case .antigravity: Color(red: 0.36, green: 0.78, blue: 0.62)
        }
    }

    /// The same tints, for the AppKit-drawn menu bar title.
    var nsTint: NSColor {
        switch self {
        case .claude: NSColor(red: 0.85, green: 0.47, blue: 0.29, alpha: 1)
        case .codex: NSColor(red: 0.36, green: 0.55, blue: 0.94, alpha: 1)
        case .cursor: NSColor(red: 0.60, green: 0.45, blue: 0.92, alpha: 1)
        case .grok: NSColor(red: 0.90, green: 0.76, blue: 0.29, alpha: 1)
        case .antigravity: NSColor(red: 0.36, green: 0.78, blue: 0.62, alpha: 1)
        }
    }

    /// Filesystem-safe slug for this provider's isolated account homes.
    var directorySlug: String { rawValue }

    /// How a second account for this provider is authenticated.
    ///
    /// `isolatedCLI` providers ship a real CLI login we can run inside an
    /// app-owned home, which is what makes true multi-account OAuth possible.
    /// The rest expose no such boundary, so an extra account means holding one
    /// pasted credential in the Keychain.
    var credentialKind: AccountCredentialKind {
        switch self {
        case .claude, .codex: .isolatedCLI
        case .cursor, .grok, .antigravity: .keychainSecret
        }
    }

    /// The CLI that owns authentication for `isolatedCLI` providers.
    var cliExecutableName: String? {
        switch self {
        case .claude: "claude"
        case .codex: "codex"
        case .cursor, .grok, .antigravity: nil
        }
    }

    /// Bundled app that may carry the CLI inside it.
    var cliAppBundleName: String? {
        switch self {
        case .codex: "Codex"
        default: nil
        }
    }

    /// Where the user goes to repair a `keychainSecret` account's credential.
    var credentialHelpText: String {
        switch self {
        case .cursor:
            "Paste a Cursor session token. In Cursor, open the dashboard in a browser and copy the `WorkosCursorSessionToken` cookie value."
        case .grok:
            "Paste a Grok API session token. The Grok CLI stores one per account in ~/.grok/auth.json under `key`."
        case .antigravity:
            "Paste an Antigravity access token. Limits normally reads the running Antigravity app directly, so a token is only needed for a second account."
        case .claude, .codex:
            ""
        }
    }
}

enum AccountCredentialKind: String, Codable, Hashable, Sendable {
    /// The provider's own CLI owns the OAuth session inside an isolated home.
    case isolatedCLI
    /// Limits holds one opaque credential in the macOS Keychain.
    case keychainSecret
}
