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

    public init(store: PanelDataStore) {
        self.store = store
        self.server = PanelServer(store: store)
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
        let config = PanelServerConfig(port: AppSettings.panelPort, bindLAN: AppSettings.panelBindLAN)
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
        "http://127.0.0.1:\(AppSettings.panelPort)/"
    }
}
