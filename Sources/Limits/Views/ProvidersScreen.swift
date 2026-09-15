import SwiftUI

/// Organized by provider, then by account: add accounts, sign them in, choose
/// what appears where, and repair anything broken.
struct ProvidersScreen: View {
    @EnvironmentObject private var accounts: AccountsStore
    @EnvironmentObject private var usage: UsageStore
    @EnvironmentObject private var router: Router

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: Theme.cardGap) {
                    if let error = usage.lastLoginError {
                        loginErrorBanner(error)
                    }
                    ForEach(Provider.allCases) { provider in
                        ProviderSection(provider: provider).id(provider)
                    }
                    Text("Limits reads each provider's own saved login. It never refreshes or changes your credentials.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                        .padding(.top, 2)
                }
                .padding(Theme.contentPadding)
            }
            .onChange(of: router.highlighted) { _, id in
                guard let id, let profile = accounts.profile(id: id) else { return }
                withAnimation { proxy.scrollTo(profile.provider, anchor: .top) }
            }
        }
    }

    private func loginErrorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(Theme.warning)
            Text(message)
                .font(.system(size: 11))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("Dismiss") { usage.lastLoginError = nil }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Theme.warning.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Theme.warning.opacity(0.24), lineWidth: 0.5)
        )
    }
}

/// One provider: a tracking switch and its accounts.
private struct ProviderSection: View {
    @EnvironmentObject private var accounts: AccountsStore
    @EnvironmentObject private var router: Router

    let provider: Provider

    private var isTracked: Bool { accounts.trackedProviders.contains(provider) }

    var body: some View {
        GlassCard(muted: !isTracked) {
            VStack(spacing: 0) {
                header
                if isTracked {
                    Rectangle().fill(Theme.divider).frame(height: 0.5)
                    ForEach(accounts.profiles(for: provider)) { profile in
                        AccountRow(profile: profile)
                        Rectangle()
                            .fill(Theme.divider)
                            .frame(height: 0.5)
                            .padding(.leading, Theme.cardPadding)
                    }
                    addAccountRow
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
    }

    private var header: some View {
        HStack(spacing: 10) {
            ProviderMarkPlate(provider: provider, plateSize: 26, markSize: 15, cornerRadius: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(provider.displayName)
                    .font(.system(size: 13, weight: .semibold))
                    .kerning(-0.15)
                Text(subtitle)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 10)
            Toggle("", isOn: Binding(
                get: { isTracked },
                set: { accounts.setTracked(provider, tracked: $0) }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
            .labelsHidden()
            .help("Track \(provider.displayName)")
        }
        .padding(.horizontal, Theme.cardPadding)
        .padding(.vertical, 11)
        // Dim an untracked provider rather than hiding it: discovering a
        // supported provider should not require adding it first.
        .opacity(isTracked ? 1 : 0.55)
    }

    private var subtitle: String {
        switch provider.credentialKind {
        case .isolatedCLI:
            "Sign in to as many accounts as you like — each gets its own isolated profile."
        case .keychainSecret:
            "Reads the account \(provider.displayName) is signed into. Extra accounts use a saved token."
        }
    }

    private var addAccountRow: some View {
        Button {
            router.sheet = .addAccount
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "plus").font(.system(size: 10, weight: .semibold))
                Text("Add another \(provider.displayName) account")
                    .font(.system(size: 11.5))
                Spacer()
            }
            .foregroundStyle(Color.accentColor)
            .contentShape(Rectangle())
            .padding(.horizontal, Theme.cardPadding)
            .padding(.vertical, 9)
        }
        .buttonStyle(.plain)
    }
}

/// One account row: status, visibility checkboxes, and its fix action.
private struct AccountRow: View {
    @EnvironmentObject private var accounts: AccountsStore
    @EnvironmentObject private var usage: UsageStore
    @EnvironmentObject private var router: Router

    let profile: AccountProfile
    @State private var isRenaming = false
    @State private var draftName = ""
    @State private var confirmingRemoval = false
    @State private var isHovering = false

    private var snapshot: AccountSnapshot { usage.snapshot(for: profile) }
    private var isHighlighted: Bool { router.highlighted == profile.id }
    private var isSigningIn: Bool { usage.loggingIn.contains(profile.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 10) {
                StatusDot(color: dotColor)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(snapshot.name)
                            .font(.system(size: 12, weight: .medium))
                            .kerning(-0.08)
                        if profile.isSystem { Chip(text: "System") }
                        if let plan = snapshot.quota?.planName { Chip(text: plan) }
                    }
                    Text(statusText)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 10)
                if isSigningIn {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small).scaleEffect(0.6)
                        Text("Signing in…").font(.system(size: 10.5)).foregroundStyle(.secondary)
                    }
                } else {
                    visibilityControls
                    actionsMenu
                }
            }

            if snapshot.issue != nil {
                IssueRow(snapshot: snapshot) { apply($0) }
            }
        }
        .padding(.horizontal, Theme.cardPadding)
        .padding(.vertical, 10)
        .background(rowBackground)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.2), value: isHighlighted)
        .onAppear {
            guard isHighlighted else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                if router.highlighted == profile.id { router.highlighted = nil }
            }
        }
        .alert("Rename account", isPresented: $isRenaming) {
            TextField("Name", text: $draftName)
            Button("Save") { accounts.rename(profile.id, to: draftName) }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Remove \(snapshot.name)?", isPresented: $confirmingRemoval) {
            Button("Remove", role: .destructive) {
                accounts.remove(profile.id)
                Task { await usage.refreshAll() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deletes the account's saved credential and its isolated profile folder. Your \(profile.provider.displayName) installation itself is untouched.")
        }
    }

    @ViewBuilder
    private var rowBackground: some View {
        if isHighlighted {
            Color.accentColor.opacity(0.12)
        } else if isHovering {
            Color.primary.opacity(0.035)
        } else {
            Color.clear
        }
    }

    /// Checkboxes rather than filled toggle buttons: two of these per row in a
    /// long list, the button style's filled-when-on state dominates the screen
    /// and buries the account name that actually identifies the row.
    private var visibilityControls: some View {
        HStack(spacing: 12) {
            Toggle("Menu Bar", isOn: Binding(
                get: { profile.showsInMenuBar },
                set: { accounts.setShowsInMenuBar(profile.id, $0) }
            ))
            .help("Show this account's remaining percentage in the menu bar")

            Toggle("Track", isOn: Binding(
                get: { profile.isEnabled },
                set: { accounts.setEnabled(profile.id, $0) }
            ))
            .help("Fetch this account and show it on the Limits screen")
        }
        .toggleStyle(.checkbox)
        .controlSize(.small)
        .font(.system(size: 10.5))
        .fixedSize()
    }

    private var actionsMenu: some View {
        Menu {
            if profile.canSignInAgain {
                Button("Sign in again") { Task { await usage.signIn(profile) } }
            }
            if profile.credentialKind == .keychainSecret, !profile.isSystem {
                Button("Update token…") { router.sheet = .credential(profile) }
            }
            Button("Refresh now") { Task { await usage.refresh(profile) } }
            Button("Rename…") {
                draftName = snapshot.name
                isRenaming = true
            }
            if !profile.isSystem {
                Divider()
                Button("Remove account", role: .destructive) { confirmingRemoval = true }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More actions")
    }

    private var dotColor: Color {
        if snapshot.needsAttention { return Theme.warning }
        if snapshot.issue != nil { return .yellow }
        return snapshot.quota == nil ? .secondary : Theme.healthy
    }

    private var statusText: String {
        if let issue = snapshot.issue { return issue.title }
        guard let quota = snapshot.quota else { return "Waiting for first refresh…" }
        guard let window = quota.headlineWindow else { return "Signed in" }
        return "\(Formatting.percent(window.remainingPercent)) left · \(window.label)"
    }

    private func apply(_ remedy: AccountIssue.Remedy) {
        switch remedy {
        case .signInAgain: Task { await usage.signIn(profile) }
        case .retry: Task { await usage.refresh(profile) }
        case .authorizeKeychain: Task { await usage.authorizeKeychain(for: profile) }
        case .replaceToken: router.sheet = .credential(profile)
        case .signInWithProviderApp, .installCLI: router.sheet = .guidance(profile)
        }
    }
}
