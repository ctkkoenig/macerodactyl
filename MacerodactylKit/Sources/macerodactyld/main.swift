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

// First run: the operator creates the first admin through the browser (the panel
// serves a setup page while no account exists) rather than fishing a password out
// of an on-disk file. Just note where to go; never auto-mint an account here.
if (try? AccountManager(store: store).hasAnyUser()) == false {
    logger.notice("no accounts yet — open the panel and complete first-run setup to create the admin")
}

let containers = DaemonContainerService(cli: cli, stacksRoot: config.stacksRootURL, store: store)
let server = PanelServer(store: store, containers: containers)

// Cross-platform scheduled task chains. launchd does not exist on this (Linux)
// host, so the DB-backed schedules the web writes are fired by an in-process
// cron loop. A schedule runs its ordered chain — power / console command /
// backup — or, with no chain, the implicit single restart. This never starts a
// container at boot (compose restart policies own that); the daemon only acts on
// a schedule's own tasks. Power runs under a hard deadline so a hung docker
// (stale socket) is recorded as a timeout, not awaited forever.
let scheduler = InProcessScheduler(store: store) { name, task in
    switch task.action {
    case .power:
        do {
            _ = try await cli.run([task.payload, name], timeout: .seconds(60))
            return .success("\(task.payload) \(name)")
        } catch DockerError.timeout {
            return .timedOut("docker \(task.payload) \(name) timed out (the daemon may be down or the socket is stale)")
        } catch {
            return .failed("docker \(task.payload) \(name) failed: \(error)")
        }
    case .command:
        let ok = await containers.consoleSend(containerName: name, line: task.payload)
        return ok ? .success("sent to console") : .failed("the server isn't running / has no console")
    case .backup:
        do {
            _ = try await containers.createBackup(containerName: name)
            return .success("backed up \(name)")
        } catch {
            return .failed("backup failed: \(error)")
        }
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
    // Graceful stop: cancel the loop, then WAIT for any in-flight restart to
    // finish recording its outcome before the process exits (a SIGKILL can't be
    // drained — nothing can — but a normal SIGTERM shutdown no longer loses the
    // record of a restart it was in the middle of firing).
    schedulerTask.cancel()
    _ = await schedulerTask.value
    await scheduler.awaitInFlight()  // let any running chain finish recording
} catch {
    schedulerTask.cancel()
    fail("server error: \(error)")
}
