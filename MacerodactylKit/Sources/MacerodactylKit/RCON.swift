import Foundation

// The RCON client is built on Network.framework (Apple-only). Detection and the
// protocol codec below are cross-platform; only the live TCP client is gated, so
// on Linux the Minecraft console falls back to `docker exec` (see callers).
#if canImport(Network)
import Network
#endif

/// Source RCON protocol (what Minecraft speaks): little-endian frames of
/// [int32 length][int32 requestID][int32 type][body bytes][0x00 0x00],
/// where length counts everything after itself. Auth is type 3; commands are
/// type 2; server responses are type 0 (auth success echoes type 2 with your
/// id, auth failure answers id -1).
public struct RCONPacket: Sendable, Equatable {
    public static let authType: Int32 = 3
    public static let commandType: Int32 = 2
    public static let responseType: Int32 = 0

    public let id: Int32
    public let type: Int32
    public let body: String

    public init(id: Int32, type: Int32, body: String) {
        self.id = id
        self.type = type
        self.body = body
    }

    public func encoded() -> Data {
        let bodyBytes = Data(body.utf8)
        let length = Int32(4 + 4 + bodyBytes.count + 2)
        var data = Data(capacity: Int(length) + 4)
        data.append(le: length)
        data.append(le: id)
        data.append(le: type)
        data.append(bodyBytes)
        data.append(contentsOf: [0, 0])
        return data
    }

    /// Consumes one complete packet from the front of `buffer`, or returns nil
    /// (leaving the buffer untouched) if a full frame hasn't arrived yet.
    public static func decode(from buffer: inout Data) -> RCONPacket? {
        guard buffer.count >= 4 else { return nil }
        let length = buffer.readLE(at: 0)
        guard length >= 10, length <= 1 << 20 else {
            // Nonsense frame — drop the buffer rather than loop forever.
            buffer.removeAll()
            return nil
        }
        let total = Int(length) + 4
        guard buffer.count >= total else { return nil }
        let id = buffer.readLE(at: 4)
        let type = buffer.readLE(at: 8)
        let bodyLength = Int(length) - 10
        let bodyStart = buffer.startIndex + 12
        let body = String(decoding: buffer[bodyStart..<(bodyStart + bodyLength)], as: UTF8.self)
        buffer.removeFirst(total)
        return RCONPacket(id: id, type: type, body: body)
    }
}

extension Data {
    mutating func append(le value: Int32) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }

    /// Reads a little-endian Int32 at a byte offset relative to startIndex.
    func readLE(at offset: Int) -> Int32 {
        let start = startIndex + offset
        return self[start..<(start + 4)].withUnsafeBytes { raw in
            Int32(littleEndian: raw.loadUnaligned(as: Int32.self))
        }
    }
}

public enum RCONError: Error, Equatable, Sendable {
    case notConnected
    case connectionFailed(String)
    case authenticationFailed
    case timedOut
    case closed
}

/// Where a container's RCON endpoint is reachable from the host.
public struct RCONEndpoint: Sendable, Equatable {
    public let host: String
    public let port: UInt16
    public let password: String

    public init(host: String, port: UInt16, password: String) {
        self.host = host
        self.port = port
        self.password = password
    }
}

#if canImport(Network)
/// Minimal RCON client over Network.framework. One client is bound to one
/// endpoint; operations are serialized by the actor.
public actor RCONClient {
    private let endpoint: RCONEndpoint
    private var connection: NWConnection?
    private var receiveBuffer = Data()
    private var nextRequestID: Int32 = 1
    public private(set) var isAuthenticated = false

    public init(endpoint: RCONEndpoint) {
        self.endpoint = endpoint
    }

    /// Connects and authenticates.
    public func connect(timeout: Duration = .seconds(8)) async throws {
        guard connection == nil else { return }
        guard let port = NWEndpoint.Port(rawValue: endpoint.port) else {
            throw RCONError.connectionFailed("bad port")
        }
        let connection = NWConnection(host: NWEndpoint.Host(endpoint.host), port: port, using: .tcp)
        self.connection = connection

        try await withWatchdog(timeout, connection: connection) {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                let once = OnceFlag()
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        if once.claim() { cont.resume() }
                    case .failed(let error):
                        if once.claim() { cont.resume(throwing: RCONError.connectionFailed(String(describing: error))) }
                    case .waiting(let error):
                        // Fail fast (connection refused surfaces as .waiting).
                        connection.cancel()
                        if once.claim() { cont.resume(throwing: RCONError.connectionFailed(String(describing: error))) }
                    case .cancelled:
                        // The watchdog (or close()) cancelled us mid-connect.
                        if once.claim() { cont.resume(throwing: RCONError.closed) }
                    default:
                        break
                    }
                }
                connection.start(queue: .global(qos: .userInitiated))
            }
        }

        // Authenticate: success echoes our id with type 2; failure answers id -1.
        let authID = takeRequestID()
        try await send(RCONPacket(id: authID, type: RCONPacket.authType, body: endpoint.password))
        while true {
            let packet = try await receivePacket(timeout: timeout)
            if packet.id == -1 {
                close()
                throw RCONError.authenticationFailed
            }
            if packet.type == RCONPacket.commandType {
                guard packet.id == authID else { continue }
                isAuthenticated = true
                return
            }
            // Some servers precede the auth response with an empty type-0 packet.
        }
    }

    /// Sends one command and returns the server's response text.
    public func send(command: String, timeout: Duration = .seconds(8)) async throws -> String {
        guard connection != nil, isAuthenticated else { throw RCONError.notConnected }
        let requestID = takeRequestID()
        try await send(RCONPacket(id: requestID, type: RCONPacket.commandType, body: command))

        var response = ""
        while true {
            let packet = try await receivePacket(timeout: timeout)
            if packet.id == requestID {
                response = packet.body
                break
            }
            // Stale continuation packets from an earlier command: drop them.
        }
        // Large responses can span packets. Anything already buffered with the
        // same id belongs to this response; never block waiting for more —
        // Minecraft answers in a single packet in practice, and a blocking
        // drain here would trip the watchdog and kill the session.
        while let extra = RCONPacket.decode(from: &receiveBuffer) {
            if extra.id == requestID { response += extra.body }
        }
        return response
    }

    public func close() {
        connection?.cancel()
        connection = nil
        receiveBuffer.removeAll()
        isAuthenticated = false
    }

    // MARK: internals

    private func takeRequestID() -> Int32 {
        defer { nextRequestID = nextRequestID == Int32.max ? 1 : nextRequestID + 1 }
        return nextRequestID
    }

    private func send(_ packet: RCONPacket) async throws {
        guard let connection else { throw RCONError.notConnected }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(
                content: packet.encoded(),
                completion: .contentProcessed { error in
                    if let error {
                        cont.resume(throwing: RCONError.connectionFailed(String(describing: error)))
                    } else {
                        cont.resume()
                    }
                })
        }
    }

    private func receivePacket(timeout: Duration) async throws -> RCONPacket {
        guard let connection else { throw RCONError.notConnected }
        return try await withWatchdog(timeout, connection: connection) {
            while true {
                if let packet = RCONPacket.decode(from: &self.receiveBuffer) {
                    return packet
                }
                let chunk = try await self.receiveChunk(connection)
                self.receiveBuffer.append(chunk)
            }
        }
    }

    private func receiveChunk(_ connection: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { data, _, isComplete, error in
                if let data, !data.isEmpty {
                    cont.resume(returning: data)
                } else if error != nil || isComplete {
                    cont.resume(throwing: RCONError.closed)
                } else {
                    cont.resume(throwing: RCONError.closed)
                }
            }
        }
    }

    /// Runs an operation with a deadline. NWConnection operations can't be
    /// cancelled directly, so the watchdog cancels the connection — which makes
    /// any pending receive/send resume with an error — and the error is
    /// reported as a timeout.
    private func withWatchdog<T: Sendable>(
        _ timeout: Duration, connection: NWConnection,
        _ operation: () async throws -> T
    ) async throws -> T {
        let fired = OnceFlag()
        let watchdog = Task {
            try? await Task.sleep(for: timeout)
            if !Task.isCancelled, fired.claim() {
                connection.cancel()
            }
        }
        defer { watchdog.cancel() }
        do {
            return try await operation()
        } catch {
            if !fired.claim() {
                // The watchdog got there first: the failure is a timeout.
                close()
                throw RCONError.timedOut
            }
            throw error
        }
    }
}

#endif  // canImport(Network) — end of the RCONClient actor

/// Detects whether a container is a Minecraft server reachable over RCON.
/// Detection reads `docker inspect` at runtime — the password comes from the
/// container's environment and is never stored anywhere by the app.
public enum MinecraftRCON {
    public enum Detection: Sendable, Equatable {
        case notMinecraft
        /// Minecraft, but its RCON port isn't published to the host.
        case unreachable(reason: String)
        case available(RCONEndpoint)
    }

    public static func detect(containerID: String, cli: DockerCLI) async -> Detection {
        guard let output = try? await cli.run(["inspect", containerID], timeout: .seconds(10)) else {
            return .notMinecraft
        }
        return parse(inspectJSON: Data(output.utf8))
    }

    /// Pure parser over `docker inspect` output (an array of one object).
    public static func parse(inspectJSON: Data) -> Detection {
        struct Inspect: Decodable {
            struct Config: Decodable {
                let Env: [String]?
                let Image: String?
            }
            struct PortBinding: Decodable {
                let HostIp: String?
                let HostPort: String?
            }
            struct NetworkSettings: Decodable {
                let Ports: [String: [PortBinding]?]?
            }
            let Config: Config?
            let NetworkSettings: NetworkSettings?
        }
        guard let inspected = try? JSONDecoder().decode([Inspect].self, from: inspectJSON).first else {
            return .notMinecraft
        }

        var env: [String: String] = [:]
        for entry in inspected.Config?.Env ?? [] {
            if let eq = entry.firstIndex(of: "=") {
                env[String(entry[entry.startIndex..<eq])] = String(entry[entry.index(after: eq)...])
            }
        }
        let image = inspected.Config?.Image ?? ""
        let isMinecraft = image.contains("itzg/minecraft-server") || env["RCON_PASSWORD"] != nil
        guard isMinecraft else { return .notMinecraft }

        guard let password = env["RCON_PASSWORD"], !password.isEmpty else {
            return .unreachable(reason: "No RCON_PASSWORD in the container's environment.")
        }
        let containerPort = env["RCON_PORT"] ?? "25575"
        let bindings = inspected.NetworkSettings?.Ports?["\(containerPort)/tcp"] ?? nil
        guard let hostPortString = bindings?.first?.HostPort, let hostPort = UInt16(hostPortString) else {
            return .unreachable(reason: "RCON port \(containerPort) isn't published to the host — add a port mapping for it.")
        }
        return .available(RCONEndpoint(host: "127.0.0.1", port: hostPort, password: password))
    }
}
