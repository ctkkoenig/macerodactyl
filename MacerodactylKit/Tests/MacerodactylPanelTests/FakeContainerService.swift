import Foundation
import MacerodactylKit

@testable import MacerodactylPanel

/// In-memory container service for HTTP tests. Records power actions, serves
/// canned logs/console, and backs files with a real temp directory so the SAME
/// FileService + PathConfinement run over HTTP as in the native app.
final class FakeContainerService: ContainerService, @unchecked Sendable {
    struct Fixture {
        let container: DockerContainer
        let stackRoot: URL?  // nil = no file access (bare container)
    }

    private let lock = NSLock()
    private(set) var powerCalls: [(action: ContainerStore.PowerAction, name: String)] = []
    var fixtures: [String: Fixture]

    init(fixtures: [String: Fixture]) { self.fixtures = fixtures }

    func allContainers() async -> [DockerContainer] {
        fixtures.values.map(\.container).sorted { $0.name < $1.name }
    }
    func container(named name: String) async -> DockerContainer? { fixtures[name]?.container }

    func power(_ action: ContainerStore.PowerAction, containerName: String) async throws {
        guard fixtures[containerName] != nil else { throw ContainerServiceError.notFound }
        lock.withLock { powerCalls.append((action, containerName)) }
    }

    func logLines(containerName: String) async -> AsyncThrowingStream<String, Error>? {
        guard fixtures[containerName] != nil else { return nil }
        return AsyncThrowingStream { continuation in
            continuation.yield("log line 1")
            continuation.yield("log line 2")
            continuation.finish()
        }
    }

    var cannedLogHistory: [String: String] = [:]
    func logHistory(containerName: String, tail: Int, since: String?) async -> String? {
        guard fixtures[containerName] != nil else { return nil }
        if let canned = cannedLogHistory[containerName] { return canned }
        return [
            "2026-09-02T10:00:00Z starting up",
            "2026-09-02T10:00:01Z listening on 8080",
            "2026-09-02T10:00:02Z ERROR failed to connect to db",
            "2026-09-02T10:00:03Z retrying",
        ].joined(separator: "\n")
    }

    func runConsole(containerName: String, command: String) async -> ConsoleEntry? {
        guard fixtures[containerName] != nil else { return nil }
        return ConsoleEntry(command: command, output: "ran: \(command)")
    }

    private(set) var consoleInput: [(name: String, line: String)] = []
    func consoleSend(containerName: String, line: String) async -> Bool {
        guard let fixture = fixtures[containerName], fixture.container.isRunning else { return false }
        lock.withLock { consoleInput.append((containerName, line)) }
        return true
    }

    func fileService(containerName: String) async -> FileService? {
        guard let fixture = fixtures[containerName], let root = fixture.stackRoot else { return nil }
        return FileService(container: fixture.container, stacksRoot: root.deletingLastPathComponent())
    }

    // Stats + schedules for the container-feature tests.
    private(set) var scheduleCalls: [(op: String, name: String)] = []

    var cannedLimits: [String: ContainerLimits] = [
        "bot": ContainerLimits(memoryBytes: 512 * 1024 * 1024, cpuCores: 2)  // "secret" left unlimited
    ]
    func limits() async -> [String: ContainerLimits] { cannedLimits }
    var cannedExitInfo: [String: ContainerExitInfo] = [:]
    func exitInfo(containerName: String) async -> ContainerExitInfo? { cannedExitInfo[containerName] }
    var cannedStartedAt: [String: Date] = [:]
    func startedAt(containerName: String) async -> Date? { cannedStartedAt[containerName] }

    func statsSnapshot() async -> [String: ContainerStats] {
        var out: [String: ContainerStats] = [:]
        for (name, fixture) in fixtures where fixture.container.isRunning {
            out[name] = ContainerStats(
                name: name, cpuPercent: 1, memUsedBytes: 1_000_000,
                memLimitBytes: 10_000_000, memPercent: 10, netRxBytes: 100,
                netTxBytes: 50, pids: 3)
        }
        return out
    }

    func statsStream(containerName: String) async -> AsyncThrowingStream<ContainerStats, Error>? {
        guard let fixture = fixtures[containerName], fixture.container.isRunning else { return nil }
        return AsyncThrowingStream { continuation in
            continuation.yield(
                ContainerStats(
                    name: containerName, cpuPercent: 2, memUsedBytes: 2_000_000,
                    memLimitBytes: 10_000_000, memPercent: 20, netRxBytes: 200, netTxBytes: 100, pids: 4))
            continuation.finish()
        }
    }

    var dockerIsReachable = true
    func dockerReachable() async -> Bool { dockerIsReachable }

    private var currentSchedules: [String: RestartSchedule] = [:]
    func schedule(containerName: String) async -> (RestartSchedule, ScheduleRunResult?)? {
        lock.withLock { currentSchedules[containerName] }.map { ($0, nil) }
    }
    func setSchedule(containerName: String, hour: Int, minute: Int, weekdays: Set<Int>) async throws {
        lock.withLock {
            scheduleCalls.append(("set", containerName))
            currentSchedules[containerName] = RestartSchedule(
                containerName: containerName, hour: hour, minute: minute, weekdays: weekdays)
        }
    }
    func removeSchedule(containerName: String) async throws {
        lock.withLock {
            scheduleCalls.append(("remove", containerName))
            currentSchedules[containerName] = nil
        }
    }

    // Lifecycle — records the op and streams a couple of canned progress lines.
    private(set) var lifecycleCalls: [(op: String, name: String)] = []
    private func cannedStream(_ lines: [String]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            for line in lines { continuation.yield(line) }
            continuation.finish()
        }
    }

    func pullImage(containerName: String) async -> AsyncThrowingStream<String, Error>? {
        guard fixtures[containerName] != nil else { return nil }
        lock.withLock { lifecycleCalls.append(("pull", containerName)) }
        return cannedStream(["Pulling img:latest", "Pull complete"])
    }
    func recreate(containerName: String) async -> AsyncThrowingStream<String, Error>? {
        guard fixtures[containerName] != nil else { return nil }
        lock.withLock { lifecycleCalls.append(("recreate", containerName)) }
        return cannedStream(["Recreating", "Started"])
    }
    func composeApply(containerName: String) async -> AsyncThrowingStream<String, Error>? {
        guard fixtures[containerName] != nil else { return nil }
        lock.withLock { lifecycleCalls.append(("compose", containerName)) }
        return cannedStream(["Applying compose", "Done"])
    }
    func remove(containerName: String) async throws {
        guard let fixture = fixtures[containerName] else { throw ContainerServiceError.notFound }
        guard !fixture.container.isRunning else { throw ContainerServiceError.conflict("running") }
        lock.withLock { lifecycleCalls.append(("remove", containerName)) }
    }

    private(set) var backupCalls: [(op: String, name: String, file: String)] = []
    func createBackup(containerName: String) async throws -> BackupService.CreatedBackup? {
        guard fixtures[containerName] != nil else { return nil }
        let uuid = UUID().uuidString
        lock.withLock { backupCalls.append(("create", containerName, uuid)) }
        return BackupService.CreatedBackup(uuid: uuid, fileName: "\(uuid).tar.gz", bytes: 2048)
    }
    func restoreBackup(containerName: String, fileName: String) async throws {
        lock.withLock { backupCalls.append(("restore", containerName, fileName)) }
    }
    func deleteBackupFile(containerName: String, fileName: String) async throws {
        lock.withLock { backupCalls.append(("delete", containerName, fileName)) }
    }
    func backupFileURL(containerName: String, fileName: String) async -> URL? { nil }

    var pruneResult = "Total reclaimed space: 1.2GB"
    var diskResult = "TYPE  TOTAL  ACTIVE  SIZE  RECLAIMABLE"
    func imagePrune() async throws -> String {
        lock.withLock { lifecycleCalls.append(("image-prune", "*")) }
        return pruneResult
    }
    func diskUsage() async throws -> String { diskResult }

    // Provisioning — records the spec and streams a scripted install log so route
    // tests run end-to-end without docker. `existingStacks` simulates name clashes.
    private(set) var provisionSpecs: [ProvisionSpec] = []
    private(set) var deprovisioned: [String] = []
    var existingStacks: Set<String> = []
    var provisionShouldFail = false
    func provision(_ spec: ProvisionSpec) async -> AsyncThrowingStream<String, Error> {
        lock.withLock { provisionSpecs.append(spec) }
        if provisionShouldFail {
            return AsyncThrowingStream { continuation in
                continuation.yield("» Preparing \(spec.name)…")
                continuation.yield("✖ Provisioning failed: docker exited 1")
                continuation.finish(throwing: ContainerServiceError.unavailable("install failed"))
            }
        }
        return cannedStream(["» Preparing \(spec.name)…", "» Starting the server…", "✔ Server \"\(spec.name)\" created."])
    }
    private(set) var reconfigured: [ProvisionSpec] = []
    private(set) var reinstalled: [ProvisionSpec] = []
    func reconfigure(_ spec: ProvisionSpec) async -> AsyncThrowingStream<String, Error> {
        lock.withLock { reconfigured.append(spec) }
        return cannedStream(["» Applying changes…", "✔ Server \"\(spec.name)\" updated."])
    }
    func reinstall(_ spec: ProvisionSpec) async -> AsyncThrowingStream<String, Error> {
        lock.withLock { reinstalled.append(spec) }
        return cannedStream(["» Re-running egg install…", "✔ Server \"\(spec.name)\" reinstalled."])
    }
    func deprovision(name: String) async throws {
        lock.withLock { deprovisioned.append(name) }
    }
    func stackExists(name: String) async -> Bool { existingStacks.contains(name) }
}

extension DockerContainer {
    static func fixture(name: String, workingDir: String? = nil, running: Bool = true) -> DockerContainer {
        DockerContainer(
            id: name + "-id", name: name, image: "img:latest",
            state: running ? .running : .exited, status: running ? "Up 2 minutes" : "Exited (0)",
            health: nil, ports: "0.0.0.0:80->80/tcp", composeProject: workingDir != nil ? "stack" : nil,
            composeService: nil, composeWorkingDir: workingDir
        )
    }
}
