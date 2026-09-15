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
    /// Measuring lets the popover grow to fit and scroll only past the cap.
    @State private var contentHeight: CGFloat = 0
    private static let maximumScrollHeight: CGFloat = 460

    private var groups: [(provider: Provider, accounts: [AccountSnapshot])] { usage.groupedSnapshots }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Theme.divider).frame(height: 0.5)
            if groups.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(spacing: 7) {
                        ForEach(groups, id: \.provider) { group in
                            ProviderGroupCard(provider: group.provider, accounts: group.accounts)
                        }
                    }
                    .padding(9)
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
            Rectangle().fill(Theme.divider).frame(height: 0.5)
            footer
        }
        .frame(width: Theme.popoverWidth)
    }

    private var header: some View {
        HStack(spacing: 9) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Limits")
                    .font(.system(size: 12.5, weight: .semibold))
                    .kerning(-0.15)
                Text(subtitle)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                Task { await usage.refreshAll() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .medium))
                    .opacity(usage.isRefreshingAll ? 0.4 : 1)
            }
            .buttonStyle(.borderless)
            .disabled(usage.isRefreshingAll)
            .help("Refresh all accounts")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    /// Leads with what needs action, and falls back to freshness.
    private var subtitle: String {
        if usage.isRefreshingAll { return "Refreshing…" }
        let attention = usage.attentionSnapshots.count
        if attention > 0 {
            return "\(attention) account\(attention == 1 ? "" : "s") need attention"
        }
        let low = usage.groupedSnapshots
            .flatMap(\.accounts)
            .filter { ($0.quota?.lowestRemainingPercent).map(Formatting.isLow) == true }
            .count
        let freshness = Formatting.relative(usage.states.values.compactMap(\.lastRefreshedAt).max())
            ?? "not refreshed yet"
        if low > 0 {
            return "\(low) account\(low == 1 ? "" : "s") low · \(freshness.lowercased())"
        }
        return freshness
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
            Button("Add Account") { router.openDashboard(.providers, sheet: .addAccount(nil)) }
                .controlSize(.small)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
        .padding(.horizontal, 22)
    }

    private var footer: some View {
        HStack(spacing: 2) {
            FooterButton(title: "Limits") { router.openDashboard(.limits) }
            FooterButton(title: "Providers") { router.openDashboard(.providers) }
            Spacer()
            FooterButton(title: "Settings") { router.presentSettings?() }
            FooterButton(title: "Quit") { NSApplication.shared.terminate(nil) }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
    }
}

/// Footer control with the hover highlight macOS menus use.
private struct FooterButton: View {
    let title: String
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11.5))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isHovering ? Color.primary.opacity(0.09) : .clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

/// One provider's card in the popover.
private struct ProviderGroupCard: View {
    let provider: Provider
    let accounts: [AccountSnapshot]

    private var lowestRemaining: Double? {
        accounts.compactMap { $0.quota?.lowestRemainingPercent }.min()
    }

    private var isLow: Bool { lowestRemaining.map(Formatting.isLow) ?? false }
    private var needsAttention: Bool { accounts.contains { $0.needsAttention } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                ProviderMark(provider: provider, size: 13)
                Text(provider.displayName)
                    .font(.system(size: 11.5, weight: .semibold))
                    .kerning(-0.1)
                Spacer()
                summary
            }
            ForEach(accounts) { snapshot in
                AccountBlock(
                    snapshot: snapshot,
                    showsName: accounts.count > 1 || !snapshot.profile.isSystem
                )
                if snapshot.id != accounts.last?.id {
                    Rectangle().fill(Theme.divider).frame(height: 0.5)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: Theme.popoverCardRadius, style: .continuous)
                .fill(Theme.cardFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.popoverCardRadius, style: .continuous)
                // A low provider is outlined rather than filled: the card stays
                // readable while still catching the eye first.
                .strokeBorder(isLow ? Theme.low.opacity(0.28) : Theme.cardStroke, lineWidth: 0.5)
        )
    }

    @ViewBuilder
    private var summary: some View {
        if needsAttention {
            Text("needs attention")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Theme.warning)
        } else if let lowestRemaining {
            Text(accounts.count > 1
                 ? "lowest \(Formatting.percent(lowestRemaining))"
                 : (isLow ? "\(Formatting.percent(lowestRemaining)) left" : "\(Formatting.percent(lowestRemaining))"))
                .font(.system(size: 10, weight: isLow ? .medium : .regular))
                .foregroundStyle(isLow ? Theme.low : .secondary)
        }
    }
}

/// One account inside a provider card.
private struct AccountBlock: View {
    @EnvironmentObject private var usage: UsageStore
    @EnvironmentObject private var router: Router

    let snapshot: AccountSnapshot
    let showsName: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if showsName {
                HStack(spacing: 5) {
                    Text(snapshot.name)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                    if let plan = snapshot.quota?.planName { Chip(text: plan) }
                    Spacer()
                    if snapshot.state.isRefreshing {
                        ProgressView().controlSize(.small).scaleEffect(0.5)
                    }
                }
            }

            if let quota = snapshot.quota {
                ForEach(quota.windows) { window in
                    QuotaWindowRow(window: window, provider: snapshot.provider, diameter: 22)
                }
            }

            if snapshot.issue != nil {
                IssueRow(snapshot: snapshot) { apply($0) }
            } else if snapshot.quota == nil {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small).scaleEffect(0.5)
                    Text("Loading…").font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Remedies needing no input run here. Anything requiring typing or
    /// explanation hands off to the Providers screen, pre-targeted at this
    /// account so the user never has to hunt for it.
    private func apply(_ remedy: AccountIssue.Remedy) {
        switch remedy {
        case .signInAgain: startSignIn(snapshot.profile)
        case .retry: Task { await usage.refresh(snapshot.profile) }
        case .authorizeKeychain: Task { await usage.authorizeKeychain(for: snapshot.profile) }
        case .replaceToken: openProviders(sheet: .credential(snapshot.profile))
        case .signInWithProviderApp, .installCLI: openProviders(sheet: .guidance(snapshot.profile))
        }
    }

    /// Antigravity needs a code pasted back, which the popover is too small
    /// for — hand it to the Providers screen instead.
    private func startSignIn(_ profile: AccountProfile) {
        if profile.provider == .antigravity {
            openProviders(sheet: .antigravitySignIn(profile))
        } else {
            Task { await usage.signIn(profile) }
        }
    }

    private func openProviders(sheet: Router.Sheet? = nil) {
        router.highlighted = snapshot.id
        router.openDashboard(.providers, sheet: sheet)
    }
}
