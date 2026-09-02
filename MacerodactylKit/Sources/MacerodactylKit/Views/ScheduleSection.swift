import SwiftUI

/// Scheduled-restart management for one container, shown on its Overview tab.
/// Saving writes a launchd agent plist and bootstraps it; removing boots the
/// agent out first and only then deletes the plist, so nothing is orphaned.
struct ScheduleSection: View {
    let store: ContainerStore
    let container: DockerContainer

    @State private var service: ScheduleService?
    @State private var schedule: RestartSchedule?
    @State private var lastResult: ScheduleRunResult?
    @State private var health: ScheduleService.AgentHealth?
    @State private var errorMessage: String?
    @State private var showingEditor = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Scheduled restart")
                .font(.headline)
            content
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
        }
        .task(id: container.id) { reload() }
        .sheet(isPresented: $showingEditor) {
            ScheduleEditorSheet(
                containerName: container.name,
                existing: schedule
            ) { hour, minute, weekdays in
                save(hour: hour, minute: minute, weekdays: weekdays)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let schedule {
            HStack(spacing: 10) {
                Image(systemName: "clock.arrow.circlepath")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Restarts \(schedule.timeDescription)")
                    lastRunLine
                    healthLine
                }
                Spacer()
                Button("Edit") { showingEditor = true }
                Button("Remove", role: .destructive) { remove() }
            }
            .controlSize(.small)
        } else {
            HStack {
                Text("None. Restart policies keep containers up at boot; a schedule adds a recurring restart on top — it runs even while this app is closed.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Add schedule…") { showingEditor = true }
                    .controlSize(.small)
            }
        }
    }

    @ViewBuilder
    private var lastRunLine: some View {
        if let lastResult {
            let stamp = lastResult.date.formatted(date: .abbreviated, time: .shortened)
            switch lastResult.outcome {
            case .success:
                Label("Last run \(stamp): ok", systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .failed:
                Label("Last run \(stamp) FAILED: \(lastResult.message)", systemImage: "xmark.octagon.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            case .timedOut:
                Label("Last run \(stamp) TIMED OUT — docker didn't respond within \(ScheduleService.restartDeadlineSeconds)s and was stopped. Docker Desktop may be quit (a stale socket makes restart hang).", systemImage: "clock.badge.exclamationmark.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        } else {
            Text("Hasn't run yet")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private var healthLine: some View {
        switch health {
        case .binaryMissing(let installed):
            Text("BROKEN: points at \(installed), which no longer exists — scheduled restarts fail to launch and produce no log. Edit and save to rewrite it with the current docker path.")
                .font(.caption)
                .foregroundStyle(.red)
        case .binaryOutdated(let installed, let current):
            Text("Written for \(installed); docker is now \(current). Edit and save to update the agent.")
                .font(.caption)
                .foregroundStyle(.orange)
        case .ok, nil:
            EmptyView()
        }
    }

    private func reload() {
        errorMessage = nil
        guard let cli = store.cli else {
            service = nil
            return
        }
        do {
            let service = try ScheduleService(dockerPath: cli.binary.path)
            self.service = service
            schedule = service.schedule(forContainerName: container.name)
            lastResult = schedule.flatMap { service.lastResult(for: $0) }
            health = schedule != nil ? service.health(forContainerName: container.name) : nil
        } catch {
            errorMessage = "Schedules unavailable: \(error.localizedDescription)"
        }
    }

    private func save(hour: Int, minute: Int, weekdays: Set<Int>) {
        guard let service else { return }
        let new = RestartSchedule(containerName: container.name, hour: hour, minute: minute, weekdays: weekdays)
        do {
            try service.install(new)
            reload()
        } catch {
            errorMessage = describe(error)
        }
    }

    private func remove() {
        guard let service else { return }
        do {
            try service.remove(containerName: container.name)
            reload()
        } catch {
            errorMessage = describe(error)
        }
    }

    private func describe(_ error: Error) -> String {
        switch error {
        case ScheduleError.launchctlFailed(let message): "launchctl: \(message)"
        case ScheduleError.io(let message): "File error: \(message)"
        default: String(describing: error)
        }
    }
}

private struct ScheduleEditorSheet: View {
    let containerName: String
    let existing: RestartSchedule?
    let onSave: (Int, Int, Set<Int>) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var hour: Int
    @State private var minute: Int
    @State private var weekdays: Set<Int>

    private static let dayNames = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

    init(containerName: String, existing: RestartSchedule?, onSave: @escaping (Int, Int, Set<Int>) -> Void) {
        self.containerName = containerName
        self.existing = existing
        self.onSave = onSave
        _hour = State(initialValue: existing?.hour ?? 4)
        _minute = State(initialValue: existing?.minute ?? 0)
        _weekdays = State(initialValue: existing?.weekdays ?? [])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Restart \(containerName)")
                .font(.headline)
            HStack {
                Text("At")
                Picker("Hour", selection: $hour) {
                    ForEach(0..<24, id: \.self) { Text(String(format: "%02d", $0)).tag($0) }
                }
                .frame(width: 70)
                Text(":")
                Picker("Minute", selection: $minute) {
                    ForEach(0..<60, id: \.self) { Text(String(format: "%02d", $0)).tag($0) }
                }
                .frame(width: 70)
                .labelsHidden()
            }
            .labelsHidden()
            VStack(alignment: .leading, spacing: 6) {
                Text("On")
                    .foregroundStyle(.secondary)
                HStack(spacing: 4) {
                    ForEach(0..<7, id: \.self) { day in
                        Toggle(Self.dayNames[day], isOn: Binding(
                            get: { weekdays.contains(day) },
                            set: { on in if on { weekdays.insert(day) } else { weekdays.remove(day) } }
                        ))
                        .toggleStyle(.button)
                        .controlSize(.small)
                    }
                }
                Text(weekdays.isEmpty ? "Every day" : "Selected days only")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Text("Runs via launchd even when Macerodactyl is closed. Restart only — nothing is ever started at boot by this app.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button(existing == nil ? "Add schedule" : "Save changes") {
                    onSave(hour, minute, weekdays)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
