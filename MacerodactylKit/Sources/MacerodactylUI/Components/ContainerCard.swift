import MacerodactylKit
import SwiftUI

/// A container card on the landing — the Pterodactyl "server list" unit. Name,
/// status dot, address, and live CPU/mem (or "—" when unmeasured). Quiet by
/// design; the stat cards inside a container are what carry visual weight.
struct ContainerCard: View {
    let container: DockerContainer
    let stats: ContainerStats?
    let statsAvailable: Bool
    let busy: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                StatusDot(container: container, size: 10)
                Text(container.name)
                    .font(.headline)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if busy { ProgressView().controlSize(.small) }
            }
            Text(address)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            HStack(spacing: 16) {
                miniStat("CPU", cpu)
                miniStat("Memory", mem)
            }
            .padding(.top, 2)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator.opacity(0.5), lineWidth: 0.5))
        .contentShape(RoundedRectangle(cornerRadius: 12))
    }

    private func miniStat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption2).foregroundStyle(.tertiary)
            Text(value).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
        }
    }

    private var address: String {
        container.ports.isEmpty ? (container.isRunning ? "no published ports" : container.status) : container.ports
    }
    private var cpu: String {
        guard container.isRunning else { return "—" }
        return stats.map { String(format: "%.1f%%", $0.cpuPercent) } ?? (statsAvailable ? "—" : "—")
    }
    private var mem: String {
        guard container.isRunning else { return "—" }
        return stats.map { ByteFormat.string($0.memUsedBytes) } ?? "—"
    }
}
