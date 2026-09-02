import Foundation
import Hummingbird
import HummingbirdAuth
import HummingbirdTLS
import Logging
import MacerodactylKit
import NIOSSL

/// Configuration for one server run.
public struct PanelServerConfig: Sendable, Equatable {
    public var port: Int
    /// When false the server binds 127.0.0.1 (local only); true binds 0.0.0.0
    /// (reachable on the LAN) and is an explicit, warned opt-in.
    public var bindLAN: Bool
    /// Paths to a PEM certificate + key. When set, the server serves HTTPS and
    /// session cookies are marked `Secure`. nil = plain HTTP (TLS terminates at
    /// a tunnel, the recommended default).
    public var tls: TLSFiles?

    public struct TLSFiles: Sendable, Equatable {
        public let certificatePath: String
        public let privateKeyPath: String
        public init(certificatePath: String, privateKeyPath: String) {
            self.certificatePath = certificatePath
            self.privateKeyPath = privateKeyPath
        }
    }

    public init(port: Int = AppSettings.defaultPanelPort, bindLAN: Bool = false, tls: TLSFiles? = nil) {
        self.port = port
        self.bindLAN = bindLAN
        self.tls = tls
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
    private let rateLimiter: LoginRateLimiter
    private var runTask: Task<Void, Never>?
    private(set) public var isRunning = false

    public init(store: PanelDataStore, containers: ContainerService) {
        self.store = store
        self.containers = containers
        // Persist throttling in the same SQLite so a restart isn't a reset.
        self.rateLimiter = LoginRateLimiter(store: SQLiteRateLimitStore(store: store))
    }

    /// Builds the router with the full middleware stack and routes. Exposed so
    /// tests can drive it via HummingbirdTesting without opening a socket.
    /// nonisolated: constructs fresh state and only reads Sendable members.
    public nonisolated func buildRouter(secureCookies: Bool = false) -> Router<PanelRequestContext> {
        let router = Router(context: PanelRequestContext.self)
        // Order matters: identity is resolved first, then CSRF guards mutating
        // requests. Both are global so no route can forget them.
        router.add(middleware: SessionAuthenticator(store: store))
        router.add(middleware: CSRFMiddleware())
        PanelRoutes(store: store, rateLimiter: rateLimiter, containers: containers, secureCookies: secureCookies)
            .register(on: router)
        return router
    }

    public func start(config: PanelServerConfig) async throws {
        guard !isRunning else { return }
        var logger = Logger(label: "macerodactyl.panel")
        logger.logLevel = .notice
        isRunning = true
        runTask = Task { [config, logger] in
            do {
                try await Self.serve(
                    router: buildRouter(secureCookies: config.tls != nil), config: config, logger: logger)
            } catch {
                // Cancellation on stop(), or a bind/TLS failure; nothing to do.
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
    public nonisolated func runUntilTerminated(config: PanelServerConfig, logger: Logger) async throws {
        try await Self.serve(router: buildRouter(secureCookies: config.tls != nil), config: config, logger: logger)
    }

    /// Builds and runs the Application, serving HTTPS when TLS files are given
    /// (the two Application types differ, so each branch runs inline).
    private static func serve(
        router: Router<PanelRequestContext>, config: PanelServerConfig, logger: Logger
    ) async throws {
        let appConfig = ApplicationConfiguration(
            address: .hostname(config.host, port: config.port), serverName: "Macerodactyl")
        if let tls = config.tls {
            let tlsConfiguration = try Self.makeTLSConfiguration(tls)
            let app = Application(
                router: router, server: try .tls(.http1(), tlsConfiguration: tlsConfiguration),
                configuration: appConfig, logger: logger)
            try await app.runService()
        } else {
            let app = Application(router: router, configuration: appConfig, logger: logger)
            try await app.runService()
        }
    }

    private static func makeTLSConfiguration(_ tls: PanelServerConfig.TLSFiles) throws -> TLSConfiguration {
        let certificates = try NIOSSLCertificate.fromPEMFile(tls.certificatePath)
            .map { NIOSSLCertificateSource.certificate($0) }
        let key = try NIOSSLPrivateKey(file: tls.privateKeyPath, format: .pem)
        return TLSConfiguration.makeServerConfiguration(certificateChain: certificates, privateKey: .privateKey(key))
    }
}
