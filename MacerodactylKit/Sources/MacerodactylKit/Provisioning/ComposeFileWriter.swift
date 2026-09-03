import Foundation

/// A host↔container port mapping for a provisioned server.
public struct PortMapping: Sendable, Equatable {
    public var hostIP: String
    public var hostPort: Int
    public var containerPort: Int
    public var proto: String
    public init(hostIP: String, hostPort: Int, containerPort: Int, proto: String = "tcp") {
        self.hostIP = hostIP
        self.hostPort = hostPort
        self.containerPort = containerPort
        self.proto = proto
    }
}

/// An extra bind mount attached to a server (the "Mounts" feature).
public struct VolumeMount: Sendable, Equatable {
    public var source: String
    public var target: String
    public var readOnly: Bool
    public init(source: String, target: String, readOnly: Bool = false) {
        self.source = source
        self.target = target
        self.readOnly = readOnly
    }
}

/// Everything needed to render a server's single-service compose stack. The
/// startup is already `{{VAR}}`-substituted; the environment is already resolved.
public struct ProvisionSpec: Sendable, Equatable {
    public var name: String
    public var serviceName: String
    public var image: String
    public var startup: String
    public var environment: [String: String]
    public var install: PterodactylEgg.InstallScript
    public var limits: ServerLimits
    public var portMappings: [PortMapping]
    public var extraMounts: [VolumeMount]
    /// The egg's `config.files` (raw JSON) — applied to the data dir before boot.
    public var configFiles: String
    /// Graceful-stop mapping from the egg's `config.stop` (see ComposeFileWriter).
    public var stopSignal: String?
    public var stopGracePeriodSeconds: Int?
    public var dataDirName: String
    public var containerDataPath: String
    public var restartPolicy: String

    public init(
        name: String,
        serviceName: String = "server",
        image: String,
        startup: String,
        environment: [String: String],
        install: PterodactylEgg.InstallScript = .init(),
        limits: ServerLimits = .init(),
        portMappings: [PortMapping] = [],
        extraMounts: [VolumeMount] = [],
        configFiles: String = "",
        stopSignal: String? = nil,
        stopGracePeriodSeconds: Int? = nil,
        dataDirName: String = "data",
        containerDataPath: String = "/home/container",
        restartPolicy: String = "unless-stopped"
    ) {
        self.name = name
        self.serviceName = serviceName
        self.image = image
        self.startup = startup
        self.environment = environment
        self.install = install
        self.limits = limits
        self.portMappings = portMappings
        self.extraMounts = extraMounts
        self.configFiles = configFiles
        self.stopSignal = stopSignal
        self.stopGracePeriodSeconds = stopGracePeriodSeconds
        self.dataDirName = dataDirName
        self.containerDataPath = containerDataPath
        self.restartPolicy = restartPolicy
    }
}

/// Renders a `ProvisionSpec` to a deterministic `docker-compose.yml`. The output
/// is hand-emitted (no YAML dependency) with strict double-quoting of every
/// scalar that can carry metacharacters — the startup command especially, which
/// legitimately contains shell syntax (`$(...)`, `&&`, quotes) that must survive
/// into the container's own bash untouched. `docker compose up` injects the
/// project/service/working_dir labels itself, so none are written here.
public enum ComposeFileWriter {
    public static func compose(_ spec: ProvisionSpec) -> String {
        var lines: [String] = []
        lines.append("services:")
        lines.append("  \(spec.serviceName):")
        lines.append("    container_name: \(spec.name)")
        lines.append("    image: \(yaml(spec.image))")
        lines.append("    working_dir: \(spec.containerDataPath)")
        // Run the substituted startup through the container's own bash so shell
        // syntax in the startup works, matching Wings.
        lines.append("    entrypoint: [\"/bin/bash\", \"-c\"]")
        lines.append("    command: [\(yaml(spec.startup))]")
        // Keep stdin open (no TTY) so `docker attach` can write to the server
        // process — the basis of a real interactive console (see ConsoleBroker).
        lines.append("    stdin_open: true")
        lines.append("    tty: false")
        lines.append("    restart: \(spec.restartPolicy)")
        // Graceful shutdown from the egg's config.stop (T0.3): a specific signal
        // and/or a longer grace window so a save completes before SIGKILL.
        if let signal = spec.stopSignal, !signal.isEmpty {
            lines.append("    stop_signal: \(signal)")
        }
        if let grace = spec.stopGracePeriodSeconds, grace > 0 {
            lines.append("    stop_grace_period: \(grace)s")
        }

        if !spec.environment.isEmpty {
            lines.append("    environment:")
            for key in spec.environment.keys.sorted() {
                lines.append("      \(key): \(yaml(spec.environment[key] ?? ""))")
            }
        }

        if !spec.portMappings.isEmpty {
            lines.append("    ports:")
            for p in spec.portMappings {
                lines.append("      - \(yaml("\(p.hostIP):\(p.hostPort):\(p.containerPort)/\(p.proto)"))")
            }
        }

        lines.append("    volumes:")
        lines.append("      - \(yaml("./\(spec.dataDirName):\(spec.containerDataPath)"))")
        for m in spec.extraMounts {
            let suffix = m.readOnly ? ":ro" : ""
            lines.append("      - \(yaml("\(m.source):\(m.target)\(suffix)"))")
        }

        appendLimits(spec.limits, to: &lines)

        return lines.joined(separator: "\n") + "\n"
    }

    private static func appendLimits(_ limits: ServerLimits, to lines: inout [String]) {
        if let mem = limits.memoryLimitMiB {
            lines.append("    mem_limit: \(mem)m")
        }
        if let swap = limits.memSwapLimitMiB {
            lines.append("    memswap_limit: \(swap == -1 ? "-1" : "\(swap)m")")
        }
        if let cpus = limits.cpus {
            // Trim a trailing ".0" for whole cores, but keep fractional values.
            lines.append("    cpus: \(formatCPUs(cpus))")
        }
        if let pinning = limits.cpuPinning, !pinning.isEmpty {
            lines.append("    cpuset: \(yaml(pinning))")
        }
        if let weight = limits.ioWeight {
            lines.append("    blkio_config:")
            lines.append("      weight: \(weight)")
        }
        if let pids = limits.pidsLimit {
            lines.append("    pids_limit: \(pids)")
        }
        if limits.effectiveOOMKillDisable {
            lines.append("    oom_kill_disable: true")
        }
    }

    static func formatCPUs(_ value: Double) -> String {
        if value == value.rounded() { return String(Int(value)) }
        return String(value)
    }

    /// A YAML double-quoted scalar with the escapes YAML requires inside double
    /// quotes: backslash, double-quote, and the common control characters.
    static func yaml(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            case "\r": out += "\\r"
            default: out.unicodeScalars.append(scalar)
            }
        }
        out += "\""
        return out
    }
}
