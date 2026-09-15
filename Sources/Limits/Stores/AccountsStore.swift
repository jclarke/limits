import Foundation
import SwiftUI

/// Owns the set of tracked accounts and their isolated homes. Persists to
/// UserDefaults; the credentials themselves never appear here.
@MainActor
final class AccountsStore: ObservableObject {
    static let profilesKey = "limits.accounts.v1"
    static let trackedProvidersKey = "limits.trackedProviders.v1"

    /// Managed accounts only. System accounts are synthesized so a provider
    /// the user already uses shows up without any setup.
    @Published private(set) var managed: [AccountProfile] = []
    /// Providers the user wants tracked at all.
    @Published private(set) var trackedProviders: Set<Provider> = []
    /// System-account visibility, keyed by provider.
    @Published private(set) var systemOverrides: [Provider: SystemOverride] = [:]
    /// Accounts read out of a provider's own credential store, refreshed from
    /// disk rather than persisted here.
    @Published private(set) var discovered: [Provider: [DiscoveredAccount]] = [:]
    /// Visibility for discovered accounts, keyed by `AccountID` — the only
    /// part of them Limits owns.
    @Published private(set) var discoveredOverrides: [String: SystemOverride] = [:]

    struct DiscoveredAccount: Hashable, Sendable {
        let key: String
        let name: String
    }



    struct SystemOverride: Codable, Hashable, Sendable {
        var isEnabled: Bool = true
        var showsInMenuBar: Bool = true
        var displayName: String = ""
        /// Empty means "derive one from the name".
        var menuBarLabel: String = ""

        init() {}

        /// Decoded field by field rather than by synthesis.
        ///
        /// Swift's synthesized `init(from:)` ignores property defaults: a key
        /// missing from stored JSON throws, and because the caller decodes
        /// with `try?`, one newly added field would silently discard every
        /// account the user had configured. Adding a field must never cost
        /// someone their setup.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
            showsInMenuBar = try container.decodeIfPresent(Bool.self, forKey: .showsInMenuBar) ?? true
            displayName = try container.decodeIfPresent(String.self, forKey: .displayName) ?? ""
            menuBarLabel = try container.decodeIfPresent(String.self, forKey: .menuBarLabel) ?? ""
        }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    // MARK: - Derived

    /// Every account to show, system first within each provider, in provider
    /// declaration order so the UI never reshuffles between launches.
    var allProfiles: [AccountProfile] {
        Provider.allCases
            .filter(trackedProviders.contains)
            .flatMap { profiles(for: $0) }
    }

    func profiles(for provider: Provider) -> [AccountProfile] {
        // A provider whose own tools track several accounts is listed straight
        // from that store; there is no separate "system" account to add,
        // because every one of them is a system account.
        if provider.discoversAccounts {
            let live = discovered[provider] ?? []
            let liveKeys = Set(live.map(\.key))
            // A saved copy of an account that is still signed in would show the
            // same numbers twice under two names.
            let savedButNotLive = managed.filter {
                $0.provider == provider
                    && !liveKeys.contains($0.providerAccountKey ?? "")
            }
            return live.map { account in
                var profile = AccountProfile.discovered(
                    provider,
                    key: account.key,
                    name: account.name
                )
                if let override = discoveredOverrides[profile.id.rawValue] {
                    profile.isEnabled = override.isEnabled
                    profile.showsInMenuBar = override.showsInMenuBar
                    if !override.displayName.isEmpty { profile.displayName = override.displayName }
                    if !override.menuBarLabel.isEmpty { profile.menuBarLabel = override.menuBarLabel }
                }
                return profile
            } + savedButNotLive.sorted { $0.createdAt < $1.createdAt }
        }

        let owned = managed
            .filter { $0.provider == provider }
            .sorted { $0.createdAt < $1.createdAt }

        var system = AccountProfile.system(provider)
        if let override = systemOverrides[provider] {
            system.isEnabled = override.isEnabled
            system.showsInMenuBar = override.showsInMenuBar
            if !override.displayName.isEmpty { system.displayName = override.displayName }
            if !override.menuBarLabel.isEmpty { system.menuBarLabel = override.menuBarLabel }
        }
        return [system] + owned
    }

    /// Re-reads the accounts a provider's own CLI holds. Cheap enough to run
    /// on every refresh round, which is how a sign-in performed outside Limits
    /// shows up without the user doing anything.
    func refreshDiscoveredAccounts() {
        var next = discovered
        next[.grok] = GrokAuthReader().loadAll().map {
            DiscoveredAccount(key: $0.key, name: $0.resolvedName)
        }
        guard next != discovered else { return }
        discovered = next
    }

    /// Resolved once per account, because naming one costs a process launch.
    private var cursorNames: [String: String] = [:]

    /// Cursor's sources need an async read, so it updates separately from the
    /// synchronous file-backed providers.
    func refreshDiscoveredCursorAccounts() async {
        var accounts: [DiscoveredAccount] = []
        for auth in await CursorAuthReader().loadAll() {
            guard let subject = auth.subject else { continue }
            if let email = auth.email, !email.isEmpty {
                cursorNames[subject] = email
            } else if cursorNames[subject] == nil,
                      let reported = await CursorAuthReader.signedInEmailFromCLI() {
                // Only the editor caches an address; the CLI will report its
                // own when asked, which beats labelling the row "Cursor
                // account" forever.
                cursorNames[subject] = reported
            }
            accounts.append(
                DiscoveredAccount(key: subject, name: cursorNames[subject] ?? "Cursor account")
            )
        }
        guard discovered[.cursor] != accounts else { return }
        discovered[.cursor] = accounts
    }

    /// Default selection when adding an account with no provider context.
    /// Picking a provider the user actually tracks beats a hardcoded one they
    /// may not even use.
    var firstTrackedProvider: Provider {
        Provider.allCases.first(where: trackedProviders.contains) ?? .claude
    }

    func profile(id: AccountID) -> AccountProfile? {
        allProfiles.first { $0.id == id }
    }

    // MARK: - Providers

    func setTracked(_ provider: Provider, tracked: Bool) {
        // No-op writes are ignored. A SwiftUI `Toggle` bound to a computed
        // value can invoke its setter during window restoration, and without
        // this guard that silently tracks a provider the user never chose.
        guard trackedProviders.contains(provider) != tracked else { return }
        if tracked {
            trackedProviders.insert(provider)
        } else {
            trackedProviders.remove(provider)
        }
        persist()
    }

    // MARK: - Accounts

    /// Creates a managed profile. `isolatedCLI` providers get an app-owned
    /// home with owner-only permissions; credential providers get none.
    /// Saves a copy of the session a provider's CLI just produced as its own
    /// account. The credential goes to Limits' Keychain namespace, never to a
    /// file, and the provider's identifier is kept so the live row can be
    /// recognised as the same account.
    @discardableResult
    func captureAccount(
        provider: Provider,
        displayName: String,
        providerAccountKey: String,
        secret: String
    ) throws -> AccountProfile {
        // Re-capturing an account already held refreshes it in place rather
        // than adding a second row for the same person.
        if let existing = managed.first(where: {
            $0.provider == provider && $0.providerAccountKey == providerAccountKey
        }) {
            try AccountSecretStore.save(secret, for: existing.id)
            return existing
        }

        let id = AccountID.managed(UUID())
        try AccountSecretStore.save(secret, for: id)
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let profile = AccountProfile(
            id: id,
            provider: provider,
            displayName: trimmed.isEmpty ? defaultName(for: provider) : trimmed,
            kind: .managed,
            configurationDirectory: nil,
            isEnabled: true,
            showsInMenuBar: true,
            createdAt: .now,
            providerAccountKey: providerAccountKey
        )
        managed.append(profile)
        trackedProviders.insert(provider)
        persist()
        return profile
    }

    func createManagedAccount(provider: Provider, displayName: String) throws -> AccountProfile {
        guard provider.supportsMultipleAccounts else {
            throw AccountIssue.other(
                "\(provider.displayName) supports one account: its CLI stores a single credential that a second sign-in would overwrite."
            )
        }
        let uuid = UUID()
        let id = AccountID.managed(uuid)
        var directory: String?

        if provider.credentialKind == .isolatedCLI {
            let url = Self.accountsDirectory
                .appending(path: provider.directorySlug, directoryHint: .isDirectory)
                .appending(path: uuid.uuidString.lowercased(), directoryHint: .isDirectory)
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            directory = url.path
        }

        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let profile = AccountProfile(
            id: id,
            provider: provider,
            displayName: trimmed.isEmpty ? defaultName(for: provider) : trimmed,
            kind: .managed,
            configurationDirectory: directory,
            isEnabled: true,
            showsInMenuBar: false,
            createdAt: .now
        )
        managed.append(profile)
        trackedProviders.insert(provider)
        persist()
        return profile
    }

    func rename(_ id: AccountID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let index = managed.firstIndex(where: { $0.id == id }) {
            managed[index].displayName = trimmed
        } else if let provider = systemProvider(for: id) {
            systemOverrides[provider, default: SystemOverride()].displayName = trimmed
        } else {
            discoveredOverrides[id.rawValue, default: SystemOverride()].displayName = trimmed
        }
        persist()
    }

    func setEnabled(_ id: AccountID, _ enabled: Bool) {
        // An unknown account means the row was asked about state it no longer
        // has — a SwiftUI toggle can fire its setter while the list is being
        // rebuilt. Writing then records a value the user never chose, and for
        // a nil lookup the "no-op" check below would pass and do exactly that.
        guard let current = profile(id: id), current.isEnabled != enabled else { return }
        if let index = managed.firstIndex(where: { $0.id == id }) {
            managed[index].isEnabled = enabled
        } else if let provider = systemProvider(for: id) {
            systemOverrides[provider, default: SystemOverride()].isEnabled = enabled
        } else {
            discoveredOverrides[id.rawValue, default: SystemOverride()].isEnabled = enabled
        }
        persist()
    }

    /// Sets the menu bar's two-character label. An empty value restores the
    /// one derived from the account name.
    func setMenuBarLabel(_ id: AccountID, _ label: String) {
        let normalized = String(
            label.filter { $0.isLetter || $0.isNumber }.prefix(2)
        ).uppercased()
        guard let current = profile(id: id),
              current.menuBarLabel ?? "" != normalized else { return }
        if let index = managed.firstIndex(where: { $0.id == id }) {
            managed[index].menuBarLabel = normalized.isEmpty ? nil : normalized
        } else if let provider = systemProvider(for: id) {
            systemOverrides[provider, default: SystemOverride()].menuBarLabel = normalized
        } else {
            discoveredOverrides[id.rawValue, default: SystemOverride()].menuBarLabel = normalized
        }
        persist()
    }

    func setShowsInMenuBar(_ id: AccountID, _ shows: Bool) {
        guard let current = profile(id: id), current.showsInMenuBar != shows else { return }
        if let index = managed.firstIndex(where: { $0.id == id }) {
            managed[index].showsInMenuBar = shows
        } else if let provider = systemProvider(for: id) {
            systemOverrides[provider, default: SystemOverride()].showsInMenuBar = shows
        } else {
            discoveredOverrides[id.rawValue, default: SystemOverride()].showsInMenuBar = shows
        }
        persist()
    }

    /// Removes a managed account, its stored credential and its isolated home.
    /// System accounts cannot be removed — untrack the provider instead.
    @discardableResult
    func remove(_ id: AccountID) -> AccountProfile? {
        guard let index = managed.firstIndex(where: { $0.id == id }) else { return nil }
        let removed = managed.remove(at: index)
        AccountSecretStore.delete(for: id)
        if let directory = removed.configurationDirectoryURL {
            removeManagedDirectoryIfSafe(directory)
        }
        persist()
        return removed
    }

    func defaultName(for provider: Provider) -> String {
        // +2 because the system account is always #1.
        "\(provider.displayName) \(managed.count(where: { $0.provider == provider }) + 2)"
    }

    private func systemProvider(for id: AccountID) -> Provider? {
        Provider.allCases.first { AccountID.system($0) == id }
    }

    // MARK: - Persistence

    private struct Persisted: Codable {
        var managed: [AccountProfile]
        var tracked: [Provider]
        var systemOverrides: [String: SystemOverride]
        var discoveredOverrides: [String: SystemOverride]?

        init(
            managed: [AccountProfile],
            tracked: [Provider],
            systemOverrides: [String: SystemOverride],
            discoveredOverrides: [String: SystemOverride]?
        ) {
            self.managed = managed
            self.tracked = tracked
            self.systemOverrides = systemOverrides
            self.discoveredOverrides = discoveredOverrides
        }

        /// Tolerant for the same reason as `SystemOverride`: a decode failure
        /// here resets the user's entire configuration.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            managed = try container.decodeIfPresent([AccountProfile].self, forKey: .managed) ?? []
            tracked = try container.decodeIfPresent([Provider].self, forKey: .tracked) ?? []
            systemOverrides = try container.decodeIfPresent(
                [String: SystemOverride].self, forKey: .systemOverrides
            ) ?? [:]
            discoveredOverrides = try container.decodeIfPresent(
                [String: SystemOverride].self, forKey: .discoveredOverrides
            )
        }
    }

    private func load() {
        guard let data = defaults.data(forKey: Self.profilesKey),
              let decoded = try? JSONDecoder().decode(Persisted.self, from: data) else {
            // First launch: track whatever the machine already has set up so
            // the app is useful before the user configures anything.
            trackedProviders = Set(Self.autodetectedProviders())
            refreshDiscoveredAccounts()
            return
        }
        // An earlier build offered managed Antigravity profiles before it was
        // clear its CLI keeps only one credential. They can never resolve, so
        // they are dropped rather than left showing a permanent error.
        managed = decoded.managed.filter(Self.isValid).filter(\.provider.supportsMultipleAccounts)
        trackedProviders = Set(decoded.tracked)
        systemOverrides = decoded.systemOverrides.reduce(into: [:]) { result, entry in
            guard let provider = Provider(rawValue: entry.key) else { return }
            result[provider] = entry.value
        }
        discoveredOverrides = decoded.discoveredOverrides ?? [:]
        refreshDiscoveredAccounts()
    }

    private func persist() {
        let payload = Persisted(
            managed: managed,
            tracked: Array(trackedProviders),
            systemOverrides: systemOverrides.reduce(into: [:]) { $0[$1.key.rawValue] = $1.value },
            discoveredOverrides: discoveredOverrides
        )
        guard let data = try? JSONEncoder().encode(payload) else { return }
        defaults.set(data, forKey: Self.profilesKey)
    }

    /// A profile whose isolated home was configured but now points outside the
    /// app's own directory is rejected rather than trusted.
    private static func isValid(_ profile: AccountProfile) -> Bool {
        guard profile.kind == .managed else { return false }
        guard let directory = profile.configurationDirectory else {
            // A captured account keeps its credential in the Keychain and has
            // no filesystem home to validate.
            return profile.provider.capturesCredentials
                || profile.provider.credentialKind == .keychainSecret
        }
        return URL(fileURLWithPath: directory).standardizedFileURL.path
            .hasPrefix(accountsDirectory.standardizedFileURL.path)
    }

    /// Only ever deletes inside the app's own accounts directory.
    private func removeManagedDirectoryIfSafe(_ directory: URL) {
        let resolved = directory.standardizedFileURL
        guard resolved.path.hasPrefix(Self.accountsDirectory.standardizedFileURL.path),
              resolved.path != Self.accountsDirectory.standardizedFileURL.path else { return }
        try? FileManager.default.removeItem(at: resolved)
    }

    static var accountsDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appending(path: "com.josephclarke.limits", directoryHint: .isDirectory)
            .appending(path: "accounts", directoryHint: .isDirectory)
    }

    /// Providers with a credential already on this machine.
    private static func autodetectedProviders() -> [Provider] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let exists = { (path: String) in FileManager.default.fileExists(atPath: path) }
        var detected: [Provider] = []
        if exists(home.appending(path: ".claude").path) { detected.append(.claude) }
        if exists(home.appending(path: ".codex").path) { detected.append(.codex) }
        if exists(NSString(string: "~/Library/Application Support/Cursor").expandingTildeInPath) {
            detected.append(.cursor)
        }
        if exists(home.appending(path: ".grok").path) { detected.append(.grok) }
        // Antigravity ships both a desktop app and the `agy` CLI, and the CLI
        // keeps its own state under ~/.gemini. Checking only for the .app
        // misses anyone who uses the CLI alone.
        if exists("/Applications/Antigravity.app")
            || exists(home.appending(path: "Applications/Antigravity.app").path)
            || exists(home.appending(path: ".gemini/antigravity-cli").path)
            || exists(home.appending(path: ".antigravity").path)
            || CLIResolver.resolve(named: "agy") != nil {
            detected.append(.antigravity)
        }
        // Never start with an empty screen.
        return detected.isEmpty ? [.claude] : detected
    }
}
