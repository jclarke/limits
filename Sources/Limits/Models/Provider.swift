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

    var tint: Color { Color(nsColor: nsTint) }

    /// Brand tint, in the light/dark pair the design specifies. The darker
    /// value carries enough contrast on a light background; the lighter one
    /// stays legible on a dark one. Resolved dynamically so a theme change
    /// repaints without the app rebuilding anything.
    var nsTint: NSColor {
        let (light, dark): (UInt32, UInt32) = switch self {
        case .claude: (0xC25F30, 0xD9784A)
        case .codex: (0x3A6BD6, 0x5C8CF0)
        case .cursor: (0x7B4FD8, 0x9973EB)
        case .grok: (0xA8871F, 0xE6C24A)
        case .antigravity: (0x2E9B74, 0x5CC79E)
        }
        return NSColor(name: nil) { appearance in
            appearance.isDark ? NSColor(hex: dark) : NSColor(hex: light)
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
        case .claude, .codex, .antigravity: .isolatedCLI
        case .cursor, .grok: .keychainSecret
        }
    }

    /// Whether a second account can exist alongside the first.
    ///
    /// Antigravity's CLI stores its credential under one fixed Keychain
    /// identity (`service=gemini, account=antigravity`) with nothing in it
    /// derived from the profile, so a second sign-in overwrites the first.
    /// Redirecting HOME to isolate it does not help either — macOS resolves
    /// the login keychain from HOME, so the CLI finds no keychain at all and
    /// raises a system "Keychain Not Found" dialog.
    var supportsMultipleAccounts: Bool {
        switch self {
        // Grok's own auth file is keyed per account, so a new sign-in adds
        // rather than replaces — no app-owned profile needed.
        case .claude, .codex, .grok: true
        // Antigravity and Cursor each store one credential under a fixed
        // Keychain identity, so a second sign-in overwrites the first.
        case .antigravity, .cursor: false
        }
    }

    /// Accounts this provider's own tools already hold, which Limits lists
    /// rather than creating.
    var discoversAccounts: Bool { self == .grok }

    /// Whether Limits can run this provider's sign-in itself, including for
    /// the account the provider's own tools already use.
    var supportsInAppSignIn: Bool {
        switch self {
        case .antigravity, .cursor, .grok: true
        case .claude, .codex: false
        }
    }

    /// The CLI that owns authentication for `isolatedCLI` providers.
    var cliExecutableName: String? {
        switch self {
        case .claude: "claude"
        case .codex: "codex"
        // Antigravity's own CLI. Its sign-in prints a Google URL and then
        // accepts the code the callback page shows, which is a flow Limits
        // can drive without ever handling the credential itself.
        case .antigravity: "agy"
        case .cursor: "cursor-agent"
        case .grok: "grok"
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
        case .claude, .codex, .antigravity:
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
