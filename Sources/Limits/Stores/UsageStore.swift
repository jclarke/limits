import Foundation
import SwiftUI

/// Drives refresh and holds live state per account.
@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var states: [AccountID: AccountState] = [:]
    @Published private(set) var isRefreshingAll = false
    @Published var lastLoginError: String?
    /// Set while a CLI sign-in is in flight so the UI can show progress and
    /// block a second concurrent login for the same account.
    @Published private(set) var loggingIn: Set<AccountID> = []

    /// Providers publish 5-hour and weekly windows, so a few minutes of
    /// staleness is invisible while a tighter loop just burns rate limit —
    /// Claude starts answering usage checks with 429 at a once-a-minute poll.
    static let refreshInterval: TimeInterval = 300

    private let accounts: AccountsStore
    private let fetcher = QuotaFetcher()
    private var timer: Timer?
    /// One in-flight fetch per account. Without this, a manual refresh during
    /// the timer's round would double every provider request.
    private var inFlight: Set<AccountID> = []

    init(accounts: AccountsStore) {
        self.accounts = accounts
    }

    deinit { timer?.invalidate() }

    func start() {
        guard timer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refreshAll() }
        }
        // Quota checks are not worth waking a sleeping Mac for.
        timer.tolerance = Self.refreshInterval * 0.25
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        Task { await refreshAll() }
    }

    // MARK: - Snapshots

    func state(for id: AccountID) -> AccountState { states[id] ?? AccountState() }

    func snapshot(for profile: AccountProfile) -> AccountSnapshot {
        AccountSnapshot(profile: profile, state: state(for: profile.id))
    }

    /// Enabled accounts grouped by provider, provider order preserved.
    var groupedSnapshots: [(provider: Provider, accounts: [AccountSnapshot])] {
        Provider.allCases.compactMap { provider in
            guard accounts.trackedProviders.contains(provider) else { return nil }
            let rows = accounts.profiles(for: provider)
                .filter(\.isEnabled)
                .map(snapshot(for:))
            return rows.isEmpty ? nil : (provider, rows)
        }
    }

    /// Accounts the user chose to surface in the menu bar title.
    var menuBarSnapshots: [AccountSnapshot] {
        accounts.allProfiles
            .filter { $0.isEnabled && $0.showsInMenuBar }
            .map(snapshot(for:))
    }

    /// Everything needing the user's attention, across every enabled account.
    var attentionSnapshots: [AccountSnapshot] {
        accounts.allProfiles
            .filter(\.isEnabled)
            .map(snapshot(for:))
            .filter(\.needsAttention)
    }

    // MARK: - Refresh

    func refreshAll(keychainInteraction: KeychainRead.Interaction = .disallowed) async {
        isRefreshingAll = true
        defer { isRefreshingAll = false }
        // A sign-in performed outside Limits should show up on its own.
        accounts.refreshDiscoveredAccounts()
        await accounts.refreshDiscoveredCursorAccounts()
        let profiles = accounts.allProfiles.filter(\.isEnabled)
        // Concurrently, but each account still guarded by `inFlight`.
        await withTaskGroup(of: Void.self) { group in
            for profile in profiles {
                group.addTask { @MainActor [weak self] in
                    await self?.refresh(profile, keychainInteraction: keychainInteraction)
                }
            }
        }
        // Drop state for accounts that no longer exist.
        let live = Set(accounts.allProfiles.map(\.id))
        states = states.filter { live.contains($0.key) }
    }

    func refresh(
        _ profile: AccountProfile,
        keychainInteraction: KeychainRead.Interaction = .disallowed
    ) async {
        guard !inFlight.contains(profile.id) else { return }
        inFlight.insert(profile.id)
        var pending = state(for: profile.id)
        pending.isRefreshing = true
        states[profile.id] = pending
        defer { inFlight.remove(profile.id) }

        do {
            let quota = try await fetcher.fetch(profile, keychainInteraction: keychainInteraction)
            states[profile.id] = AccountState(
                quota: quota,
                issue: nil,
                isRefreshing: false,
                lastRefreshedAt: .now
            )
        } catch {
            let issue = (error as? AccountIssue) ?? .other(error.localizedDescription)
            var failed = state(for: profile.id)
            failed.isRefreshing = false
            failed.issue = issue
            // Keep the last good numbers next to the warning; a transient
            // failure should not blank a row the user is watching.
            states[profile.id] = failed
        }
    }

    // MARK: - Sign-in

    /// Runs the provider's OAuth login for a managed CLI account, then
    /// immediately refreshes so the row shows real numbers on success.
    func signIn(_ profile: AccountProfile) async {
        guard profile.canSignInAgain, let directory = profile.configurationDirectoryURL else {
            lastLoginError = "This account can't be signed in from Limits."
            return
        }
        guard !loggingIn.contains(profile.id) else { return }
        loggingIn.insert(profile.id)
        lastLoginError = nil
        defer { loggingIn.remove(profile.id) }

        do {
            try await AccountLoginService().login(
                provider: profile.provider,
                configurationDirectory: directory
            )
            await refresh(profile)
        } catch {
            let issue = (error as? AccountIssue) ?? .other(error.localizedDescription)
            lastLoginError = issue.message(provider: profile.provider)
            var failed = state(for: profile.id)
            failed.issue = issue
            failed.isRefreshing = false
            states[profile.id] = failed
        }
    }

    /// Runs a provider CLI's own sign-in against its existing credential
    /// store. Adds an account for Grok; replaces one for Cursor.
    func signInSharedHome(provider: Provider) async {
        lastLoginError = nil
        let marker = AccountID(rawValue: "sharedhome.\(provider.rawValue)")
        guard !loggingIn.contains(marker) else { return }
        loggingIn.insert(marker)
        defer { loggingIn.remove(marker) }
        do {
            // The CLI's credential is about to be replaced, so keep a copy of
            // the account it currently holds. The editor's is untouched and
            // stays discoverable on its own.
            if provider.capturesCredentials { await captureCurrentAccount(provider: provider) }

            try await AccountLoginService().signInSharedHome(provider: provider)

            accounts.refreshDiscoveredAccounts()
            await accounts.refreshDiscoveredCursorAccounts()
            await refreshAll()
        } catch {
            let issue = (error as? AccountIssue) ?? .other(error.localizedDescription)
            lastLoginError = issue.message(provider: provider)
        }
    }

    /// Copies whatever the provider is signed into now into its own account.
    /// Only ever called from an explicit "add account" action.
    private func captureCurrentAccount(provider: Provider) async {
        guard provider == .cursor,
              let identity = await CursorAccountCapture.currentCLIIdentity(),
              CursorAccountCapture.isWorthCapturing(identity) else { return }
        try? accounts.captureAccount(
            provider: provider,
            displayName: identity.suggestedName,
            providerAccountKey: identity.subject,
            secret: identity.token
        )
    }

    func isSigningIn(provider: Provider) -> Bool {
        loggingIn.contains(AccountID(rawValue: "sharedhome.\(provider.rawValue)"))
    }

    /// Saves a pasted credential for a keychain-backed account and refreshes.
    func saveCredential(_ secret: String, for profile: AccountProfile) async {
        do {
            try AccountSecretStore.save(secret, for: profile.id)
            await refresh(profile)
        } catch {
            let issue = (error as? AccountIssue) ?? .other(error.localizedDescription)
            lastLoginError = issue.message(provider: profile.provider)
        }
    }

    /// Retries one account with the Keychain dialog allowed. Only ever called
    /// from an explicit user action.
    func authorizeKeychain(for profile: AccountProfile) async {
        await refresh(profile, keychainInteraction: .allowed)
    }
}
