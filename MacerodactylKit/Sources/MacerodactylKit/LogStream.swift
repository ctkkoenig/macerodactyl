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
