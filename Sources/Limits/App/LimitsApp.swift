import SwiftUI

/// Every surface — menu bar item, dashboard, settings — is owned by
/// `AppDelegate`, because an `LSUIElement` app cannot rely on SwiftUI's scene
/// plumbing for window presentation. `Settings` here is an empty placeholder
/// only because `App` requires at least one scene; it is never shown.
struct LimitsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}
