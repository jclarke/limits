import SwiftUI

/// The scene graph is intentionally empty: the menu bar item and the dashboard
/// window are both owned by `AppDelegate`. `Settings` exists only because an
/// `App` needs at least one scene, and it is never presented.
struct LimitsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}
