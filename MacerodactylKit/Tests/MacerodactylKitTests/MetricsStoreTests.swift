import Foundation
import Testing

@testable import MacerodactylKit

@Suite struct MetricsStoreTests {
    private func store() throws -> PanelDataStore {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try PanelDataStore(databasePath: dir.appending(path: "m.sqlite").path)
    }

    private func sample(_ name: String, cpu: Double, at: Date) -> ContainerStats {
        ContainerStats(
            name: name, cpuPercent: cpu, memUsedBytes: 1_000, memLimitBytes: 2_000,
            memPercent: 50, netRxBytes: 10, netTxBytes: 20, pids: 3, measuredAt: at)
    }

    @Test func recordsAndReadsBackOldestToNewest() throws {
        let db = try store()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        try db.recordMetric(sample("bot", cpu: 1, at: t0))
        try db.recordMetric(sample("bot", cpu: 2, at: t0.addingTimeInterval(20)))
        try db.recordMetric(sample("bot", cpu: 3, at: t0.addingTimeInterval(40)))
        try db.recordMetric(sample("other", cpu: 9, at: t0))  // different container

        let series = try db.metrics(container: "bot")
        #expect(series.map(\.cpuPercent) == [1, 2, 3])  // oldest→newest
        #expect(series.allSatisfy { $0.name == "bot" })  // no cross-container leak
        #expect(try db.metrics(container: "other").count == 1)
    }

    @Test func sinceFilterExcludesOlderSamples() throws {
        let db = try store()
        let now = Date()
        try db.recordMetric(sample("bot", cpu: 1, at: now.addingTimeInterval(-3_600)))  // 1h ago
        try db.recordMetric(sample("bot", cpu: 2, at: now.addingTimeInterval(-60)))  // 1m ago
        let recent = try db.metrics(container: "bot", since: now.addingTimeInterval(-300))
        #expect(recent.map(\.cpuPercent) == [2])
    }

    @Test func pruneByAgeDropsOldSamples() throws {
        let db = try store()
        let now = Date()
        try db.recordMetric(sample("bot", cpu: 1, at: now.addingTimeInterval(-48 * 3_600)))  // 2 days
        try db.recordMetric(sample("bot", cpu: 2, at: now.addingTimeInterval(-60)))  // fresh
        try db.pruneMetrics(maxAge: 24 * 3_600, maxPerContainer: 10_000)
        #expect(try db.metrics(container: "bot").map(\.cpuPercent) == [2])
    }

    @Test func pruneByPerContainerCapKeepsNewest() throws {
        let db = try store()
        let t0 = Date()
        for i in 0..<50 {
            try db.recordMetric(sample("bot", cpu: Double(i), at: t0.addingTimeInterval(Double(i))))
        }
        try db.pruneMetrics(maxAge: 365 * 24 * 3_600, maxPerContainer: 10)
        let kept = try db.metrics(container: "bot")
        #expect(kept.count == 10)
        #expect(kept.map(\.cpuPercent) == Array(40..<50).map(Double.init))  // newest 10
        #expect(try db.metricsCount() == 10)
    }
}
