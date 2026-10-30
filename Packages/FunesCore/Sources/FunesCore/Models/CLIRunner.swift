import Foundation
import os
import Synchronization

/// One run of a command-line tool (ADR-0024): an argument array (never a shell string), the
/// environment, the directory it runs in, what goes to its standard input, and a time limit.
public struct CLIInvocation: Sendable, Hashable {
    public var executable: String
    public var arguments: [String]
    public var environment: [String: String]
    public var directory: URL
    public var input: String
    public var timeout: Duration

    public init(executable: String, arguments: [String], environment: [String: String], directory: URL, input: String = "",
                timeout: Duration) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.directory = directory
        self.input = input
        self.timeout = timeout
    }
}

/// What a run printed. Standard error is kept only as a short tail, for error codes.
public struct CLIOutput: Sendable, Hashable {
    public var exitCode: Int32
    public var lines: [String]
    public var errorTail: String
    public var timedOut: Bool
    /// The line handler stopped it.
    public var stopped: Bool

    public init(exitCode: Int32, lines: [String], errorTail: String = "", timedOut: Bool = false, stopped: Bool = false) {
        self.exitCode = exitCode
        self.lines = lines
        self.errorTail = errorTail
        self.timedOut = timedOut
        self.stopped = stopped
    }
}

/// Runs a command-line tool. `line` sees each line of standard output as it arrives; returning
/// false stops the process at once (a tool event in a subscription CLI's stream).
public protocol CLIProcessRunning: Sendable {
    func run(_ invocation: CLIInvocation, line: @escaping @Sendable (String) -> Bool) async throws -> CLIOutput
}

/// Foundation's `Process`, with the output read as it comes, the input written and closed, a kill
/// on timeout, on a stop and on cancellation.
public struct SystemCLIProcess: CLIProcessRunning {
    public init() {}

    /// The run's mutable state, behind its lock.
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        let process: Process
        let line: @Sendable (String) -> Bool
        var buffer = Data()
        var lines: [String] = []
        var errors = Data()
        var stopped = false
        var timedOut = false
        var resumed = false
        /// The task was cancelled: a process not started yet never starts.
        var cancelled = false

        init(process: Process, line: @escaping @Sendable (String) -> Bool) {
            self.process = process
            self.line = line
        }

        /// Splits output into lines and hands each to the handler; a false answer kills the process.
        func take(_ data: Data) {
            lock.lock()
            defer { lock.unlock() }
            guard !stopped else { return }
            buffer.append(data)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let text = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)
                buffer.removeSubrange(buffer.startIndex...newline)
                lines.append(text)
                if !line(text) {
                    stopped = true
                    process.terminate()
                    return
                }
            }
        }
    }

    public func run(_ invocation: CLIInvocation, line: @escaping @Sendable (String) -> Bool) async throws -> CLIOutput {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: invocation.executable)
        process.arguments = invocation.arguments
        process.environment = invocation.environment
        process.currentDirectoryURL = invocation.directory
        let out = Pipe(), err = Pipe(), input = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = input
        let state = State(process: process, line: line)
        out.fileHandleForReading.readabilityHandler = { handle in state.take(handle.availableData) }
        err.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            state.lock.lock()
            state.errors.append(data)
            if state.errors.count > 8_192 { state.errors = state.errors.suffix(4_096) }
            state.lock.unlock()
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CLIOutput, any Error>) in
                process.terminationHandler = { p in
                    out.fileHandleForReading.readabilityHandler = nil
                    err.fileHandleForReading.readabilityHandler = nil
                    state.take(out.fileHandleForReading.readDataToEndOfFile())
                    state.lock.lock()
                    if !state.stopped, !state.buffer.isEmpty {
                        let rest = String(decoding: state.buffer, as: UTF8.self)
                        state.lines.append(rest)
                        if !line(rest) { state.stopped = true }
                    }
                    guard !state.resumed else {
                        state.lock.unlock()
                        return
                    }
                    state.resumed = true
                    let result = CLIOutput(exitCode: p.terminationStatus, lines: state.lines,
                                           errorTail: String(decoding: state.errors.suffix(600), as: UTF8.self),
                                           timedOut: state.timedOut, stopped: state.stopped)
                    state.lock.unlock()
                    continuation.resume(returning: result)
                }
                // Starting and cancelling are serialized, so a cancel that comes before the start
                // (a new Ask right after the last) never leaves a process running.
                state.lock.lock()
                if state.cancelled {
                    state.resumed = true
                    state.lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                do {
                    try process.run()
                    state.lock.unlock()
                } catch {
                    state.resumed = true
                    state.lock.unlock()
                    continuation.resume(throwing: ProviderError.unavailable)
                    return
                }
                let data = Data(invocation.input.utf8)
                // A process killed before it read its input (a cancelled search answer) makes the
                // write fail instead of raising SIGPIPE, which would end Funes.
                _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
                DispatchQueue.global(qos: .utility).async {
                    try? input.fileHandleForWriting.write(contentsOf: data)
                    try? input.fileHandleForWriting.close()
                }
                let seconds = Double(invocation.timeout.components.seconds) + Double(invocation.timeout.components.attoseconds) / 1e18
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + seconds) {
                    state.lock.lock()
                    defer { state.lock.unlock() }
                    guard state.process.isRunning else { return }
                    state.timedOut = true
                    state.process.terminate()
                }
            }
        } onCancel: {
            state.lock.lock()
            state.cancelled = true
            let running = state.process.isRunning
            state.lock.unlock()
            if running { state.process.terminate() }
        }
    }
}

/// What subscription providers share (ADR-0024, model providers §5.8): finding the CLI the user
/// installed, a new empty directory per call, an environment without API keys, and the record of
/// providers stopped for a tool event.
public enum CLIRunner {
    /// Removed from every child's environment, so the user's plan is what's used.
    public static let strippedVariables = ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CODEX_API_KEY", "OPENAI_API_KEY"]
    /// Per call (ADR-0024 §5).
    public static let timeout: Duration = .seconds(90)

    static let logger = Logger(subsystem: "com.funesvault.mac", category: "models")

    /// The environment a call gets: Funes's own, minus API keys, plus `extra`.
    public static func environment(_ base: [String: String] = ProcessInfo.processInfo.environment,
                                   extra: [String: String] = [:]) -> [String: String] {
        var env = base
        for key in strippedVariables { env[key] = nil }
        env.merge(extra) { _, new in new }
        return env
    }

    /// Runs `body` in a new empty directory under the temporary folder (outside any repository),
    /// deleted afterwards.
    public static func inTemporaryDirectory<T: Sendable>(_ body: (URL) async throws -> T) async throws -> T {
        let dir = FileManager.default.temporaryDirectory.appending(path: "funes-cli-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: dir) }
        return try await body(dir)
    }

    /// Providers that showed a tool or command event: unavailable until Test connection passes.
    private static let blockedProviders = Mutex<Set<ProviderID>>([])

    static func block(_ id: ProviderID) {
        blockedProviders.withLock { _ = $0.insert(id) }
        logger.error("provider_tool_blocked \(id.rawValue, privacy: .public)") // log-safe: provider id only
    }

    public static func isBlocked(_ id: ProviderID) -> Bool { blockedProviders.withLock { $0.contains(id) } }

    /// Test connection clears the block before it tries again.
    public static func unblock(_ id: ProviderID) { blockedProviders.withLock { _ = $0.remove(id) } }

    /// The first `x.y.z` in a version line ("2.1.310 (Claude Code)", "codex-cli 0.164.0").
    public static func version(in text: String) -> String? {
        text.firstMatch(of: /\d+\.\d+(\.\d+)?/).map { String($0.output.0) }
    }
}
