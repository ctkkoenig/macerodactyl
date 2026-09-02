import Foundation

public enum ContainerHealth: String, Sendable, Hashable {
    case healthy
    case unhealthy
    case starting
}

public enum ContainerRunState: String, Sendable, Hashable {
    case running, exited, created, paused, restarting, removing, dead
    case unknown

    public init(dockerState: String) {
        self = ContainerRunState(rawValue: dockerState.lowercased()) ?? .unknown
    }
}

public struct DockerContainer: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let image: String
    public let state: ContainerRunState
    /// Raw status string from docker, e.g. "Up 3 days (healthy)".
    public let status: String
    public let health: ContainerHealth?
    public let ports: String
    public let composeProject: String?
    public let composeService: String?
    public let composeWorkingDir: String?

    public var isCompose: Bool { composeProject != nil }
    public var isRunning: Bool { state == .running }

    public init(
        id: String, name: String, image: String, state: ContainerRunState,
        status: String, health: ContainerHealth?, ports: String,
        composeProject: String?, composeService: String?, composeWorkingDir: String?
    ) {
        self.id = id
        self.name = name
        self.image = image
        self.state = state
        self.status = status
        self.health = health
        self.ports = ports
        self.composeProject = composeProject
        self.composeService = composeService
        self.composeWorkingDir = composeWorkingDir
    }
}

/// A compose project and its containers.
public struct ContainerStack: Identifiable, Hashable, Sendable {
    public let name: String
    public let workingDir: String?
    public let containers: [DockerContainer]

    public var id: String { name }
    public var runningCount: Int { containers.count(where: \.isRunning) }
}

public struct ContainerGroups: Sendable, Equatable {
    public let stacks: [ContainerStack]
    public let unmanaged: [DockerContainer]

    public var all: [DockerContainer] { stacks.flatMap(\.containers) + unmanaged }
    public var isEmpty: Bool { stacks.isEmpty && unmanaged.isEmpty }

    public init(stacks: [ContainerStack], unmanaged: [DockerContainer]) {
        self.stacks = stacks
        self.unmanaged = unmanaged
    }

    public static let empty = ContainerGroups(stacks: [], unmanaged: [])
}

public enum DockerPSParser {
    static let composeProjectLabel = "com.docker.compose.project"
    static let composeServiceLabel = "com.docker.compose.service"
    static let composeWorkingDirLabel = "com.docker.compose.project.working_dir"

    /// One line of `docker ps -a --format '{{json .}}'`.
    private struct PSLine: Decodable {
        let ID: String
        let Names: String
        let Image: String
        let State: String
        let Status: String
        let Ports: String?
        let Labels: String?
    }

    /// Parses the output of `docker ps -a --no-trunc --format '{{json .}}'`.
    /// Unparseable lines are skipped rather than failing the whole refresh.
    public static func parse(_ output: String) -> [DockerContainer] {
        let decoder = JSONDecoder()
        return output.split(separator: "\n").compactMap { line -> DockerContainer? in
            guard let data = line.data(using: .utf8),
                  let ps = try? decoder.decode(PSLine.self, from: data) else { return nil }
            let labels = parseLabels(ps.Labels ?? "")
            return DockerContainer(
                id: ps.ID,
                name: ps.Names,
                image: ps.Image,
                state: ContainerRunState(dockerState: ps.State),
                status: ps.Status,
                health: parseHealth(fromStatus: ps.Status),
                ports: ps.Ports ?? "",
                composeProject: labels[composeProjectLabel],
                composeService: labels[composeServiceLabel],
                composeWorkingDir: labels[composeWorkingDirLabel]
            )
        }
    }

    /// Health is not a separate `docker ps` field; it rides inside the status
    /// string in parentheses: "Up 3 days (healthy)". Only recognized health
    /// values count — "Exited (1) 2 hours ago" carries an exit code, not health.
    public static func parseHealth(fromStatus status: String) -> ContainerHealth? {
        for match in status.matches(of: /\(([^)]+)\)/) {
            let inner = String(match.1).lowercased()
            switch inner {
            case "healthy": return .healthy
            case "unhealthy": return .unhealthy
            case "health: starting": return .starting
            default: continue
            }
        }
        return nil
    }

    /// `docker ps` renders labels as "k1=v1,k2=v2". Values can themselves
    /// contain commas (working_dir paths, descriptions), so a segment without
    /// "=" is glued back onto the previous value.
    public static func parseLabels(_ raw: String) -> [String: String] {
        guard !raw.isEmpty else { return [:] }
        var result: [String: String] = [:]
        var lastKey: String?
        for segment in raw.split(separator: ",", omittingEmptySubsequences: false) {
            if let eq = segment.firstIndex(of: "=") {
                let key = String(segment[segment.startIndex..<eq])
                let value = String(segment[segment.index(after: eq)...])
                result[key] = value
                lastKey = key
            } else if let key = lastKey {
                result[key]! += "," + segment
            }
        }
        return result
    }

    /// Groups containers into compose stacks + an Unmanaged section, excluding
    /// the app's own container (self-exclusion rule) — sorted for stable UI.
    public static func group(_ containers: [DockerContainer]) -> ContainerGroups {
        let visible = containers.filter { !isSelf($0) }
        var byProject: [String: [DockerContainer]] = [:]
        var unmanaged: [DockerContainer] = []
        for container in visible {
            if let project = container.composeProject {
                byProject[project, default: []].append(container)
            } else {
                unmanaged.append(container)
            }
        }
        let stacks = byProject
            .map { name, members in
                ContainerStack(
                    name: name,
                    workingDir: members.compactMap(\.composeWorkingDir).first,
                    containers: members.sorted { $0.name < $1.name }
                )
            }
            .sorted { $0.name < $1.name }
        return ContainerGroups(stacks: stacks, unmanaged: unmanaged.sorted { $0.name < $1.name })
    }

    /// The app never lists itself.
    static func isSelf(_ container: DockerContainer) -> Bool {
        container.name.lowercased().contains("macerodactyl")
            || container.image.lowercased().contains("macerodactyl")
    }
}
