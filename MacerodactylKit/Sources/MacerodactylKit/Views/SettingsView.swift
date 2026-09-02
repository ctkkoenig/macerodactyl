import SwiftUI

/// App settings. Everything here applies live — changing the stacks folder,
/// docker path, or refresh interval takes effect without a restart via the
/// settings-changed notification the setters post.
public struct MacerodactylSettingsView: View {
    let store: ContainerStore

    @State private var dockerOverride = AppSettings.dockerPathOverride ?? ""
    @State private var stacksPath = AppSettings.stacksRoot.path
    @State private var refresh = AppSettings.refreshInterval
    @State private var stacksExists = AppSettings.stacksRootExists()
    @State private var repairMessage: String?
    @State private var staleCount = 0

    public init(store: ContainerStore) {
        self.store = store
    }

    public var body: some View {
        Form {
            Section("Docker") {
                LabeledContent("Resolved binary") {
                    Text(store.cli?.binary.path ?? "not found")
                        .font(.callout.monospaced())
                        .foregroundStyle(store.cli == nil ? .red : .secondary)
                        .textSelection(.enabled)
                }
                HStack {
                    TextField("Override path (optional)", text: $dockerOverride, prompt: Text("Auto-detect"))
                        .textFieldStyle(.roundedBorder)
                    Button("Choose…") { chooseFile(into: $dockerOverride) }
                    Button("Apply") { applyDockerOverride() }
                }
                Text(
                    "Leave blank to auto-detect: ~/.orbstack/bin, /opt/homebrew/bin, then /usr/local/bin. Docker Desktop installs the last one."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("Stacks folder") {
                HStack {
                    TextField("Stacks folder", text: $stacksPath)
                        .textFieldStyle(.roundedBorder)
                    Button("Choose…") { chooseDirectory(into: $stacksPath) }
                    Button("Apply") { applyStacksPath() }
                }
                if !stacksExists {
                    HStack {
                        Label("This folder doesn’t exist yet.", systemImage: "folder.badge.questionmark")
                            .foregroundStyle(.orange)
                        Spacer()
                        Button("Create it") { createStacks() }
                    }
                    .font(.callout)
                }
                Text("Compose projects live here. File editing is confined to stacks under this folder.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Refresh") {
                Picker("Auto-refresh every", selection: $refresh) {
                    Text("2 seconds").tag(2.0)
                    Text("3 seconds").tag(3.0)
                    Text("5 seconds").tag(5.0)
                    Text("10 seconds").tag(10.0)
                }
                .onChange(of: refresh) { _, value in
                    AppSettings.setRefreshInterval(value)
                    store.startPolling(interval: value)
                }
            }

            Section("Scheduled restarts") {
                if staleCount > 0 {
                    HStack {
                        Label(
                            "\(staleCount) schedule\(staleCount == 1 ? "" : "s") point at a docker path that changed.",
                            systemImage: "wrench.and.screwdriver"
                        )
                        .foregroundStyle(.orange)
                        Spacer()
                        Button("Repair all") { repairSchedules() }
                            .buttonStyle(.borderedProminent)
                    }
                    .font(.callout)
                } else {
                    Label("All schedules point at the current docker path.", systemImage: "checkmark.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if let repairMessage {
                    Text(repairMessage).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 520)
        .task { refreshStaleCount() }
    }

    private func applyDockerOverride() {
        AppSettings.setDockerPathOverride(dockerOverride.isEmpty ? nil : dockerOverride)
        store.resolveBinary()
        Task { await store.refresh() }
        refreshStaleCount()
    }

    private func applyStacksPath() {
        AppSettings.stacksRoot = URL(fileURLWithPath: (stacksPath as NSString).expandingTildeInPath)
        stacksExists = AppSettings.stacksRootExists()
    }

    private func createStacks() {
        do {
            try AppSettings.createStacksRoot()
            stacksExists = true
        } catch {
            repairMessage = "Couldn’t create the folder: \(error.localizedDescription)"
        }
    }

    private func refreshStaleCount() {
        guard let path = store.cli?.binary.path,
            let service = try? ScheduleService(dockerPath: path)
        else {
            staleCount = 0
            return
        }
        staleCount = service.schedulesNeedingRepair().count
    }

    private func repairSchedules() {
        guard let path = store.cli?.binary.path,
            let service = try? ScheduleService(dockerPath: path)
        else { return }
        do {
            let repaired = try service.repairAll()
            repairMessage = repaired.isEmpty ? "Nothing needed repair." : "Repaired: \(repaired.joined(separator: ", "))."
            refreshStaleCount()
        } catch {
            repairMessage = "Repair failed: \(error.localizedDescription)"
            refreshStaleCount()
        }
    }

    private func chooseFile(into binding: Binding<String>) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.showsHiddenFiles = true
        if panel.runModal() == .OK, let url = panel.url { binding.wrappedValue = url.path }
    }

    private func chooseDirectory(into binding: Binding<String>) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url { binding.wrappedValue = url.path }
    }
}
