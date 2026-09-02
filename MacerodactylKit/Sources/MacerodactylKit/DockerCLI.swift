import Foundation

public enum DockerError: Error, Equatable, Sendable {
    /// The docker CLI exists but cannot reach the daemon (Docker Desktop, or
    /// whichever provider is installed, isn't running).
    case daemonUnavailable
    case timeout
    case nonZeroExit(code: Int32, stderr: String)
    case launchFailed(String)
}

/// Runs the docker CLI via Process. This is the only way the app talks to
/// Docker — never the Unix socket (see CLAUDE.md). Arguments are always passed
/// as an array; nothing is ever interpolated through a shell.
public struct DockerCLI: Sendable {
    public let binary: URL

    public init(binary: URL) {
        self.binary = binary
    }

    public struct CommandResult: Sendable {
        public let stdout: String
        public let stderr: String
        public let exitCode: Int32
    }

    /// Runs `docker <args>` and returns stdout, throwing on failure.
    @discardableResult
    public func run(_ args: [String], timeout: Duration = .seconds(60)) async throws -> String {
        let result = try await execute(args, timeout: timeout)
        guard result.exitCode == 0 else {
            if Self.indicatesDaemonDown(result.stderr) {
                throw DockerError.daemonUnavailable
            }
            throw DockerError.nonZeroExit(code: result.exitCode, stderr: result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return result.stdout
    }

    /// Runs `docker <args>` without treating non-zero exit as an error.
    public func execute(_ args: [String], timeout: Duration = .seconds(60)) async throws -> CommandResult {
        let process = Process()
        process.executableURL = binary
        process.arguments = args
        // A minimal, controlled environment; docker needs HOME to find its config.
        process.environment = [
            "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
            "PATH": "/usr/bin:/bin",
        ]

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw DockerError.launchFailed(String(describing: error))
        }

        async let stdoutData = Self.readAll(outPipe.fileHandleForReading)
        async let stderrData = Self.readAll(errPipe.fileHandleForReading)

        let timedOut = await Self.wait(for: process, timeout: timeout)
        let stdout = String(decoding: await stdoutData, as: UTF8.self)
        let stderr = String(decoding: await stderrData, as: UTF8.self)

        if timedOut {
            throw DockerError.timeout
        }
        return CommandResult(stdout: stdout, stderr: stderr, exitCode: process.terminationStatus)
    }

    /// Streams stdout of `docker <args>` line by line (used for `logs --follow`).
    /// Terminating the stream's consumer terminates the process.
    /// When `mergeStderr` is true, stderr lines are ALSO yielded live (still
    /// captured for error reporting). Needed for `docker pull` / `docker compose`
    /// which write their progress to stderr, not stdout.
    public func streamLines(_ args: [String], mergeStderr: Bool = false) -> AsyncThrowingStream<String, Error> {
        let binary = self.binary
        return AsyncThrowingStream { continuation in
            let process = Process()
            process.executableURL = binary
            process.arguments = args
            process.environment = [
                "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
                "PATH": "/usr/bin:/bin",
            ]
            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe
            process.standardInput = FileHandle.nullDevice

            let stderrBox = DataBox()
            let stderrLineBox = DataBox()
            errPipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty {
                    handle.readabilityHandler = nil
                    if mergeStderr, let last = stderrLineBox.drainRemainder() {
                        continuation.yield(last)
                    }
                } else {
                    stderrBox.append(chunk)
                    if mergeStderr {
                        for line in stderrLineBox.appendAndSplitLines(chunk) {
                            continuation.yield(line)
                        }
                    }
                }
            }

            let lineBox = DataBox()
            outPipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty {
                    handle.readabilityHandler = nil
                    if let last = lineBox.drainRemainder() {
                        continuation.yield(last)
                    }
                    return
                }
                for line in lineBox.appendAndSplitLines(chunk) {
                    continuation.yield(line)
                }
            }

            process.terminationHandler = { process in
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                if process.terminationStatus == 0 || process.terminationReason == .uncaughtSignal {
                    continuation.finish()
                } else {
                    let stderr = String(decoding: stderrBox.snapshot(), as: UTF8.self)
                    if Self.indicatesDaemonDown(stderr) {
                        continuation.finish(throwing: DockerError.daemonUnavailable)
                    } else {
                        continuation.finish(
                            throwing: DockerError.nonZeroExit(
                                code: process.terminationStatus,
                                stderr: stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                            ))
                    }
                }
            }

            continuation.onTermination = { _ in
                if process.isRunning {
                    process.terminate()
                }
            }

            do {
                try process.run()
            } catch {
                continuation.finish(throwing: DockerError.launchFailed(String(describing: error)))
            }
        }
    }

    /// One-shot stats for all running containers in a single process
    /// (`docker stats --no-stream`). Cheaper than per-container polling; used
    /// for the landing cards on a slow cadence. Returns only real readings.
    public func statsSnapshot(timeout: Duration = .seconds(20)) async throws -> [String: ContainerStats] {
        let output = try await run(["stats", "--no-stream", "--format", "{{json .}}"], timeout: timeout)
        return DockerStatsParser.parseSnapshot(output)
    }

    /// Continuous stats for one container, by polling `docker stats --no-stream`
    /// on a short interval. Streaming mode (`docker stats` without --no-stream)
    /// is unusable when piped: it emits ANSI screen-refresh sequences that
    /// aren't valid JSON. Polling --no-stream gives clean readings, one
    /// container per short-lived call, and trivial teardown — cancel the
    /// consumer and the loop stops (no long-lived process to leak).
    public func statsStream(containerID: String, interval: Duration = .seconds(2)) -> AsyncThrowingStream<ContainerStats, Error> {
        return AsyncThrowingStream { continuation in
            let task = Task {
                while !Task.isCancelled {
                    do {
                        let output = try await run(["stats", "--no-stream", "--format", "{{json .}}", containerID], timeout: .seconds(20))
                        if let stats = DockerStatsParser.parse(line: output.split(separator: "\n").first.map(String.init) ?? output) {
                            continuation.yield(stats)
                        }
                    } catch is CancellationError {
                        break
                    } catch {
                        continuation.finish(throwing: error)
                        return
                    }
                    try? await Task.sleep(for: interval)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The container's start time, for a truthful uptime (nil if unavailable).
    public func startedAt(containerID: String) async -> Date? {
        guard
            let output = try? await run(
                ["inspect", "--format", "{{.State.StartedAt}}", containerID], timeout: .seconds(10)
            )
        else { return nil }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: trimmed) ?? ISO8601DateFormatter().date(from: trimmed)
    }

    /// True if `docker compose version` succeeds (the plugin is installed).
    public func composePluginWorks() async -> Bool {
        guard let result = try? await execute(["compose", "version"], timeout: .seconds(10)) else {
            return false
        }
        return result.exitCode == 0
    }

    static func indicatesDaemonDown(_ stderr: String) -> Bool {
        stderr.contains("Cannot connect to the Docker daemon")
            || stderr.contains("Is the docker daemon running")
            || stderr.contains("dial unix")
    }

    private static func readAll(_ handle: FileHandle) async -> Data {
        await withCheckedContinuation { continuation in
            let box = DataBox()
            handle.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty {
                    handle.readabilityHandler = nil
                    continuation.resume(returning: box.snapshot())
                } else {
                    box.append(chunk)
                }
            }
        }
    }

    /// Waits for termination, killing the process on timeout. Returns true if it timed out.
    private static func wait(for process: Process, timeout: Duration) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await withCheckedContinuation { continuation in
                    let once = OnceFlag()
                    process.terminationHandler = { _ in
                        if once.claim() { continuation.resume() }
                    }
                    // The process may have exited before the handler was set,
                    // in which case the handler never fires.
                    if !process.isRunning, once.claim() {
                        continuation.resume()
                    }
                }
                return false
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                if Task.isCancelled { return false }
                if process.isRunning {
                    process.terminate()
                    try? await Task.sleep(for: .seconds(2))
                    if process.isRunning {
                        kill(process.processIdentifier, SIGKILL)
                    }
                }
                return true
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }
}

final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    /// Returns true exactly once, for the first caller.
    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}

/// Thread-safe byte buffer used from FileHandle readability handlers.
final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    func snapshot() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return data
    }

    /// Appends a chunk and returns any complete lines, keeping the remainder buffered.
    func appendAndSplitLines(_ chunk: Data) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        data.append(chunk)
        var lines: [String] = []
        while let newline = data.firstIndex(of: UInt8(ascii: "\n")) {
            let lineData = data[data.startIndex..<newline]
            lines.append(String(decoding: lineData, as: UTF8.self))
            data.removeSubrange(data.startIndex...newline)
        }
        return lines
    }

    func drainRemainder() -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard !data.isEmpty else { return nil }
        let line = String(decoding: data, as: UTF8.self)
        data.removeAll()
        return line
    }
}
