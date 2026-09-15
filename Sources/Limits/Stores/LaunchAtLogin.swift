import Foundation
import ServiceManagement
import SwiftUI

/// Launch-at-login backed by `SMAppService`, the modern replacement for login
/// item helpers. The system owns the state, so it is read back rather than
/// mirrored into preferences where the two could disagree.
@MainActor
final class LaunchAtLogin: ObservableObject {
    @Published private(set) var isEnabled: Bool
    @Published var lastError: String?

    init() {
        isEnabled = SMAppService.mainApp.status == .enabled
    }

    /// Registration records the app's current path, so a bundle that is moved
    /// or rebuilt elsewhere silently stops launching. Surfacing the failure
    /// beats a switch that flips back with no explanation.
    func set(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        refresh()
    }

    func refresh() {
        isEnabled = SMAppService.mainApp.status == .enabled
    }

    /// `.requiresApproval` means the user disabled it in System Settings; the
    /// app cannot override that and should say so instead of retrying.
    var requiresApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }
}
