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

    public static var dockerPathOverride: String? {
        get { UserDefaults.standard.string(forKey: dockerPathOverrideKey) }
        set { UserDefaults.standard.set(newValue, forKey: dockerPathOverrideKey) }
    }

    public static var refreshInterval: TimeInterval {
        let value = UserDefaults.standard.double(forKey: refreshIntervalKey)
        return value > 0 ? value : defaultRefreshInterval
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

public extension Notification.Name {
    /// Posted when a setting changes so live views re-read without a restart.
    static let macerodactylSettingsChanged = Notification.Name("macerodactylSettingsChanged")
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
