import Foundation

/// The resource limits chosen when *creating* a server. This is deliberately
/// separate from `ContainerLimits` (which is the read-only view derived from
/// `docker inspect` of an existing container): this one is richer and models the
/// full Pterodactyl create form, and its job is to be translated into compose
/// keys by `ComposeFileWriter`.
///
/// Pterodactyl's "0 means unlimited" and "cpu percent = threads × 100"
/// conventions are preserved so eggs and operators see familiar numbers.
public struct ServerLimits: Sendable, Equatable, Codable {
    /// Memory in MiB; 0 = unlimited.
    public var memoryMiB: Int
    /// Additional swap in MiB; 0 = swap disabled, -1 = unlimited.
    public var swapMiB: Int
    /// Disk in MiB; 0 = unlimited. NOTE: not hard-enforced on Docker Desktop for
    /// macOS (no project quotas on bind mounts) — stored/displayed as a soft
    /// target, never faked as enforced.
    public var diskMiB: Int
    /// CPU limit as a percent; 0 = unlimited, 100 = one core, 200 = two cores.
    public var cpuPercent: Int
    /// Optional CPU pinning (a docker `cpuset`, e.g. "0,2,3"); nil = all threads.
    public var cpuPinning: String?
    /// Optional block-IO weight (10–1000); nil = docker default.
    public var ioWeight: Int?
    /// Optional PID limit; nil = docker default.
    public var pidsLimit: Int?
    /// When true, docker will NOT OOM-kill the container at its memory limit.
    public var oomKillDisable: Bool

    public init(
        memoryMiB: Int = 0,
        swapMiB: Int = 0,
        diskMiB: Int = 0,
        cpuPercent: Int = 0,
        cpuPinning: String? = nil,
        ioWeight: Int? = nil,
        pidsLimit: Int? = nil,
        oomKillDisable: Bool = false
    ) {
        self.memoryMiB = memoryMiB
        self.swapMiB = swapMiB
        self.diskMiB = diskMiB
        self.cpuPercent = cpuPercent
        self.cpuPinning = cpuPinning
        self.ioWeight = ioWeight
        self.pidsLimit = pidsLimit
        self.oomKillDisable = oomKillDisable
    }

    // MARK: - Compose translations (nil = "omit this key / leave unlimited")

    /// `mem_limit` in MiB, or nil when unlimited.
    public var memoryLimitMiB: Int? { memoryMiB > 0 ? memoryMiB : nil }

    /// `memswap_limit` in MiB. Docker's `memswap_limit` is memory + swap
    /// combined; setting it equal to `mem_limit` disables swap. Returns -1 for
    /// unlimited swap, nil when there's no memory limit to anchor it to.
    public var memSwapLimitMiB: Int? {
        guard memoryMiB > 0 else { return nil }
        if swapMiB < 0 { return -1 }
        return memoryMiB + max(swapMiB, 0)
    }

    /// `cpus` (fractional cores), or nil when unlimited.
    public var cpus: Double? {
        cpuPercent > 0 ? (Double(cpuPercent) / 100.0) : nil
    }

    /// `oom_kill_disable` only makes sense alongside a memory limit.
    public var effectiveOOMKillDisable: Bool {
        oomKillDisable && memoryMiB > 0
    }

    /// Whether disk is being requested as a (soft) limit — used to decide whether
    /// to show the "not enforced on this platform" note.
    public var hasDiskTarget: Bool { diskMiB > 0 }
}
