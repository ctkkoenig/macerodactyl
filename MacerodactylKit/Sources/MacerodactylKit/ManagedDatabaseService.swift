import Foundation

/// Manages the single shared MariaDB container the panel provisions databases on.
/// It shells out to the docker CLI (per the project's no-socket rule) — starting
/// the container on first use, waiting until it accepts connections, and running
/// admin SQL through `docker exec … mariadb`. Every value that reaches the shell
/// is passed as a discrete argv element (never a shell string), and the SQL text
/// is built by `DatabaseProvisioning` from a strict allow-list.
public struct ManagedDatabaseService: Sendable {
    public static let containerName = "macerodactyl-db"
    public static let volumeName = "macerodactyl-db-data"
    public static let defaultImage = "mariadb:11"

    let cli: DockerCLI
    public init(cli: DockerCLI) { self.cli = cli }

    public enum EngineError: Error, Equatable, Sendable {
        case startFailed(String)
        case notReady
        case sqlFailed(String)
    }

    /// True if the shared container is up right now.
    public func isRunning() async -> Bool {
        guard
            let out = try? await cli.run(
                ["ps", "--filter", "name=^/\(Self.containerName)$", "--filter", "status=running", "--format", "{{.Names}}"],
                timeout: .seconds(10))
        else { return false }
        return out.split(separator: "\n").contains(Substring(Self.containerName))
    }

    private func exists() async -> Bool {
        guard
            let out = try? await cli.run(
                ["ps", "-a", "--filter", "name=^/\(Self.containerName)$", "--format", "{{.Names}}"], timeout: .seconds(10))
        else { return false }
        return out.split(separator: "\n").contains(Substring(Self.containerName))
    }

    /// Ensures the shared MariaDB is running: starts an existing-but-stopped one,
    /// or pulls + runs a fresh one with a persistent volume, then waits until it
    /// accepts connections (first boot initializes the data dir, ~15–30s).
    public func ensureRunning(config: DatabaseEngineConfig) async throws {
        if await isRunning() {
            try await waitUntilReady(config: config)
            return
        }
        if await exists() {
            _ = try await cli.run(["start", Self.containerName], timeout: .seconds(30))
        } else {
            _ = try? await cli.run(["pull", config.image], timeout: .seconds(600))
            do {
                _ = try await cli.run(
                    [
                        "run", "-d", "--name", Self.containerName, "--restart", "unless-stopped",
                        "-e", "MARIADB_ROOT_PASSWORD=\(config.rootPassword)",
                        "-v", "\(Self.volumeName):/var/lib/mysql",
                        "-p", "\(config.hostPort):3306",
                        config.image,
                    ], timeout: .seconds(120))
            } catch {
                throw EngineError.startFailed("\(error)")
            }
        }
        try await waitUntilReady(config: config)
    }

    /// Polls `SELECT 1` until the engine answers or the attempts run out.
    private func waitUntilReady(config: DatabaseEngineConfig, attempts: Int = 40) async throws {
        for _ in 0..<attempts {
            if (try? await runSQL(config: config, sql: "SELECT 1;")) != nil { return }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
        }
        throw EngineError.notReady
    }

    /// Runs admin SQL as root inside the container. The password is attached to
    /// `-p` (MariaDB's form) as one argv element; the SQL is one `-e` element.
    @discardableResult
    public func runSQL(config: DatabaseEngineConfig, sql: String) async throws -> String {
        do {
            return try await cli.run(
                ["exec", Self.containerName, "mariadb", "-uroot", "-p\(config.rootPassword)", "-e", sql],
                timeout: .seconds(30))
        } catch {
            throw EngineError.sqlFailed("\(error)")
        }
    }
}
