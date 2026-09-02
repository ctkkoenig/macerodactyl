import Foundation
import MacerodactylKit

/// A `ContainerService` for the headless daemon: it talks to the docker CLI
/// directly, with no `@MainActor` / `ContainerStore` / SwiftUI dependency, so it
/// runs in `macerodactyld` (and, later, a Linux build) without a GUI. Behavior
/// mirrors `LiveContainerService`, sourcing containers from `docker ps` rather
/// than an in-process observable store.
public struct DaemonContainerService: ContainerService {
    let cli: DockerCLI
    let stacksRoot: URL

    public init(cli: DockerCLI, stacksRoot: URL) {
        self.cli = cli
        self.stacksRoot = stacksRoot
    }

    /// All containers (including stopped), grouped so the app's own container is
    /// excluded — same rule the GUI uses.
    private func fetchAll() async -> [DockerContainer] {
        guard
            let output = try? await cli.run(
                ["ps", "-a", "--no-trunc", "--format", "{{json .}}"], timeout: .seconds(15))
        else { return [] }
        return DockerPSParser.group(DockerPSParser.parse(output)).all
    }

    public func allContainers() async -> [DockerContainer] { await fetchAll() }

    public func container(named name: String) async -> DockerContainer? {
        await fetchAll().first { $0.name == name }
    }

    public func power(_ action: ContainerStore.PowerAction, containerName: String) async throws {
        guard let container = await container(named: containerName) else {
            throw ContainerServiceError.notFound
        }
        try await cli.run([action.rawValue, container.id], timeout: .seconds(120))
    }

    public func logLines(containerName: String) async -> AsyncThrowingStream<String, Error>? {
        guard let container = await container(named: containerName) else { return nil }
        return LogStreamService.lines(for: container.id, cli: cli)
    }

    public func logHistory(containerName: String, tail: Int, since: String?) async -> String? {
        guard let container = await container(named: containerName) else { return nil }
        return await LogStreamService.history(for: container.id, cli: cli, tail: tail, since: since)
    }

    public func runConsole(containerName: String, command: String) async -> ConsoleEntry? {
        guard let container = await container(named: containerName) else { return nil }
        switch await MinecraftRCON.detect(containerID: container.id, cli: cli) {
        case .available(let endpoint):
            let client = RCONClient(endpoint: endpoint)
            do {
                try await client.connect()
                let response = try await client.send(command: command)
                await client.close()
                return ConsoleEntry(command: command, output: response.isEmpty ? "(no response)" : response)
            } catch {
                return ConsoleEntry(command: command, output: "RCON error: \(error)", isError: true)
            }
        case .unreachable(let reason):
            return ConsoleEntry(command: command, output: "RCON unavailable: \(reason)", isError: true)
        case .notMinecraft:
            return await ExecConsole(containerID: container.id, cli: cli).run(command)
        }
    }

    public func fileService(containerName: String) async -> FileService? {
        guard let container = await container(named: containerName) else { return nil }
        return FileService(container: container, stacksRoot: stacksRoot)
    }

    public func statsSnapshot() async -> [String: ContainerStats] {
        (try? await cli.statsSnapshot()) ?? [:]
    }

    public func statsStream(containerName: String) async -> AsyncThrowingStream<ContainerStats, Error>? {
        guard let container = await container(named: containerName), container.isRunning else { return nil }
        return cli.statsStream(containerID: container.id)
    }

    public func schedule(containerName: String) async -> (RestartSchedule, ScheduleRunResult?)? {
        guard let service = try? ScheduleService(dockerPath: cli.binary.path),
            let schedule = service.schedule(forContainerName: containerName)
        else { return nil }
        return (schedule, service.lastResult(for: schedule))
    }

    public func setSchedule(containerName: String, hour: Int, minute: Int, weekdays: Set<Int>) async throws {
        let service = try ScheduleService(dockerPath: cli.binary.path)
        try service.install(RestartSchedule(containerName: containerName, hour: hour, minute: minute, weekdays: weekdays))
    }

    public func removeSchedule(containerName: String) async throws {
        let service = try ScheduleService(dockerPath: cli.binary.path)
        try service.remove(containerName: containerName)
    }

    public func dockerReachable() async -> Bool {
        (try? await cli.run(["version", "--format", "{{.Server.Version}}"], timeout: .seconds(5))) != nil
    }
}
