import Foundation
import MacerodactylKit
import Testing

@testable import MacerodactylPanel

@Suite struct MetricsSamplerTests {
    private func makeStore() throws -> PanelDataStore {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try PanelDataStore(databasePath: dir.appending(path: "m.sqlite").path)
    }

    private func runningFixtures() -> [String: FakeContainerService.Fixture] {
        let bot = DockerContainer(
            id: "c1", name: "bot", image: "img", state: .running, status: "Up",
            health: nil, ports: "", composeProject: "p", composeService: "bot", composeWorkingDir: nil)
        let stopped = DockerContainer(
            id: "c2", name: "idle", image: "img", state: .exited, status: "Exited (0)",
            health: nil, ports: "", composeProject: "p", composeService: "idle", composeWorkingDir: nil)
        return [
            "bot": .init(container: bot, stackRoot: nil),
            "idle": .init(container: stopped, stackRoot: nil),
        ]
    }

    @Test func sampleOnceRecordsRunningContainersOnly() async throws {
        let store = try makeStore()
        let service = FakeContainerService(fixtures: runningFixtures())
        let sampler = MetricsSampler(store: store, containers: service)

        let count = await sampler.sampleOnce()
        #expect(count == 1)  // only the running container
        #expect(try store.metrics(container: "bot").count == 1)
        #expect(try store.metrics(container: "idle").isEmpty)  // stopped → no reading
    }

    @Test func pruneFiresOnScheduleAndBoundsRows() async throws {
        let store = try makeStore()
        let service = FakeContainerService(fixtures: runningFixtures())
        // Tiny cap + prune every tick so the bound is observable deterministically.
        let sampler = MetricsSampler(
            store: store, containers: service, retention: 365 * 24 * 3_600, maxPerContainer: 3, pruneEvery: 1)
        for _ in 0..<10 { await sampler.sampleOnce() }
        // 10 samples recorded, but the per-container cap holds it to 3.
        #expect(try store.metrics(container: "bot").count == 3)
    }
}
