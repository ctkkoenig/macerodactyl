import Foundation

/// UserDefaults-backed settings, shared by the native UI and the web layer.
public enum AppSettings {
    public static let dockerPathOverrideKey = "dockerPathOverride"
    public static let refreshIntervalKey = "refreshInterval"
    public static let stacksRootKey = "stacksRoot"
    // Web panel (wired up in Phase 3; keys reserved now)
    public static let panelEnabledKey = "panelEnabled"
    public static let panelPortKey = "panelPort"
    public static let panelBindLANKey = "panelBindLAN"

    public static let defaultRefreshInterval: TimeInterval = 3
    public static let defaultPanelPort = 27180

    /// True when launched by the XCUITest smoke test (via the `-uitest` argument).
    /// The app then skips its continuous docker polling and the single-instance
    /// guard, so `XCUIApplication.launch()` can reach an idle, testable state.
    public static var isUITesting: Bool {
        ProcessInfo.processInfo.arguments.contains("-uitest")
    }

    public static var dockerPathOverride: String? {
        get { UserDefaults.standard.string(forKey: dockerPathOverrideKey) }
        set { UserDefaults.standard.set(newValue, forKey: dockerPathOverrideKey) }
    }

    public static var refreshInterval: TimeInterval {
        let value = UserDefaults.standard.double(forKey: refreshIntervalKey)
        return value > 0 ? value : defaultRefreshInterval
    }

    // MARK: Web panel

    public static var panelEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: panelEnabledKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: panelEnabledKey)
            NotificationCenter.default.post(name: .macerodactylPanelSettingsChanged, object: nil)
        }
    }

    public static var panelPort: Int {
        get {
            let value = UserDefaults.standard.integer(forKey: panelPortKey)
            return value > 0 ? value : defaultPanelPort
        }
        set {
            UserDefaults.standard.set(newValue, forKey: panelPortKey)
            NotificationCenter.default.post(name: .macerodactylPanelSettingsChanged, object: nil)
        }
    }

    /// Whether the panel binds to the LAN (0.0.0.0) instead of localhost only.
    /// An explicit, warned opt-in.
    public static var panelBindLAN: Bool {
        get { UserDefaults.standard.bool(forKey: panelBindLANKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: panelBindLANKey)
            NotificationCenter.default.post(name: .macerodactylPanelSettingsChanged, object: nil)
        }
    }

    public static let panelTLSEnabledKey = "panelTLSEnabled"

    /// Serve the panel over HTTPS with a self-signed cert. For LAN access
    /// without a tunnel — encrypts credentials on the wire. Off by default.
    public static var panelTLSEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: panelTLSEnabledKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: panelTLSEnabledKey)
            NotificationCenter.default.post(name: .macerodactylPanelSettingsChanged, object: nil)
        }
    }

    /// The panel-daemon config derived from the current GUI settings. Writing it
    /// to the shared file lets a `macerodactyld` process serve with the same
    /// port/bind/TLS the GUI chose.
    public static func currentPanelConfig() -> PanelConfig {
        PanelConfig(
            port: panelPort, bindLAN: panelBindLAN, dockerPathOverride: dockerPathOverride,
            stacksRoot: stacksRoot.path, tlsEnabled: panelTLSEnabled)
    }

    /// Persists the shared panel config so the daemon stays in step with the GUI.
    public static func syncPanelConfig() {
        try? currentPanelConfig().save()
    }

    /// Root under which stack folders (compose file + bind-mounted data) live.
    /// Defaults to ~/stacks; user-overridable, tilde-expanded.
    public static var stacksRoot: URL {
        get {
            if let path = UserDefaults.standard.string(forKey: stacksRootKey), !path.isEmpty {
                return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            }
            return defaultStacksRoot
        }
        set {
            UserDefaults.standard.set(newValue.path, forKey: stacksRootKey)
            NotificationCenter.default.post(name: .macerodactylSettingsChanged, object: nil)
        }
    }

    public static var defaultStacksRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "stacks")
    }

    /// Whether the configured stacks root currently exists as a directory.
    public static func stacksRootExists() -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: stacksRoot.path, isDirectory: &isDir) && isDir.boolValue
    }

    /// Creates the stacks root if missing. Returns the URL on success.
    @discardableResult
    public static func createStacksRoot() throws -> URL {
        try FileManager.default.createDirectory(at: stacksRoot, withIntermediateDirectories: true)
        return stacksRoot
    }

    public static func setDockerPathOverride(_ path: String?) {
        UserDefaults.standard.set(path, forKey: dockerPathOverrideKey)
        NotificationCenter.default.post(name: .macerodactylSettingsChanged, object: nil)
    }

    public static func setRefreshInterval(_ interval: TimeInterval) {
        UserDefaults.standard.set(interval, forKey: refreshIntervalKey)
        NotificationCenter.default.post(name: .macerodactylSettingsChanged, object: nil)
    }
}

extension Notification.Name {
    /// Posted when a setting changes so live views re-read without a restart.
    public static let macerodactylSettingsChanged = Notification.Name("macerodactylSettingsChanged")
    /// Posted when a web-panel setting changes so the server restarts/rebinds.
    public static let macerodactylPanelSettingsChanged = Notification.Name("macerodactylPanelSettingsChanged")
}

public enum AppPaths {
    /// ~/Library/Application Support/Macerodactyl (created on demand).
    public static func supportDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )
        let dir = base.appending(path: "Macerodactyl")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    public static func databasePath() throws -> String {
        try supportDirectory().appending(path: "panel.sqlite").path
    }
}
