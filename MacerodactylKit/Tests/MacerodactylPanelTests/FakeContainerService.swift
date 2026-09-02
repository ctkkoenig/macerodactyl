import Foundation
import MacerodactylKit
@testable import MacerodactylPanel

/// In-memory container service for HTTP tests. Records power actions, serves
/// canned logs/console, and backs files with a real temp directory so the SAME
/// FileService + PathConfinement run over HTTP as in the native app.
final class FakeContainerService: ContainerService, @unchecked Sendable {
    struct Fixture {
        let container: DockerContainer
        let stackRoot: URL?   // nil = no file access (bare container)
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

    func runConsole(containerName: String, command: String) async -> ConsoleEntry? {
        guard fixtures[containerName] != nil else { return nil }
        return ConsoleEntry(command: command, output: "ran: \(command)")
    }

    func fileService(containerName: String) async -> FileService? {
        guard let fixture = fixtures[containerName], let root = fixture.stackRoot else { return nil }
        return FileService(container: fixture.container, stacksRoot: root.deletingLastPathComponent())
    }

    // Stats + schedules for the container-feature tests.
    private(set) var scheduleCalls: [(op: String, name: String)] = []

    func statsSnapshot() async -> [String: ContainerStats] {
        var out: [String: ContainerStats] = [:]
        for (name, fixture) in fixtures where fixture.container.isRunning {
            out[name] = ContainerStats(name: name, cpuPercent: 1, memUsedBytes: 1_000_000,
                                       memLimitBytes: 10_000_000, memPercent: 10, netRxBytes: 100,
                                       netTxBytes: 50, pids: 3)
        }
        return out
    }

    func statsStream(containerName: String) async -> AsyncThrowingStream<ContainerStats, Error>? {
        guard let fixture = fixtures[containerName], fixture.container.isRunning else { return nil }
        return AsyncThrowingStream { continuation in
            continuation.yield(ContainerStats(name: containerName, cpuPercent: 2, memUsedBytes: 2_000_000,
                memLimitBytes: 10_000_000, memPercent: 20, netRxBytes: 200, netTxBytes: 100, pids: 4))
            continuation.finish()
        }
    }

    func schedule(containerName: String) async -> (RestartSchedule, ScheduleRunResult?)? { nil }
    func setSchedule(containerName: String, hour: Int, minute: Int, weekdays: Set<Int>) async throws {
        lock.withLock { scheduleCalls.append(("set", containerName)) }
    }
    func removeSchedule(containerName: String) async throws {
        lock.withLock { scheduleCalls.append(("remove", containerName)) }
    }
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
