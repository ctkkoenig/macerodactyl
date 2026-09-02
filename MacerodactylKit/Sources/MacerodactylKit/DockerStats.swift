import Foundation

/// One measured resource reading for a container. Every field here was read
/// from `docker stats`; nothing is inferred or zero-filled. Absence is modeled
/// by the *absence* of a `ContainerStats`, never by a zero.
public struct ContainerStats: Sendable, Equatable {
    public let name: String
    public let cpuPercent: Double
    public let memUsedBytes: Double
    public let memLimitBytes: Double
    public let memPercent: Double
    public let netRxBytes: Double
    public let netTxBytes: Double
    public let pids: Int
    public let measuredAt: Date

    public init(
        name: String, cpuPercent: Double, memUsedBytes: Double, memLimitBytes: Double,
        memPercent: Double, netRxBytes: Double, netTxBytes: Double, pids: Int, measuredAt: Date = Date()
    ) {
        self.name = name
        self.cpuPercent = cpuPercent
        self.memUsedBytes = memUsedBytes
        self.memLimitBytes = memLimitBytes
        self.memPercent = memPercent
        self.netRxBytes = netRxBytes
        self.netTxBytes = netTxBytes
        self.pids = pids
        self.measuredAt = measuredAt
    }
}

/// Pure parsing of `docker stats --format '{{json .}}'` lines, including the
/// human-readable unit strings docker emits ("1.5MiB / 512MiB", "1.2kB / 3.4MB",
/// "12.34%"). This is the testable core — unit handling is where the bugs hide.
public enum DockerStatsParser {
    private struct StatsLine: Decodable {
        let Name: String?
        let Container: String?
        let CPUPerc: String?
        let MemUsage: String?
        let MemPerc: String?
        let NetIO: String?
        let PIDs: String?
    }

    /// Parses one JSON line, or nil if it can't be read (skipped, not zeroed).
    public static func parse(line: String, now: Date = Date()) -> ContainerStats? {
        guard let data = line.data(using: .utf8),
            let stats = try? JSONDecoder().decode(StatsLine.self, from: data),
            let name = stats.Name ?? stats.Container
        else { return nil }
        let (used, limit) = splitPair(stats.MemUsage).map { (parseBytes($0.0), parseBytes($0.1)) } ?? (nil, nil)
        let (rx, tx) = splitPair(stats.NetIO).map { (parseBytes($0.0), parseBytes($0.1)) } ?? (nil, nil)
        // A running container always reports memory + net; if those are missing
        // the line isn't a usable reading.
        guard let used, let limit, let rx, let tx else { return nil }
        return ContainerStats(
            name: name,
            cpuPercent: parsePercent(stats.CPUPerc) ?? 0,
            memUsedBytes: used, memLimitBytes: limit,
            memPercent: parsePercent(stats.MemPerc) ?? (limit > 0 ? used / limit * 100 : 0),
            netRxBytes: rx, netTxBytes: tx,
            pids: stats.PIDs.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) } ?? 0,
            measuredAt: now
        )
    }

    /// Parses a whole `--no-stream` snapshot (one JSON object per line) into a
    /// name-keyed map. Only real readings appear; stopped containers are absent.
    public static func parseSnapshot(_ output: String, now: Date = Date()) -> [String: ContainerStats] {
        var result: [String: ContainerStats] = [:]
        for line in output.split(separator: "\n") {
            if let stats = parse(line: String(line), now: now) {
                result[stats.name] = stats
            }
        }
        return result
    }

    /// "12.34%" → 12.34; "--" or malformed → nil.
    static func parsePercent(_ value: String?) -> Double? {
        guard let value else { return nil }
        let trimmed = value.replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces)
        return Double(trimmed)
    }

    /// Splits "A / B" into (A, B). docker uses " / " as the separator.
    static func splitPair(_ value: String?) -> (String, String)? {
        guard let value else { return nil }
        let parts = value.components(separatedBy: "/")
        guard parts.count == 2 else { return nil }
        return (parts[0].trimmingCharacters(in: .whitespaces), parts[1].trimmingCharacters(in: .whitespaces))
    }

    /// Parses a docker byte string ("1.5MiB", "3.4MB", "1kB", "0B", "1.2GiB").
    /// docker mixes binary (MiB/GiB) and decimal (kB/MB) units; both are handled.
    static func parseBytes(_ value: String) -> Double? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        // Find where the numeric prefix ends.
        let split = trimmed.firstIndex { $0.isLetter } ?? trimmed.endIndex
        let numberPart = String(trimmed[trimmed.startIndex..<split])
        let unitPart = String(trimmed[split...]).trimmingCharacters(in: .whitespaces)
        guard let number = Double(numberPart) else { return nil }
        let multiplier: Double =
            switch unitPart {
            case "B", "": 1
            case "kB": 1_000
            case "KiB": 1_024
            case "MB": 1_000_000
            case "MiB": 1_048_576
            case "GB": 1_000_000_000
            case "GiB": 1_073_741_824
            case "TB": 1_000_000_000_000
            case "TiB": 1_099_511_627_776
            default: 1
            }
        return number * multiplier
    }
}

public enum ByteFormat {
    /// Compact human string for the UI ("512 MB", "1.4 GB").
    public static func string(_ bytes: Double) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
    }
}
