import SwiftUI

/// The redesign is a narrow single-column utility window rather than a split
/// view: a unified translucent titlebar carrying a segmented screen switcher,
/// with glass cards below it.
struct DashboardView: View {
    @EnvironmentObject private var accounts: AccountsStore
    @EnvironmentObject private var usage: UsageStore
    @EnvironmentObject private var router: Router

    var body: some View {
        Group {
            switch router.tab {
            case .limits: LimitsScreen()
            case .providers: ProvidersScreen()
            }
        }
        .frame(width: Theme.windowWidth)
        .frame(maxHeight: .infinity)
        // Vibrancy behind the whole window is what makes the cards read as
        // glass rather than as flat panels.
        .background(VisualEffectBackground(material: .underWindowBackground))
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Screen", selection: $router.tab) {
                    ForEach(Router.Tab.allCases) { tab in
                        Text(tab.title).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 168)
            }
            ToolbarItemGroup {
                if router.tab == .providers {
                    Button {
                        router.sheet = .addAccount(nil)
                    } label: {
                        Label("Add Account", systemImage: "plus")
                    }
                    .help("Add a provider account")
                }
                Button {
                    Task { await usage.refreshAll() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(usage.isRefreshingAll)
                .help("Refresh every tracked account")
            }
        }
        .sheet(item: $router.sheet) { sheet in
            switch sheet {
            case .addAccount(let provider):
                AddAccountSheet(initialProvider: provider ?? accounts.firstTrackedProvider)
                    .environmentObject(accounts)
                    .environmentObject(usage)
                    .environmentObject(router)
            case .credential(let profile):
                CredentialEntrySheet(profile: profile).environmentObject(usage)
            case .guidance(let profile):
                GuidanceSheet(profile: profile)
            case .antigravitySignIn(let profile):
                AntigravitySignInView(profile: profile) { _ in router.sheet = nil }
                    .environmentObject(usage)
            }
        }
    }
}

/// NSVisualEffectView bridge — SwiftUI's materials only tint a shape, they do
/// not give the window itself real vibrancy.
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blendingMode
    }
}

/// The Limits screen: one glass card per provider, accounts stacked inside.
struct LimitsScreen: View {
    @EnvironmentObject private var usage: UsageStore
    @EnvironmentObject private var router: Router

    var body: some View {
        ScrollView {
            LazyVStack(spacing: Theme.cardGap) {
                if usage.groupedSnapshots.isEmpty {
                    emptyState
                } else {
                    ForEach(usage.groupedSnapshots, id: \.provider) { group in
                        ProviderLimitsCard(provider: group.provider, accounts: group.accounts)
                    }
                }
                footer
            }
            .padding(Theme.contentPadding)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 9) {
            Image(systemName: "gauge.with.dots.needle.67percent")
                .font(.title)
                .foregroundStyle(.secondary)
            Text("No accounts tracked").font(.subheadline).fontWeight(.medium)
            Text("Add an account on the Providers screen to see its limits here.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Open Providers") { router.tab = .providers }
                .controlSize(.small)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }

    private var footer: some View {
        HStack(spacing: 5) {
            if usage.isRefreshingAll {
                ProgressView().controlSize(.small).scaleEffect(0.55)
                Text("Refreshing…")
            } else if let updated = Formatting.relative(
                usage.states.values.compactMap(\.lastRefreshedAt).max()
            ) {
                Text(updated)
            }
            Spacer()
        }
        .font(.system(size: 10.5))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 4)
        .padding(.top, 2)
    }
}

/// One provider card: header, then a section per account.
private struct ProviderLimitsCard: View {
    @EnvironmentObject private var usage: UsageStore
    @EnvironmentObject private var router: Router

    let provider: Provider
    let accounts: [AccountSnapshot]

    private var lowestRemaining: Double? {
        accounts.compactMap { $0.quota?.lowestRemainingPercent }.min()
    }

    private var needsAttention: Bool { accounts.contains { $0.needsAttention } }

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                header
                ForEach(accounts) { snapshot in
                    if snapshot.id != accounts.first?.id {
                        Rectangle()
                            .fill(Theme.divider)
                            .frame(height: 0.5)
                    }
                    accountSection(snapshot)
                }
            }
            .padding(.horizontal, Theme.cardPadding)
            .padding(.top, 11)
            .padding(.bottom, 12)
        }
    }

    /// With one account there is no ambiguity about whose plan this is, so it
    /// belongs beside the provider name rather than stranded on a line of its
    /// own above the meters.
    private var soloPlanName: String? {
        guard accounts.count == 1, accounts[0].profile.isSystem else { return nil }
        return accounts[0].quota?.planName
    }

    private var header: some View {
        HStack(spacing: 8) {
            ProviderMarkPlate(provider: provider)
            Text(provider.displayName)
                .font(.system(size: 13, weight: .semibold))
                .kerning(-0.15)
            if let soloPlanName { Chip(text: soloPlanName) }
            Spacer(minLength: 6)
            if accounts.count > 1 {
                Text("\(accounts.count) accounts")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            // The header carries the provider's worst number so a collapsed
            // glance still tells the user where they stand.
            if let lowestRemaining {
                StatusDot(color: statusColor, size: 5)
                Text(Formatting.percent(lowestRemaining))
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Formatting.isLow(lowestRemaining) ? Theme.low : .secondary)
            } else if needsAttention {
                StatusDot(color: Theme.warning, size: 5)
            }
        }
    }

    private var statusColor: Color {
        if needsAttention { return Theme.warning }
        guard let lowestRemaining else { return .secondary }
        return Formatting.isLow(lowestRemaining) ? Theme.low : Theme.healthy
    }

    @ViewBuilder
    private func accountSection(_ snapshot: AccountSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // A single system account needs no name: the provider header
            // directly above already identifies it.
            if accounts.count > 1 || !snapshot.profile.isSystem {
                HStack(spacing: 6) {
                    Text(snapshot.name)
                        .font(.system(size: 11.5, weight: .medium))
                        .kerning(-0.08)
                    if let plan = snapshot.quota?.planName { Chip(text: plan) }
                    Spacer(minLength: 0)
                    if snapshot.state.isRefreshing {
                        ProgressView().controlSize(.small).scaleEffect(0.5)
                    }
                }
            }

            if let quota = snapshot.quota {
                ForEach(quota.windows) { window in
                    QuotaWindowRow(window: window, provider: provider)
                }
            }

            if snapshot.issue != nil {
                IssueRow(snapshot: snapshot) { apply($0, to: snapshot) }
            } else if snapshot.quota == nil {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small).scaleEffect(0.5)
                    Text("Loading…").font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
            }
        }
    }


    /// Antigravity's sign-in needs a code pasted back, so it opens a screen;
    /// Claude and Codex complete entirely inside their own CLI.
    private func startSignIn(_ profile: AccountProfile) {
        if profile.provider == .antigravity {
            router.sheet = .antigravitySignIn(profile)
        } else {
            Task { await usage.signIn(profile) }
        }
    }

    private func apply(_ remedy: AccountIssue.Remedy, to snapshot: AccountSnapshot) {
        switch remedy {
        case .signInAgain: startSignIn(snapshot.profile)
        case .retry: Task { await usage.refresh(snapshot.profile) }
        case .authorizeKeychain: Task { await usage.authorizeKeychain(for: snapshot.profile) }
        case .replaceToken: router.sheet = .credential(snapshot.profile)
        case .signInWithProviderApp, .installCLI: router.sheet = .guidance(snapshot.profile)
        }
    }
}
