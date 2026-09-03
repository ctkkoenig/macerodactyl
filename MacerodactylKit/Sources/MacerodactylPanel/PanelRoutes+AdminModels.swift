import Foundation
import Hummingbird
import HummingbirdAuth
import MacerodactylKit
import NIOCore

// DTOs for the admin API (response + request bodies). Kept separate from the
// handlers for readability. Optionals encode via `encodeIfPresent` (omitted when
// nil), so request bodies can share a type with list responses.

struct AuditDTO: Encodable {
    let id: Int64
    let timestamp: String
    let username: String
    let action: String
    let container: String?
    let outcome: String
    let ip: String?
    let detail: String?
    init(_ e: AuditEntry) {
        id = e.id
        timestamp = e.timestamp
        username = e.username
        action = e.action
        container = e.containerName
        outcome = e.outcome
        ip = e.sourceIP
        detail = e.detail
    }
}

struct OverviewDTO: Encodable {
    let servers: Int
    let users: Int
    let eggs: Int
    let allocationsFree: Int
    let allocationsTotal: Int
    let dockerReachable: Bool
}

struct SettingsDTO: Codable {
    let companyName: String
    let require2FA: String
    let defaultLanguage: String
    let defaultTimezone: String
    init(_ s: PanelGlobalSettings) {
        companyName = s.companyName
        require2FA = s.require2FA.rawValue
        defaultLanguage = s.defaultLanguage
        defaultTimezone = s.defaultTimezone
    }
}

struct UserDTO: Encodable {
    let id: Int64
    let username: String
    let isAdmin: Bool
}

struct CreateUserBody: Decodable {
    let username: String
    let password: String
    let isAdmin: Bool?
}

struct NodeDTO: Codable {
    let name: String
    let locationId: Int64?
    let hostIp: String
    let portRangeStart: Int
    let portRangeEnd: Int
    init(_ n: NodeConfig) {
        name = n.name
        locationId = n.locationID
        hostIp = n.hostIP
        portRangeStart = n.portRangeStart
        portRangeEnd = n.portRangeEnd
    }
}

struct LocationDTO: Codable {
    let id: Int64?
    let short: String
    let description: String?
}

struct AllocationDTO: Encodable {
    let id: Int64
    let ip: String
    let port: Int
    let proto: String
    let serverName: String?
    let isPrimary: Bool
    init(_ a: PortAllocation) {
        id = a.id
        ip = a.ip
        port = a.port
        proto = a.proto
        serverName = a.serverName
        isPrimary = a.isPrimary
    }
}

struct GenerateAllocationsBody: Decodable {
    let ip: String?
    let portStart: Int
    let portEnd: Int
    let proto: String?
}

struct NestDTO: Codable {
    let id: Int64?
    let name: String
    let author: String?
    let description: String?
}

struct EggSummaryDTO: Encodable {
    let id: Int64
    let nestId: Int64
    let name: String
    let author: String?
    let description: String?
    let metaVersion: String?
    init(_ e: StoredEgg) {
        id = e.id
        nestId = e.nestID
        name = e.name
        author = e.author
        description = e.eggDescription
        metaVersion = e.metaVersion
    }
}

struct EggImageDTO: Encodable {
    let label: String
    let image: String
}

struct EggVariableDTO: Encodable {
    let name: String
    let description: String
    let envVariable: String
    let defaultValue: String
    let userViewable: Bool
    let userEditable: Bool
    let rules: [String]
}

struct EggDetailDTO: Encodable {
    let id: Int64
    let nestId: Int64
    let name: String
    let author: String?
    let description: String?
    let metaVersion: String?
    let startup: String
    let hasInstallScript: Bool
    let images: [EggImageDTO]
    let variables: [EggVariableDTO]
    init(stored: StoredEgg, egg: PterodactylEgg) {
        id = stored.id
        nestId = stored.nestID
        name = egg.name
        author = egg.author
        description = egg.eggDescription
        metaVersion = egg.metaVersion
        startup = egg.startup
        hasInstallScript = egg.install.isRunnable
        images = egg.dockerImages.map { EggImageDTO(label: $0.label, image: $0.image) }
        variables = egg.variables.map {
            EggVariableDTO(
                name: $0.name, description: $0.variableDescription, envVariable: $0.envVariable,
                defaultValue: $0.defaultValue, userViewable: $0.userViewable, userEditable: $0.userEditable,
                rules: $0.rules)
        }
    }
}

struct ImportEggBody: Decodable {
    let nestId: Int64?
    let nestName: String?
    let json: String
}

struct ImportResultDTO: Encodable {
    let eggId: Int64
    let name: String
    let warnings: [String]
}

struct ServerDTO: Encodable {
    let id: Int64
    let name: String
    let uuid: String
    let dockerImage: String
    let status: String
    let running: Bool
    let memoryMiB: Int
    let cpuPercent: Int
    let ownerUserId: Int64?
    let createdAt: String
    init(record: ServerRecord, running: Bool) {
        id = record.id
        name = record.name
        uuid = record.uuid
        dockerImage = record.dockerImage
        status = record.status
        self.running = running
        memoryMiB = record.limits.memoryMiB
        cpuPercent = record.limits.cpuPercent
        ownerUserId = record.ownerUserID
        createdAt = record.createdAt
    }
}

struct CreateServerBody: Decodable {
    let name: String
    let eggId: Int64
    let ownerUserId: Int64?
    let image: String?
    let memoryMiB: Int?
    let swapMiB: Int?
    let diskMiB: Int?
    let cpuPercent: Int?
    let cpuPinning: String?
    let ioWeight: Int?
    let pidsLimit: Int?
    let oomKillDisable: Bool?
    let additionalAllocations: Int?
    let values: [String: String]?
    let mountIds: [Int64]?
}

struct DatabaseDTO: Encodable {
    let id: Int64
    let name: String
    let host: String?
    let port: Int?
    let username: String?
    init(_ d: ServerDatabaseRecord) {
        id = d.id
        name = d.name
        host = d.host
        port = d.port
        username = d.username
    }
}

struct CreateDatabaseBody: Decodable {
    let name: String
    let host: String?
    let port: Int?
    let username: String?
}

struct MountDTO: Encodable {
    let id: Int64
    let name: String
    let source: String
    let target: String
    let readOnly: Bool
    let description: String?
    init(_ m: MountRecord) {
        id = m.id
        name = m.name
        source = m.source
        target = m.target
        readOnly = m.readOnly
        description = m.mountDescription
    }
}

struct CreateMountBody: Decodable {
    let name: String
    let source: String
    let target: String
    let readOnly: Bool?
    let description: String?
}

// MARK: - Create Server (SSE provisioning)

extension PanelRoutes {
    @Sendable func apiAdminServerCreate(_ request: Request, context: PanelRequestContext) async throws -> Response {
        let user = try context.requireIdentity()
        guard let body = try? await request.decode(as: CreateServerBody.self, context: context) else {
            return json(["error": "bad request"], status: .badRequest)
        }
        // Accept a friendly name and normalize it to a valid stack identifier
        // (the name doubles as the compose project / container / grant key).
        let name = ServerProvisioner.slugify(body.name)
        guard ServerProvisioner.isValidName(name) else {
            return json(["error": "A server name needs at least one letter or number."], status: .badRequest)
        }
        let clash = (try? store.serverRecord(name: name)) ?? nil
        let stackExists = await containers.stackExists(name: name)
        if clash != nil || stackExists {
            return json(["error": "a server named \"\(name)\" already exists"], status: .conflict)
        }
        guard let stored = try store.egg(id: body.eggId) else {
            return json(["error": "egg not found"], status: .notFound)
        }
        let egg = try stored.parsed()
        let image = (body.image?.isEmpty == false ? body.image! : egg.defaultImage) ?? ""
        guard !image.isEmpty else { return json(["error": "no docker image for this egg"], status: .badRequest) }

        // Reserve allocations, skipping ports currently published by live containers.
        let liveHostPorts = AllocationSelector.publishedHostPorts(from: await containers.allContainers().map(\.ports))
        let count = 1 + max(0, body.additionalAllocations ?? 0)
        let reserved: [PortAllocation]
        do {
            reserved = try store.reserveAllocations(serverName: name, count: count, excludingPorts: liveHostPorts)
        } catch {
            return json(
                ["error": "not enough free allocations — add some under Nodes first"], status: .conflict)
        }
        guard let primary = reserved.first(where: \.isPrimary) ?? reserved.first else {
            try? store.freeAllocations(serverName: name)
            return json(["error": "allocation failed"], status: .internalServerError)
        }

        let settings = (try? store.globalSettings()) ?? .default
        let limits = ServerLimits(
            memoryMiB: body.memoryMiB ?? 0, swapMiB: body.swapMiB ?? 0, diskMiB: body.diskMiB ?? 0,
            cpuPercent: body.cpuPercent ?? 0, cpuPinning: body.cpuPinning, ioWeight: body.ioWeight,
            pidsLimit: body.pidsLimit, oomKillDisable: body.oomKillDisable ?? false)
        let uuid = UUID().uuidString
        let runtime = ServerRuntimeContext(
            memoryMiB: limits.memoryMiB, swapMiB: limits.swapMiB, diskMiB: limits.diskMiB, port: primary.port,
            cpuPercent: limits.cpuPercent, uuid: uuid, timezone: settings.defaultTimezone)
        let resolved = VariableResolver.resolveStartup(egg: egg, values: body.values ?? [:], runtime: runtime)
        let mappings = reserved.map {
            PortMapping(hostIP: $0.ip, hostPort: $0.port, containerPort: $0.port, proto: $0.proto)
        }
        // Resolve any selected admin mounts into real binds (host source must
        // exist and not be a system-critical path). Invalid ones are skipped.
        var extraMounts: [VolumeMount] = []
        var linkedMountIds: [Int64] = []
        if let mountIds = body.mountIds, !mountIds.isEmpty {
            let byID = Dictionary(uniqueKeysWithValues: ((try? store.listMounts()) ?? []).map { ($0.id, $0) })
            for id in mountIds {
                guard let mount = byID[id], Self.mountSourceIsValid(mount.source) else { continue }
                extraMounts.append(VolumeMount(source: mount.source, target: mount.target, readOnly: mount.readOnly))
                linkedMountIds.append(id)
            }
        }

        let stop = ServerStop.from(configStop: egg.configStop)
        let spec = ProvisionSpec(
            name: name, image: image, startup: resolved.startup.value, environment: resolved.environment,
            install: egg.install, limits: limits, portMappings: mappings, extraMounts: extraMounts,
            configFiles: egg.configFiles, stopSignal: stop.signal, stopGracePeriodSeconds: stop.graceSeconds)

        // Persist the record BEFORE streaming so a crash mid-install is visible.
        let serverID = try? store.createServerRecord(
            uuid: uuid, name: name, eggID: stored.id, dockerImage: image, ownerUserID: body.ownerUserId,
            limits: limits, startup: egg.startup, values: resolved.environment, status: "installing")
        if let serverID {
            for mountID in linkedMountIds { try? store.linkServerMount(serverID: serverID, mountID: mountID) }
        }
        audit(
            user: user.username, action: "admin.server.create", container: name, outcome: "started",
            ip: context.clientIP, detail: egg.name)

        let base = await containers.provision(spec)
        return Self.sseResponse(
            payloads: finalizeProvision(
                base, name: name, ownerUserID: body.ownerUserId, adminUser: user.username, ip: context.clientIP))
    }

    /// A mount source must be an existing absolute host path that isn't a
    /// system-critical directory or the docker socket. Admin-only, but a bad
    /// mount can wreck a host, so it's checked.
    static func mountSourceIsValid(_ source: String) -> Bool {
        guard source.hasPrefix("/") else { return false }
        let std = URL(fileURLWithPath: source).standardizedFileURL.path
        let blocked: Set<String> = [
            "/", "/etc", "/usr", "/bin", "/sbin", "/lib", "/boot", "/dev", "/proc", "/sys",
            "/var", "/var/run", "/run", "/System", "/Library", "/var/run/docker.sock",
        ]
        guard !blocked.contains(std) else { return false }
        return FileManager.default.fileExists(atPath: std)
    }

    /// Forwards the provisioning log and, when it completes, flips the server
    /// record to active and mints the owner's full grant; on failure marks it
    /// install_failed and frees the reserved allocations. Runs even if the client
    /// disconnects (the wrapped task is cancelled, which surfaces as an error).
    private func finalizeProvision(
        _ base: AsyncThrowingStream<String, Error>, name: String, ownerUserID: Int64?, adminUser: String, ip: String
    ) -> AsyncThrowingStream<String, Error> {
        let store = self.store
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await line in base { continuation.yield(line) }
                    try? store.setServerStatus(name: name, status: "active")
                    if let ownerID = ownerUserID, let owner = try? store.user(id: ownerID) {
                        try? AccountManager(store: store).setGrant(
                            userID: owner.id, containerName: name,
                            grant: ContainerGrant(
                                view: true, power: true, files: true, console: true, schedules: true, lifecycle: true),
                            filesGrantable: true)
                    }
                    try? store.recordAudit(
                        username: adminUser, action: "admin.server.create", containerName: name, outcome: "ok",
                        sourceIP: ip, detail: nil)
                    continuation.finish()
                } catch {
                    try? store.setServerStatus(name: name, status: "install_failed")
                    try? store.freeAllocations(serverName: name)
                    try? store.recordAudit(
                        username: adminUser, action: "admin.server.create", containerName: name, outcome: "error",
                        sourceIP: ip, detail: "\(error)")
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
