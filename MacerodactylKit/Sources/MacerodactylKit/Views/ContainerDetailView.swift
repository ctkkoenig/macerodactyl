import SwiftUI

struct ContainerDetailView: View {
    let store: ContainerStore
    let container: DockerContainer

    private var isBusy: Bool { store.busyContainerIDs.contains(container.id) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                actions
                overview
                Text("Logs, console, and file editing arrive in the next phase.")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(container.name)
    }

    private var header: some View {
        HStack(spacing: 10) {
            StatusDot(container: container)
            Text(container.name)
                .font(.title2.bold())
            if let health = container.health {
                Text(health.rawValue)
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(healthColor.opacity(0.18), in: Capsule())
                    .foregroundStyle(healthColor)
            }
            if isBusy {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }

    private var healthColor: Color {
        switch container.health {
        case .healthy: .green
        case .unhealthy: .orange
        case .starting: .yellow
        case nil: .secondary
        }
    }

    private var actions: some View {
        HStack {
            Button("Start", systemImage: "play.fill") { run(.start) }
                .disabled(container.isRunning || isBusy)
            Button("Stop", systemImage: "stop.fill") { run(.stop) }
                .disabled(!container.isRunning || isBusy)
            Button("Restart", systemImage: "arrow.clockwise") { run(.restart) }
                .disabled(!container.isRunning || isBusy)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
    }

    private var overview: some View {
        Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 8) {
            row("Status", container.status)
            row("Image", container.image)
            row("ID", String(container.id.prefix(12)))
            if !container.ports.isEmpty {
                row("Ports", container.ports)
            }
            if let project = container.composeProject {
                row("Stack", project)
            }
            if let service = container.composeService {
                row("Service", service)
            }
            if let workingDir = container.composeWorkingDir {
                row("Directory", workingDir)
            }
        }
        .textSelection(.enabled)
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            Text(value)
                .font(.body.monospaced())
        }
    }

    private func run(_ action: ContainerStore.PowerAction) {
        Task { try? await store.perform(action, on: container) }
    }
}
