import Darwin
import Foundation

/// Runs a provider's own OAuth login inside an app-owned configuration home.
/// The resulting tokens stay owned by that provider's CLI; Limits only reads
/// them. This is what makes a second (or fifth) account possible without ever
/// touching the user's real `~/.claude` or `~/.codex` session.
/// Derived from TokenRemain (Apache-2.0); see NOTICE.
struct AccountLoginService: Sendable {
    /// Environment for a spawned provider CLI, pinned to an isolated home.
    ///
    /// Routing overrides are stripped deliberately: if the user's shell points
    /// Claude or Codex at a proxy or a raw API key, inheriting that would log
    /// the new profile into something other than the subscription account the
    /// user is trying to add.
    enum Environment {
        private static let claudeRoutingOverrides = [
            "ANTHROPIC_BASE_URL", "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN",
            "ANTHROPIC_BEDROCK_BASE_URL", "ANTHROPIC_VERTEX_BASE_URL",
            "ANTHROPIC_FOUNDRY_BASE_URL", "CLAUDE_CODE_USE_BEDROCK",
            "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY"
        ]
        private static let codexRoutingOverrides = ["OPENAI_BASE_URL", "OPENAI_API_BASE", "OPENAI_API_KEY"]

        static func build(
            provider: Provider,
            configurationDirectory: URL,
            base: [String: String] = ProcessInfo.processInfo.environment
        ) -> [String: String] {
            var environment = base
            switch provider {
            case .claude:
                claudeRoutingOverrides.forEach { environment.removeValue(forKey: $0) }
                environment["CLAUDE_CONFIG_DIR"] = configurationDirectory.path
            case .codex:
                codexRoutingOverrides.forEach { environment.removeValue(forKey: $0) }
                environment["CODEX_HOME"] = configurationDirectory.path
            case .antigravity, .cursor, .grok:
                // Antigravity builds its environment in AntigravityEnvironment,
                // which also has to strip ambient Google credentials.
                break
            }
            return environment
        }
    }

    /// Signs the given profile in, then verifies a session actually exists.
    /// Verification matters: both CLIs can exit 0 after the user closes the
    /// browser tab without completing consent.
    func login(provider: Provider, configurationDirectory: URL) async throws {
        try FileManager.default.createDirectory(
            at: configurationDirectory,
            withIntermediateDirectories: true,
            // Owner-only: these directories hold live OAuth material.
            attributes: [.posixPermissions: 0o700]
        )
        switch provider {
        case .claude:
            try await loginClaude(configurationDirectory: configurationDirectory)
        case .codex:
            try await loginCodex(configurationDirectory: configurationDirectory)
        case .antigravity:
            // Antigravity's sign-in pauses for a pasted code, so it is driven
            // by AntigravityLoginSession rather than run to completion here.
            throw AccountIssue.other("Antigravity sign-in runs on its own screen.")
        case .cursor, .grok:
            throw AccountIssue.other("\(provider.displayName) has no CLI sign-in. Add this account with a token instead.")
        }
    }

    // MARK: - Claude

    /// `claude auth login` is an Ink TUI. Pointing stdout at `/dev/null` makes
    /// it believe the first browser open failed, so it launches the OAuth flow
    /// a *second* time. Give it a real PTY, drain the paint so it never blocks
    /// on a full buffer, and let the official callback finish.
    private func loginClaude(configurationDirectory: URL) async throws {
        guard let executable = Self.executable(for: .claude) else {
            throw AccountIssue.cliMissing(executable: "claude")
        }
        try await runInPTY(
            executable: executable,
            arguments: ["auth", "login", "--claudeai"],
            environment: Self.environment(for: .claude, executable: executable, directory: configurationDirectory)
        )
        guard try await claudeIsLoggedIn(configurationDirectory: configurationDirectory) else {
            throw AccountIssue.other("Claude finished without creating a signed-in profile.")
        }
    }

    private func claudeIsLoggedIn(configurationDirectory: URL) async throws -> Bool {
        guard let executable = Self.executable(for: .claude) else {
            throw AccountIssue.cliMissing(executable: "claude")
        }
        let data = try await ProcessRunner.run(
            executable.path,
            arguments: ["auth", "status", "--json"],
            environment: Self.environment(for: .claude, executable: executable, directory: configurationDirectory),
            timeout: 30
        )
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return object["loggedIn"] as? Bool == true
    }

    // MARK: - Codex

    private func loginCodex(configurationDirectory: URL) async throws {
        guard let executable = Self.executable(for: .codex) else {
            throw AccountIssue.cliMissing(executable: "codex")
        }
        let environment = Self.environment(for: .codex, executable: executable, directory: configurationDirectory)
        // The browser round-trip is user-paced and may involve signing into
        // Google or an SSO provider first, so allow plenty of time.
        _ = try await ProcessRunner.run(
            executable.path,
            arguments: ["login"],
            environment: environment,
            timeout: 900
        )
        // Verify by exit status, not by output. `codex login status` prints
        // to stderr, and its logged-out text ("Not logged in") contains the
        // logged-in text as a substring — so matching on the message is wrong
        // in both directions. It exits 0 only when a session exists.
        do {
            _ = try await ProcessRunner.run(
                executable.path,
                arguments: ["login", "status"],
                environment: environment,
                timeout: 30
            )
        } catch {
            throw AccountIssue.other("Codex finished without creating a signed-in profile.")
        }
    }

    // MARK: - Shared-home sign-in

    /// Runs a provider CLI's own sign-in against the credential store it
    /// already uses, for providers that need no app-owned profile.
    ///
    /// Grok keys `auth.json` per account, so this *adds* an account. Cursor
    /// stores one credential under a fixed Keychain identity, so it replaces.
    /// Both complete in the browser without a code to paste back.
    func signInSharedHome(provider: Provider) async throws {
        guard let name = provider.cliExecutableName,
              let executable = Self.executable(for: provider) else {
            throw AccountIssue.cliMissing(executable: provider.cliExecutableName ?? "")
        }
        let arguments: [String]
        switch provider {
        case .grok: arguments = ["login", "--oauth"]
        case .cursor: arguments = ["login"]
        default:
            throw AccountIssue.other("\(provider.displayName) has no shared-home sign-in.")
        }

        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = CLIResolver.launchPath(existing: environment["PATH"], executable: executable)
        // These CLIs open the browser themselves and wait on a loopback
        // callback, so the default browser must stay enabled.
        environment.removeValue(forKey: "NO_OPEN_BROWSER")

        // `grok login` clears its credential file before the new session
        // lands, so an interrupted sign-in — Limits quitting, the user closing
        // the browser — leaves them signed out of accounts they already had.
        // Keep a copy and put it back if the sign-in does not complete.
        let rescue = CredentialRescue(provider: provider)
        rescue.capture()

        do {
            // The browser round-trip is user-paced and may include an SSO hop.
            try await runInPTY(
                executable: executable,
                arguments: arguments,
                environment: environment,
                timeout: 900
            )
        } catch {
            rescue.restoreIfLost()
            throw error
        }

        guard try await sharedHomeIsSignedIn(provider: provider) else {
            rescue.restoreIfLost()
            throw AccountIssue.other("\(name) finished without creating a signed-in account.")
        }
        rescue.discard()
    }

    /// Protects a provider's existing credential file across a sign-in that
    /// rewrites it in place.
    private struct CredentialRescue {
        let provider: Provider
        private let backup: URL

        init(provider: Provider) {
            self.provider = provider
            backup = FileManager.default.temporaryDirectory
                .appending(path: "limits-\(provider.rawValue)-auth-\(UUID().uuidString).json")
        }

        private var source: URL? {
            switch provider {
            case .grok: GrokAuthReader().authFileURL
            // Cursor and the rest keep credentials in the Keychain, which a
            // sign-in updates atomically — there is nothing to lose here.
            default: nil
            }
        }

        func capture() {
            guard let source, FileManager.default.fileExists(atPath: source.path) else { return }
            try? FileManager.default.copyItem(at: source, to: backup)
        }

        /// Only restores when the provider genuinely has nothing usable left,
        /// so a successful sign-in is never rolled back over.
        func restoreIfLost() {
            defer { discard() }
            guard let source, FileManager.default.fileExists(atPath: backup.path) else { return }
            guard GrokAuthReader(authFileURL: source).loadAll().isEmpty else { return }
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.copyItem(at: backup, to: source)
        }

        func discard() {
            try? FileManager.default.removeItem(at: backup)
        }
    }

    private func sharedHomeIsSignedIn(provider: Provider) async throws -> Bool {
        switch provider {
        case .grok:
            return !GrokAuthReader().loadAll().isEmpty
        case .cursor:
            guard let executable = Self.executable(for: .cursor) else { return false }
            // `status` exits non-zero when signed out.
            return (try? await ProcessRunner.run(
                executable.path,
                arguments: ["status"],
                timeout: 30
            )) != nil
        default:
            return false
        }
    }

    // MARK: - Shared

    static func executable(for provider: Provider) -> URL? {
        guard let name = provider.cliExecutableName else { return nil }
        return CLIResolver.resolve(named: name, appBundleName: provider.cliAppBundleName)
    }

    private static func environment(
        for provider: Provider,
        executable: URL,
        directory: URL
    ) -> [String: String] {
        var environment = Environment.build(provider: provider, configurationDirectory: directory)
        // A GUI app inherits no shell PATH, so a Node-based CLI would fail to
        // find its own interpreter without this.
        environment["PATH"] = CLIResolver.launchPath(existing: environment["PATH"], executable: executable)
        return environment
    }

    /// Runs a CLI attached to a pseudo-terminal, discarding its paint. Used
    /// for TUI logins that misbehave when their output is not a terminal.
    private func runInPTY(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval? = nil
    ) async throws {
        try await Task.detached(priority: .userInitiated) {
            var master: Int32 = -1
            var slave: Int32 = -1
            var windowSize = winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0)
            guard openpty(&master, &slave, nil, nil, &windowSize) == 0 else {
                throw AccountIssue.other("Could not allocate a terminal for the sign-in flow.")
            }
            defer { Darwin.close(master) }

            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            var environment = environment
            environment["TERM"] = "xterm-256color"
            process.environment = environment

            let terminal = FileHandle(fileDescriptor: slave, closeOnDealloc: false)
            process.standardInput = terminal
            process.standardOutput = terminal
            process.standardError = terminal
            try process.run()
            // The parent must drop its copy or the child never sees EOF.
            Darwin.close(slave)

            // Non-blocking drain: a full PTY buffer would otherwise wedge the
            // child mid-login while it waits to paint.
            let flags = fcntl(master, F_GETFL)
            _ = fcntl(master, F_SETFL, flags | O_NONBLOCK)
            var bytes = [UInt8](repeating: 0, count: 8_192)
            let deadline = timeout.map { Date().addingTimeInterval($0) }
            while process.isRunning {
                while Darwin.read(master, &bytes, bytes.count) > 0 {}
                if let deadline, Date() > deadline {
                    process.terminate()
                    break
                }
                usleep(50_000)
            }
            process.waitUntilExit()
            while Darwin.read(master, &bytes, bytes.count) > 0 {}

            guard process.terminationStatus == 0 else {
                throw AccountIssue.other("Sign-in did not complete (exit code \(process.terminationStatus)).")
            }
        }.value
    }
}
