import Foundation
import Logging
import MacerodactylKit
import MacerodactylPanel

// macerodactyld — the headless web-panel server, supervised by launchd.
//
// It reads the shared PanelConfig, serves the panel over HTTP until it receives
// SIGTERM/SIGINT, and NEVER starts containers — RunAtLoad launches only this
// server, so restart-at-boot is still the job of compose restart policies.
//
// Config: `~/Library/Application Support/Macerodactyl/config.json`.
// State (accounts/grants/sessions/audit): the same `panel.sqlite` the GUI uses.

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("macerodactyld: \(message)\n".utf8))
    exit(1)
}

let config = PanelConfig.load()

guard let dockerURL = DockerBinaryLocator.resolve(override: config.dockerPathOverride) else {
    fail("docker binary not found (checked override, ~/.orbstack/bin, /opt/homebrew/bin, /usr/local/bin)")
}
let cli = DockerCLI(binary: dockerURL)

let dbPath: String
do { dbPath = try AppPaths.databasePath() } catch { fail("cannot resolve database path: \(error)") }

let store: PanelDataStore
do { store = try PanelDataStore(databasePath: dbPath) } catch { fail("cannot open database: \(error)") }

var logger = Logger(label: "macerodactyld")
logger.logLevel = .notice

// First run: mint an admin if none exists so the panel is usable even when
// launched daemon-first, dropping the one-time password in a 0600 file.
// Idempotent — never disturbs existing accounts.
if let created = try? await AccountManager(store: store).createFirstAdminIfNeeded() {
    let creds = "username: \(created.username)\npassword: \(created.password)\n"
    if let dir = try? AppPaths.supportDirectory() {
        let url = dir.appending(path: "first-admin.txt")
        try? creds.data(using: .utf8)?.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        logger.notice("created first admin — one-time password at \(url.path)")
    }
}

let containers = DaemonContainerService(cli: cli, stacksRoot: config.stacksRootURL)
let server = PanelServer(store: store, containers: containers)

let host = config.bindLAN ? "0.0.0.0 (LAN)" : "127.0.0.1 (local only)"
logger.notice("macerodactyld serving on \(host):\(config.port) — docker at \(dockerURL.path)")

do {
    try await server.runUntilTerminated(config: .init(port: config.port, bindLAN: config.bindLAN), logger: logger)
} catch {
    fail("server error: \(error)")
}
