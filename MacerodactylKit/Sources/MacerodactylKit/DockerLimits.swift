import Foundation

/// A container's configured resource limits, read from `docker inspect`'s
/// `HostConfig` — NOT from `docker stats`, whose "limit" silently falls back to
/// the host's total memory when no limit is set (which would look like a real
/// ceiling). `nil` means genuinely unlimited, and the UI shows "Unlimited"
/// rather than inventing a number.
///
/// Disk usage is deliberately absent: per-container disk needs `docker ps
/// --size` / `docker system df -v`, both expensive to poll, so that stat is
/// omitted rather than faked.
public struct ContainerLimits: Sendable, Equatable {
    /// Memory limit in bytes, or nil if unlimited.
    public let memoryBytes: Int64?
    /// CPU limit in cores (e.g. 1.5), or nil if unlimited.
    public let cpuCores: Double?

    public init(memoryBytes: Int64?, cpuCores: Double?) {
        self.memoryBytes = memoryBytes
        self.cpuCores = cpuCores
    }

    public static let unlimited = ContainerLimits(memoryBytes: nil, cpuCores: nil)
}

extension DockerCLI {
    /// Reads limits for the given container ids in ONE `docker inspect` call
    /// (limits are static-ish, so callers fetch them on load, not every poll).
    /// Keyed by container name. Missing/failed ids simply don't appear.
    public func containerLimits(ids: [String]) async -> [String: ContainerLimits] {
        guard !ids.isEmpty else { return [:] }
        // One line per container: name|memory|nanoCpus|cpuQuota|cpuPeriod.
        let format = "{{.Name}}|{{.HostConfig.Memory}}|{{.HostConfig.NanoCpus}}|{{.HostConfig.CpuQuota}}|{{.HostConfig.CpuPeriod}}"
        guard let output = try? await run(["inspect", "--format", format] + ids, timeout: .seconds(20)) else {
            return [:]
        }
        return DockerLimitsParser.parse(output)
    }
}

/// Pure parser for the `docker inspect` limits lines (the testable core).
public enum DockerLimitsParser {
    public static func parse(_ output: String) -> [String: ContainerLimits] {
        var result: [String: ContainerLimits] = [:]
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let parts = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 5 else { continue }
            // `.Name` comes back as "/name"; strip the leading slash.
            let name = parts[0].hasPrefix("/") ? String(parts[0].dropFirst()) : parts[0]
            guard !name.isEmpty else { continue }

            let memory = Int64(parts[1]) ?? 0
            let nanoCpus = Int64(parts[2]) ?? 0
            let cpuQuota = Int64(parts[3]) ?? 0
            let cpuPeriod = Int64(parts[4]) ?? 0

            let memoryBytes: Int64? = memory > 0 ? memory : nil
            let cpuCores: Double?
            if nanoCpus > 0 {
                cpuCores = Double(nanoCpus) / 1_000_000_000
            } else if cpuQuota > 0, cpuPeriod > 0 {
                cpuCores = Double(cpuQuota) / Double(cpuPeriod)
            } else {
                cpuCores = nil
            }
            result[name] = ContainerLimits(memoryBytes: memoryBytes, cpuCores: cpuCores)
        }
        return result
    }
}
