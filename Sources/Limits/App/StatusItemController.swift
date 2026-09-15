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
            for (index, snapshot) in snapshots.enumerated() {
                if index > 0 { title.append(plain("  ")) }
                append(provider: snapshot.provider, to: title)
                title.append(plain(" " + value(for: snapshot), color: color(for: snapshot)))
            }
        }

        if !usage.attentionSnapshots.isEmpty {
            title.append(plain("  "))
            append(symbol: "exclamationmark.triangle.fill", color: .systemOrange, to: title)
        }

        button.attributedTitle = title
        button.setAccessibilityLabel(accessibilityText(snapshots))
    }

    /// An account with an auth problem shows a dash: the menu bar must never
    /// imply fresh numbers it does not have.
    private func value(for snapshot: AccountSnapshot) -> String {
        guard snapshot.issue == nil, let remaining = snapshot.quota?.lowestRemainingPercent else {
            return "—"
        }
        return Formatting.percent(remaining)
    }

    private func color(for snapshot: AccountSnapshot) -> NSColor {
        guard snapshot.issue == nil, let remaining = snapshot.quota?.lowestRemainingPercent else {
            return .secondaryLabelColor
        }
        // Only call out the states that need action; a healthy figure stays
        // in the menu bar's own color so it reads as ordinary status.
        switch remaining {
        case ..<10: return .systemRed
        case ..<25: return .systemOrange
        default: return .labelColor
        }
    }

    private func plain(_ text: String, color: NSColor = .labelColor) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: color
        ])
    }

    /// The provider's real brand mark, tinted to its color.
    private func append(provider: Provider, to title: NSMutableAttributedString) {
        guard let image = ProviderLogo.tinted(provider, pointSize: 13, color: provider.nsTint) else {
            append(symbol: provider.symbolName, color: provider.nsTint, to: title)
            return
        }
        title.append(attachment(image))
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
        let parts = snapshots.map { "\($0.provider.displayName) \(value(for: $0))" }
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
        // Refresh on open so a popover the user just summoned is never stale.
        Task { await usage.refreshAll() }
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
