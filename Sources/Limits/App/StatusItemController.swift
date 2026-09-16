import AppKit
import Combine
import SwiftUI

/// Owns the menu bar item and its popover.
///
/// The title is built as an `NSAttributedString` with the provider glyphs
/// inlined as text attachments rather than as a SwiftUI `MenuBarExtra` label:
/// AppKit then sizes the item to its content and renders each glyph in its own
/// color, neither of which a SwiftUI menu bar label does reliably.
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let accounts: AccountsStore
    private let usage: UsageStore
    private let router: Router

    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var cancellables: Set<AnyCancellable> = []
    private var appearanceObservation: NSKeyValueObservation?

    init(accounts: AccountsStore, usage: UsageStore, router: Router) {
        self.accounts = accounts
        self.usage = usage
        self.router = router
        super.init()
    }

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(togglePopover(_:))
        item.button?.setAccessibilityLabel("Limits")
        statusItem = item

        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        popover.contentViewController = NSHostingController(
            rootView: PopoverView()
                .environmentObject(accounts)
                .environmentObject(usage)
                .environmentObject(router)
        )

        // Rebuild the title whenever either store publishes a change.
        usage.objectWillChange
            .merge(with: accounts.objectWillChange)
            // Coalesce the burst of updates a refresh round produces.
            .debounce(for: .milliseconds(80), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.updateTitle() }
            .store(in: &cancellables)

        // The marks are baked at the menu bar's current foreground color, so
        // they have to be redrawn when the user switches theme — otherwise
        // they stay black on a newly dark menu bar.
        appearanceObservation = item.button?.observe(\.effectiveAppearance) { [weak self] _, _ in
            Task { @MainActor in self?.updateTitle() }
        }

        updateTitle()
    }

    // MARK: - Title

    /// Exactly the accounts the user ticked "Menu Bar" for, in stable
    /// provider order. No cap and no sorting by remaining: that checkbox *is*
    /// the control for what belongs here, and reordering by a value that
    /// drifts would make the menu bar reshuffle itself as quotas change.
    private var shown: [AccountSnapshot] { usage.menuBarSnapshots }

    private func updateTitle() {
        guard let button = statusItem?.button else { return }
        let snapshots = shown
        let title = NSMutableAttributedString()

        if snapshots.isEmpty {
            append(symbol: "gauge.with.dots.needle.67percent", color: .secondaryLabelColor, to: title)
        } else {
            let labels = Self.shortLabels(for: snapshots)
            for (index, snapshot) in snapshots.enumerated() {
                if index > 0 { title.append(gap(Self.entryGap)) }
                append(provider: snapshot.provider, to: title)
                if let label = labels[snapshot.id] {
                    // A hair of space so the label clears the mark's artwork
                    // without drifting far enough to read as its own token.
                    title.append(gap(Self.markLabelGap))
                    title.append(superscript(label))
                }
                title.append(gap(Self.figureGap))
                title.append(plain(
                    value(for: snapshot),
                    color: menuBarForeground,
                    weight: weight(for: snapshot)
                ))
            }
        }

        if !usage.attentionSnapshots.isEmpty {
            title.append(plain("  "))
            append(symbol: "exclamationmark.triangle.fill", color: .systemOrange, to: title)
        }

        button.attributedTitle = title
        button.setAccessibilityLabel(accessibilityText(snapshots))
    }

    /// Space between one account's figure and the next account's mark. Wide
    /// enough that the eye groups mark, label and figure as one unit.
    private static let entryGap: CGFloat = 7
    /// Space between a mark (or its label) and the figure it belongs to.
    private static let figureGap: CGFloat = 3
    /// Space between a mark and the label riding above it.
    private static let markLabelGap: CGFloat = 2

    /// A fixed-width space. Literal spaces are font-dependent and too coarse
    /// to tune a menu bar with.
    private func gap(_ width: CGFloat) -> NSAttributedString {
        NSAttributedString(string: " ", attributes: [
            .font: NSFont.systemFont(ofSize: 12),
            .kern: width - 3.5
        ])
    }

    /// Which accounts need a label.
    ///
    /// A label is only earned when a provider shows more than one account:
    /// with a single one the mark already identifies it, and the menu bar is
    /// too scarce to spend width on nothing. Two characters are always used —
    /// a single initial collides too easily, and raised at this size the pair
    /// costs barely more width than one.
    static func shortLabels(for snapshots: [AccountSnapshot]) -> [AccountID: String] {
        var labels: [AccountID: String] = [:]
        for (_, group) in Dictionary(grouping: snapshots, by: \.provider) where group.count > 1 {
            for account in group {
                labels[account.id] = account.profile
                    .resolvedMenuBarLabel(provider: account.provider)
            }
            // Two accounts at the same provider sharing a label defeats the
            // point of having one. Derived labels get pulled apart; a label
            // the user typed is left exactly as they typed it.
            let derived = group.filter { $0.profile.menuBarLabel?.isEmpty ?? true }
            for collision in Dictionary(grouping: derived, by: { labels[$0.id] ?? "" })
                .values where collision.count > 1 {
                let names = collision.map { $0.name }
                for (account, label) in zip(collision, AccountProfile.distinctLabels(for: names)) {
                    labels[account.id] = label
                }
            }
        }
        return labels
    }

    /// Raised and small, so the label reads as a mark on the icon rather than
    /// as another word competing with the percentage.
    private func superscript(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            // Slightly tighter than the figure it labels, raised to sit level
            // with the mark's cap height.
            .font: NSFont.systemFont(ofSize: 8.5, weight: .bold),
            .foregroundColor: menuBarForeground,
            .baselineOffset: 4.5,
            .kern: -0.2
        ])
    }

    /// An account with an auth problem shows a dash: the menu bar must never
    /// imply fresh numbers it does not have.
    private func value(for snapshot: AccountSnapshot) -> String {
        guard snapshot.issue == nil, let remaining = snapshot.quota?.lowestRemainingPercent else {
            return "—"
        }
        return Formatting.percent(remaining)
    }

    /// Urgency is carried by weight rather than color.
    ///
    /// A tinted figure has to survive whatever wallpaper is behind it, and at
    /// menu bar size red and amber turn muddy against mid-tone backgrounds —
    /// the state that most needs reading became the hardest to read. Weight
    /// holds up everywhere, because it changes the glyph rather than fighting
    /// the background for contrast.
    private func weight(for snapshot: AccountSnapshot) -> NSFont.Weight {
        guard snapshot.issue == nil, let remaining = snapshot.quota?.lowestRemainingPercent else {
            return .medium
        }
        return Formatting.isLow(remaining) ? .heavy : .medium
    }

    private func plain(
        _ text: String,
        color: NSColor = .labelColor,
        weight: NSFont.Weight = .medium
    ) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: weight),
            .foregroundColor: color
        ])
    }

    /// The provider's brand mark, drawn in the menu bar's own foreground color
    /// rather than the provider's brand tint.
    ///
    /// Brand colors look right on a card but not up here: the menu bar sits on
    /// whatever wallpaper the user has, so a blue mark on a blue desktop
    /// disappears and a yellow one washes out. Every other status item is
    /// monochrome for exactly this reason. The brand tints still carry the
    /// identity everywhere the app controls its own background.
    private func append(provider: Provider, to title: NSMutableAttributedString) {
        guard let image = ProviderLogo.tinted(
            provider,
            pointSize: 13,
            color: menuBarForeground
        ) else {
            append(symbol: provider.symbolName, color: menuBarForeground, to: title)
            return
        }
        title.append(attachment(image))
    }

    /// `labelColor` resolved against the *button's* appearance, not the app's.
    /// The menu bar has its own light/dark state — it can be dark while the
    /// app is light — and this is what makes the marks match the clock and
    /// every other status item beside them.
    private var menuBarForeground: NSColor {
        guard let appearance = statusItem?.button?.effectiveAppearance else {
            return .labelColor
        }
        var resolved = NSColor.labelColor
        appearance.performAsCurrentDrawingAppearance {
            // usingColorSpace snapshots the dynamic color into a concrete one;
            // assigning `.labelColor` directly would stay dynamic and resolve
            // again later against the wrong appearance.
            resolved = NSColor.labelColor.usingColorSpace(.sRGB) ?? .labelColor
        }
        return resolved
    }

    private func attachment(_ image: NSImage) -> NSAttributedString {
        let attachment = NSTextAttachment()
        attachment.image = image
        // Sit the mark on the text baseline rather than the line box.
        attachment.bounds = CGRect(x: 0, y: -2.5, width: image.size.width, height: image.size.height)
        return NSAttributedString(attachment: attachment)
    }

    private func append(symbol: String, color: NSColor, to title: NSMutableAttributedString) {
        guard let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) else { return }
        let configured = image.withSymbolConfiguration(
            .init(pointSize: 12, weight: .medium)
        ) ?? image
        // A non-template image keeps the provider's own color instead of being
        // flattened to the menu bar's tint.
        configured.isTemplate = false
        let tinted = NSImage(size: configured.size, flipped: false) { rect in
            configured.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        tinted.isTemplate = false
        title.append(attachment(tinted))
    }

    private func accessibilityText(_ snapshots: [AccountSnapshot]) -> String {
        guard !snapshots.isEmpty else { return "Limits: no accounts shown" }
        let parts = snapshots.map { "\($0.provider.displayName) \($0.name) \(value(for: $0))" }
        return "Limits: " + parts.joined(separator: ", ")
            + (usage.attentionSnapshots.isEmpty ? "" : ". Some accounts need attention.")
    }

    // MARK: - Popover

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(sender)
            return
        }
        // Refresh on open so a popover the user just summoned is never stale,
        // but reuse numbers fetched moments ago — repeatedly reopening the
        // popover must not multiply provider requests.
        Task { await usage.refreshIfStale() }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    func closePopover() { popover.performClose(nil) }

    /// Development aid: show the popover without a click, so its layout can be
    /// inspected the same way the window can.
    func showPopoverForInspection() {
        guard let button = statusItem?.button, !popover.isShown else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }
}
