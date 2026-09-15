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
                VStack(alignment: .leading, spacing: 16) {
                    header
                    if let error = usage.lastLoginError {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(.orange)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(Color.orange.opacity(0.10))
                            )
                    }
                    ForEach(Provider.allCases) { provider in
                        ProviderSection(provider: provider)
                            .id(provider)
                    }
                }
                .padding(20)
            }
            .background(Color(nsColor: .underPageBackgroundColor))
            .onChange(of: router.highlighted) { _, id in
                guard let id, let profile = accounts.profile(id: id) else { return }
                withAnimation { proxy.scrollTo(profile.provider, anchor: .top) }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Providers").font(.largeTitle).fontWeight(.semibold)
                Text("Sign in to multiple accounts and choose what to show")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                router.sheet = .addAccount
            } label: {
                Label("Add Account", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

/// One provider: a tracking toggle and its accounts.
private struct ProviderSection: View {
    @EnvironmentObject private var accounts: AccountsStore
    @EnvironmentObject private var usage: UsageStore
    @EnvironmentObject private var router: Router

    let provider: Provider

    private var isTracked: Bool { accounts.trackedProviders.contains(provider) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                ProviderMark(provider: provider, size: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(provider.displayName).font(.title3).fontWeight(.semibold)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("Track", isOn: Binding(
                    get: { isTracked },
                    set: { accounts.setTracked(provider, tracked: $0) }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .help("Track \(provider.displayName)")
            }
            .padding(16)

            if isTracked {
                Divider()
                VStack(spacing: 0) {
                    ForEach(accounts.profiles(for: provider)) { profile in
                        AccountRow(profile: profile)
                        Divider().padding(.leading, 16)
                    }
                    addAccountRow
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07))
        )
        .opacity(isTracked ? 1 : 0.65)
    }

    private var subtitle: String {
        switch provider.credentialKind {
        case .isolatedCLI:
            return "Sign in to as many accounts as you like — each gets its own isolated \(provider.displayName) profile."
        case .keychainSecret:
            return "Reads the account \(provider.displayName) is signed into. Extra accounts use a saved token."
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
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
        }
        .buttonStyle(.plain)
    }
}

/// One account row: name, state, visibility toggles, and its fix action.
private struct AccountRow: View {
    @EnvironmentObject private var accounts: AccountsStore
    @EnvironmentObject private var usage: UsageStore
    @EnvironmentObject private var router: Router

    let profile: AccountProfile
    @State private var isRenaming = false
    @State private var draftName = ""
    @State private var confirmingRemoval = false

    private var snapshot: AccountSnapshot { usage.snapshot(for: profile) }
    private var isHighlighted: Bool { router.highlighted == profile.id }
    private var isSigningIn: Bool { usage.loggingIn.contains(profile.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                statusDot
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(snapshot.name).font(.body).fontWeight(.medium)
                        if profile.isSystem {
                            Text("System")
                                .font(.caption2)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Capsule().fill(Color.primary.opacity(0.08)))
                                .foregroundStyle(.secondary)
                        }
                        if let plan = snapshot.quota?.planName {
                            Text(plan).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    Text(statusText).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()

                if isSigningIn {
                    HStack(spacing: 5) {
                        ProgressView().controlSize(.small).scaleEffect(0.7)
                        Text("Signing in…").font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    controls
                }
            }

            if snapshot.issue != nil {
                IssueRow(snapshot: snapshot) { remedy in apply(remedy) }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(isHighlighted ? Color.accentColor.opacity(0.10) : .clear)
        .animation(.easeOut(duration: 0.25), value: isHighlighted)
        .onAppear {
            // Clear the highlight once the user has seen it.
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

    private var statusDot: some View {
        Circle()
            .fill(dotColor)
            .frame(width: 8, height: 8)
            .help(snapshot.issue?.title ?? "Healthy")
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
        return "\(Formatting.percent(window.remainingPercent)) remaining · \(window.label)"
    }

    private var controls: some View {
        HStack(spacing: 10) {
            // Labelled rather than icon-only: "shown in the menu bar" and
            // "tracked at all" are not concepts a glyph can carry on its own.
            Toggle(isOn: Binding(
                get: { profile.showsInMenuBar },
                set: { accounts.setShowsInMenuBar(profile.id, $0) }
            )) {
                Label("Menu Bar", systemImage: "menubar.arrow.up.rectangle")
            }
            .toggleStyle(.button)
            .help("Show this account's remaining percentage in the menu bar")

            Toggle(isOn: Binding(
                get: { profile.isEnabled },
                set: { accounts.setEnabled(profile.id, $0) }
            )) {
                Label("Track", systemImage: profile.isEnabled ? "eye" : "eye.slash")
            }
            .toggleStyle(.button)
            .help("Track this account and show it on the Limits screen")

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
        .font(.caption)
        .labelStyle(.titleAndIcon)
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
