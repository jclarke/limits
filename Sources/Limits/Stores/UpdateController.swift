import Foundation
import Sparkle

/// Sparkle's updater, exposed so the UI can show its state and trigger a check.
///
/// Updates are served from the project's own GitHub releases and verified
/// against the EdDSA public key in Info.plist, so an update that was not
/// signed by the release machine's private key is refused before it runs.
@MainActor
final class UpdateController: NSObject, ObservableObject {
    /// Mirrors the updater so a menu item can disable itself while a check is
    /// already in flight.
    @Published private(set) var canCheckForUpdates = false

    @Published var automaticallyChecks: Bool {
        didSet {
            guard updater.automaticallyChecksForUpdates != automaticallyChecks else { return }
            updater.automaticallyChecksForUpdates = automaticallyChecks
        }
    }

    private let controller: SPUStandardUpdaterController
    private var updater: SPUUpdater { controller.updater }
    private var observation: NSKeyValueObservation?

    override init() {
        // `startingUpdater: true` begins the scheduled check cycle at launch.
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        automaticallyChecks = controller.updater.automaticallyChecksForUpdates
        super.init()
        observation = controller.observe(\.updater.canCheckForUpdates, options: [.initial, .new]) {
            [weak self] _, change in
            guard let value = change.newValue else { return }
            Task { @MainActor in self?.canCheckForUpdates = value }
        }
    }

    /// The version the user is running, for display next to the check button.
    var currentVersion: String {
        let bundle = Bundle.main
        let short = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        switch (short, build) {
        case let (version?, build?): return "\(version) (\(build))"
        case let (version?, nil): return version
        default: return "unknown"
        }
    }

    func checkForUpdates() {
        updater.checkForUpdates()
    }
}
