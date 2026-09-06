import Foundation

#if canImport(Darwin)
import Darwin
#endif

/// One reading of how the machine itself is doing, as opposed to a container.
///
/// Every field is optional because the sources differ in availability: sysctl
/// and Mach always answer, the SMC may not exist (a VM, or a future model whose
/// sensor names have moved). A missing value is reported as null and rendered
/// as an em dash rather than a fabricated zero — a temperature of 0 C would
/// look like a working sensor.
public struct HostMetrics: Sendable, Equatable, Codable {
    public var measuredAt: Date

    // Hardware sensors (SMC)
    public var cpuTempC: Double?
    public var gpuTempC: Double?
    public var fanRPM: Double?
    public var fanMaxRPM: Double?
    /// Total system draw at the DC input, which includes the fan — unlike the
    /// SoC package figure, which does not.
    public var systemPowerW: Double?

    // Operating system
    public var cpuUsagePercent: Double?
    public var loadAverage1: Double?
    public var memUsedBytes: Double?
    public var memTotalBytes: Double?
    public var swapUsedBytes: Double?
    public var diskFreeBytes: Double?
    public var diskTotalBytes: Double?
    public var uptimeSeconds: Double?

    public init(measuredAt: Date = Date()) {
        self.measuredAt = measuredAt
    }

    /// Fan speed as a fraction of its maximum, which is the number worth showing:
    /// 1900 rpm means nothing without knowing the ceiling is 4900.
    public var fanPercent: Double? {
        guard let fanRPM, let fanMaxRPM, fanMaxRPM > 0 else { return nil }
        return fanRPM / fanMaxRPM * 100
    }
}

#if canImport(Darwin)

/// Samples `HostMetrics`. Holds the previous CPU tick counts, because processor
/// usage is only meaningful as a delta between two samples.
public final class HostMetricsCollector: @unchecked Sendable {
    private let smc: SMC?
    private let lock = NSLock()
    private var previousTicks: (idle: UInt64, total: UInt64)?

    /// `smc` is resolved once. If the controller is unavailable the collector
    /// still returns everything the OS can answer for.
    public init(smc: SMC? = SMC()) {
        self.smc = smc
    }

    public func sample() -> HostMetrics {
        var m = HostMetrics()

        if let smc {
            m.cpuTempC = smc.meanTemperature(prefix: "Tp")
            m.gpuTempC = smc.meanTemperature(prefix: "Tg")
            m.fanRPM = smc.read("F0Ac")
            m.fanMaxRPM = smc.read("F0Mx")
            // PDTR is "DC In Total Power" — the whole board. PSTR is a narrower
            // system figure that excludes some rails; PDTR is what corresponds
            // to what a meter at the wall would see, less PSU loss.
            m.systemPowerW = smc.read("PDTR") ?? smc.read("PSTR")
        }

        m.cpuUsagePercent = cpuUsagePercent()
        m.loadAverage1 = loadAverage1()
        let memory = memoryUsage()
        m.memUsedBytes = memory?.used
        m.memTotalBytes = memory?.total
        m.swapUsedBytes = swapUsed()
        let disk = rootDisk()
        m.diskFreeBytes = disk?.free
        m.diskTotalBytes = disk?.total
        m.uptimeSeconds = uptime()
        return m
    }

    // MARK: - CPU

    /// Busy time as a percentage of elapsed processor time since the previous
    /// call. The first call has nothing to compare against and returns nil
    /// rather than a meaningless since-boot average.
    private func cpuUsagePercent() -> Double? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        let user = UInt64(info.cpu_ticks.0)
        let system = UInt64(info.cpu_ticks.1)
        let idle = UInt64(info.cpu_ticks.2)
        let nice = UInt64(info.cpu_ticks.3)
        let total = user &+ system &+ idle &+ nice

        lock.lock()
        defer { lock.unlock() }
        defer { previousTicks = (idle, total) }
        guard let previous = previousTicks else { return nil }

        let totalDelta = total &- previous.total
        let idleDelta = idle &- previous.idle
        guard totalDelta > 0 else { return nil }
        return (1.0 - Double(idleDelta) / Double(totalDelta)) * 100
    }

    private func loadAverage1() -> Double? {
        var loads = [Double](repeating: 0, count: 3)
        guard getloadavg(&loads, 3) == 3 else { return nil }
        return loads[0]
    }

    // MARK: - Memory

    /// "Used" here matches what Activity Monitor calls Memory Used: the pages
    /// that are not reclaimable on demand. Free plus purgeable is deliberately
    /// excluded — counting cache as used would show a machine at 100% forever.
    private func memoryUsage() -> (used: Double, total: Double)? {
        var size: UInt64 = 0
        var length = MemoryLayout<UInt64>.size
        guard sysctlbyname("hw.memsize", &size, &length, nil, 0) == 0, size > 0 else { return nil }

        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        // Queried rather than read from the global `vm_kernel_page_size`, which
        // Swift 6 rejects as shared mutable state.
        var pageSize: vm_size_t = 0
        guard host_page_size(mach_host_self(), &pageSize) == KERN_SUCCESS, pageSize > 0 else { return nil }
        let page = Double(pageSize)
        let used =
            (Double(stats.active_count) + Double(stats.wire_count) + Double(stats.compressor_page_count)) * page
        return (used, Double(size))
    }

    private func swapUsed() -> Double? {
        var usage = xsw_usage()
        var length = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &length, nil, 0) == 0 else { return nil }
        return Double(usage.xsu_used)
    }

    // MARK: - Disk and uptime

    /// The boot volume. Containers, images and the panel database all live on
    /// it, so it is the one that matters for "will this keep working".
    private func rootDisk() -> (free: Double, total: Double)? {
        var fs = statfs()
        guard statfs("/", &fs) == 0 else { return nil }
        let block = Double(fs.f_bsize)
        return (Double(fs.f_bavail) * block, Double(fs.f_blocks) * block)
    }

    private func uptime() -> Double? {
        var boot = timeval()
        var length = MemoryLayout<timeval>.size
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        guard sysctl(&mib, 2, &boot, &length, nil, 0) == 0, boot.tv_sec > 0 else { return nil }
        return Date().timeIntervalSince1970 - Double(boot.tv_sec)
    }
}

#else

/// Non-Darwin builds. The panel still serves; the host page simply has nothing
/// to report, which the UI already handles — every field is optional and renders
/// as an em dash rather than a fabricated zero.
public final class HostMetricsCollector: @unchecked Sendable {
    public init() {}
    public func sample() -> HostMetrics { HostMetrics() }
}

#endif  // canImport(Darwin)
