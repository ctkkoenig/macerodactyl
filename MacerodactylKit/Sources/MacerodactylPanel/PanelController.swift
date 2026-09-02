import Foundation
import MacerodactylKit
import Observation

/// Owns the panel server's lifecycle from the app side: starts it when enabled,
/// stops it on quit or when disabled, and creates the first admin on first
/// enable. Never lets the server outlive the app.
@MainActor
@Observable
public final class PanelController {
    public let store: PanelDataStore
    private let server: PanelServer
    public private(set) var isRunning = false
    /// Set once when a first-run admin is created, for the UI to display.
    public private(set) var firstAdminPassword: String?
    /// A user-facing reason the panel could not start (e.g. HTTPS was requested
    /// but no certificate could be produced). Cleared on a successful enable.
    public private(set) var startupError: String?

    public init(store: PanelDataStore, containers: ContainerService) {
        self.store = store
        self.server = PanelServer(store: store, containers: containers)
    }

    public func applySettings() {
        if AppSettings.panelEnabled {
            Task { await enable() }
        } else {
            Task { await disable() }
        }
    }

    public func enable() async {
        // First run: mint an admin and surface its one-time password.
        if let created = (try? await AccountManager(store: store).createFirstAdminIfNeeded()) ?? nil {
            firstAdminPassword = created.password
        }
        // Keep the shared config in step so a daemon (if used) matches the GUI.
        AppSettings.syncPanelConfig()
        startupError = nil

        var tls: PanelServerConfig.TLSFiles?
        if AppSettings.panelTLSEnabled {
            do {
                let paths = try SelfSignedCertificate.ensure()
                tls = .init(certificatePath: paths.certificate, privateKeyPath: paths.privateKey)
            } catch {
                // Fail closed: never silently serve plaintext when HTTPS was
                // asked for (that would also drop the Secure cookie flag).
                await server.stop()
                isRunning = false
                startupError =
                    "HTTPS is on but no certificate could be created (\(error)). The panel was not started. Install openssl, or turn HTTPS off."
                return
            }
        }
        let config = PanelServerConfig(port: AppSettings.panelPort, bindLAN: AppSettings.panelBindLAN, tls: tls)
        await server.stop()
        try? await server.start(config: config)
        isRunning = await server.isRunning
    }

    public func disable() async {
        await server.stop()
        isRunning = false
    }

    public func consumeFirstAdminPassword() -> String? {
        defer { firstAdminPassword = nil }
        return firstAdminPassword
    }

    public var localURL: String {
        let scheme = AppSettings.panelTLSEnabled ? "https" : "http"
        return "\(scheme)://127.0.0.1:\(AppSettings.panelPort)/"
    }
}
