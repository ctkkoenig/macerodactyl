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
    public static var stacksRoot: URL {
        if let path = UserDefaults.standard.string(forKey: stacksRootKey), !path.isEmpty {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appending(path: "stacks")
    }
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
