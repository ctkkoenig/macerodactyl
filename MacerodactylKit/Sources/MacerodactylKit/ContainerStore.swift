import Foundation
import Observation

/// How reachable Docker is, as a first-class UI state.
public enum DockerAvailability: Sendable, Equatable {
    case unknown
    /// No docker binary at any known location (see DockerBinaryLocator).
    case binaryNotFound
    /// Binary exists but the daemon isn't running (OrbStack/Docker Desktop stopped).
    case daemonDown
    case ready
}

public enum StoreEvent: Sendable {
    case containersChanged
    case availabilityChanged(DockerAvailability)
}

/// The single source of truth for container state and every mutation, shared
/// by the native windows and (later) the web panel. A change made from either
/// side lands here, refreshes, and fans out through `events()` — which is what
/// lets a stop from a phone update an open native window live.
@MainActor
@Observable
public final class ContainerStore {
    public private(set) var groups: ContainerGroups = .empty
    public private(set) var availability: DockerAvailability = .unknown
    public private(set) var lastError: String?
    /// Container IDs with an in-flight power action (drives row spinners).
    public private(set) var busyContainerIDs: Set<String> = []

    public private(set) var cli: DockerCLI?
    private var pollTask: Task<Void, Never>?
    private var eventContinuations: [UUID: AsyncStream<StoreEvent>.Continuation] = [:]

    public init() {
        resolveBinary()
    }

    /// For tests and the web layer: a store with an explicit CLI.
    public init(cli: DockerCLI) {
        self.cli = cli
    }

    // MARK: Binary / lifecycle

    public func resolveBinary() {
        composeCache = nil  // provider may have changed
        if let url = DockerBinaryLocator.resolve(override: AppSettings.dockerPathOverride) {
            cli = DockerCLI(binary: url)
            if availability == .binaryNotFound { setAvailability(.unknown) }
        } else {
            cli = nil
            setAvailability(.binaryNotFound)
        }
    }

    public func startPolling(interval: TimeInterval = AppSettings.refreshInterval) {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    public func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// Subscribe to change events (used by SSE in the web layer and anything
    /// else that wants push rather than observation).
    public func events() -> AsyncStream<StoreEvent> {
        let id = UUID()
        return AsyncStream { continuation in
            eventContinuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.eventContinuations[id] = nil
                }
            }
        }
    }

    private func emit(_ event: StoreEvent) {
        for continuation in eventContinuations.values {
            continuation.yield(event)
        }
    }

    private func setAvailability(_ new: DockerAvailability) {
        guard availability != new else { return }
        availability = new
        emit(.availabilityChanged(new))
    }

    // MARK: Refresh

    public func refresh() async {
        guard let cli else {
            setAvailability(.binaryNotFound)
            return
        }
        do {
            let output = try await cli.run(
                ["ps", "-a", "--no-trunc", "--format", "{{json .}}"],
                timeout: .seconds(15)
            )
            let parsed = DockerPSParser.group(DockerPSParser.parse(output))
            setAvailability(.ready)
            lastError = nil
            if parsed != groups {
                groups = parsed
                emit(.containersChanged)
            }
        } catch DockerError.daemonUnavailable {
            setAvailability(.daemonDown)
            if !groups.isEmpty {
                groups = .empty
                emit(.containersChanged)
            }
        } catch {
            lastError = Self.describe(error)
        }
        await refreshAdvisories()
    }

    // MARK: Power actions

    public enum PowerAction: String, Sendable, CaseIterable {
        case start, stop, restart, kill

        /// `docker kill` is an abrupt SIGKILL, not a graceful stop — a distinct
        /// destructive action the UI presents separately and confirms.
        public var isDestructive: Bool { self == .kill }
    }

    /// Runs a power action on one container, then refreshes. Errors land in
    /// `lastError` and are rethrown for callers (the web layer) that report
    /// per-request.
    public func perform(_ action: PowerAction, on container: DockerContainer) async throws {
        guard let cli else { throw DockerError.daemonUnavailable }
        busyContainerIDs.insert(container.id)
        defer { busyContainerIDs.remove(container.id) }
        do {
            try await cli.run([action.rawValue, container.id], timeout: .seconds(120))
        } catch {
            lastError = Self.describe(error)
            await refresh()
            throw error
        }
        await refresh()
    }

    /// Stack-level action via docker compose, using the project's recorded
    /// working directory. User-initiated only — the app never starts anything
    /// at boot; that is what compose restart policies are for.
    public func perform(_ action: PowerAction, on stack: ContainerStack) async throws {
        guard let cli else { throw DockerError.daemonUnavailable }
        guard let workingDir = stack.workingDir else {
            throw DockerError.nonZeroExit(code: 1, stderr: "Stack has no recorded working directory")
        }
        let compose = await resolveCompose(cli: cli)
        guard let compose else {
            let message =
                "Neither `docker compose` nor a `docker-compose` binary is available. Install Docker Compose to control whole stacks."
            lastError = message
            throw DockerError.nonZeroExit(code: 1, stderr: message)
        }
        let subArgs: [String] =
            switch action {
            case .start: ["--project-directory", workingDir, "up", "-d"]
            case .stop: ["--project-directory", workingDir, "stop"]
            case .restart: ["--project-directory", workingDir, "restart"]
            case .kill: ["--project-directory", workingDir, "kill"]
            }
        let (executable, args) = compose.invocation(subArgs)
        for container in stack.containers { busyContainerIDs.insert(container.id) }
        defer { for container in stack.containers { busyContainerIDs.remove(container.id) } }
        do {
            try await DockerCLI(binary: executable).run(args, timeout: .seconds(300))
        } catch {
            lastError = Self.describe(error)
            await refresh()
            throw error
        }
        await refresh()
    }

    private var composeCache: ComposeCommand?

    /// Resolves and caches which compose shape this machine has.
    func resolveCompose(cli: DockerCLI) async -> ComposeCommand? {
        if let composeCache { return composeCache }
        let works = await cli.composePluginWorks()
        let resolved = ComposeCommand.detect(dockerBinary: cli.binary, pluginWorks: { _ in works })
        composeCache = resolved
        return resolved
    }

    public func clearError() {
        lastError = nil
    }

    /// Snapshots the environment for cold-start diagnostics, using state the
    /// store already knows plus cheap filesystem checks.
    public func environmentSnapshot(systemTools: SystemTools = SystemTools()) async -> EnvironmentSnapshot {
        let composeAvailable: Bool
        if let cli, availability == .ready {
            composeAvailable = await resolveCompose(cli: cli) != nil
        } else {
            composeAvailable = false
        }
        return EnvironmentSnapshot(
            dockerResolved: cli != nil,
            daemon: availability,
            composeAvailable: composeAvailable,
            perlAvailable: systemTools.perlPath() != nil,
            stacksRootExists: AppSettings.stacksRootExists(),
            stacksRootPath: AppSettings.stacksRoot.path,
            containerCount: groups.all.count
        )
    }

    public private(set) var advisories: [StartupAdvisory] = []

    public func refreshAdvisories() async {
        advisories = StartupDiagnostics.evaluate(await environmentSnapshot())
    }

    public nonisolated static func describe(_ error: Error) -> String {
        switch error {
        case DockerError.daemonUnavailable: "Docker isn't running."
        case DockerError.timeout: "The docker command timed out."
        case DockerError.nonZeroExit(_, let stderr): stderr.isEmpty ? "docker exited with an error." : stderr
        case DockerError.launchFailed(let reason): "Couldn't launch docker: \(reason)"
        default: String(describing: error)
        }
    }
}
