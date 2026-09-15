import Foundation

/// Asks the running Antigravity language server for quota over loopback.
/// Derived from TokenRemain (Apache-2.0); see NOTICE.
struct AntigravityLocalUsageProbe {
    struct ServerProcess: Equatable, Sendable {
        let pid: Int
        let csrfToken: String
    }

    enum ProbeError: Error, Equatable {
        case processUnavailable
        case portUnavailable
        case quotaUnavailable
    }

    private static let quotaPath = "/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary"
    private static let requestBody = Data(
        #"{"metadata":{"ideName":"antigravity","extensionName":"antigravity","ideVersion":"unknown","locale":"en"}}"#.utf8
    )

    func fetch(now: Date = .now) async throws -> ProviderQuota {
        let output = try await ProcessRunner.run("/bin/ps", arguments: ["-ax", "-o", "pid=,command="])
        let processes = Self.parseProcesses(String(decoding: output, as: UTF8.self))
        guard !processes.isEmpty else { throw ProbeError.processUnavailable }

        let delegate = LoopbackSessionDelegate()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 4
        configuration.timeoutIntervalForResource = 6
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        var foundPort = false
        for process in processes {
            let ports = await Self.listeningPorts(pid: process.pid)
            foundPort = foundPort || !ports.isEmpty
            // Antigravity normally exposes one self-signed HTTPS port and one
            // HTTP extension port. Prefer HTTPS, then try the HTTP peer.
            for scheme in ["https", "http"] {
                for port in ports {
                    guard let data = try? await Self.requestQuota(
                        scheme: scheme,
                        port: port,
                        csrfToken: process.csrfToken,
                        session: session
                    ), let quota = try? AntigravityUsageParser.parse(data, now: now) else { continue }
                    return quota
                }
            }
        }
        throw foundPort ? ProbeError.quotaUnavailable : ProbeError.portUnavailable
    }

    /// Matches only Antigravity's own language server, and only when it
    /// advertises the CSRF token its endpoint requires.
    static func parseProcesses(_ output: String) -> [ServerProcess] {
        output.split(whereSeparator: \.isNewline).compactMap { rawLine in
            let fields = rawLine.split(maxSplits: 1, omittingEmptySubsequences: true, whereSeparator: \.isWhitespace)
            guard fields.count == 2, let pid = Int(fields[0]) else { return nil }
            let command = String(fields[1])
            let lower = command.lowercased()
            let isLanguageServer = lower.contains("language_server") || lower.contains("language-server")
            let isAntigravity = lower.contains("/antigravity.app/")
                || lower.contains("--app_data_dir antigravity")
                || lower.contains("--app_data_dir=antigravity")
            guard isLanguageServer, isAntigravity,
                  let csrfToken = flag("csrf_token", in: command), !csrfToken.isEmpty else { return nil }
            return ServerProcess(pid: pid, csrfToken: csrfToken)
        }
    }

    static func parseListeningPorts(_ output: String) -> [Int] {
        guard let regex = try? NSRegularExpression(pattern: #":(\d+)\s+\(LISTEN\)"#) else { return [] }
        let range = NSRange(output.startIndex..<output.endIndex, in: output)
        let ports = regex.matches(in: output, range: range).compactMap { match -> Int? in
            guard let valueRange = Range(match.range(at: 1), in: output) else { return nil }
            return Int(output[valueRange])
        }
        return Array(Set(ports)).sorted()
    }

    private static func flag(_ name: String, in command: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: name)
        guard let regex = try? NSRegularExpression(pattern: "(?:^|\\s)--\(escaped)(?:=|\\s+)([^\\s]+)") else {
            return nil
        }
        let range = NSRange(command.startIndex..<command.endIndex, in: command)
        guard let match = regex.firstMatch(in: command, range: range),
              let valueRange = Range(match.range(at: 1), in: command) else { return nil }
        return String(command[valueRange])
    }

    private static func listeningPorts(pid: Int) async -> [Int] {
        let candidates = ["/usr/sbin/lsof", "/usr/bin/lsof"]
        guard let executable = candidates.first(where: FileManager.default.isExecutableFile(atPath:)),
              let output = try? await ProcessRunner.run(
                  executable,
                  arguments: ["-nP", "-iTCP", "-sTCP:LISTEN", "-a", "-p", String(pid)]
              ) else { return [] }
        return parseListeningPorts(String(decoding: output, as: UTF8.self))
    }

    private static func requestQuota(
        scheme: String,
        port: Int,
        csrfToken: String,
        session: URLSession
    ) async throws -> Data {
        guard let url = URL(string: "\(scheme)://127.0.0.1:\(port)\(quotaPath)") else {
            throw ProbeError.portUnavailable
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 4
        request.httpBody = requestBody
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        request.setValue(csrfToken, forHTTPHeaderField: "X-Codeium-Csrf-Token")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw ProbeError.quotaUnavailable
        }
        return data
    }
}

/// Antigravity's loopback HTTPS endpoint uses a self-signed certificate. Trust
/// is relaxed only for 127.0.0.1/localhost; every non-loopback challenge keeps
/// the platform's default validation.
private final class LoopbackSessionDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    private func disposition(
        for challenge: URLAuthenticationChallenge
    ) -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let space = challenge.protectionSpace
        let host = space.host.lowercased()
        guard space.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              host == "127.0.0.1" || host == "localhost",
              let trust = space.serverTrust else { return (.performDefaultHandling, nil) }
        return (.useCredential, URLCredential(trust: trust))
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        disposition(for: challenge)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        disposition(for: challenge)
    }
}
