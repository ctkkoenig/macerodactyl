import Foundation

/// Configuration the web-panel daemon needs, shared between the GUI and the
/// headless `macerodactyld` process via a JSON file on disk. The two run as
/// separate processes with separate `UserDefaults` domains, so a file is the
/// shared surface. The GUI writes it when panel settings change; the daemon
/// reads it at startup. Only daemon-relevant settings live here — the GUI keeps
/// its own preferences (refresh interval, etc.) in `UserDefaults`.
public struct PanelConfig: Codable, Sendable, Equatable {
    public var port: Int
    /// Bind 0.0.0.0 (LAN) instead of 127.0.0.1. An explicit, warned opt-in.
    public var bindLAN: Bool
    /// Optional explicit docker binary path (else auto-resolved).
    public var dockerPathOverride: String?
    /// Absolute path to the stacks root (compose folders live here).
    public var stacksRoot: String
    /// Serve HTTPS with a self-signed cert (Tier 1.5). Off by default; TLS is
    /// normally terminated at a tunnel.
    public var tlsEnabled: Bool

    public init(
        port: Int = AppSettings.defaultPanelPort,
        bindLAN: Bool = false,
        dockerPathOverride: String? = nil,
        stacksRoot: String = AppSettings.defaultStacksRoot.path,
        tlsEnabled: Bool = false
    ) {
        self.port = port
        self.bindLAN = bindLAN
        self.dockerPathOverride = dockerPathOverride
        self.stacksRoot = stacksRoot
        self.tlsEnabled = tlsEnabled
    }

    /// Tolerant decoding: any missing key falls back to its default, so an old
    /// config file keeps working when new fields are added.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? AppSettings.defaultPanelPort
        bindLAN = try c.decodeIfPresent(Bool.self, forKey: .bindLAN) ?? false
        dockerPathOverride = try c.decodeIfPresent(String.self, forKey: .dockerPathOverride)
        stacksRoot = try c.decodeIfPresent(String.self, forKey: .stacksRoot) ?? AppSettings.defaultStacksRoot.path
        tlsEnabled = try c.decodeIfPresent(Bool.self, forKey: .tlsEnabled) ?? false
    }

    public var stacksRootURL: URL { URL(fileURLWithPath: (stacksRoot as NSString).expandingTildeInPath) }

    public static func fileURL() throws -> URL {
        try AppPaths.supportDirectory().appending(path: "config.json")
    }

    /// Loads the shared config, or the defaults if it's missing/unreadable.
    public static func load() -> PanelConfig {
        guard let url = try? fileURL(), let data = try? Data(contentsOf: url),
            let config = try? JSONDecoder().decode(PanelConfig.self, from: data)
        else {
            return PanelConfig()
        }
        return config
    }

    /// Atomically writes the config so a daemon reading concurrently never sees
    /// a half-written file.
    public func save() throws {
        let url = try Self.fileURL()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
