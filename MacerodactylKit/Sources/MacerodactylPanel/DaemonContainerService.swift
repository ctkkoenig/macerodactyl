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
    /// When set, scheduled restarts are DB-backed (the server deploy, where
    /// launchd does not exist and macerodactyld's in-process cron loop reads the
    /// same rows). When nil, schedules fall back to launchd (macOS-side tools).
    let store: PanelDataStore?
    /// Shared across requests so one attach session per container is reused.
    let consoleHub = ConsoleHub()

    public init(cli: DockerCLI, stacksRoot: URL, store: PanelDataStore? = nil) {
        self.cli = cli
        self.stacksRoot = stacksRoot
        self.store = store
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
            #if canImport(Network)
            let client = RCONClient(endpoint: endpoint)
            do {
                try await client.connect()
                let response = try await client.send(command: command)
                await client.close()
                return ConsoleEntry(command: command, output: response.isEmpty ? "(no response)" : response)
            } catch {
                return ConsoleEntry(command: command, output: "RCON error: \(error)", isError: true)
            }
            #else
            // Linux: the RCON client needs Network.framework; use shell exec.
            _ = endpoint
            return await ExecConsole(containerID: container.id, cli: cli).run(command)
            #endif
        case .unreachable(let reason):
            return ConsoleEntry(command: command, output: "RCON unavailable: \(reason)", isError: true)
        case .notMinecraft:
            return await ExecConsole(containerID: container.id, cli: cli).run(command)
        }
    }

    public func consoleSend(containerName: String, line: String) async -> Bool {
        guard let container = await container(named: containerName), container.isRunning else { return false }
        return await consoleHub.send(cli: cli, containerID: container.id, line: line)
    }

    public func fileService(containerName: String) async -> FileService? {
        guard let container = await container(named: containerName) else { return nil }
        return FileService(container: container, stacksRoot: stacksRoot)
    }

    public func statsSnapshot() async -> [String: ContainerStats] {
        (try? await cli.statsSnapshot()) ?? [:]
    }

    public func limits() async -> [String: ContainerLimits] {
        await cli.containerLimits(ids: await fetchAll().map(\.id))
    }

    public func exitInfo(containerName: String) async -> ContainerExitInfo? {
        guard let container = await container(named: containerName) else { return nil }
        return await cli.inspectState(containerID: container.id)
    }

    public func startedAt(containerName: String) async -> Date? {
        guard let container = await container(named: containerName) else { return nil }
        return await cli.startedAt(containerID: container.id)
    }

    public func executeDatabaseSQL(_ sql: String, engine: DatabaseEngineConfig) async throws {
        let service = ManagedDatabaseService(cli: cli)
        try await service.ensureRunning(config: engine)
        try await service.runSQL(config: engine, sql: sql)
    }

    public func statsStream(containerName: String) async -> AsyncThrowingStream<ContainerStats, Error>? {
        guard let container = await container(named: containerName), container.isRunning else { return nil }
        return cli.statsStream(containerID: container.id)
    }

    public func schedule(containerName: String) async -> (RestartSchedule, ScheduleRunResult?)? {
        // DB-backed on the server; launchd only when no store is wired.
        if let store {
            guard let row = try? store.schedule(containerName: containerName) else { return nil }
            let schedule = RestartSchedule(
                containerName: row.containerName, hour: row.hour, minute: row.minute, weekdays: row.weekdays)
            return (schedule, Self.runResult(from: row))
        }
        guard let service = try? ScheduleService(dockerPath: cli.binary.path),
            let schedule = service.schedule(forContainerName: containerName)
        else { return nil }
        return (schedule, service.lastResult(for: schedule))
    }

    public func setSchedule(containerName: String, hour: Int, minute: Int, weekdays: Set<Int>) async throws {
        if let store {
            try store.upsertSchedule(containerName: containerName, hour: hour, minute: minute, weekdays: weekdays)
            return
        }
        let service = try ScheduleService(dockerPath: cli.binary.path)
        try service.install(RestartSchedule(containerName: containerName, hour: hour, minute: minute, weekdays: weekdays))
    }

    public func removeSchedule(containerName: String) async throws {
        if let store {
            try store.deleteSchedule(containerName: containerName)
            return
        }
        let service = try ScheduleService(dockerPath: cli.binary.path)
        try service.remove(containerName: containerName)
    }

    /// Reconstructs a `ScheduleRunResult` from a persisted schedule's last-run
    /// columns so the web contract (last run date/outcome/message) is unchanged.
    private static func runResult(from row: PanelDataStore.PersistedSchedule) -> ScheduleRunResult? {
        guard let iso = row.lastRunAt else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = formatter.date(from: iso) ?? ISO8601DateFormatter().date(from: iso) ?? Date(timeIntervalSince1970: 0)
        let outcome: ScheduleOutcome =
            switch row.lastOutcome {
            case "ok": .success
            case "timedOut": .timedOut
            case "missed": .missed
            default: .failed
            }
        return ScheduleRunResult(date: date, outcome: outcome, message: row.lastMessage ?? "")
    }

    public func dockerReachable() async -> Bool {
        (try? await cli.run(["version", "--format", "{{.Server.Version}}"], timeout: .seconds(5))) != nil
    }

    public func pullImage(containerName: String) async -> AsyncThrowingStream<String, Error>? {
        guard let container = await container(named: containerName) else { return nil }
        return ContainerLifecycle.pull(cli: cli, container: container)
    }

    public func recreate(containerName: String) async -> AsyncThrowingStream<String, Error>? {
        guard let container = await container(named: containerName) else { return nil }
        return await ContainerLifecycle.composeUp(cli: cli, container: container, forceRecreate: true)
    }

    public func composeApply(containerName: String) async -> AsyncThrowingStream<String, Error>? {
        guard let container = await container(named: containerName) else { return nil }
        return await ContainerLifecycle.composeUp(cli: cli, container: container, forceRecreate: false)
    }

    public func remove(containerName: String) async throws {
        guard let container = await container(named: containerName) else { throw ContainerServiceError.notFound }
        try await ContainerLifecycle.remove(cli: cli, container: container)
    }

    private func stackDir(for name: String) async -> URL? {
        guard let container = await container(named: name), let wd = container.composeWorkingDir, !wd.isEmpty
        else { return nil }
        return URL(fileURLWithPath: wd)
    }

    public func createBackup(containerName: String) async throws -> BackupService.CreatedBackup? {
        guard let dir = await stackDir(for: containerName) else { return nil }
        return try await BackupService.create(cli: cli, stackDir: dir, dataDirName: "data")
    }

    public func restoreBackup(containerName: String, fileName: String) async throws {
        guard let dir = await stackDir(for: containerName) else { throw ContainerServiceError.notFound }
        if let container = await container(named: containerName), container.isRunning {
            try? await power(.stop, containerName: containerName)
        }
        try await BackupService.restore(cli: cli, stackDir: dir, dataDirName: "data", fileName: fileName)
    }

    public func deleteBackupFile(containerName: String, fileName: String) async throws {
        guard let dir = await stackDir(for: containerName) else { return }
        try BackupService.delete(stackDir: dir, fileName: fileName)
    }

    public func backupFileURL(containerName: String, fileName: String) async -> URL? {
        guard let dir = await stackDir(for: containerName) else { return nil }
        return BackupService.fileURL(stackDir: dir, fileName: fileName)
    }

    public func imagePrune() async throws -> String { try await ContainerLifecycle.imagePrune(cli: cli) }
    public func diskUsage() async throws -> String { try await ContainerLifecycle.diskUsage(cli: cli) }

    public func provision(_ spec: ProvisionSpec) async -> AsyncThrowingStream<String, Error> {
        ServerProvisioner(cli: cli, stacksRoot: stacksRoot).provision(spec)
    }

    public func reconfigure(_ spec: ProvisionSpec) async -> AsyncThrowingStream<String, Error> {
        ServerProvisioner(cli: cli, stacksRoot: stacksRoot).reconfigure(spec)
    }

    public func reinstall(_ spec: ProvisionSpec) async -> AsyncThrowingStream<String, Error> {
        if let container = await container(named: spec.name), container.isRunning {
            try? await power(.stop, containerName: spec.name)
        }
        return ServerProvisioner(cli: cli, stacksRoot: stacksRoot).reinstall(spec)
    }

    public func deprovision(name: String) async throws {
        try await ServerProvisioner(cli: cli, stacksRoot: stacksRoot).deprovision(name: name)
    }

    public func stackExists(name: String) async -> Bool {
        FileManager.default.fileExists(atPath: stacksRoot.appendingPathComponent(name).path)
    }
}
