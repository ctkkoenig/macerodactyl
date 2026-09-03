import Foundation

/// The runtime facts Wings injects into every server as environment variables
/// and makes available for `{{...}}` substitution in the startup command. These
/// come from the allocation and resource limits chosen at create time, not from
/// the egg.
public struct ServerRuntimeContext: Sendable, Equatable {
    public var memoryMiB: Int
    public var swapMiB: Int
    public var diskMiB: Int
    /// Inside the container the server binds all interfaces; the host mapping is
    /// the allocation. So `SERVER_IP` is "0.0.0.0", matching Wings.
    public var ip: String
    public var port: Int
    public var cpuPercent: Int
    public var uuid: String
    public var location: String
    public var timezone: String

    public init(
        memoryMiB: Int,
        swapMiB: Int = 0,
        diskMiB: Int = 0,
        ip: String = "0.0.0.0",
        port: Int,
        cpuPercent: Int = 0,
        uuid: String,
        location: String = "",
        timezone: String = "UTC"
    ) {
        self.memoryMiB = memoryMiB
        self.swapMiB = swapMiB
        self.diskMiB = diskMiB
        self.ip = ip
        self.port = port
        self.cpuPercent = cpuPercent
        self.uuid = uuid
        self.location = location
        self.timezone = timezone
    }

    /// The magic environment variables, matching Wings' names.
    public var magicEnvironment: [String: String] {
        [
            "SERVER_MEMORY": String(memoryMiB),
            "SERVER_SWAP": String(swapMiB),
            "SERVER_DISK": String(diskMiB),
            "SERVER_IP": ip,
            "SERVER_PORT": String(port),
            "SERVER_CPU": String(cpuPercent),
            "P_SERVER_UUID": uuid,
            "P_SERVER_LOCATION": location,
            "TZ": timezone,
        ]
    }
}

/// Resolves egg variables + runtime context into the container environment and
/// the substituted startup command. Pure and thoroughly tested — after install
/// execution this is the highest-fidelity-risk surface, so it's kept free of I/O
/// and matched to Wings' documented behavior.
public enum VariableResolver {
    /// The container environment: every egg variable's resolved value, plus the
    /// magic runtime variables. A variable's value is the user override when the
    /// variable is user-editable and an override was supplied, otherwise its
    /// default. Non-editable variables always use their default (server-side
    /// enforcement of `user_editable`). Magic vars win on a name collision.
    public static func environment(
        egg: PterodactylEgg,
        values: [String: String],
        runtime: ServerRuntimeContext
    ) -> [String: String] {
        var env: [String: String] = [:]
        for variable in egg.variables {
            let resolved: String
            if variable.userEditable, let override = values[variable.envVariable] {
                resolved = override
            } else {
                resolved = variable.defaultValue
            }
            env[variable.envVariable] = resolved
        }
        // Magic runtime vars are authoritative and override any egg variable that
        // happens to reuse one of these reserved names.
        for (key, value) in runtime.magicEnvironment {
            env[key] = value
        }
        return env
    }

    public struct SubstitutionResult: Sendable, Equatable {
        public let value: String
        /// `{{NAMES}}` referenced in the template that weren't in the environment
        /// (replaced with "", matching Wings) — surfaced so the UI can warn.
        public let unknownVariables: [String]
    }

    private static let placeholder = try! NSRegularExpression(
        pattern: "\\{\\{\\s*([A-Za-z0-9_]+)\\s*\\}\\}")

    /// Replaces `{{VAR}}` with `environment[VAR]` in a single left-to-right pass
    /// (no recursive expansion — Wings does one pass). Unknown placeholders become
    /// the empty string and are reported.
    public static func substitute(
        _ template: String, environment: [String: String]
    ) -> SubstitutionResult {
        let ns = template as NSString
        let matches = placeholder.matches(
            in: template, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return SubstitutionResult(value: template, unknownVariables: []) }

        var result = ""
        var unknown: [String] = []
        var cursor = 0
        for match in matches {
            let full = match.range
            let name = ns.substring(with: match.range(at: 1))
            // Text between the previous match and this one, verbatim.
            if full.location > cursor {
                result += ns.substring(with: NSRange(location: cursor, length: full.location - cursor))
            }
            if let value = environment[name] {
                result += value
            } else if !unknown.contains(name) {
                unknown.append(name)
            }
            cursor = full.location + full.length
        }
        if cursor < ns.length {
            result += ns.substring(with: NSRange(location: cursor, length: ns.length - cursor))
        }
        return SubstitutionResult(value: result, unknownVariables: unknown)
    }

    /// Convenience: resolve the environment and substitute the egg's startup in
    /// one call.
    public static func resolveStartup(
        egg: PterodactylEgg,
        values: [String: String],
        runtime: ServerRuntimeContext
    ) -> (environment: [String: String], startup: SubstitutionResult) {
        let env = environment(egg: egg, values: values, runtime: runtime)
        return (env, substitute(egg.startup, environment: env))
    }
}
