import Foundation

/// Runs a short-lived tool and returns stdout. A timeout always kills the
/// child: a wedged credential probe must never stall a refresh round.
enum ProcessRunner {
    enum RunError: Error {
        case launchFailed
        case timedOut
        case exited(status: Int32, output: String)
    }

    static func run(
        _ launchPath: String,
        arguments: [String],
        environment: [String: String]? = nil,
        timeout: TimeInterval = 10
    ) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                let output = Pipe()
                process.executableURL = URL(fileURLWithPath: launchPath)
                process.arguments = arguments
                if let environment { process.environment = environment }
                process.standardOutput = output
                process.standardError = FileHandle.nullDevice

                // Read concurrently with waiting: a child that fills the pipe
                // buffer blocks forever if we wait for exit first.
                var collected = Data()
                let lock = NSLock()
                output.fileHandleForReading.readabilityHandler = { handle in
                    let chunk = handle.availableData
                    guard !chunk.isEmpty else { return }
                    lock.lock(); collected.append(chunk); lock.unlock()
                }

                do {
                    try process.run()
                } catch {
                    output.fileHandleForReading.readabilityHandler = nil
                    continuation.resume(throwing: RunError.launchFailed)
                    return
                }

                let deadline = Date().addingTimeInterval(timeout)
                while process.isRunning, Date() < deadline {
                    usleep(20_000)
                }
                if process.isRunning {
                    process.terminate()
                    output.fileHandleForReading.readabilityHandler = nil
                    continuation.resume(throwing: RunError.timedOut)
                    return
                }
                process.waitUntilExit()
                // Drain whatever landed between the last handler call and exit.
                let remainder = output.fileHandleForReading.readDataToEndOfFile()
                output.fileHandleForReading.readabilityHandler = nil
                lock.lock()
                collected.append(remainder)
                let result = collected
                lock.unlock()

                guard process.terminationStatus == 0 else {
                    continuation.resume(throwing: RunError.exited(
                        status: process.terminationStatus,
                        output: String(data: result, encoding: .utf8) ?? ""
                    ))
                    return
                }
                continuation.resume(returning: result)
            }
        }
    }
}
