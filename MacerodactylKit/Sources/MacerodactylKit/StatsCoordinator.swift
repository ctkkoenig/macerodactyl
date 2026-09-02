import Foundation
import Observation

/// Availability of a stats reading, so the UI can say "Unavailable" rather than
/// show a zero it never measured.
public enum StatsAvailability: Sendable, Equatable {
    case measuring  // stream started, no sample yet
    case available  // have a real reading
    case unavailable(String)  // daemon down, container stopped, or stats failed
}

/// Owns live resource stats for the UI. Two independent facilities:
/// - a **landing snapshot** map, refreshed on a slow cadence and only while the
///   landing is visible (`startSnapshotPolling`/`stopSnapshotPolling`);
/// - a **focused stream** for the one container whose Console/Overview is open,
///   exposing the latest sample plus a bounded history of *measured* samples
///   for a sparkline (never backfilled).
@MainActor
@Observable
public final class StatsCoordinator {
    private let cli: () -> DockerCLI?

    public init(cli: @escaping () -> DockerCLI?) {
        self.cli = cli
    }

    // MARK: Landing snapshot

    public private(set) var snapshot: [String: ContainerStats] = [:]
    public private(set) var snapshotAvailable = false
    private var snapshotTask: Task<Void, Never>?

    public func stats(for name: String) -> ContainerStats? { snapshot[name] }

    public func startSnapshotPolling(interval: TimeInterval = 5) {
        snapshotTask?.cancel()
        snapshotTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshSnapshot()
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    public func stopSnapshotPolling() {
        snapshotTask?.cancel()
        snapshotTask = nil
    }

    private func refreshSnapshot() async {
        guard let cli = cli() else {
            snapshotAvailable = false
            return
        }
        if let readings = try? await cli.statsSnapshot() {
            snapshot = readings
            snapshotAvailable = true
        } else {
            snapshotAvailable = false
        }
    }

    // MARK: Focused stream

    public private(set) var focused: ContainerStats?
    public private(set) var focusedAvailability: StatsAvailability = .measuring
    public private(set) var history: [ContainerStats] = []  // measured samples only
    public private(set) var startedAt: Date?
    public let historyCap = 60
    private var focusTask: Task<Void, Never>?
    private var focusedContainerID: String?

    /// Begin streaming stats for one container. Safe to call repeatedly; a new
    /// container replaces the old stream (tearing down its docker process).
    public func focus(containerID: String, containerName: String, running: Bool) {
        guard focusedContainerID != containerID else { return }
        unfocus()
        focusedContainerID = containerID
        history = []
        focused = nil
        guard let cli = cli() else {
            focusedAvailability = .unavailable("Docker isn’t available.")
            return
        }
        guard running else {
            focusedAvailability = .unavailable("Container isn’t running.")
            return
        }
        focusedAvailability = .measuring

        focusTask = Task { [weak self] in
            async let started = cli.startedAt(containerID: containerID)
            await MainActor.run { [weak self] in self?.startedAt = nil }
            let startDate = await started
            await MainActor.run { [weak self] in self?.startedAt = startDate }
            do {
                for try await sample in cli.statsStream(containerID: containerID) {
                    guard let self, !Task.isCancelled else { return }
                    self.focused = sample
                    self.focusedAvailability = .available
                    self.history.append(sample)
                    if self.history.count > self.historyCap { self.history.removeFirst(self.history.count - self.historyCap) }
                }
                self?.focusedAvailability = .unavailable("Stats stream ended.")
            } catch is CancellationError {
                // Left the screen — nothing to report.
            } catch {
                self?.focusedAvailability = .unavailable("Stats unavailable.")
            }
        }
    }

    public func unfocus() {
        focusTask?.cancel()
        focusTask = nil
        focusedContainerID = nil
        startedAt = nil
    }
}
