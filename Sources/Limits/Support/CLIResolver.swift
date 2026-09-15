import Foundation

/// Finds provider CLIs from a LaunchServices-started GUI app. A GUI process
/// gets no shell initialization, so version-manager installs (nvm, asdf,
/// volta, pnpm) have to be found without the interactive PATH. This is the
/// single most common reason a menu-bar app "can't find" a CLI the user can
/// clearly run in their terminal.
enum CLIResolver {
    static func resolve(
        named executableName: String,
        appBundleName: String? = nil,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        let fileManager = FileManager.default
        let home = homeDirectory.path
        var candidates = [
            "\(home)/.local/bin/\(executableName)",
            "\(home)/.npm-global/bin/\(executableName)",
            "\(home)/.npm/bin/\(executableName)",
            "\(home)/.volta/bin/\(executableName)",
            "\(home)/.asdf/shims/\(executableName)",
            "\(home)/.local/share/pnpm/\(executableName)",
            "/opt/homebrew/bin/\(executableName)",
            "/usr/local/bin/\(executableName)"
        ]

        if let appBundleName {
            for applications in ["\(home)/Applications", "/Applications"] {
                candidates += [
                    "\(applications)/\(appBundleName).app/Contents/Resources/\(executableName)",
                    "\(applications)/\(appBundleName).app/Contents/MacOS/\(executableName)"
                ]
            }
        }
        if let path = environment["PATH"] {
            candidates += path.split(separator: ":").map { "\($0)/\(executableName)" }
        }

        // Newest nvm-managed Node first, matching what a fresh shell would pick.
        let nvmVersions = homeDirectory.appending(path: ".nvm/versions/node", directoryHint: .isDirectory)
        if let versions = try? fileManager.contentsOfDirectory(
            at: nvmVersions,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) {
            candidates += versions
                .sorted { $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedDescending }
                .map { $0.appending(path: "bin/\(executableName)", directoryHint: .notDirectory).path }
        }

        return candidates.first(where: fileManager.isExecutableFile(atPath:))
            .map(URL.init(fileURLWithPath:))
    }

    /// PATH handed to a spawned CLI. The resolved executable's own directory
    /// leads so a Node-based install can still find its `node` interpreter.
    static func launchPath(
        existing: String?,
        executable: URL,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> String {
        let home = homeDirectory.path
        let hints = [
            executable.deletingLastPathComponent().path,
            "\(home)/.local/bin", "\(home)/.npm-global/bin",
            "\(home)/.volta/bin", "\(home)/.asdf/shims",
            "\(home)/.local/share/pnpm",
            "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"
        ]
        let current = existing?.split(separator: ":").map(String.init) ?? []
        var seen = Set<String>()
        return (hints + current).filter { seen.insert($0).inserted }.joined(separator: ":")
    }
}
