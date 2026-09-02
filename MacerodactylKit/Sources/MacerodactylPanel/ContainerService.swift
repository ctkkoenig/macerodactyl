import Foundation
import MacerodactylKit

/// What the web routes need from the container layer. Abstracted so routes are
/// testable with a fake, and so the live implementation can route mutations
/// through the shared native store (a phone action then updates open native
/// windows live). Every implementation uses the SAME FileService and path
/// confinement as the native app — never a parallel one.
public protocol ContainerService: Sendable {
    /// All containers currently known (unfiltered; callers scope via the engine).
    func allContainers() async -> [DockerContainer]
    /// Look up one by name, or nil if it genuinely doesn't exist.
    func container(named name: String) async -> DockerContainer?
    /// Power action, routed so shared state updates live. Throws on failure.
    func power(_ action: ContainerStore.PowerAction, containerName: String) async throws
    /// A live log line stream that tears its docker process down when the
    /// consuming task is cancelled (client disconnect).
    func logLines(containerName: String) async -> AsyncThrowingStream<String, Error>?
    /// Run one console command (exec, or RCON for Minecraft).
    func runConsole(containerName: String, command: String) async -> ConsoleEntry?
    /// File service for a container, or nil if it has no stack folder.
    func fileService(containerName: String) async -> FileService?
    /// Live stats snapshot for all containers (for the landing).
    func statsSnapshot() async -> [String: ContainerStats]
    /// Live stats stream for one container (for the focused view).
    func statsStream(containerName: String) async -> AsyncThrowingStream<ContainerStats, Error>?
    /// The current schedule for a container, if any, plus its last run.
    func schedule(containerName: String) async -> (RestartSchedule, ScheduleRunResult?)?
    /// Install/replace a schedule. Throws on failure.
    func setSchedule(containerName: String, hour: Int, minute: Int, weekdays: Set<Int>) async throws
    /// Remove a container's schedule (no-op if none).
    func removeSchedule(containerName: String) async throws
}

/// Live implementation backed by the shared `ContainerStore` (native source of
/// truth) plus the docker CLI. Power actions go through the store so its
/// `groups` update and open native windows refresh without a manual reload.
public struct LiveContainerService: ContainerService {
    let store: ContainerStore
    let stacksRoot: @Sendable () -> URL

    public init(store: ContainerStore, stacksRoot: @escaping @Sendable () -> URL = { AppSettings.stacksRoot }) {
        self.store = store
        self.stacksRoot = stacksRoot
    }

    public func allContainers() async -> [DockerContainer] {
        await MainActor.run { store.groups.all }
    }

    public func container(named name: String) async -> DockerContainer? {
        await MainActor.run { store.groups.all.first { $0.name == name } }
    }

    public func power(_ action: ContainerStore.PowerAction, containerName: String) async throws {
        guard let container = await container(named: containerName) else {
            throw ContainerServiceError.notFound
        }
        try await MainActor.run { store }.perform(action, on: container)
    }

    public func logLines(containerName: String) async -> AsyncThrowingStream<String, Error>? {
        guard let container = await container(named: containerName),
              let cli = await MainActor.run(body: { store.cli }) else { return nil }
        return LogStreamService.lines(for: container.id, cli: cli)
    }

    public func runConsole(containerName: String, command: String) async -> ConsoleEntry? {
        guard let container = await container(named: containerName),
              let cli = await MainActor.run(body: { store.cli }) else { return nil }
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
        return FileService(container: container, stacksRoot: stacksRoot())
    }

    public func statsSnapshot() async -> [String: ContainerStats] {
        guard let cli = await MainActor.run(body: { store.cli }) else { return [:] }
        return (try? await cli.statsSnapshot()) ?? [:]
    }

    public func statsStream(containerName: String) async -> AsyncThrowingStream<ContainerStats, Error>? {
        guard let container = await container(named: containerName), container.isRunning,
              let cli = await MainActor.run(body: { store.cli }) else { return nil }
        return cli.statsStream(containerID: container.id)
    }

    public func schedule(containerName: String) async -> (RestartSchedule, ScheduleRunResult?)? {
        guard let cli = await MainActor.run(body: { store.cli }),
              let service = try? ScheduleService(dockerPath: cli.binary.path),
              let schedule = service.schedule(forContainerName: containerName) else { return nil }
        return (schedule, service.lastResult(for: schedule))
    }

    public func setSchedule(containerName: String, hour: Int, minute: Int, weekdays: Set<Int>) async throws {
        guard let cli = await MainActor.run(body: { store.cli }) else { throw ContainerServiceError.notFound }
        let service = try ScheduleService(dockerPath: cli.binary.path)
        try service.install(RestartSchedule(containerName: containerName, hour: hour, minute: minute, weekdays: weekdays))
    }

    public func removeSchedule(containerName: String) async throws {
        guard let cli = await MainActor.run(body: { store.cli }) else { throw ContainerServiceError.notFound }
        let service = try ScheduleService(dockerPath: cli.binary.path)
        try service.remove(containerName: containerName)
    }
}

public enum ContainerServiceError: Error, Equatable, Sendable {
    case notFound
}

/// Client-facing messages for file errors, matching the native app's wording.
enum FileServiceMessage {
    static func describe(_ error: Error) -> String {
        switch error {
        case FileServiceError.tooLarge(let actual, let limit):
            let fmt = ByteCountFormatter()
            return "This file is \(fmt.string(fromByteCount: Int64(actual))) — larger than the \(fmt.string(fromByteCount: Int64(limit))) editing limit."
        case FileServiceError.binaryFile: return "This looks like a binary file; the editor only opens text."
        case FileServiceError.notFound: return "The file no longer exists."
        case FileServiceError.isDirectory: return "That's a directory."
        case FileServiceError.notARegularFile: return "Not a regular file."
        case FileServiceError.escapesRoot, FileServiceError.invalidPath: return "That path is outside the stack folder and was blocked."
        case FileServiceError.io(let detail): return "File error: \(detail)"
        default: return "\(error)"
        }
    }
}
