import AppKit
import SwiftUI

/// The menu bar dropdown: every tracked account grouped by provider, with any
/// problem repairable inline.
struct PopoverView: View {
    @EnvironmentObject private var accounts: AccountsStore
    @EnvironmentObject private var usage: UsageStore
    @EnvironmentObject private var router: Router

    /// A `ScrollView` has no intrinsic height, so an `NSPopover` sizing to its
    /// hosting controller picks an arbitrary one and clips the content.
    /// Measuring the content lets the popover grow to fit and only start
    /// scrolling once it would outgrow the screen.
    @State private var contentHeight: CGFloat = 0
    private static let maximumScrollHeight: CGFloat = 460

    private var groups: [(provider: Provider, accounts: [AccountSnapshot])] { usage.groupedSnapshots }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if groups.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(groups, id: \.provider) { group in
                            ProviderGroupCard(provider: group.provider, accounts: group.accounts)
                        }
                    }
                    .padding(10)
                    .background(
                        GeometryReader { geometry in
                            Color.clear
                                .onAppear { contentHeight = geometry.size.height }
                                .onChange(of: geometry.size.height) { _, height in
                                    contentHeight = height
                                }
                        }
                    )
                }
                .frame(height: min(max(contentHeight, 80), Self.maximumScrollHeight))
            }
            Divider()
            footer
        }
        .frame(width: Metrics.popoverWidth)
    }

    private var header: some View {
        HStack(spacing: 9) {
            Image(systemName: "gauge.with.dots.needle.67percent")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 1) {
                Text("Limits").font(.headline)
                Text(subtitle).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                Task { await usage.refreshAll() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .opacity(usage.isRefreshingAll ? 0.4 : 1)
            }
            .buttonStyle(.borderless)
            .disabled(usage.isRefreshingAll)
            .help("Refresh all accounts")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var subtitle: String {
        if usage.isRefreshingAll { return "Refreshing…" }
        let attention = usage.attentionSnapshots.count
        if attention > 0 {
            return "\(attention) account\(attention == 1 ? "" : "s") need attention"
        }
        return Formatting.relative(usage.states.values.compactMap(\.lastRefreshedAt).max())
            ?? "Not refreshed yet"
    }

    private var emptyState: some View {
        VStack(spacing: 9) {
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
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
        .padding(.horizontal, 22)
    }

    private var footer: some View {
        HStack(spacing: 4) {
            FooterButton(title: "Limits", symbol: "gauge.with.dots.needle.67percent") {
                open(tab: .limits)
            }
            FooterButton(title: "Providers", symbol: "person.2.badge.key") {
                open(tab: .providers)
            }
            Spacer()
            FooterButton(title: "Quit", symbol: "power") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
    }

    private func open(tab: Router.Tab, sheet: Router.Sheet? = nil) {
        router.openDashboard(tab, sheet: sheet)
    }
}

/// Footer control with the hover highlight macOS menus use.
private struct FooterButton: View {
    let title: String
    let symbol: String
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.caption)
                Text(title).font(.callout)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(isHovering ? Color.primary.opacity(0.09) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

/// One provider's card in the popover, listing each of its accounts.
private struct ProviderGroupCard: View {
    let provider: Provider
    let accounts: [AccountSnapshot]

    private var lowestRemaining: Double? {
        accounts.compactMap { $0.quota?.lowestRemainingPercent }.min()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                ProviderMark(provider: provider, size: 13)
                Text(provider.displayName).font(.subheadline).fontWeight(.semibold)
                Spacer()
                if accounts.count > 1, let lowestRemaining {
                    // Neutral unless it needs attention, so a warning color in
                    // this spot always means something.
                    Text("lowest \(Formatting.percent(lowestRemaining))")
                        .font(.caption2)
                        .foregroundStyle(
                            Formatting.isLow(lowestRemaining)
                                ? Formatting.tint(forRemaining: lowestRemaining)
                                : Color.secondary
                        )
                }
            }

            ForEach(accounts) { snapshot in
                AccountBlock(snapshot: snapshot,
                             showsName: accounts.count > 1 || !snapshot.profile.isSystem)
                if snapshot.id != accounts.last?.id {
                    Divider().opacity(0.4)
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.primary.opacity(0.05))
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
                    if let plan = snapshot.quota?.planName { Chip(text: plan) }
                    Spacer()
                    if snapshot.state.isRefreshing {
                        ProgressView().controlSize(.small).scaleEffect(0.55)
                    }
                }
            }

            if let quota = snapshot.quota {
                ForEach(quota.windows) { window in
                    QuotaWindowRow(window: window, provider: snapshot.provider, isCompact: true)
                }
            }

            if snapshot.issue != nil {
                IssueRow(snapshot: snapshot, isCompact: true) { apply($0) }
            } else if snapshot.quota == nil {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small).scaleEffect(0.55)
                    Text("Loading…").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Remedies needing no input run here. Anything requiring typing or
    /// explanation hands off to the Providers screen, pre-targeted at this
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
