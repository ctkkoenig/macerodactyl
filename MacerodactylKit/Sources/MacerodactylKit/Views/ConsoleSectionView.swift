import SwiftUI

/// The signature screen: power buttons across the top (Start, Restart, Stop, and
/// Kill as a distinct destructive action), a large terminal filling most of the
/// page, and the live stat-card row. The stats update continuously; that
/// liveness is what makes the panel feel alive.
struct ConsoleSectionView: View {
    let store: ContainerStore
    let stats: StatsCoordinator
    let container: DockerContainer

    @State private var showingKillConfirm = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isBusy: Bool { store.busyContainerIDs.contains(container.id) }

    var body: some View {
        VStack(spacing: 0) {
            powerBar
            Divider()
            ConsoleView(store: store, container: container)
                .frame(maxHeight: .infinity)
            Divider()
            StatCardRow(
                stats: stats.focused, availability: stats.focusedAvailability,
                cpuHistory: cpuHistory, memHistory: memHistory, uptime: uptimeString
            )
            .padding(14)
        }
    }

    private var powerBar: some View {
        HStack(spacing: 10) {
            Button("Start", systemImage: "play.fill") { run(.start) }
                .disabled(container.isRunning || isBusy)
            Button("Restart", systemImage: "arrow.clockwise") { run(.restart) }
                .disabled(!container.isRunning || isBusy)
            Button("Stop", systemImage: "stop.fill") { run(.stop) }
                .disabled(!container.isRunning || isBusy)
            Spacer()
            // Kill is set apart — destructive, abrupt, confirmed.
            Button("Kill", systemImage: "bolt.fill", role: .destructive) { showingKillConfirm = true }
                .disabled(!container.isRunning || isBusy)
                .tint(.red)
            if isBusy { ProgressView().controlSize(.small) }
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .labelStyle(.titleAndIcon)
        .padding(14)
        .confirmationDialog("Kill \(container.name)?", isPresented: $showingKillConfirm, titleVisibility: .visible) {
            Button("Kill container", role: .destructive) { run(.kill) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Kill sends SIGKILL immediately — the container has no chance to shut down cleanly. Use Stop for a graceful shutdown.")
        }
    }

    private func run(_ action: ContainerStore.PowerAction) {
        Task { try? await store.perform(action, on: container) }
    }

    private var cpuHistory: [Double] { stats.history.map { min(1, $0.cpuPercent / 100) } }
    private var memHistory: [Double] { stats.history.map { min(1, $0.memPercent / 100) } }
    private var uptimeString: String? { UptimeFormatter.string(since: stats.startedAt) }
}
