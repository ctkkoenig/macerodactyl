import Foundation
import Observation

/// Pure argument builders — kept separate so tests can pin down exactly what
/// reaches the docker CLI. Host-side commands are always argument arrays;
/// nothing is ever interpolated through a host shell.
public enum DockerArgs {
    public static func logs(containerID: String, tail: Int = 500, timestamps: Bool = false) -> [String] {
        var args = ["logs", "--follow", "--tail", String(tail)]
        if timestamps { args.append("--timestamps") }
        args.append(containerID)
        return args
    }

    /// The user's command line is handed to the *container's* shell as a single
    /// argument. The host never interprets it.
    public static func exec(containerID: String, commandLine: String) -> [String] {
        ["exec", containerID, "/bin/sh", "-c", commandLine]
    }
}

public enum LogStreamService {
    /// Live log lines for one container. The returned stream owns a
    /// `docker logs --follow` child process; when the consuming task is
    /// cancelled (window closed, container switched), the stream's termination
    /// handler tears the process down — nothing outlives its consumer.
    public static func lines(for containerID: String, cli: DockerCLI, tail: Int = 500) -> AsyncThrowingStream<String, Error> {
        cli.streamLines(DockerArgs.logs(containerID: containerID, tail: tail))
    }

    /// A bounded, non-streaming snapshot of a container's recent logs, for search
    /// and download. `docker logs` writes to BOTH stdout and stderr, so both are
    /// captured; `--timestamps` lets them be merged back into one chronological
    /// stream. Retention is docker's own log driver — this reads what docker
    /// already keeps, never a duplicate store. Returns nil if the command fails.
    public static func history(
        for containerID: String, cli: DockerCLI, tail: Int = 2_000, since: String? = nil
    ) async -> String? {
        var args = ["logs", "--timestamps", "--tail", String(max(1, tail))]
        if let since, !since.isEmpty { args += ["--since", since] }
        args.append(containerID)
        guard let result = try? await cli.execute(args, timeout: .seconds(20)) else { return nil }
        return mergeChronologically(stdout: result.stdout, stderr: result.stderr)
    }

    /// Merges the two `--timestamps`-prefixed streams into one, ordered by the
    /// leading RFC3339 timestamp. Lines without a parseable timestamp keep their
    /// relative order at the end (stable).
    static func mergeChronologically(stdout: String, stderr: String) -> String {
        func lines(_ s: String) -> [Substring] {
            s.split(separator: "\n", omittingEmptySubsequences: true)
        }
        let all = lines(stdout) + lines(stderr)
        let stamped = all.enumerated().map { (index, line) -> (ts: String, order: Int, line: Substring) in
            // Timestamp is the first whitespace-delimited token when present.
            let ts = line.prefix(while: { $0 != " " })
            return (String(ts), index, line)
        }
        let sorted = stamped.sorted { a, b in
            if a.ts == b.ts { return a.order < b.order }
            return a.ts < b.ts
        }
        return sorted.map { String($0.line) }.joined(separator: "\n")
    }
}

public struct LogLine: Identifiable, Sendable, Equatable {
    public let id: Int
    public let text: String
}

/// Capped scrollback for a log view. Appends are O(1) amortized: when the cap
/// is exceeded the oldest ~10% is dropped in one operation, so a container
/// spraying thousands of lines a second doesn't turn every append into a
/// front-removal.
@MainActor
@Observable
public final class LogBuffer {
    public private(set) var lines: [LogLine] = []
    public let cap: Int
    private var nextID = 0

    public init(cap: Int = 10_000) {
        self.cap = max(cap, 100)
    }

    public func append(_ newLines: [String]) {
        guard !newLines.isEmpty else { return }
        lines.append(
            contentsOf: newLines.map { text in
                defer { nextID += 1 }
                return LogLine(id: nextID, text: text)
            })
        if lines.count > cap {
            lines.removeFirst(lines.count - cap + cap / 10)
        }
    }

    public func append(_ line: String) {
        append([line])
    }

    public func clear() {
        lines.removeAll()
    }
}
