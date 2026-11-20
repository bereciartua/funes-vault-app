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

    /// How long a stopped process gets to exit on SIGTERM before SIGKILL.
    static let killGrace: TimeInterval = 2
    /// How long output may still arrive once the process has exited. A read already under way
    /// lands well within it; a helper the CLI left running with the pipes open doesn't hold the run.
    static let drainGrace: TimeInterval = 2

    /// Ends a process: SIGTERM, then SIGKILL if it's still running after `killGrace` (a CLI that
    /// ignores SIGTERM can't outlive a search answer's deadline). The kill waits on a queue of its
    /// own: when a shared global queue's threads are all busy or blocked (a loaded Mac, a parallel
    /// test run), it would never fire.
    static func stop(_ process: Process) {
        guard process.isRunning else { return }
        let pid = process.processIdentifier
        process.terminate()
        DispatchQueue(label: "com.funesvault.cli.kill", qos: .userInitiated).asyncAfter(deadline: .now() + killGrace) {
            if process.isRunning { kill(pid, SIGKILL) }
        }
    }

    /// The run's mutable state, behind its lock.
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        let process: Process
        let line: @Sendable (String) -> Bool
        /// The run's time limit and output drain, on its own queue for the same reason as the kill.
        let control = DispatchQueue(label: "com.funesvault.cli.control", qos: .userInitiated)
        var buffer = Data()
        var lines: [String] = []
        var errors = Data()
        var stopped = false
        var timedOut = false
        var resumed = false
        /// The task was cancelled: a process not started yet never starts.
        var cancelled = false
        var continuation: CheckedContinuation<CLIOutput, any Error>?
        var timeLimit: DispatchWorkItem?
        var exitStatus: Int32?
        var outputEnded = false
        var errorsEnded = false
        /// Reads taken from a pipe and not yet handed over: the drain waits for them too.
        var reading = 0
        /// The read ends, to see whether output is still waiting when the drain runs out.
        let outputFD: Int32
        let errorsFD: Int32

        init(process: Process, line: @escaping @Sendable (String) -> Bool, outputFD: Int32, errorsFD: Int32) {
            self.process = process
            self.line = line
            self.outputFD = outputFD
            self.errorsFD = errorsFD
        }

        func beginRead() { lock.withLock { reading += 1 } }
        func endRead() { lock.withLock { reading -= 1 } }

        /// Whether output is still on its way: a read being handed over, or bytes waiting in a
        /// stream that hasn't ended.
        private func waiting() -> Bool {
            if reading > 0 { return true }
            var fds = [(outputFD, outputEnded), (errorsFD, errorsEnded)].filter { !$0.1 }
                .map { pollfd(fd: $0.0, events: Int16(POLLIN), revents: 0) }
            return !fds.isEmpty && poll(&fds, nfds_t(fds.count), 0) > 0
        }

        /// Splits output into lines and hands each to the handler; a false answer kills the process.
        func take(_ data: Data) {
            lock.lock()
            defer { lock.unlock() }
            // Nothing reaches the handler once the run has returned (output after the drain).
            guard !stopped, !resumed else { return }
            buffer.append(data)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let text = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)
                buffer.removeSubrange(buffer.startIndex...newline)
                lines.append(text)
                if !line(text) {
                    stopped = true
                    SystemCLIProcess.stop(process)
                    return
                }
            }
        }

        func takeError(_ data: Data) {
            lock.withLock {
                guard !resumed else { return }
                errors.append(data)
                if errors.count > 8_192 { errors = errors.suffix(4_096) }
            }
        }

        func outputEnd() {
            lock.lock()
            outputEnded = true
            finish()
        }

        func errorsEnd() {
            lock.lock()
            errorsEnded = true
            finish()
        }

        /// The process exited: the result once both streams have ended, or after `drainGrace` (longer
        /// while output is still on its way, up to ten more checks). Output still on its way after
        /// that makes the run timed out, not a success with lines missing (a tool event among them).
        func exited(_ status: Int32, drain: @escaping @Sendable () -> Void) {
            lock.lock()
            exitStatus = status
            let open = !(outputEnded && errorsEnded)
            finish()
            if open { scheduleDrain(after: SystemCLIProcess.drainGrace, checks: 10, drain: drain) }
        }

        private func scheduleDrain(after delay: TimeInterval, checks: Int, drain: @escaping @Sendable () -> Void) {
            control.asyncAfter(deadline: .now() + delay) {
                self.lock.lock()
                guard !self.resumed else {
                    self.lock.unlock()
                    return
                }
                if self.waiting() {
                    guard checks == 0 else {
                        self.lock.unlock()
                        self.scheduleDrain(after: 0.2, checks: checks - 1, drain: drain)
                        return
                    }
                    self.timedOut = true
                }
                self.outputEnded = true
                self.errorsEnded = true
                self.finish()
                drain()
            }
        }

        /// Called with the lock held; releases it. Resumes once the process has exited and both
        /// streams have ended, so no output still being read is missed (a stream's last read can
        /// come after the process's exit).
        private func finish() {
            guard let status = exitStatus, outputEnded, errorsEnded, !resumed, let continuation else {
                lock.unlock()
                return
            }
            if !stopped, !buffer.isEmpty {
                let rest = String(decoding: buffer, as: UTF8.self)
                buffer.removeAll()
                lines.append(rest)
                if !line(rest) { stopped = true }
            }
            resumed = true
            self.continuation = nil
            timeLimit?.cancel()
            timeLimit = nil
            let result = CLIOutput(exitCode: status, lines: lines, errorTail: String(decoding: errors.suffix(600), as: UTF8.self),
                                   timedOut: timedOut, stopped: stopped)
            lock.unlock()
            continuation.resume(returning: result)
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
        let state = State(process: process, line: line, outputFD: out.fileHandleForReading.fileDescriptor,
                          errorsFD: err.fileHandleForReading.fileDescriptor)
        // An empty read is the stream's end: after every earlier read's handler has run, as a
        // handle's reads are handled one at a time.
        out.fileHandleForReading.readabilityHandler = { handle in
            state.beginRead()
            defer { state.endRead() }
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                state.outputEnd()
            } else {
                state.take(data)
            }
        }
        err.fileHandleForReading.readabilityHandler = { handle in
            state.beginRead()
            defer { state.endRead() }
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                state.errorsEnd()
            } else {
                state.takeError(data)
            }
        }
        // Stops reading: a process that never started, or streams a leftover helper keeps open.
        let unhook: @Sendable () -> Void = {
            out.fileHandleForReading.readabilityHandler = nil
            err.fileHandleForReading.readabilityHandler = nil
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CLIOutput, any Error>) in
                process.terminationHandler = { p in state.exited(p.terminationStatus, drain: unhook) }
                // Starting and cancelling are serialized, so a cancel that comes before the start
                // (a new Ask right after the last) never leaves a process running.
                state.lock.lock()
                if state.cancelled {
                    state.resumed = true
                    state.lock.unlock()
                    process.terminationHandler = nil
                    unhook()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                state.continuation = continuation
                do {
                    try process.run()
                } catch {
                    state.resumed = true
                    state.continuation = nil
                    state.lock.unlock()
                    process.terminationHandler = nil
                    unhook()
                    continuation.resume(throwing: ProviderError.unavailable)
                    return
                }
                // Weak: a cancelled work item keeps what it holds until its deadline passes.
                let timeLimit = DispatchWorkItem { [weak state] in
                    guard let state else { return }
                    state.lock.lock()
                    defer { state.lock.unlock() }
                    guard state.process.isRunning else { return }
                    state.timedOut = true
                    SystemCLIProcess.stop(state.process)
                }
                state.timeLimit = timeLimit
                state.lock.unlock()
                let data = Data(invocation.input.utf8)
                // A process killed before it read its input (a cancelled search answer) makes the
                // write fail instead of raising SIGPIPE, which would end Funes.
                _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
                // Its own queue: the write blocks while the CLI isn't reading, and on a shared
                // global queue it could wait behind other work past the time limit.
                DispatchQueue(label: "com.funesvault.cli.input", qos: .userInitiated).async {
                    try? input.fileHandleForWriting.write(contentsOf: data)
                    try? input.fileHandleForWriting.close()
                }
                let seconds = Double(invocation.timeout.components.seconds) + Double(invocation.timeout.components.attoseconds) / 1e18
                state.control.asyncAfter(deadline: .now() + seconds, execute: timeLimit)
            }
        } onCancel: {
            state.lock.lock()
            state.cancelled = true
            let running = state.process.isRunning
            state.lock.unlock()
            if running { SystemCLIProcess.stop(state.process) }
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

    /// Where Homebrew puts `node` and npm's global commands (Apple silicon, then Intel).
    static let toolDirectories = ["/opt/homebrew/bin", "/usr/local/bin"]

    /// The environment a call gets: Funes's own, minus API keys, plus `extra`. An app started from
    /// the Finder has a minimal `PATH`, so an npm-installed CLI (`#!/usr/bin/env node`) wouldn't
    /// find `node`: the executable's own directory and Homebrew's go first.
    public static func environment(_ base: [String: String] = ProcessInfo.processInfo.environment,
                                   executable: String? = nil, extra: [String: String] = [:]) -> [String: String] {
        var env = base
        for key in strippedVariables { env[key] = nil }
        if let executable {
            let own = (executable as NSString).deletingLastPathComponent
            var path: [String] = []
            for dir in [own] + toolDirectories + (base["PATH"] ?? "").split(separator: ":").map(String.init)
            where !dir.isEmpty && !path.contains(dir) { path.append(dir) }
            env["PATH"] = path.joined(separator: ":")
        }
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
