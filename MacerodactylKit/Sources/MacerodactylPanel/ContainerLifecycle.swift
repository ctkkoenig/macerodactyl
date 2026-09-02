import Foundation
import MacerodactylKit

/// Destructive container lifecycle, shared by the live (GUI) and daemon services
/// so there is exactly one implementation. Pull/recreate/compose-apply stream
/// their output; remove is one-shot and refuses a running container. Image prune
/// and disk usage are daemon-global (admin-only at the route layer).
enum ContainerLifecycle {
    /// `docker pull <image>` — progress on stderr, so merge it into the stream.
    static func pull(cli: DockerCLI, container: DockerContainer) -> AsyncThrowingStream<String, Error> {
        cli.streamLines(["pull", container.image], mergeStderr: true)
    }

    /// Removes a stopped container. Refuses while it is running — the caller must
    /// stop it first (an explicit, auditable two-step, never a surprise kill).
    static func remove(cli: DockerCLI, container: DockerContainer) async throws {
        guard !container.isRunning else {
            throw ContainerServiceError.conflict("Stop the container before removing it.")
        }
        try await cli.run(["rm", container.id], timeout: .seconds(60))
    }

    /// `docker compose up -d` in the container's stack folder. `forceRecreate`
    /// targets just this service and recreates it (the T2.1 "recreate"); without
    /// it, the whole stack is applied (the T2.2 "apply edited compose").
    /// Requires the compose plugin (Docker Desktop ships it); returns a
    /// one-line error stream otherwise rather than failing silently.
    static func composeUp(
        cli: DockerCLI, container: DockerContainer, forceRecreate: Bool
    ) async -> AsyncThrowingStream<String, Error>? {
        guard let dir = container.composeWorkingDir, !dir.isEmpty else { return nil }
        guard await cli.composePluginWorks() else {
            return errorStream("The docker compose plugin is not available; compose operations need it.")
        }
        var args = ["compose", "--project-directory", dir, "up", "-d"]
        if forceRecreate {
            args.append("--force-recreate")
            if let service = container.composeService, !service.isEmpty { args.append(service) }
        }
        return cli.streamLines(args, mergeStderr: true)
    }

    static func imagePrune(cli: DockerCLI) async throws -> String {
        try await cli.run(["image", "prune", "-f"], timeout: .seconds(120))
    }

    static func diskUsage(cli: DockerCLI) async throws -> String {
        try await cli.run(["system", "df"], timeout: .seconds(30))
    }

    private static func errorStream(_ message: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(message)
            continuation.finish(throwing: ContainerServiceError.unavailable(message))
        }
    }
}
