import SwiftUI

/// The per-container workspace: a persistent section sidebar (Console, Overview,
/// Logs, Files, Schedules) beside the selected section's detail. You always know
/// which container you're operating on — its name titles the workspace.
struct ContainerWorkspaceView: View {
    let store: ContainerStore
    let stats: StatsCoordinator
    let container: DockerContainer

    enum Section: String, CaseIterable, Identifiable {
        case console = "Console"
        case overview = "Overview"
        case logs = "Logs"
        case files = "Files"
        case schedules = "Schedules"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .console: "terminal"
            case .overview: "square.grid.2x2"
            case .logs: "text.alignleft"
            case .files: "folder"
            case .schedules: "clock.arrow.circlepath"
            }
        }
    }

    @State private var section: Section = .console
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    /// The live container as the store refreshes it (so status/health update).
    private var live: DockerContainer {
        store.groups.all.first { $0.id == container.id } ?? container
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            List(Section.allCases, selection: $section) { item in
                Label(item.rawValue, systemImage: item.symbol)
                    .tag(item)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 240)
            .navigationTitle(live.name)
        } detail: {
            detail
                .navigationTitle(live.name)
                .navigationSubtitle(section.rawValue)
        }
        .task(id: container.id) {
            stats.focus(containerID: container.id, containerName: container.name, running: live.isRunning)
        }
        .onDisappear { stats.unfocus() }
        .onChange(of: live.isRunning) { _, running in
            stats.focus(containerID: container.id, containerName: container.name, running: running)
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch section {
        case .console: ConsoleSectionView(store: store, stats: stats, container: live)
        case .overview: OverviewSectionView(store: store, stats: stats, container: live)
        case .logs: LogsView(store: store, container: live)
        case .files: FilesView(store: store, container: live)
        case .schedules:
            ScrollView { ScheduleSection(store: store, container: live).padding(20) }
        }
    }
}

/// Overview = metadata + the live stat cards (shared component).
struct OverviewSectionView: View {
    let store: ContainerStore
    let stats: StatsCoordinator
    let container: DockerContainer

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                StatCardRow(
                    stats: stats.focused, availability: stats.focusedAvailability,
                    cpuHistory: cpuHistory, memHistory: memHistory, uptime: uptimeString
                )
                metadata
            }
            .padding(20)
        }
    }

    private var metadata: some View {
        Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 8) {
            row("Status", container.status)
            row("Image", container.image)
            row("ID", String(container.id.prefix(12)), mono: true)
            if !container.ports.isEmpty { row("Ports", container.ports) }
            if let project = container.composeProject { row("Stack", project) }
            if let dir = container.composeWorkingDir { row("Directory", dir) }
        }
        .textSelection(.enabled)
    }

    private func row(_ label: String, _ value: String, mono: Bool = false) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            Text(value).font(mono ? .body.monospaced() : .body)
        }
    }

    private var cpuHistory: [Double] { stats.history.map { min(1, $0.cpuPercent / 100) } }
    private var memHistory: [Double] { stats.history.map { min(1, $0.memPercent / 100) } }
    private var uptimeString: String? { UptimeFormatter.string(since: stats.startedAt) }
}

enum UptimeFormatter {
    static func string(since date: Date?) -> String? {
        guard let date else { return nil }
        let seconds = Int(Date().timeIntervalSince(date))
        guard seconds >= 0 else { return nil }
        let d = seconds / 86_400, h = (seconds % 86_400) / 3_600, m = (seconds % 3_600) / 60
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }
}
