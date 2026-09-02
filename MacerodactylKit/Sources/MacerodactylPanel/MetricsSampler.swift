import Foundation
import MacerodactylKit

/// Periodically samples resource stats for every running container and appends
/// them to the retained-metrics table, so the panel has a history beyond the
/// live stream even when nobody is watching. One `docker stats --no-stream`
/// process per tick (all containers at once), on a deliberately slow cadence,
/// and it prunes on a schedule so the table can never fill the disk.
///
/// Read-only: it never starts, stops, or otherwise touches a container. Its
/// lifetime is tied to the panel process (started with the server, cancelled on
/// shutdown), so it never outlives a quit.
public actor MetricsSampler {
    private let store: PanelDataStore
    private let containers: ContainerService
    private let interval: Duration
    private let retention: TimeInterval
    private let maxPerContainer: Int
    /// Prune every this-many ticks rather than every tick (pruning is a delete
    /// over the whole table; no need to run it constantly).
    private let pruneEvery: Int

    private var task: Task<Void, Never>?
    private var ticksSincePrune = 0

    public init(
        store: PanelDataStore,
        containers: ContainerService,
        interval: Duration = .seconds(20),
        retention: TimeInterval = 24 * 60 * 60,
        maxPerContainer: Int = 5_000,
        pruneEvery: Int = 30
    ) {
        self.store = store
        self.containers = containers
        self.interval = interval
        self.retention = retention
        self.maxPerContainer = maxPerContainer
        self.pruneEvery = max(1, pruneEvery)
    }

    public func start() {
        guard task == nil else { return }
        task = Task { [weak self] in await self?.loop() }
    }

    public func stop() {
        task?.cancel()
        task = nil
    }

    /// One sampling pass, exposed for tests to drive deterministically without
    /// waiting on the timer. Records every current sample; prunes on schedule.
    @discardableResult
    public func sampleOnce() async -> Int {
        let snapshot = await containers.statsSnapshot()
        for sample in snapshot.values {
            try? store.recordMetric(sample)
        }
        ticksSincePrune += 1
        if ticksSincePrune >= pruneEvery {
            try? store.pruneMetrics(maxAge: retention, maxPerContainer: maxPerContainer)
            ticksSincePrune = 0
        }
        return snapshot.count
    }

    private func loop() async {
        // Prune once at startup so a long downtime's stale rows go promptly.
        try? store.pruneMetrics(maxAge: retention, maxPerContainer: maxPerContainer)
        while !Task.isCancelled {
            _ = await sampleOnce()
            try? await Task.sleep(for: interval)
        }
    }
}
