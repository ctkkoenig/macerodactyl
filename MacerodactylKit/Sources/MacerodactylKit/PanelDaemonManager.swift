import Foundation

/// Installs and supervises the web-panel daemon (`macerodactyld`) as a per-user
/// **LaunchAgent**, so the panel survives the GUI quitting, keeps running across
/// logins (the owner runs autologin), and restarts itself on crash via
/// `KeepAlive`. A LaunchAgent — not a LaunchDaemon — because Docker Desktop is a
/// per-user service whose socket a system (root) daemon can't cleanly reach.
///
/// `RunAtLoad` launches only the SERVER, never a container: booting the panel is
/// not booting workloads (that stays the job of compose restart policies).
public struct PanelDaemonManager: Sendable {
    public static let label = "com.macerodactyl.panel"

    public let launchAgentsDirectory: URL
    public let logsDirectory: URL
    let managesLaunchd: Bool

    public init() throws {
        launchAgentsDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/LaunchAgents")
        logsDirectory = try AppPaths.supportDirectory().appending(path: "daemon-logs")
        managesLaunchd = true
        try FileManager.default.createDirectory(at: launchAgentsDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
    }

    init(launchAgentsDirectory: URL, logsDirectory: URL, managesLaunchd: Bool) {
        self.launchAgentsDirectory = launchAgentsDirectory
        self.logsDirectory = logsDirectory
        self.managesLaunchd = managesLaunchd
    }

    public var plistPath: URL {
        launchAgentsDirectory.appending(path: "\(Self.label).plist")
    }

    /// The exact plist installed for a given daemon binary. `KeepAlive` keeps
    /// the server up whenever the agent is loaded; stopping the panel means
    /// unloading the agent, not letting the process exit. The binary path is
    /// absolute — launchd inherits no shell PATH.
    public func plistDictionary(daemonBinaryPath: String) -> [String: Any] {
        [
            "Label": Self.label,
            "ProgramArguments": [daemonBinaryPath],
            "RunAtLoad": true,
            "KeepAlive": true,
            "ProcessType": "Interactive",
            "StandardOutPath": logsDirectory.appending(path: "panel.out.log").path,
            "StandardErrorPath": logsDirectory.appending(path: "panel.err.log").path,
        ]
    }

    public func plistXML(daemonBinaryPath: String) throws -> String {
        let data = try PropertyListSerialization.data(
            fromPropertyList: plistDictionary(daemonBinaryPath: daemonBinaryPath), format: .xml, options: 0)
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: Lifecycle

    /// Writes the plist and loads the agent (replacing any existing one).
    public func install(daemonBinaryPath: String) throws {
        guard FileManager.default.isExecutableFile(atPath: daemonBinaryPath) else {
            throw DaemonError.binaryNotExecutable(daemonBinaryPath)
        }
        if FileManager.default.fileExists(atPath: plistPath.path) {
            _ = try? launchctl("bootout", "gui/\(getuid())/\(Self.label)")
        }
        do {
            let data = try PropertyListSerialization.data(
                fromPropertyList: plistDictionary(daemonBinaryPath: daemonBinaryPath), format: .xml, options: 0)
            try data.write(to: plistPath, options: .atomic)
        } catch {
            throw DaemonError.io(error.localizedDescription)
        }
        try launchctl("bootstrap", "gui/\(getuid())", plistPath.path)
    }

    /// Unloads the agent and deletes its plist — never orphans either half.
    public func uninstall() throws {
        _ = try? launchctl("bootout", "gui/\(getuid())/\(Self.label)")
        if FileManager.default.fileExists(atPath: plistPath.path) {
            try? FileManager.default.removeItem(at: plistPath)
        }
    }

    /// Asks launchd to restart the running instance (used after a config change).
    public func kickstart() throws {
        try launchctl("kickstart", "-k", "gui/\(getuid())/\(Self.label)")
    }

    public var isInstalled: Bool {
        FileManager.default.fileExists(atPath: plistPath.path)
    }

    /// Whether launchd currently has the agent loaded (present in its list).
    public func isLoaded() -> Bool {
        guard managesLaunchd else { return false }
        return (try? launchctl("print", "gui/\(getuid())/\(Self.label)")) != nil
    }

    /// The docker binary path currently baked into the installed plist, if any —
    /// used to detect a stale install after the app moves.
    public func installedBinaryPath() -> String? {
        guard let data = try? Data(contentsOf: plistPath),
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
            let args = plist["ProgramArguments"] as? [String]
        else { return nil }
        return args.first
    }

    // MARK: launchctl

    @discardableResult
    private func launchctl(_ args: String...) throws -> String {
        guard managesLaunchd else { return "" }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = args
        let errPipe = Pipe()
        process.standardError = errPipe
        process.standardOutput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw DaemonError.launchctlFailed(String(describing: error))
        }
        process.waitUntilExit()
        let stderr = String(
            decoding: errPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0 else {
            throw DaemonError.launchctlFailed(stderr.isEmpty ? "launchctl exited \(process.terminationStatus)" : stderr)
        }
        return stderr
    }
}

public enum DaemonError: Error, Equatable, Sendable {
    case binaryNotExecutable(String)
    case launchctlFailed(String)
    case io(String)
}
