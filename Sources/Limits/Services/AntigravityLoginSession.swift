import AppKit
import Darwin
import Foundation

/// Drives Antigravity's own sign-in to completion inside an app-owned profile.
///
/// `agy` prints a Google authorization URL, then waits — either for the
/// callback to land server-side or for the user to paste the code that
/// `antigravity.google/oauth-callback` displays. Limits opens the URL, collects
/// that code, and hands it to the CLI. The credential is minted and stored by
/// Antigravity; Limits never sees a token, only the short-lived code the user
/// was already shown.
///
/// The session has to stay alive between those two steps, which is why this is
/// a long-lived object rather than the one-shot `AccountLoginService.login`
/// that Claude and Codex use.
@MainActor
final class AntigravityLoginSession: ObservableObject {
    enum Phase: Equatable {
        case idle
        case launching
        /// The browser is open and the CLI is waiting for the code.
        case awaitingCode(URL)
        case completing
        case finished
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle

    private var process: Process?
    private var watchdog: Task<Void, Never>?
    private var master: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var transcript = ""
    /// The CLI only prints the URL once, so it is retained for "open again".
    private(set) var authorizationURL: URL?

    private static let urlPrompt = "Please visit the URL to log in:"
    private static let codePrompt = "paste the authorization code"

    /// Starts `agy` against this profile and waits for its authorization URL.
    ///
    /// `--print` is used rather than the bare CLI because the bare command
    /// renders sign-in inside a full-screen TUI, where the URL never reaches
    /// stdout as plain text. The prompt itself never runs: the session is torn
    /// down as soon as authentication resolves.
    func start() {
        guard case .idle = phase else { return }
        phase = .launching

        guard let executable = AccountLoginService.executable(for: .antigravity) else {
            phase = .failed(AccountIssue.cliMissing(executable: "agy").message(provider: .antigravity))
            return
        }

        var slave: Int32 = -1
        var size = winsize(ws_row: 40, ws_col: 120, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&master, &slave, nil, nil, &size) == 0 else {
            phase = .failed("Could not allocate a terminal for the sign-in flow.")
            return
        }

        let process = Process()
        process.executableURL = executable
        // A prompt is required to reach the non-TUI code path; its content is
        // irrelevant because the process is killed once auth resolves.
        process.arguments = ["--print", "hello"]
        process.environment = AntigravityEnvironment.build(executable: executable)
        let terminal = FileHandle(fileDescriptor: slave, closeOnDealloc: false)
        process.standardInput = terminal
        process.standardOutput = terminal
        process.standardError = terminal

        do {
            try process.run()
        } catch {
            Darwin.close(master)
            Darwin.close(slave)
            master = -1
            phase = .failed("Could not start `agy`.")
            return
        }
        Darwin.close(slave)
        self.process = process

        let source = DispatchSource.makeReadSource(fileDescriptor: master, queue: .main)
        source.setEventHandler { [weak self] in self?.drain() }
        source.resume()
        readSource = source

        process.terminationHandler = { [weak self] finished in
            Task { @MainActor in self?.processEnded(status: finished.terminationStatus) }
        }

        startWatchdog()
    }

    /// Watches for the two outcomes that never print an authorization URL.
    ///
    /// `agy` only asks for a browser sign-in when it has nothing to work with.
    /// Against a profile that is merely *expired* it renews the credential
    /// silently and goes straight on to the prompt — so waiting for a URL that
    /// is never coming left the sheet stuck on "Starting Antigravity's
    /// sign-in…" forever. Whichever lands first wins: a usable credential
    /// means the session is done, and neither within the deadline is a
    /// failure worth reporting rather than spinning on.
    private func startWatchdog() {
        watchdog = Task { [weak self] in
            let deadline = Date().addingTimeInterval(45)
            while !Task.isCancelled, Date() < deadline {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard let self else { return }
                if case .awaitingCode = self.phase { return }
                if case .completing = self.phase { return }
                if await AntigravityTokenReader().load() != nil {
                    // Renewed without ever needing the browser. Stop the CLI
                    // before it starts running the prompt this used to launch.
                    self.markFinished()
                    return
                }
            }
            guard let self, case .launching = self.phase else { return }
            self.phase = .failed(
                "Antigravity did not start a sign-in. Try running `agy` once in a terminal, then check again."
            )
            self.cleanUp()
        }
    }

    /// Hands the code from the callback page to the waiting CLI.
    func submit(code: String) {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, case .awaitingCode = phase, master >= 0 else { return }
        phase = .completing
        var line = Array((trimmed + "\n").utf8)
        _ = Darwin.write(master, &line, line.count)
    }

    func openAuthorizationURL() {
        guard let authorizationURL else { return }
        NSWorkspace.shared.open(authorizationURL)
    }

    func cancel() {
        cleanUp()
        phase = .idle
    }

    // MARK: - Output

    private func drain() {
        guard master >= 0 else { return }
        var bytes = [UInt8](repeating: 0, count: 4_096)
        let count = Darwin.read(master, &bytes, bytes.count)
        guard count > 0 else { return }
        transcript += String(decoding: bytes[0..<count], as: UTF8.self)

        if authorizationURL == nil,
           let url = Self.authorizationURL(in: transcript),
           transcript.contains(Self.codePrompt) || transcript.contains(Self.urlPrompt) {
            authorizationURL = url
            phase = .awaitingCode(url)
            NSWorkspace.shared.open(url)
        }
    }

    /// Pulls the Google authorization URL out of the CLI's terminal output.
    /// Restricted to Google's own authorization endpoint so no other URL the
    /// CLI happens to print can send the user somewhere unexpected.
    static func authorizationURL(in output: String) -> URL? {
        for token in output.split(whereSeparator: { $0.isWhitespace }) {
            guard token.hasPrefix("https://accounts.google.com/o/oauth2/") else { continue }
            let cleaned = token.trimmingCharacters(in: CharacterSet(charactersIn: "\"'<>()[]"))
            guard let url = URL(string: cleaned),
                  url.host?.lowercased() == "accounts.google.com" else { continue }
            return url
        }
        return nil
    }

    private func processEnded(status: Int32) {
        // Success is judged by the credential Antigravity wrote, not the exit
        // code: the CLI is killed mid-prompt once the token lands, so a
        // non-zero status is the normal outcome of a successful sign-in.
        switch phase {
        case .completing, .awaitingCode:
            phase = .failed("Antigravity ended the sign-in before it completed. Try again.")
        default:
            break
        }
        cleanUp()
    }

    /// Called by the store once it has confirmed a credential exists.
    func markFinished() {
        phase = .finished
        cleanUp()
    }

    private func cleanUp() {
        watchdog?.cancel()
        watchdog = nil
        readSource?.cancel()
        readSource = nil
        if let process, process.isRunning {
            process.terminationHandler = nil
            process.terminate()
        }
        process = nil
        if master >= 0 {
            Darwin.close(master)
            master = -1
        }
    }
}

/// Environment for a spawned `agy`, pinned to an app-owned profile.
enum AntigravityEnvironment {
    /// Ambient Google credentials must not leak into an isolated profile — a
    /// stray API key silently changes which account the CLI authenticates as.
    private static let removedKeys = [
        "GEMINI_API_KEY", "GOOGLE_API_KEY", "GOOGLE_APPLICATION_CREDENTIALS",
        "GOOGLE_CLOUD_PROJECT", "GOOGLE_CLOUD_LOCATION", "GOOGLE_CLOUD_QUOTA_PROJECT",
        "GOOGLE_GENAI_USE_VERTEXAI", "GCLOUD_PROJECT", "CLOUDSDK_CORE_PROJECT",
        "GEMINI_HOME"
    ]

    /// HOME is deliberately left alone. `agy` stores its credential in the
    /// macOS Keychain, and the Security framework resolves the login keychain
    /// from HOME — pointing HOME at an app-owned folder makes the CLI find no
    /// keychain and raises a system "Keychain Not Found" dialog offering to
    /// reset the user's keychain. Isolation is not worth that, especially as
    /// the credential's Keychain identity is fixed and would collide anyway.
    static func build(
        executable: URL,
        base: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var environment = base
        removedKeys.forEach { environment.removeValue(forKey: $0) }
        environment["PATH"] = CLIResolver.launchPath(existing: environment["PATH"], executable: executable)
        // Limits opens the authorization URL itself, so the CLI must not race
        // it with a second browser window.
        environment["BROWSER"] = "/usr/bin/true"
        environment["TERM"] = "xterm-256color"
        return environment
    }


}
