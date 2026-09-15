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
    func start(configurationDirectory: URL) {
        guard case .idle = phase else { return }
        phase = .launching

        guard let executable = AccountLoginService.executable(for: .antigravity) else {
            phase = .failed(AccountIssue.cliMissing(executable: "agy").message(provider: .antigravity))
            return
        }
        do {
            try FileManager.default.createDirectory(
                at: configurationDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            phase = .failed("Could not create the account's profile folder.")
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
        process.environment = AntigravityEnvironment.build(
            configurationDirectory: configurationDirectory,
            executable: executable
        )
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

    static func build(
        configurationDirectory: URL,
        executable: URL,
        base: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var environment = base
        removedKeys.forEach { environment.removeValue(forKey: $0) }
        // `agy` keys its whole profile off HOME — config, state and, crucially,
        // its credential — so redirecting HOME is what isolates one account
        // from another.
        environment["HOME"] = configurationDirectory.path
        environment["PATH"] = CLIResolver.launchPath(existing: environment["PATH"], executable: executable)
        // Limits opens the authorization URL itself, so the CLI must not race
        // it with a second browser window.
        environment["BROWSER"] = "/usr/bin/true"
        environment["TERM"] = "xterm-256color"
        return environment
    }

    /// Where `agy` keeps the OAuth credential inside a profile.
    static func credentialURL(configurationDirectory: URL) -> URL {
        configurationDirectory.appending(path: ".gemini/oauth_creds.json")
    }
}
