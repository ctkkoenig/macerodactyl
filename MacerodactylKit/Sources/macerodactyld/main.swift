import Dispatch
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
// IMPORTANT: `main` is *synchronous* and runs the server on an unstructured Task
// on the global concurrency executor, blocking the main thread on a semaphore.
// A top-level `await` would make the whole body run as the async *main* task,
// which is a fragile entry point outside an interactive session.
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

let containers = DaemonContainerService(cli: cli, stacksRoot: config.stacksRootURL)
let server = PanelServer(store: store, containers: containers)

let host = config.bindLAN ? "0.0.0.0 (LAN)" : "127.0.0.1 (local only)"
logger.notice("macerodactyld starting on \(host):\(config.port) — docker at \(dockerURL.path)")

// Run the server on the global executor; block the main thread until it exits.
let done = DispatchSemaphore(value: 0)
let serverConfig = PanelServerConfig(port: config.port, bindLAN: config.bindLAN)
let daemonLogger = logger

Task {
    // First run: if no account exists, mint an admin so the panel is usable even
    // when launched daemon-first, and drop the one-time password in a 0600 file
    // the GUI/owner can read. Idempotent — never disturbs existing accounts.
    if let created = try? await AccountManager(store: store).createFirstAdminIfNeeded() {
        let creds = "username: \(created.username)\npassword: \(created.password)\n"
        if let dir = try? AppPaths.supportDirectory() {
            let url = dir.appending(path: "first-admin.txt")
            try? creds.data(using: .utf8)?.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            daemonLogger.notice("created first admin — one-time password at \(url.path)")
        }
    }
    do {
        try await server.runUntilTerminated(config: serverConfig, logger: daemonLogger)
    } catch {
        FileHandle.standardError.write(Data("macerodactyld: server error: \(error)\n".utf8))
    }
    done.signal()
}

done.wait()
