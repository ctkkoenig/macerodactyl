import SwiftUI

/// Live log tail for one container. The stream (and its `docker logs -f`
/// child process) lives exactly as long as `.task(id:)` — SwiftUI cancels it
/// when the view disappears or the selected container changes, and the
/// stream's termination handler kills the child.
struct LogsView: View {
    let store: ContainerStore
    let container: DockerContainer

    @State private var buffer = LogBuffer()
    @State private var follow = true
    @State private var filter = ""
    @State private var streamNote: String?

    private var visibleLines: [LogLine] {
        let trimmed = filter.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return buffer.lines }
        return buffer.lines.filter { $0.text.localizedCaseInsensitiveContains(trimmed) }
    }

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            logArea
        }
        .task(id: container.id) {
            await streamLogs()
        }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Toggle("Follow", isOn: $follow)
                .toggleStyle(.switch)
                .controlSize(.small)
            TextField("Filter", text: $filter)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 220)
            Spacer()
            Button("Copy", systemImage: "doc.on.doc") { copyAll() }
                .disabled(buffer.lines.isEmpty)
            Button("Clear", systemImage: "trash") { buffer.clear() }
                .disabled(buffer.lines.isEmpty)
        }
        .buttonStyle(.borderless)
        .labelStyle(.titleOnly)
        .padding(10)
    }

    private var logArea: some View {
        ScrollViewReader { proxy in
            ScrollView([.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(visibleLines) { line in
                        Text(line.text)
                            .font(.system(size: 11.5, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(line.id)
                    }
                }
                .padding(8)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .overlay {
                if buffer.lines.isEmpty {
                    ContentUnavailableView {
                        Label(streamNote ?? "No output yet", systemImage: "text.alignleft")
                    } description: {
                        Text(streamNote == nil ? "Waiting for the container to log something…" : "")
                    }
                }
            }
            .onChange(of: buffer.lines.last?.id) { _, lastID in
                if follow, let lastID {
                    proxy.scrollTo(lastID, anchor: .bottom)
                }
            }
            .onChange(of: follow) { _, isOn in
                if isOn, let lastID = buffer.lines.last?.id {
                    proxy.scrollTo(lastID, anchor: .bottom)
                }
            }
        }
    }

    private func streamLogs() async {
        buffer.clear()
        streamNote = nil
        guard let cli = store.cli else {
            streamNote = "Docker isn't available"
            return
        }
        do {
            for try await line in LogStreamService.lines(for: container.id, cli: cli) {
                buffer.append(line)
            }
            streamNote = "Log stream ended"
        } catch is CancellationError {
            // View went away — the child process is already being torn down.
        } catch {
            streamNote = ContainerStore.describe(error)
        }
    }

    private func copyAll() {
        let text = visibleLines.map(\.text).joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
