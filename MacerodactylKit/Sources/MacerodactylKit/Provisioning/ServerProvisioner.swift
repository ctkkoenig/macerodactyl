import Foundation

public enum ProvisionError: Error, Equatable {
    case invalidName(String)
    case alreadyExists(String)
    case composeUnavailable
    case pathEscape
}

/// Turns a `ProvisionSpec` into a running compose stack under the stacks root,
/// as one streamed transaction. Every docker sub-step is forwarded line-by-line
/// so the wizard shows a live install log, and any failure rolls the partial
/// stack back so a half-finished create leaves nothing behind.
///
/// Shared by the live (GUI) and daemon services — it depends only on a
/// `DockerCLI` and the stacks root, never on the store or SwiftUI. The startup
/// and environment in the spec are already resolved; provisioning is purely
/// mechanical (filesystem + docker).
public struct ServerProvisioner: Sendable {
    let cli: DockerCLI
    let stacksRoot: URL

    public init(cli: DockerCLI, stacksRoot: URL) {
        self.cli = cli
        self.stacksRoot = stacksRoot
    }

    /// A valid stack/compose-project name (also the folder and container name).
    static let namePattern = "^[a-z0-9][a-z0-9._-]{0,62}$"

    public static func isValidName(_ name: String) -> Bool {
        name.range(of: namePattern, options: .regularExpression) != nil
    }

    /// Turns a friendly, human-typed name ("My SMP #1", "Test") into a valid
    /// stack identifier ("my-smp-1", "test"). The name doubles as the compose
    /// project / container name / grant key, which must be lowercase with a
    /// limited charset — so rather than reject "Test", we normalize it. Returns
    /// "" only when the input has no usable alphanumeric character.
    public static func slugify(_ raw: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789._-")
        let alnum = Set("abcdefghijklmnopqrstuvwxyz0123456789")
        var out = ""
        var lastDash = false
        for ch in raw.lowercased() {
            if allowed.contains(ch) {
                out.append(ch)
                lastDash = false
            } else if !lastDash && !out.isEmpty {
                out.append("-")
                lastDash = true
            }
        }
        while let first = out.first, !alnum.contains(first) { out.removeFirst() }
        while let last = out.last, "-._".contains(last) { out.removeLast() }
        if out.count > 63 { out = String(out.prefix(63)) }
        while let last = out.last, "-._".contains(last) { out.removeLast() }
        return out
    }

    public func stackExists(name: String) -> Bool {
        FileManager.default.fileExists(atPath: stacksRoot.appendingPathComponent(name).path)
    }

    public func provision(_ spec: ProvisionSpec) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await runSteps(spec: spec) { continuation.yield($0) }
                    continuation.yield("✔ Server \"\(spec.name)\" created.")
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Steps

    /// The confined stack directory for a validated name. The strict name regex
    /// (no `/`, no `..`, no leading dot) is the real traversal guard; this also
    /// asserts, as defense in depth, that the directory's parent canonicalizes to
    /// exactly the stacks root. Both sides resolve the SAME existing path (the
    /// root), sidestepping the `/private/tmp`↔`/tmp` inconsistency that makes an
    /// independent `standardizedFileURL` prefix check unreliable on macOS.
    func confinedStackDir(name: String) throws -> URL {
        guard Self.isValidName(name) else { throw ProvisionError.invalidName(name) }
        let dir = stacksRoot.appendingPathComponent(name, isDirectory: true)
        let parentReal = dir.deletingLastPathComponent().resolvingSymlinksInPath().path
        let rootReal = stacksRoot.resolvingSymlinksInPath().path
        guard parentReal == rootReal, dir.lastPathComponent == name else {
            throw ProvisionError.pathEscape
        }
        return dir
    }

    private func runSteps(spec: ProvisionSpec, emit: @escaping (String) -> Void) async throws {
        // Phase 1 — pre-creation checks. A failure here has created nothing on
        // disk, so it never rolls back (and so a name clash never deletes the
        // existing stack).
        let stackDir: URL
        do {
            emit("» Preparing \(spec.name)…")
            stackDir = try confinedStackDir(name: spec.name)
            guard !FileManager.default.fileExists(atPath: stackDir.path) else {
                throw ProvisionError.alreadyExists(spec.name)
            }
            guard await cli.composePluginWorks() else { throw ProvisionError.composeUnavailable }
        } catch {
            emit("✖ Provisioning failed: \(Self.describe(error))")
            throw error
        }

        // Phase 2 — creation. Any failure rolls the (this-run-created) stack back.
        do {
            try await scaffoldAndStart(spec: spec, stackDir: stackDir, emit: emit)
        } catch {
            emit("✖ Provisioning failed: \(Self.describe(error))")
            await rollback(stackDir: stackDir, emit: emit)
            throw error
        }
    }

    private func scaffoldAndStart(
        spec: ProvisionSpec, stackDir: URL, emit: @escaping (String) -> Void
    ) async throws {
        let dataDir = stackDir.appendingPathComponent(spec.dataDirName, isDirectory: true)
        let installDir = stackDir.appendingPathComponent(".install", isDirectory: true)
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)

        // Install step (only if the egg ships a runnable script).
        if spec.install.isRunnable {
            try FileManager.default.createDirectory(at: installDir, withIntermediateDirectories: true)
            let scriptURL = installDir.appendingPathComponent("install.sh")
            try Data(spec.install.script.utf8).write(to: scriptURL)

            emit("» Running egg install script in \(spec.install.container)…")
            var args = [
                "run", "--rm", "--entrypoint", spec.install.entrypoint,
                "-w", "/mnt/server",
                "-v", "\(dataDir.path):/mnt/server",
                "-v", "\(installDir.path):/mnt/install:ro",
            ]
            for key in spec.environment.keys.sorted() {
                args.append("-e")
                args.append("\(key)=\(spec.environment[key] ?? "")")
            }
            args.append(spec.install.container)
            args.append("/mnt/install/install.sh")
            for try await line in cli.streamLines(args, mergeStderr: true) { emit(line) }

            // Match Wings: the install ran as root, so hand the data dir to the
            // runtime user (uid 1000 in the pterodactyl yolks images). Best-effort
            // — harmless where the platform already maps ownership (Docker Desktop).
            emit("» Setting data ownership…")
            let chown = [
                "run", "--rm", "--entrypoint", "chown",
                "-v", "\(dataDir.path):/mnt/server",
                spec.install.container, "-R", "1000:1000", "/mnt/server",
            ]
            do {
                for try await line in cli.streamLines(chown, mergeStderr: true) { emit(line) }
            } catch {
                emit("  (ownership fix skipped: \(Self.describe(error)))")
            }
        }

        // Compose file + bring up.
        emit("» Writing docker-compose.yml…")
        let composeURL = stackDir.appendingPathComponent("docker-compose.yml")
        try Data(ComposeFileWriter.compose(spec).utf8).write(to: composeURL)

        emit("» Starting the server…")
        for try await line in cli.streamLines(
            ["compose", "--project-directory", stackDir.path, "up", "-d"], mergeStderr: true)
        {
            emit(line)
        }

        // Tidy the install artifacts.
        try? FileManager.default.removeItem(at: installDir)
    }

    /// Best-effort teardown of a partial or unwanted stack. `stackDir` is always
    /// one this provisioner produced via `confinedStackDir`, so it is known to be
    /// inside the stacks root.
    private func rollback(stackDir: URL, emit: @escaping (String) -> Void) async {
        emit("» Rolling back…")
        if FileManager.default.fileExists(atPath: stackDir.appendingPathComponent("docker-compose.yml").path) {
            _ = try? await cli.run(
                ["compose", "--project-directory", stackDir.path, "down", "-v"], timeout: .seconds(60))
        }
        try? FileManager.default.removeItem(at: stackDir)
    }

    /// Tear down a provisioned server entirely: `compose down -v` then remove the
    /// stack folder (confined). Used by the admin "delete server" action.
    public func deprovision(name: String) async throws {
        let stackDir = try confinedStackDir(name: name)
        if FileManager.default.fileExists(atPath: stackDir.appendingPathComponent("docker-compose.yml").path) {
            _ = try? await cli.run(
                ["compose", "--project-directory", stackDir.path, "down", "-v"], timeout: .seconds(120))
        }
        if FileManager.default.fileExists(atPath: stackDir.path) {
            try FileManager.default.removeItem(at: stackDir)
        }
    }

    static func describe(_ error: Error) -> String {
        switch error {
        case ProvisionError.invalidName(let n):
            return "\"\(n)\" isn't a valid name (use a–z, 0–9, dot, dash, underscore)."
        case ProvisionError.alreadyExists(let n): return "a stack named \"\(n)\" already exists."
        case ProvisionError.composeUnavailable: return "the docker compose plugin isn't available."
        case ProvisionError.pathEscape: return "the resolved path escaped the stacks root."
        case DockerError.nonZeroExit(let code, let stderr):
            return "docker exited \(code)\(stderr.isEmpty ? "" : ": \(stderr)")"
        case DockerError.daemonUnavailable: return "the docker daemon isn't reachable."
        default: return "\(error)"
        }
    }
}
