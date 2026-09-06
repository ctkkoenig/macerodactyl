import Foundation

/// A host port that can be assigned to a server. On a single machine this is the
/// Pterodactyl "allocation": an `ip:port` the server's primary/extra ports bind
/// to on the host.
public struct PortAllocation: Sendable, Equatable, Identifiable {
    public var id: Int64
    public var ip: String
    public var port: Int
    public var proto: String
    /// The server this is assigned to, or nil when free.
    public var serverName: String?
    public var isPrimary: Bool
    public var notes: String?

    public init(
        id: Int64, ip: String, port: Int, proto: String = "tcp",
        serverName: String? = nil, isPrimary: Bool = false, notes: String? = nil
    ) {
        self.id = id
        self.ip = ip
        self.port = port
        self.proto = proto
        self.serverName = serverName
        self.isPrimary = isPrimary
        self.notes = notes
    }

    public var isFree: Bool { serverName == nil }
}

/// Pure port-selection logic — no I/O, so it's fully unit-testable. The
/// store-backed reservation (transactional under the DB lock) lives in
/// `PanelDataStore+Provisioning`.
public enum AllocationSelector {
    /// The first port inside `ranges` that is neither already assigned in the
    /// pool nor currently published by a live container. Returns nil if the pool
    /// is exhausted.
    public static func firstFree(
        ranges: [ClosedRange<Int>], assigned: Set<Int>, hostInUse: Set<Int>
    ) -> Int? {
        for range in ranges {
            for port in range where !assigned.contains(port) && !hostInUse.contains(port) {
                return port
            }
        }
        return nil
    }

    /// Every port a set of ranges covers (for an admin "generate allocations"
    /// action). Clamped to valid TCP/UDP port numbers.
    public static func expand(ranges: [ClosedRange<Int>]) -> [Int] {
        var ports: [Int] = []
        var seen = Set<Int>()
        for range in ranges {
            for port in range where port >= 1 && port <= 65535 && seen.insert(port).inserted {
                ports.append(port)
            }
        }
        return ports
    }

    /// Extracts the host-side ports from `docker ps` "Ports" strings, e.g.
    /// "0.0.0.0:27980->80/tcp, :::27980->80/tcp" → {27980}. Only mapped host
    /// ports (those with a `->`) count; bare exposed ports don't occupy a host
    /// port. Used to avoid handing out a port some running container already
    /// binds, even if it isn't in our allocation pool.
    public static func publishedHostPorts(from portsStrings: [String]) -> Set<Int> {
        var ports = Set<Int>()
        for entry in portsStrings {
            for mapping in entry.split(separator: ",") {
                let piece = mapping.trimmingCharacters(in: .whitespaces)
                // Only the "host->container" mappings publish a host port.
                guard let arrow = piece.range(of: "->") else { continue }
                let hostSide = piece[piece.startIndex..<arrow.lowerBound]
                // hostSide is like "0.0.0.0:27980" or ":::27980" or "27980".
                if let colon = hostSide.lastIndex(of: ":") {
                    let portText = hostSide[hostSide.index(after: colon)...]
                    if let port = Int(portText) { ports.insert(port) }
                } else if let port = Int(hostSide) {
                    ports.insert(port)
                }
            }
        }
        return ports
    }
}
