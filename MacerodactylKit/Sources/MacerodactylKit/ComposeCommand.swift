import Foundation

/// Compose ships in two shapes: the modern `docker compose` subcommand (a CLI
/// plugin) and the legacy standalone `docker-compose` binary. Which one is
/// present varies by machine, so the app detects rather than assumes.
public enum ComposeCommand: Sendable, Equatable {
    /// `docker compose …` — args are prefixed with "compose".
    case plugin(dockerBinary: URL)
    /// `docker-compose …` — a separate executable, no "compose" prefix.
    case standalone(binary: URL)

    /// The executable to run and the argument prefix that precedes the
    /// caller's own compose args (e.g. `--project-directory <dir> up -d`).
    public func invocation(_ arguments: [String]) -> (executable: URL, args: [String]) {
        switch self {
        case .plugin(let docker): (docker, ["compose"] + arguments)
        case .standalone(let binary): (binary, arguments)
        }
    }

    /// Standalone `docker-compose` lives beside `docker` on both architectures
    /// (/opt/homebrew/bin on Apple Silicon, /usr/local/bin on Intel), so we
    /// look next to the resolved docker binary first, then the usual bins.
    public static func standaloneCandidates(besideDocker docker: URL) -> [URL] {
        var candidates = [docker.deletingLastPathComponent().appending(path: "docker-compose")]
        candidates += [
            URL(fileURLWithPath: "/opt/homebrew/bin/docker-compose"),
            URL(fileURLWithPath: "/usr/local/bin/docker-compose"),
        ]
        return candidates
    }

    /// Detects the available shape. `pluginWorks` should run
    /// `docker compose version` and report success; it's injected so the logic
    /// is testable without a live docker. Prefers the plugin (what Docker
    /// Desktop ships), falls back to a standalone binary on disk, else nil.
    public static func detect(
        dockerBinary: URL,
        pluginWorks: (URL) -> Bool,
        fileManager: FileManager = .default
    ) -> ComposeCommand? {
        if pluginWorks(dockerBinary) {
            return .plugin(dockerBinary: dockerBinary)
        }
        if let standalone = standaloneCandidates(besideDocker: dockerBinary)
            .first(where: { fileManager.isExecutableFile(atPath: $0.path) }) {
            return .standalone(binary: standalone)
        }
        return nil
    }
}
