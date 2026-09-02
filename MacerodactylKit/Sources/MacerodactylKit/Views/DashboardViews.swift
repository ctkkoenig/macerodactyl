import SwiftUI

/// Root of the native UI. Owns the store; the app target just instantiates this.
public struct DashboardRootView: View {
    @State private var store = ContainerStore()
    @State private var selectedContainerID: String?

    public init() {}

    public var body: some View {
        Group {
            switch store.availability {
            case .binaryNotFound:
                DockerBinaryMissingView(store: store)
            default:
                dashboard
            }
        }
        .frame(minWidth: 760, minHeight: 460)
        .task {
            store.startPolling()
        }
    }

    private var dashboard: some View {
        NavigationSplitView {
            SidebarView(store: store, selectedContainerID: $selectedContainerID)
                .navigationSplitViewColumnWidth(min: 230, ideal: 270)
        } detail: {
            if let container = store.groups.all.first(where: { $0.id == selectedContainerID }) {
                ContainerDetailView(store: store, container: container)
            } else if store.availability == .daemonDown {
                DaemonDownView(store: store)
            } else {
                ContentUnavailableView(
                    "Select a container",
                    systemImage: "shippingbox",
                    description: Text("Pick a container from the sidebar to inspect and control it.")
                )
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Refresh", systemImage: "arrow.clockwise") {
                    Task { await store.refresh() }
                }
                .help("Refresh now")
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let error = store.lastError {
                ErrorBanner(message: error) { store.clearError() }
            }
        }
    }
}

struct SidebarView: View {
    let store: ContainerStore
    @Binding var selectedContainerID: String?

    var body: some View {
        List(selection: $selectedContainerID) {
            if store.availability == .daemonDown {
                Label("Docker isn't running", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
            }
            ForEach(store.groups.stacks) { stack in
                Section {
                    ForEach(stack.containers) { container in
                        ContainerRowView(store: store, container: container)
                            .tag(container.id)
                    }
                } header: {
                    StackHeaderView(store: store, stack: stack)
                }
            }
            if !store.groups.unmanaged.isEmpty {
                Section("Unmanaged") {
                    ForEach(store.groups.unmanaged) { container in
                        ContainerRowView(store: store, container: container)
                            .tag(container.id)
                    }
                }
            }
        }
        .overlay {
            if store.groups.isEmpty && store.availability == .ready {
                ContentUnavailableView(
                    "No containers",
                    systemImage: "shippingbox",
                    description: Text("Nothing is defined yet. Compose stacks and docker run containers both show up here.")
                )
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            WordmarkFooter()
        }
    }
}

/// Branding assets bundled with the Kit (also served by the web panel later).
/// Two wordmarks ship: the light one for dark backgrounds, the dark one for
/// light backgrounds — pick by current appearance, never hope one fits both.
public enum Brand {
    public static let wordmarkLight: NSImage? = load("wordmark-light")
    public static let wordmarkDark: NSImage? = load("wordmark-dark")

    public static func wordmark(for colorScheme: ColorScheme) -> NSImage? {
        colorScheme == .dark ? wordmarkLight : wordmarkDark
    }

    private static func load(_ name: String) -> NSImage? {
        Bundle.module.url(forResource: name, withExtension: "png").flatMap { NSImage(contentsOf: $0) }
    }
}

struct WordmarkFooter: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if let wordmark = Brand.wordmark(for: colorScheme) {
            Image(nsImage: wordmark)
                .resizable()
                .scaledToFit()
                .frame(maxHeight: 22)
                .padding(.vertical, 10)
                .padding(.horizontal, 14)
                .frame(maxWidth: .infinity)
        }
    }
}

struct StackHeaderView: View {
    let store: ContainerStore
    let stack: ContainerStack

    var body: some View {
        HStack {
            Text(stack.name)
            Spacer()
            Text("\(stack.runningCount)/\(stack.containers.count)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Menu {
                Button("Start stack") { run(.start) }
                Button("Stop stack") { run(.stop) }
                Button("Restart stack") { run(.restart) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    private func run(_ action: ContainerStore.PowerAction) {
        Task { try? await store.perform(action, on: stack) }
    }
}

struct ContainerRowView: View {
    let store: ContainerStore
    let container: DockerContainer

    var body: some View {
        HStack(spacing: 8) {
            StatusDot(container: container)
            VStack(alignment: .leading, spacing: 1) {
                Text(container.name)
                    .lineLimit(1)
                Text(container.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if store.busyContainerIDs.contains(container.id) {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .contextMenu {
            if container.isRunning {
                Button("Stop") { run(.stop) }
                Button("Restart") { run(.restart) }
            } else {
                Button("Start") { run(.start) }
            }
        }
    }

    private func run(_ action: ContainerStore.PowerAction) {
        Task { try? await store.perform(action, on: container) }
    }
}

struct StatusDot: View {
    let container: DockerContainer

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 9, height: 9)
            .help(helpText)
    }

    private var color: Color {
        switch (container.state, container.health) {
        case (.running, .unhealthy): .orange
        case (.running, .starting): .yellow
        case (.running, _): .green
        case (.paused, _): .yellow
        case (.restarting, _): .yellow
        default: .secondary.opacity(0.5)
        }
    }

    private var helpText: String {
        if let health = container.health {
            "\(container.state.rawValue) (\(health.rawValue))"
        } else {
            container.state.rawValue
        }
    }
}

struct DaemonDownView: View {
    let store: ContainerStore

    var body: some View {
        ContentUnavailableView {
            Label("Docker isn't running", systemImage: "exclamationmark.triangle")
        } description: {
            Text("Start OrbStack or Docker Desktop, then try again. Macerodactyl never starts the daemon or your containers itself.")
        } actions: {
            Button("Check again") {
                Task { await store.refresh() }
            }
        }
    }
}

/// Shown when no docker binary exists at any known location.
struct DockerBinaryMissingView: View {
    let store: ContainerStore
    @State private var overridePath: String = AppSettings.dockerPathOverride ?? ""

    var body: some View {
        ContentUnavailableView {
            Label("Docker CLI not found", systemImage: "questionmark.folder")
        } description: {
            Text("Looked in ~/.orbstack/bin, /opt/homebrew/bin, and /usr/local/bin. If docker lives somewhere else, point Macerodactyl at it.")
        } actions: {
            HStack {
                TextField("Path to docker binary", text: $overridePath)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 280)
                Button("Browse…") { browse() }
                Button("Use this path") {
                    AppSettings.dockerPathOverride = overridePath
                    store.resolveBinary()
                    Task { await store.refresh() }
                }
                .disabled(overridePath.isEmpty)
            }
        }
    }

    private func browse() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.showsHiddenFiles = true
        if panel.runModal() == .OK, let url = panel.url {
            overridePath = url.path
        }
    }
}

struct ErrorBanner: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text(message)
                .lineLimit(2)
            Spacer()
            Button("Dismiss", action: dismiss)
                .buttonStyle(.borderless)
        }
        .padding(10)
        .background(.bar)
    }
}
