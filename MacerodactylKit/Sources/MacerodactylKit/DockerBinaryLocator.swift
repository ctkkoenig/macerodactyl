import Foundation

/// Resolves the `docker` binary by explicit path. GUI apps do not inherit the
/// shell PATH, so a bare `docker` lookup succeeds in Terminal and fails when
/// the app is launched from Finder — never rely on PATH.
public enum DockerBinaryLocator {
    /// Candidate locations, in priority order after the user override. The macOS
    /// paths come first (Docker Desktop is the primary target); `/usr/bin/docker`
    /// is included so the headless server also resolves docker in a Linux
    /// container (Tier 4), where the CLI lives on PATH at that path.
    public static var defaultCandidates: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            home.appending(path: ".orbstack/bin/docker"),
            URL(fileURLWithPath: "/opt/homebrew/bin/docker"),
            URL(fileURLWithPath: "/usr/local/bin/docker"),
            URL(fileURLWithPath: "/usr/bin/docker"),
        ]
    }

    /// Returns the first executable docker binary: the user override if set and
    /// valid, otherwise the first existing candidate.
    public static func resolve(
        override: String? = nil,
        candidates: [URL] = defaultCandidates,
        fileManager: FileManager = .default
    ) -> URL? {
        if let override, !override.isEmpty {
            let url = URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
            if fileManager.isExecutableFile(atPath: url.path) {
                return url
            }
            // An invalid override falls through to the candidates rather than
            // leaving the app dead in the water.
        }
        return candidates.first { fileManager.isExecutableFile(atPath: $0.path) }
    }
}
