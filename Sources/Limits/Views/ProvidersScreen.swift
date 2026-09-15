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
                LazyVStack(alignment: .leading, spacing: Metrics.sectionSpacing) {
                    if let error = usage.lastLoginError {
                        loginErrorBanner(error)
                    }
                    ForEach(Provider.allCases) { provider in
                        ProviderSection(provider: provider).id(provider)
                    }
                    Text("Limits reads each provider's own saved login. It never refreshes or changes your credentials.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.top, 2)
                }
                .padding(16)
            }
            .onChange(of: router.highlighted) { _, id in
                guard let id, let profile = accounts.profile(id: id) else { return }
                withAnimation { proxy.scrollTo(profile.provider, anchor: .top) }
            }
        }
    }

    private func loginErrorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("Dismiss") { usage.lastLoginError = nil }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
                .fill(Color.orange.opacity(0.09))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.22))
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
        VStack(alignment: .leading, spacing: 0) {
            header
            if isTracked {
                Divider()
                ForEach(accounts.profiles(for: provider)) { profile in
                    AccountRow(profile: profile)
                    Divider().padding(.leading, Metrics.cardPadding)
                }
                addAccountRow
            }
        }
        .background(
            RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08))
        )
        .clipShape(RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous))
    }

    private var header: some View {
        HStack(spacing: 10) {
            ProviderMark(provider: provider, size: 17)
            VStack(alignment: .leading, spacing: 2) {
                Text(provider.displayName).font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Toggle("", isOn: Binding(
                get: { isTracked },
                set: { accounts.setTracked(provider, tracked: $0) }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
            .labelsHidden()
            .help("Track \(provider.displayName)")
        }
        .padding(Metrics.cardPadding)
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
                Image(systemName: "plus.circle.fill").foregroundStyle(Color.accentColor)
                Text("Add another \(provider.displayName) account").font(.callout)
                Spacer()
            }
            .contentShape(Rectangle())
            .padding(.horizontal, Metrics.cardPadding)
            .padding(.vertical, 10)
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
                        Text(snapshot.name).fontWeight(.medium)
                        if profile.isSystem { Chip(text: "System") }
                        if let plan = snapshot.quota?.planName { Chip(text: plan) }
                    }
                    Text(statusText).font(.caption).foregroundStyle(.secondary)
                }

                Spacer(minLength: 12)

                if isSigningIn {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small).scaleEffect(0.65)
                        Text("Signing in…").font(.caption).foregroundStyle(.secondary)
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
        .padding(Metrics.cardPadding)
        .background(rowBackground)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.2), value: isHighlighted)
        .onAppear {
            // Clear the highlight once the user has had time to see it.
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
        HStack(spacing: 14) {
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
        .font(.caption)
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
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More actions")
    }

    private var dotColor: Color {
        if snapshot.needsAttention { return .orange }
        if snapshot.issue != nil { return .yellow }
        return snapshot.quota == nil ? .secondary : .green
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
