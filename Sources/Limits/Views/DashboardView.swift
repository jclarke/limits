import SwiftUI

/// Two screens only: Limits and Providers.
struct DashboardView: View {
    @EnvironmentObject private var accounts: AccountsStore
    @EnvironmentObject private var usage: UsageStore
    @EnvironmentObject private var router: Router

    var body: some View {
        NavigationSplitView {
            List(selection: $router.tab) {
                Section("Monitor") {
                    ForEach(Router.Tab.allCases) { tab in
                        Label(tab.title, systemImage: tab.symbolName).tag(tab)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 240)
            .safeAreaInset(edge: .bottom) { syncStatus }
        } detail: {
            Group {
                switch router.tab {
                case .limits: LimitsScreen()
                case .providers: ProvidersScreen()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    /// A single honest line about whether the numbers on screen can be trusted.
    private var syncStatus: some View {
        let attention = usage.attentionSnapshots.count
        return HStack(spacing: 7) {
            Circle()
                .fill(attention == 0 ? Color.green : Color.orange)
                .frame(width: 7, height: 7)
            Text(attention == 0
                 ? "All accounts healthy"
                 : "\(attention) account\(attention == 1 ? "" : "s") need attention")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

/// The dashboard's Limits screen: one card per provider, accounts inside.
struct LimitsScreen: View {
    @EnvironmentObject private var accounts: AccountsStore
    @EnvironmentObject private var usage: UsageStore
    @EnvironmentObject private var router: Router

    private let columns = [GridItem(.adaptive(minimum: 330, maximum: 520), spacing: 16, alignment: .top)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if !usage.attentionSnapshots.isEmpty {
                    AttentionBanner()
                }
                if usage.groupedSnapshots.isEmpty {
                    ContentUnavailableView {
                        Label("No accounts tracked", systemImage: "gauge.with.dots.needle.67percent")
                    } description: {
                        Text("Add an account on the Providers screen to see its limits here.")
                    } actions: {
                        Button("Open Providers") { router.tab = .providers }
                            .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity, minHeight: 300)
                } else {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(usage.groupedSnapshots, id: \.provider) { group in
                            ProviderLimitsCard(provider: group.provider, accounts: group.accounts)
                        }
                    }
                }
            }
            .padding(20)
        }
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Limits").font(.largeTitle).fontWeight(.semibold)
                Text("Quota windows across your AI coding tools")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let updated = Formatting.relative(usage.states.values.compactMap(\.lastRefreshedAt).max()) {
                Text(updated).font(.caption).foregroundStyle(.secondary)
            }
            Button {
                Task { await usage.refreshAll() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(usage.isRefreshingAll)
        }
    }
}

/// Jumps straight from a problem to the account that has it.
private struct AttentionBanner: View {
    @EnvironmentObject private var usage: UsageStore
    @EnvironmentObject private var router: Router

    var body: some View {
        let snapshots = usage.attentionSnapshots
        VStack(alignment: .leading, spacing: 8) {
            Label(
                "\(snapshots.count) account\(snapshots.count == 1 ? "" : "s") need attention",
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.orange)

            ForEach(snapshots) { snapshot in
                HStack(spacing: 6) {
                    ProviderMark(provider: snapshot.provider, size: 11)
                    Text("\(snapshot.provider.displayName) · \(snapshot.name)").font(.caption)
                    Text(snapshot.issue?.title ?? "").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Fix") {
                        router.tab = .providers
                        router.highlighted = snapshot.id
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.orange.opacity(0.10))
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
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 7) {
                ProviderMark(provider: provider, size: 15)
                Text(provider.displayName).font(.title3).fontWeight(.semibold)
                Spacer()
                if accounts.count > 1 {
                    Text("\(accounts.count) accounts").font(.caption).foregroundStyle(.secondary)
                }
            }

            ForEach(accounts) { snapshot in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: snapshot.profile.isSystem ? "person.crop.circle" : "person.crop.circle.badge.plus")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(snapshot.name).font(.subheadline).fontWeight(.medium)
                        if let plan = snapshot.quota?.planName {
                            Text(plan)
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.primary.opacity(0.08)))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if snapshot.state.isRefreshing {
                            ProgressView().controlSize(.small).scaleEffect(0.65)
                        }
                    }

                    if let quota = snapshot.quota {
                        ForEach(quota.windows) { window in
                            QuotaWindowRow(window: window)
                        }
                    }

                    if snapshot.issue != nil {
                        IssueRow(snapshot: snapshot) { remedy in
                            apply(remedy, to: snapshot)
                        }
                    } else if snapshot.quota == nil {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small).scaleEffect(0.65)
                            Text("Loading…").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if snapshot.id != accounts.last?.id { Divider() }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07))
        )
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
