import Foundation
import Hummingbird
import HummingbirdAuth
import Logging
import MacerodactylKit

/// Configuration for one server run.
public struct PanelServerConfig: Sendable, Equatable {
    public var port: Int
    /// When false the server binds 127.0.0.1 (local only); true binds 0.0.0.0
    /// (reachable on the LAN) and is an explicit, warned opt-in.
    public var bindLAN: Bool

    public init(port: Int = AppSettings.defaultPanelPort, bindLAN: Bool = false) {
        self.port = port
        self.bindLAN = bindLAN
    }

    public var host: String { bindLAN ? "0.0.0.0" : "127.0.0.1" }
}

/// The web panel server. Its lifetime is tied to the app process — it never
/// survives a quit — so the app stays safe to close. Plain HTTP only: TLS is
/// expected to terminate upstream (Cloudflare Tunnel), so no certificate
/// handling lives here.
public actor PanelServer {
    private let store: PanelDataStore
    private let containers: ContainerService
    private let rateLimiter = LoginRateLimiter()
    private var runTask: Task<Void, Never>?
    private(set) public var isRunning = false

    public init(store: PanelDataStore, containers: ContainerService) {
        self.store = store
        self.containers = containers
    }

    /// Builds the router with the full middleware stack and routes. Exposed so
    /// tests can drive it via HummingbirdTesting without opening a socket.
    /// nonisolated: constructs fresh state and only reads Sendable members.
    public nonisolated func buildRouter() -> Router<PanelRequestContext> {
        let router = Router(context: PanelRequestContext.self)
        // Order matters: identity is resolved first, then CSRF guards mutating
        // requests. Both are global so no route can forget them.
        router.add(middleware: SessionAuthenticator(store: store))
        router.add(middleware: CSRFMiddleware())
        PanelRoutes(store: store, rateLimiter: rateLimiter, containers: containers).register(on: router)
        return router
    }

    public func start(config: PanelServerConfig) async throws {
        guard !isRunning else { return }
        let router = buildRouter()
        var logger = Logger(label: "macerodactyl.panel")
        logger.logLevel = .notice
        let app = Application(
            router: router,
            configuration: .init(
                address: .hostname(config.host, port: config.port),
                serverName: "Macerodactyl"
            ),
            logger: logger
        )
        isRunning = true
        runTask = Task {
            do {
                try await app.runService()
            } catch {
                // Cancellation on stop() lands here; nothing to do.
            }
        }
    }

    public func stop() async {
        runTask?.cancel()
        runTask = nil
        isRunning = false
    }

    /// Runs the server in the foreground until it receives SIGTERM/SIGINT, then
    /// shuts down gracefully. This is the entry point for the headless
    /// `macerodactyld` daemon, which launchd supervises — the process must stay
    /// alive for the server's lifetime rather than returning immediately.
    /// nonisolated: builds fresh state and only reads Sendable members.
    public nonisolated func runUntilTerminated(config: PanelServerConfig, logger: Logger) async throws {
        let router = buildRouter()
        let app = Application(
            router: router,
            configuration: .init(
                address: .hostname(config.host, port: config.port),
                serverName: "Macerodactyl"
            ),
            logger: logger
        )
        try await app.runService()
    }
}
