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
        // Create 0600 at creation time — no window where the one-time password
        // is world-readable (createFile applies the mode as the file is made).
        try? FileManager.default.removeItem(at: url)
        FileManager.default.createFile(
            atPath: url.path, contents: Data(creds.utf8), attributes: [.posixPermissions: 0o600])
        logger.notice("created first admin — one-time password at \(url.path)")
    }
}

let containers = DaemonContainerService(cli: cli, stacksRoot: config.stacksRootURL, store: store)
let server = PanelServer(store: store, containers: containers)

// Cross-platform scheduled restarts. launchd does not exist on this (Linux)
// host, so the DB-backed schedules the web writes are fired by an in-process
// cron loop instead. Restart-only — this never starts a container at boot;
// compose restart policies own that. Each restart runs under a hard deadline so
// a hung docker (stale socket) is recorded as a timeout, not awaited forever.
let scheduler = InProcessScheduler(store: store) { name in
    do {
        _ = try await cli.run(["restart", name], timeout: .seconds(60))
        return .success("restarted \(name)")
    } catch DockerError.timeout {
        return .timedOut("docker restart \(name) timed out (the daemon may be down or the socket is stale)")
    } catch {
        return .failed("docker restart \(name) failed: \(error)")
    }
}
let schedulerTask = Task { await scheduler.run() }

// TLS is opt-in for LAN-without-tunnel: generate a self-signed cert on demand.
// Fail CLOSED — someone who enabled HTTPS must never be silently downgraded to
// plaintext (which would also strip the Secure cookie flag). If the cert can't
// be produced, refuse to serve rather than send credentials in the clear.
var tlsFiles: PanelServerConfig.TLSFiles?
if config.tlsEnabled {
    do {
        let paths = try SelfSignedCertificate.ensure()
        tlsFiles = .init(certificatePath: paths.certificate, privateKeyPath: paths.privateKey)
        logger.notice("HTTPS enabled with self-signed certificate at \(paths.certificate)")
    } catch {
        fail(
            "HTTPS was requested but the certificate could not be produced (\(error)). Refusing to serve plain HTTP. Install openssl or turn HTTPS off in the app."
        )
    }
}

let scheme = tlsFiles == nil ? "http" : "https"
let host = config.bindLAN ? "0.0.0.0 (LAN)" : "127.0.0.1 (local only)"
logger.notice("macerodactyld serving \(scheme) on \(host):\(config.port) — docker at \(dockerURL.path)")

do {
    try await server.runUntilTerminated(
        config: .init(port: config.port, bindLAN: config.bindLAN, tls: tlsFiles), logger: logger)
    schedulerTask.cancel()
} catch {
    schedulerTask.cancel()
    fail("server error: \(error)")
}
