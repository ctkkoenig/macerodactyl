import SwiftUI

/// Console state for one container. Which backend it speaks is decided by
/// detection: Minecraft servers get RCON (never `docker exec` — that would be
/// a shell, not the server prompt); everything else gets the line-based exec
/// console. The model is created per container (`.id` on the view), so a
/// session can never drift to a different container.
@MainActor
@Observable
final class ConsoleModel {
    enum Backend: Equatable {
        case detecting
        case exec
        case rcon(RCONEndpoint)
        case rconUnreachable(String)
    }

    private(set) var backend: Backend = .detecting
    private(set) var entries: [ConsoleEntry] = []
    private(set) var busy = false
    private(set) var rconConnected = false
    var history: [String] = []

    private var rconClient: RCONClient?

    func detect(container: DockerContainer, cli: DockerCLI) async {
        switch await MinecraftRCON.detect(containerID: container.id, cli: cli) {
        case .notMinecraft:
            backend = .exec
        case .unreachable(let reason):
            backend = .rconUnreachable(reason)
        case .available(let endpoint):
            backend = .rcon(endpoint)
        }
    }

    func run(_ line: String, container: DockerContainer, cli: DockerCLI) async {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !busy else { return }
        busy = true
        defer { busy = false }
        history.append(trimmed)

        switch backend {
        case .exec:
            let entry = await ExecConsole(containerID: container.id, cli: cli).run(trimmed)
            entries.append(entry)
        case .rcon(let endpoint):
            await runRCON(trimmed, endpoint: endpoint)
        case .detecting, .rconUnreachable:
            break
        }
    }

    private func runRCON(_ command: String, endpoint: RCONEndpoint) async {
        do {
            let client: RCONClient
            if let existing = rconClient {
                client = existing
            } else {
                client = RCONClient(endpoint: endpoint)
                try await client.connect()
                rconClient = client
                rconConnected = true
            }
            let response = try await client.send(command: command)
            entries.append(
                ConsoleEntry(
                    command: command,
                    output: response.isEmpty ? "(no response)" : response
                ))
        } catch {
            // Drop the session so the next command reconnects fresh.
            await rconClient?.close()
            rconClient = nil
            rconConnected = false
            let message =
                switch error {
                case RCONError.authenticationFailed: "RCON authentication failed — wrong password."
                case RCONError.timedOut: "RCON timed out. The server may still be starting."
                case RCONError.connectionFailed(let reason): "RCON connection failed: \(reason)"
                default: String(describing: error)
                }
            entries.append(ConsoleEntry(command: command, output: message, isError: true))
        }
    }

    func shutdown() {
        let client = rconClient
        rconClient = nil
        rconConnected = false
        Task { await client?.close() }
    }
}

struct ConsoleView: View {
    let store: ContainerStore
    let container: DockerContainer

    @State private var model = ConsoleModel()
    @State private var input = ""
    @State private var historyCursor: Int?
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            scrollback
            Divider()
            inputBar
        }
        .task(id: container.id) {
            guard let cli = store.cli else { return }
            await model.detect(container: container, cli: cli)
        }
        .onDisappear {
            model.shutdown()
        }
    }

    private var scrollback: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    banner
                    ForEach(model.entries) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(prompt) \(entry.command)")
                                .font(.system(size: 12, design: .monospaced).bold())
                            if !entry.output.isEmpty {
                                Text(entry.output)
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(entry.isError ? Color.orange : .primary)
                            }
                        }
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .id(entry.id)
                    }
                }
                .padding(10)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .onChange(of: model.entries.last?.id) { _, lastID in
                if let lastID { proxy.scrollTo(lastID, anchor: .bottom) }
            }
        }
    }

    @ViewBuilder
    private var banner: some View {
        switch model.backend {
        case .detecting:
            Label("Checking for RCON…", systemImage: "magnifyingglass")
                .foregroundStyle(.secondary)
        case .exec:
            Label(
                "Line-based console: each command runs fresh via docker exec in /bin/sh. No TTY — state like cd doesn't persist between commands.",
                systemImage: "terminal"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        case .rcon:
            Label(
                model.rconConnected ? "RCON connected" : "Minecraft server — console speaks RCON. First command connects.",
                systemImage: "network"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        case .rconUnreachable(let reason):
            Label("Minecraft server, but RCON is unreachable: \(reason)", systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    private var isMinecraft: Bool {
        if case .rcon = model.backend { return true }
        if case .rconUnreachable = model.backend { return true }
        return false
    }

    private var prompt: String { isMinecraft ? ">" : "$" }

    private var inputBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            if case .rcon = model.backend {
                HStack(spacing: 6) {
                    ForEach(["list", "time set day", "save-all"], id: \.self) { quick in
                        Button(quick) {
                            input = quick
                            submit()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .font(.caption.monospaced())
                    }
                }
            }
            HStack(spacing: 8) {
                Text(prompt)
                    .font(.system(size: 12, design: .monospaced).bold())
                    .foregroundStyle(.secondary)
                TextField(inputPlaceholder, text: $input)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .focused($inputFocused)
                    .disabled(!inputEnabled)
                    .onSubmit(submit)
                    .onKeyPress(.upArrow) { recallHistory(direction: -1) }
                    .onKeyPress(.downArrow) { recallHistory(direction: 1) }
                if model.busy {
                    ProgressView()
                        .controlSize(.small)
                }
            }
        }
        .padding(10)
    }

    private var inputEnabled: Bool {
        switch model.backend {
        case .exec, .rcon: !model.busy
        case .detecting, .rconUnreachable: false
        }
    }

    private var inputPlaceholder: String {
        switch model.backend {
        case .rcon: "Server command (e.g. list)"
        case .exec: "Shell command (e.g. ls /data)"
        case .detecting: "…"
        case .rconUnreachable: "Console unavailable"
        }
    }

    private func submit() {
        let line = input
        input = ""
        historyCursor = nil
        guard let cli = store.cli else { return }
        Task {
            await model.run(line, container: container, cli: cli)
            inputFocused = true
        }
    }

    private func recallHistory(direction: Int) -> KeyPress.Result {
        guard !model.history.isEmpty else { return .ignored }
        var cursor = historyCursor ?? model.history.count
        cursor += direction
        if cursor < 0 { cursor = 0 }
        if cursor >= model.history.count {
            historyCursor = nil
            input = ""
            return .handled
        }
        historyCursor = cursor
        input = model.history[cursor]
        return .handled
    }
}
