import Foundation

/// A cold-start advisory: what's wrong (or merely worth noting) and what to do
/// about it. Every environment that could stop the app working is turned into
/// one of these so it explains itself instead of failing blankly.
public struct StartupAdvisory: Sendable, Equatable, Identifiable {
    public enum Severity: Sendable, Equatable {
        case blocking   // the app can't manage containers at all
        case degraded   // some capability is unavailable
        case info       // nothing wrong; just orienting a new user
    }

    public let id: String
    public let severity: Severity
    public let title: String
    public let detail: String
    public let remedy: String

    public init(id: String, severity: Severity, title: String, detail: String, remedy: String) {
        self.id = id
        self.severity = severity
        self.title = title
        self.detail = detail
        self.remedy = remedy
    }
}

/// Snapshot of the environment, injectable so every cold-start case can be
/// faked in tests rather than only exercised on a working machine.
public struct EnvironmentSnapshot: Sendable, Equatable {
    public var dockerResolved: Bool
    public var daemon: DockerAvailability
    public var composeAvailable: Bool
    public var perlAvailable: Bool
    public var stacksRootExists: Bool
    public var stacksRootPath: String
    public var containerCount: Int

    public init(
        dockerResolved: Bool, daemon: DockerAvailability, composeAvailable: Bool,
        perlAvailable: Bool, stacksRootExists: Bool, stacksRootPath: String, containerCount: Int
    ) {
        self.dockerResolved = dockerResolved
        self.daemon = daemon
        self.composeAvailable = composeAvailable
        self.perlAvailable = perlAvailable
        self.stacksRootExists = stacksRootExists
        self.stacksRootPath = stacksRootPath
        self.containerCount = containerCount
    }
}

public enum StartupDiagnostics {
    /// Pure evaluation: given a snapshot, the ordered advisories to show.
    /// Blocking issues short-circuit the ones that depend on them (no point
    /// warning about an empty container list when docker isn't even installed).
    public static func evaluate(_ env: EnvironmentSnapshot) -> [StartupAdvisory] {
        if !env.dockerResolved {
            return [StartupAdvisory(
                id: "docker-missing",
                severity: .blocking,
                title: "Docker isn’t installed",
                detail: "No docker binary was found in ~/.orbstack/bin, /opt/homebrew/bin, or /usr/local/bin.",
                remedy: "Install Docker Desktop (the expected setup), or if docker lives elsewhere, set its path in Settings."
            )]
        }
        if env.daemon == .daemonDown {
            return [StartupAdvisory(
                id: "daemon-down",
                severity: .blocking,
                title: "The Docker daemon isn’t running",
                detail: "The docker CLI is installed but can’t reach the daemon.",
                remedy: "Start Docker Desktop (or your Docker provider) and wait for it to finish launching. Macerodactyl never starts the daemon itself."
            )]
        }

        var advisories: [StartupAdvisory] = []
        if !env.composeAvailable {
            advisories.append(StartupAdvisory(
                id: "compose-missing",
                severity: .degraded,
                title: "Docker Compose not found",
                detail: "Neither `docker compose` nor a standalone `docker-compose` is available.",
                remedy: "Install Docker Compose to start, stop, and restart whole stacks. Individual containers still work without it."
            ))
        }
        if !env.perlAvailable {
            advisories.append(StartupAdvisory(
                id: "perl-missing",
                severity: .degraded,
                title: "System perl not found",
                detail: "Scheduled restarts normally run under /usr/bin/perl, which enforces a hard timeout so a stuck docker can’t hang forever.",
                remedy: "Schedules still work, but a hung restart won’t be force-killed at the deadline. Restoring /usr/bin/perl re-enables the safeguard."
            ))
        }
        if !env.stacksRootExists {
            advisories.append(StartupAdvisory(
                id: "stacks-missing",
                severity: .info,
                title: "Stacks folder doesn’t exist yet",
                detail: "\(env.stacksRootPath) isn’t there. File editing is scoped to stacks under this folder, so until it exists (and holds your compose projects) the Files tab stays empty.",
                remedy: "Create it from Settings, or point the stacks folder at where your compose projects already live."
            ))
        }
        if env.containerCount == 0 {
            advisories.append(StartupAdvisory(
                id: "no-containers",
                severity: .info,
                title: "No containers yet",
                detail: "Docker is running but nothing is defined. Compose stacks and bare `docker run` containers both appear here once they exist.",
                remedy: "Start a container or bring up a compose stack, then it shows up automatically."
            ))
        }
        return advisories
    }
}
