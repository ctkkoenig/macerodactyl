import Foundation

/// Holds one persistent `docker attach` session per container, used purely as
/// the **stdin** channel for the interactive console — typing `stop`/`say hi`
/// reaches the server's own process. Console *output* is the existing
/// `docker logs --follow` stream (one reliable source, with backlog), so a
/// command's result shows up there the same as any other server output; that's
/// the Pterodactyl console model and it unifies Minecraft (stdin commands log
/// their own output) instead of needing RCON.
///
/// Sessions are opened lazily on first send, cached, and dropped when the attach
/// stream ends (container stopped). A shared instance lives on the container
/// service so state persists across requests.
public actor ConsoleHub {
    private struct Live {
        let attach: AttachSession
        let monitor: Task<Void, Never>
    }
    private var sessions: [String: Live] = [:]

    public init() {}

    /// Sends one line to a container's stdin, opening the attach session if
    /// needed. Returns false if a session can't be established.
    public func send(cli: DockerCLI, containerID: String, line: String) -> Bool {
        let attach = existing(containerID) ?? open(cli: cli, containerID: containerID)
        guard attach.isRunning else {
            drop(containerID)
            return false
        }
        attach.write(line)
        return true
    }

    /// Closes the attach session for a container (e.g. when it is stopped).
    public func close(containerID: String) {
        guard let live = sessions[containerID] else { return }
        live.attach.close()
        live.monitor.cancel()
        sessions[containerID] = nil
    }

    // MARK: - Internals

    private func existing(_ id: String) -> AttachSession? {
        guard let live = sessions[id] else { return nil }
        if live.attach.isRunning { return live.attach }
        drop(id)
        return nil
    }

    private func open(cli: DockerCLI, containerID: String) -> AttachSession {
        let attach = cli.attach(containerID: containerID)
        // Drain the attach output stream (logs is the real output channel) only
        // to notice when it ends, so a dead session is dropped from the cache.
        let monitor = Task { [attach] in
            do {
                for try await _ in attach.lines {}
            } catch {}
            await self.drop(containerID)
        }
        sessions[containerID] = Live(attach: attach, monitor: monitor)
        return attach
    }

    private func drop(_ id: String) {
        guard let live = sessions[id] else { return }
        live.monitor.cancel()
        sessions[id] = nil
    }
}
