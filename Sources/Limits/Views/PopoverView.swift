import AppKit
import SwiftUI

/// The menu bar dropdown: every tracked account grouped by provider, with any
/// problem repairable inline.
struct PopoverView: View {
    @EnvironmentObject private var accounts: AccountsStore
    @EnvironmentObject private var usage: UsageStore
    @EnvironmentObject private var router: Router

    private var groups: [(provider: Provider, accounts: [AccountSnapshot])] { usage.groupedSnapshots }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if groups.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(groups, id: \.provider) { group in
                            ProviderGroupCard(provider: group.provider, accounts: group.accounts)
                        }
                    }
                    .padding(10)
                }
                // Tall enough for a few providers, bounded so the popover
                // never grows past the screen on a busy setup.
                .frame(maxHeight: 460)
            }
            Divider()
            footer
        }
        .frame(width: 340)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "gauge.with.dots.needle.67percent")
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 1) {
                Text("Limits").font(.headline)
                if let updated = Formatting.relative(latestRefresh) {
                    Text(updated).font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button {
                Task { await usage.refreshAll() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .rotationEffect(.degrees(usage.isRefreshingAll ? 360 : 0))
                    .animation(
                        usage.isRefreshingAll
                            ? .linear(duration: 1).repeatForever(autoreverses: false)
                            : .default,
                        value: usage.isRefreshingAll
                    )
            }
            .buttonStyle(.borderless)
            .help("Refresh all accounts")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "person.2.badge.key")
                .font(.title)
                .foregroundStyle(.secondary)
            Text("No accounts yet").font(.subheadline).fontWeight(.medium)
            Text("Add a provider account to start tracking limits.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Add Account") { open(tab: .providers, sheet: .addAccount) }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .padding(.horizontal, 20)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button("Limits") { open(tab: .limits) }
                .buttonStyle(.borderless)
            Button("Providers") { open(tab: .providers) }
                .buttonStyle(.borderless)
            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var latestRefresh: Date? {
        usage.states.values.compactMap(\.lastRefreshedAt).max()
    }

    private func open(tab: Router.Tab, sheet: Router.Sheet? = nil) {
        router.openDashboard(tab, sheet: sheet)
    }
}

/// One provider's card in the popover, listing each of its accounts.
private struct ProviderGroupCard: View {
    @EnvironmentObject private var usage: UsageStore
    @EnvironmentObject private var router: Router

    let provider: Provider
    let accounts: [AccountSnapshot]

    private var lowestRemaining: Double? {
        accounts.compactMap { $0.quota?.lowestRemainingPercent }.min()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                ProviderMark(provider: provider)
                Text(provider.displayName).font(.subheadline).fontWeight(.semibold)
                Spacer()
                if accounts.count > 1, let lowestRemaining {
                    Text("lowest \(Formatting.percent(lowestRemaining))")
                        .font(.caption2)
                        .foregroundStyle(Formatting.tint(forRemaining: lowestRemaining))
                }
            }

            ForEach(accounts) { snapshot in
                AccountBlock(snapshot: snapshot, showsName: accounts.count > 1 || !snapshot.profile.isSystem)
                if snapshot.id != accounts.last?.id {
                    Divider().opacity(0.4)
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.primary.opacity(0.045))
        )
    }
}

/// One account inside a provider card.
private struct AccountBlock: View {
    @EnvironmentObject private var usage: UsageStore
    @EnvironmentObject private var router: Router

    let snapshot: AccountSnapshot
    let showsName: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if showsName {
                HStack(spacing: 5) {
                    Text(snapshot.name).font(.caption).foregroundStyle(.secondary)
                    if let plan = snapshot.quota?.planName {
                        Text(plan)
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.primary.opacity(0.08)))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if snapshot.state.isRefreshing {
                        ProgressView().controlSize(.small).scaleEffect(0.6)
                    }
                }
            }

            if let quota = snapshot.quota {
                ForEach(quota.windows) { window in
                    QuotaWindowRow(window: window, isCompact: true)
                }
            }

            if snapshot.issue != nil {
                IssueRow(snapshot: snapshot, isCompact: true) { remedy in
                    apply(remedy)
                }
            } else if snapshot.quota == nil {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small).scaleEffect(0.6)
                    Text("Loading…").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Remedies that need no input run right here. Anything requiring typing
    /// or explanation hands off to the Providers screen, pre-targeted at this
    /// account so the user never has to hunt for it.
    private func apply(_ remedy: AccountIssue.Remedy) {
        switch remedy {
        case .signInAgain:
            Task { await usage.signIn(snapshot.profile) }
        case .retry:
            Task { await usage.refresh(snapshot.profile) }
        case .authorizeKeychain:
            Task { await usage.authorizeKeychain(for: snapshot.profile) }
        case .replaceToken:
            openProviders(sheet: .credential(snapshot.profile))
        case .signInWithProviderApp, .installCLI:
            openProviders(sheet: .guidance(snapshot.profile))
        }
    }

    private func openProviders(sheet: Router.Sheet? = nil) {
        router.highlighted = snapshot.id
        router.openDashboard(.providers, sheet: sheet)
    }
}
