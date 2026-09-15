import SwiftUI

/// Two screens only: Limits and Providers.
struct DashboardView: View {
    @EnvironmentObject private var accounts: AccountsStore
    @EnvironmentObject private var usage: UsageStore
    @EnvironmentObject private var router: Router

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            Group {
                switch router.tab {
                case .limits: LimitsScreen()
                case .providers: ProvidersScreen()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .underPageBackgroundColor))
            .navigationTitle(router.tab.title)
            .toolbar {
                ToolbarItemGroup {
                    if router.tab == .providers {
                        Button {
                            router.sheet = .addAccount
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
        }
        .sheet(item: $router.sheet) { sheet in
            switch sheet {
            case .addAccount:
                AddAccountSheet()
                    .environmentObject(accounts)
                    .environmentObject(usage)
                    .environmentObject(router)
            case .credential(let profile):
                CredentialEntrySheet(profile: profile)
                    .environmentObject(usage)
            case .guidance(let profile):
                GuidanceSheet(profile: profile)
            }
        }
    }

    private var sidebar: some View {
        List(selection: $router.tab) {
            Section("Monitor") {
                ForEach(Router.Tab.allCases) { tab in
                    Label(tab.title, systemImage: tab.symbolName).tag(tab)
                }
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 172, ideal: 188, max: 240)
        .safeAreaInset(edge: .bottom, spacing: 0) { healthFooter }
    }

    /// One honest line about whether the numbers on screen can be trusted.
    private var healthFooter: some View {
        let attention = usage.attentionSnapshots.count
        return VStack(spacing: 0) {
            Divider()
            HStack(spacing: 7) {
                StatusDot(color: attention == 0 ? .green : .orange)
                Text(attention == 0
                     ? "All accounts healthy"
                     : "\(attention) account\(attention == 1 ? "" : "s") need attention")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
        }
    }
}

/// The Limits screen: one card per provider, accounts inside.
struct LimitsScreen: View {
    @EnvironmentObject private var usage: UsageStore
    @EnvironmentObject private var router: Router

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Metrics.sectionSpacing) {
                if !usage.attentionSnapshots.isEmpty {
                    AttentionBanner()
                }
                if usage.groupedSnapshots.isEmpty {
                    emptyState
                } else {
                    BalancedColumns(
                        items: usage.groupedSnapshots.map(ProviderGroup.init),
                        // One row per quota window, plus a header and a name
                        // line per account: close enough to real height to
                        // keep the columns level.
                        weight: { group in
                            2 + group.accounts.reduce(0) { total, account in
                                total + 1 + (account.quota?.windows.count ?? 1)
                            }
                        }
                    ) { group in
                        ProviderLimitsCard(provider: group.provider, accounts: group.accounts)
                    }
                }
                footer
            }
            .padding(16)
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No accounts tracked", systemImage: "gauge.with.dots.needle.67percent")
        } description: {
            Text("Add an account on the Providers screen to see its limits here.")
        } actions: {
            Button("Open Providers") { router.tab = .providers }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, minHeight: 320)
    }

    private var footer: some View {
        HStack(spacing: 5) {
            if usage.isRefreshingAll {
                ProgressView().controlSize(.small).scaleEffect(0.6)
                Text("Refreshing…")
            } else if let updated = Formatting.relative(
                usage.states.values.compactMap(\.lastRefreshedAt).max()
            ) {
                Text(updated)
            }
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.tertiary)
        .padding(.top, 2)
    }
}

/// Identifiable wrapper so a provider's accounts can drive a layout.
private struct ProviderGroup: Identifiable {
    let provider: Provider
    let accounts: [AccountSnapshot]

    var id: Provider { provider }

    init(_ group: (provider: Provider, accounts: [AccountSnapshot])) {
        provider = group.provider
        accounts = group.accounts
    }
}

/// Jumps straight from a problem to the account that has it.
private struct AttentionBanner: View {
    @EnvironmentObject private var usage: UsageStore
    @EnvironmentObject private var router: Router

    var body: some View {
        let snapshots = usage.attentionSnapshots
        VStack(alignment: .leading, spacing: 9) {
            Label(
                "\(snapshots.count) account\(snapshots.count == 1 ? "" : "s") need attention",
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.orange)

            ForEach(snapshots) { snapshot in
                HStack(spacing: 7) {
                    ProviderMark(provider: snapshot.provider, size: 12)
                    Text(snapshot.provider.displayName).font(.caption).fontWeight(.medium)
                    Text(snapshot.name).font(.caption).foregroundStyle(.secondary)
                    Text("·").foregroundStyle(.tertiary)
                    Text(snapshot.issue?.title ?? "").font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Button("Fix") {
                        router.highlighted = snapshot.id
                        router.tab = .providers
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
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

/// One provider's limits card, with each account's windows.
private struct ProviderLimitsCard: View {
    @EnvironmentObject private var usage: UsageStore
    @EnvironmentObject private var router: Router

    let provider: Provider
    let accounts: [AccountSnapshot]

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                ProviderHeader(
                    provider: provider,
                    accountCount: accounts.count,
                    // With one account there is no ambiguity about whose plan
                    // this is, so it belongs beside the provider name rather
                    // than stranded on a line of its own.
                    planName: accounts.count == 1 ? accounts.first?.quota?.planName : nil
                )

                ForEach(accounts) { snapshot in
                    VStack(alignment: .leading, spacing: 8) {
                        accountHeader(snapshot)

                        if let quota = snapshot.quota {
                            ForEach(quota.windows) { window in
                                QuotaWindowRow(window: window, provider: provider)
                            }
                        }

                        if snapshot.issue != nil {
                            IssueRow(snapshot: snapshot) { apply($0, to: snapshot) }
                        } else if snapshot.quota == nil {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small).scaleEffect(0.6)
                                Text("Loading…").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    if snapshot.id != accounts.last?.id {
                        Divider().padding(.vertical, 2)
                    }
                }
            }
        }
    }

    /// Only shown when it adds information: a lone system account's name is
    /// already implied by the provider heading above it.
    @ViewBuilder
    private func accountHeader(_ snapshot: AccountSnapshot) -> some View {
        let showsName = accounts.count > 1 || !snapshot.profile.isSystem
        if showsName {
            HStack(spacing: 6) {
                Text(snapshot.name).font(.subheadline).fontWeight(.medium)
                if let plan = snapshot.quota?.planName { Chip(text: plan) }
                Spacer(minLength: 0)
                if snapshot.state.isRefreshing {
                    ProgressView().controlSize(.small).scaleEffect(0.55)
                }
            }
        }
    }

    private func apply(_ remedy: AccountIssue.Remedy, to snapshot: AccountSnapshot) {
        switch remedy {
        case .signInAgain: Task { await usage.signIn(snapshot.profile) }
        case .retry: Task { await usage.refresh(snapshot.profile) }
        case .authorizeKeychain: Task { await usage.authorizeKeychain(for: snapshot.profile) }
        case .replaceToken: router.sheet = .credential(snapshot.profile)
        case .signInWithProviderApp, .installCLI: router.sheet = .guidance(snapshot.profile)
        }
    }
}
