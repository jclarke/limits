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
    let launchAtLogin = LaunchAtLogin()

    private var statusItemController: StatusItemController?
    private var dashboardWindow: NSWindow?
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        router.presentDashboard = { [weak self] tab in self?.showDashboard(tab) }
        router.presentSettings = { [weak self] in self?.showSettings() }

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
        if CommandLine.arguments.contains("--open-settings") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.showSettings()
            }
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

    /// Settings is an AppDelegate-owned window rather than SwiftUI's
    /// `Settings` scene. In an `LSUIElement` app that scene's
    /// `showSettingsWindow:` action has no target until the app has built a
    /// standard main menu, so invoking it does nothing at all.
    @objc func showSettings() {
        statusItemController?.closePopover()
        NSApp.setActivationPolicy(.regular)

        if let window = settingsWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hosting = NSHostingController(
            rootView: SettingsView()
                .environmentObject(launchAtLogin)
                .environmentObject(usage)
        )
        let window = NSWindow(contentViewController: hosting)
        window.title = "Limits Settings"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.center()
        window.delegate = self
        settingsWindow = window

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
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
        // The redesign's titlebar is a single translucent strip carrying the
        // segmented switcher, so the toolbar merges into it and the content
        // runs underneath.
        window.toolbarStyle = .unified
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .line
        window.isMovableByWindowBackground = true
        // A narrow single-column utility window, not a workspace: the width
        // is fixed to the design's column so cards never stretch into an
        // unreadable line length.
        window.setContentSize(NSSize(width: Theme.windowWidth, height: 660))
        window.contentMinSize = NSSize(width: Theme.windowWidth, height: 360)
        window.contentMaxSize = NSSize(width: Theme.windowWidth, height: .greatestFiniteMagnitude)
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
        guard let closing = notification.object as? NSWindow else { return }
        if closing == dashboardWindow { router.highlighted = nil }
        // Return to menu-bar-only once no window of ours still needs focus.
        let remaining = [dashboardWindow, settingsWindow]
            .compactMap { $0 }
            .filter { $0 != closing && $0.isVisible }
        if remaining.isEmpty {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
