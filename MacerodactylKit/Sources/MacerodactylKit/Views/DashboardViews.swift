import SwiftUI

/// Root of the native UI. A NavigationStack whose root is the stack-grouped
/// container landing (the Pterodactyl "server list"); selecting a container
/// pushes its workspace. Owns the shared store and the stats coordinator.
public struct DashboardRootView: View {
    @State private var store: ContainerStore
    @State private var stats: StatsCoordinator
    @State private var path: [String] = []  // container IDs

    public init(store: ContainerStore = ContainerStore()) {
        let store = store
        _store = State(initialValue: store)
        _stats = State(initialValue: StatsCoordinator(cli: { store.cli }))
    }

    public var body: some View {
        NavigationStack(path: $path) {
            landingRoot
                .navigationDestination(for: String.self) { id in
                    if let container = store.groups.all.first(where: { $0.id == id }) {
                        ContainerWorkspaceView(store: store, stats: stats, container: container)
                    } else {
                        ContentUnavailableView(
                            "Container gone", systemImage: "shippingbox",
                            description: Text("This container no longer exists."))
                    }
                }
        }
        .frame(minWidth: 820, minHeight: 560)
        .task {
            store.startPolling()
            await store.refreshAdvisories()
        }
        .onReceive(NotificationCenter.default.publisher(for: .macerodactylSettingsChanged)) { _ in
            store.resolveBinary()
            Task {
                await store.refresh()
                store.startPolling(interval: AppSettings.refreshInterval)
            }
        }
    }

    @ViewBuilder
    private var landingRoot: some View {
        switch store.availability {
        case .binaryNotFound:
            DockerBinaryMissingView(store: store)
        default:
            StacksLandingView(store: store, stats: stats, path: $path)
        }
    }
}

/// The landing: container cards grouped by stack + an Unmanaged group, in a
/// resize-aware grid. This is the top level you always return to.
struct StacksLandingView: View {
    let store: ContainerStore
    let stats: StatsCoordinator
    @Binding var path: [String]

    private let columns = [GridItem(.adaptive(minimum: 240, maximum: 360), spacing: 14)]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 22) {
                ForEach(store.groups.stacks) { stack in
                    VStack(alignment: .leading, spacing: 12) {
                        StackHeader(store: store, stack: stack)
                        grid(stack.containers)
                    }
                }
                if !store.groups.unmanaged.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        sectionLabel("Unmanaged")
                        grid(store.groups.unmanaged)
                    }
                }
            }
            .padding(20)
        }
        .background(.background)
        .navigationTitle("Containers")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await store.refresh() } }
            }
        }
        .overlay { emptyOrDaemonState }
        .task {
            stats.startSnapshotPolling()
        }
        .onDisappear { stats.stopSnapshotPolling() }
    }

    private func grid(_ containers: [DockerContainer]) -> some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
            ForEach(containers) { container in
                Button {
                    path.append(container.id)
                } label: {
                    ContainerCard(
                        container: container,
                        stats: stats.stats(for: container.name),
                        statsAvailable: stats.snapshotAvailable,
                        busy: store.busyContainerIDs.contains(container.id)
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.title3.weight(.semibold))
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var emptyOrDaemonState: some View {
        if store.availability == .daemonDown {
            DaemonDownView(store: store)
                .background(.background)
        } else if store.groups.isEmpty && store.availability == .ready {
            if store.advisories.contains(where: { $0.id == "stacks-missing" }) {
                AdvisoryListView(advisories: store.advisories)
            } else {
                ContentUnavailableView(
                    "No containers", systemImage: "shippingbox",
                    description: Text("Compose stacks and docker run containers both appear here once they exist."))
            }
        }
    }
}

struct StackHeader: View {
    let store: ContainerStore
    let stack: ContainerStack

    var body: some View {
        HStack {
            Text(stack.name)
                .font(.title3.weight(.semibold))
            Text("\(stack.runningCount)/\(stack.containers.count) running")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Menu {
                Button("Start stack") { run(.start) }
                Button("Stop stack") { run(.stop) }
                Button("Restart stack") { run(.restart) }
            } label: {
                Label("Stack actions", systemImage: "ellipsis.circle")
                    .labelStyle(.iconOnly)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func run(_ action: ContainerStore.PowerAction) {
        Task { try? await store.perform(action, on: stack) }
    }
}

struct DaemonDownView: View {
    let store: ContainerStore

    var body: some View {
        ContentUnavailableView {
            Label("Docker isn’t running", systemImage: "exclamationmark.triangle")
        } description: {
            Text(
                "Start Docker Desktop (or your Docker provider) and wait for it to finish launching. Macerodactyl never starts the daemon or your containers itself."
            )
        } actions: {
            Button("Check again") { Task { await store.refresh() } }
        }
    }
}

struct DockerBinaryMissingView: View {
    let store: ContainerStore
    @State private var overridePath: String = AppSettings.dockerPathOverride ?? ""

    var body: some View {
        ContentUnavailableView {
            Label("Docker CLI not found", systemImage: "questionmark.folder")
        } description: {
            Text("Looked in ~/.orbstack/bin, /opt/homebrew/bin, and /usr/local/bin. If docker lives elsewhere, point Macerodactyl at it.")
        } actions: {
            HStack {
                TextField("Path to docker binary", text: $overridePath)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 280)
                Button("Use this path") {
                    AppSettings.dockerPathOverride = overridePath
                    store.resolveBinary()
                    Task { await store.refresh() }
                }
                .disabled(overridePath.isEmpty)
            }
        }
    }
}

/// Cold-start advisories (unchanged behavior).
struct AdvisoryListView: View {
    let advisories: [StartupAdvisory]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(advisories) { advisory in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: icon(advisory.severity))
                            .foregroundStyle(color(advisory.severity))
                            .font(.title3)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(advisory.title).font(.headline)
                            Text(advisory.detail).foregroundStyle(.secondary)
                            Text(advisory.remedy).font(.callout)
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(color(advisory.severity).opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                }
            }
            .padding(20)
        }
        .background(.background)
    }

    private func icon(_ s: StartupAdvisory.Severity) -> String {
        switch s {
        case .blocking: "exclamationmark.octagon.fill"
        case .degraded: "exclamationmark.triangle.fill"
        case .info: "info.circle.fill"
        }
    }
    private func color(_ s: StartupAdvisory.Severity) -> Color {
        switch s {
        case .blocking: .red
        case .degraded: .orange
        case .info: .blue
        }
    }
}
