import AppKit
import SwiftUI

/// Owns the menu bar item and the dashboard window.
///
/// Both are managed in AppKit rather than as SwiftUI scenes: the status item
/// needs an attributed title SwiftUI cannot express, and having the window
/// here lets the popover open it directly instead of routing through scene
/// environment plumbing that a popover is not part of.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let accounts = AccountsStore()
    lazy var usage = UsageStore(accounts: accounts)
    let router = Router()

    private var statusItemController: StatusItemController?
    private var dashboardWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        router.presentDashboard = { [weak self] tab in self?.showDashboard(tab) }

        let controller = StatusItemController(accounts: accounts, usage: usage, router: router)
        controller.install()
        statusItemController = controller

        usage.start()

        // Development aid: `Limits.app/Contents/MacOS/Limits --open-dashboard`
        // brings the window up without needing to click the menu bar item.
        // `--dark` forces the dark appearance so both themes can be checked
        // without changing the user's system setting.
        if CommandLine.arguments.contains("--dark") {
            NSApp.appearance = NSAppearance(named: .darkAqua)
        }
        if CommandLine.arguments.contains("--open-popover") {
            // Give the first refresh a moment so the popover has real content.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                self?.statusItemController?.showPopoverForInspection()
            }
        }
        if CommandLine.arguments.contains("--open-dashboard") {
            let tab: Router.Tab = CommandLine.arguments.contains("--providers") ? .providers : .limits
            showDashboard(tab)
        }
    }

    /// A menu bar app has no Dock icon to reopen from, so the window is only
    /// ever created on demand — and reused rather than duplicated.
    func showDashboard(_ tab: Router.Tab) {
        router.tab = tab
        statusItemController?.closePopover()

        // An LSUIElement app runs as `.accessory`, and an accessory app's
        // windows cannot reliably become key or come to the front. Switch to
        // `.regular` for as long as a window is open, then drop back so the
        // app stays out of the Dock and app switcher the rest of the time.
        NSApp.setActivationPolicy(.regular)

        if let window = dashboardWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hosting = NSHostingController(
            rootView: DashboardView()
                .environmentObject(accounts)
                .environmentObject(usage)
                .environmentObject(router)
        )
        let window = NSWindow(contentViewController: hosting)
        window.title = "Limits"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        // The unified titlebar is what makes a sidebar window read as native:
        // the toolbar merges into the title area and the sidebar's vibrancy
        // runs the full height behind it.
        window.toolbarStyle = .unified
        window.titlebarSeparatorStyle = .automatic
        window.setContentSize(NSSize(width: 980, height: 660))
        window.contentMinSize = NSSize(width: 820, height: 560)
        window.center()
        window.isReleasedWhenClosed = false
        // AppKit state restoration would re-apply a previously saved sidebar
        // selection after `showDashboard` set one, landing the user on the
        // wrong screen when they asked for a specific one.
        window.isRestorable = false
        window.delegate = self
        dashboardWindow = window

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

extension AppDelegate: NSWindowDelegate {
    /// Keep the window object around so reopening is instant and preserves
    /// scroll position, but let it go if the system tears it down.
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window == dashboardWindow else { return }
        router.highlighted = nil
        // Back to a menu-bar-only app now that nothing needs focus.
        NSApp.setActivationPolicy(.accessory)
    }
}
