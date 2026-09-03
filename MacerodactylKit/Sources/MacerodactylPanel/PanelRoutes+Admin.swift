import Foundation
import Hummingbird
import HummingbirdAuth
import MacerodactylKit
import NIOCore

// The Pterodactyl-style admin API. Every route here lives under `/api/admin` and
// is gated by `RequireAdmin` (404 to non-admins, hiding the surface entirely).
// Mutations inherit the global CSRF check. This is UI-only — there is no public
// REST API (per CLAUDE.md); these endpoints serve the admin SPA at `/admin`.
extension PanelRoutes {
    func registerAdmin(on api: RouterGroup<PanelRequestContext>) {
        let admin = api.group("admin").add(middleware: RequireAdmin())

        admin.get("overview", use: apiAdminOverview)
        admin.get("settings", use: apiAdminSettingsGet)
        admin.put("settings", use: apiAdminSettingsSet)

        admin.get("users", use: apiAdminUsersList)
        admin.post("users", use: apiAdminUserCreate)
        admin.delete("users/:id", use: apiAdminUserDelete)

        admin.get("node", use: apiAdminNodeGet)
        admin.put("node", use: apiAdminNodeSet)
        admin.get("locations", use: apiAdminLocationsList)
        admin.post("locations", use: apiAdminLocationCreate)
        admin.delete("locations/:id", use: apiAdminLocationDelete)
        admin.get("allocations", use: apiAdminAllocationsList)
        admin.post("allocations", use: apiAdminAllocationsGenerate)
        admin.delete("allocations/:id", use: apiAdminAllocationDelete)

        admin.get("nests", use: apiAdminNestsList)
        admin.post("nests", use: apiAdminNestCreate)
        admin.delete("nests/:id", use: apiAdminNestDelete)
        admin.get("eggs", use: apiAdminEggsList)
        admin.get("eggs/:id", use: apiAdminEggDetail)
        admin.post("eggs/import", use: apiAdminEggImport)
        admin.get("eggs/:id/export", use: apiAdminEggExport)
        admin.delete("eggs/:id", use: apiAdminEggDelete)

        admin.get("servers", use: apiAdminServersList)
        admin.post("servers", use: apiAdminServerCreate)
        admin.delete("servers/:name", use: apiAdminServerDelete)

        admin.get("servers/:name/databases", use: apiAdminDatabasesList)
        admin.post("servers/:name/databases", use: apiAdminDatabaseCreate)
        admin.delete("databases/:id", use: apiAdminDatabaseDelete)
        admin.get("mounts", use: apiAdminMountsList)
        admin.post("mounts", use: apiAdminMountCreate)
        admin.delete("mounts/:id", use: apiAdminMountDelete)
    }

    // MARK: Overview + Settings

    @Sendable func apiAdminOverview(_ request: Request, context: PanelRequestContext) async throws -> Response {
        _ = try context.requireIdentity()
        let servers = (try? store.listServerRecords()) ?? []
        let users = (try? store.listUsers()) ?? []
        let eggs = (try? store.listEggs()) ?? []
        let allocs = (try? store.listAllocations()) ?? []
        return encode(
            OverviewDTO(
                servers: servers.count, users: users.count, eggs: eggs.count,
                allocationsFree: allocs.filter(\.isFree).count, allocationsTotal: allocs.count,
                dockerReachable: await containers.dockerReachable()))
    }

    @Sendable func apiAdminSettingsGet(_ request: Request, context: PanelRequestContext) async throws -> Response {
        _ = try context.requireIdentity()
        let s = (try? store.globalSettings()) ?? .default
        return encode(SettingsDTO(s))
    }

    @Sendable func apiAdminSettingsSet(_ request: Request, context: PanelRequestContext) async throws -> Response {
        let user = try context.requireIdentity()
        guard let body = try? await request.decode(as: SettingsDTO.self, context: context) else {
            return json(["error": "bad request"], status: .badRequest)
        }
        let require = PanelGlobalSettings.Require2FA(rawValue: body.require2FA) ?? .off
        try store.setGlobalSettings(
            PanelGlobalSettings(
                companyName: body.companyName, require2FA: require,
                defaultLanguage: body.defaultLanguage, defaultTimezone: body.defaultTimezone))
        audit(user: user.username, action: "admin.settings.update", outcome: "ok", ip: context.clientIP)
        return json(["ok": true])
    }

    // MARK: Users

    @Sendable func apiAdminUsersList(_ request: Request, context: PanelRequestContext) async throws -> Response {
        _ = try context.requireIdentity()
        let users = try store.listUsers().map { UserDTO(id: $0.id, username: $0.username, isAdmin: $0.isAdmin) }
        return encode(users)
    }

    @Sendable func apiAdminUserCreate(_ request: Request, context: PanelRequestContext) async throws -> Response {
        let user = try context.requireIdentity()
        guard let body = try? await request.decode(as: CreateUserBody.self, context: context),
            !body.username.isEmpty, body.password.count >= 8
        else { return json(["error": "username and an 8+ char password are required"], status: .badRequest) }
        do {
            let created = try await AccountManager(store: store).createUser(
                username: body.username, password: body.password, isAdmin: body.isAdmin ?? false)
            audit(
                user: user.username, action: "admin.user.create", outcome: "ok", ip: context.clientIP,
                detail: body.username)
            return encode(UserDTO(id: created.id, username: created.username, isAdmin: created.isAdmin))
        } catch {
            return json(["error": "could not create user (name may be taken)"], status: .conflict)
        }
    }

    @Sendable func apiAdminUserDelete(_ request: Request, context: PanelRequestContext) async throws -> Response {
        let user = try context.requireIdentity()
        let id = try requireInt(context, "id")
        guard id != user.id else { return json(["error": "you can't delete your own account"], status: .conflict) }
        try store.deleteUser(id: id)
        audit(user: user.username, action: "admin.user.delete", outcome: "ok", ip: context.clientIP, detail: "\(id)")
        return json(["ok": true])
    }

    // MARK: Node / Locations / Allocations

    @Sendable func apiAdminNodeGet(_ request: Request, context: PanelRequestContext) async throws -> Response {
        _ = try context.requireIdentity()
        return encode(NodeDTO(try store.nodeConfig()))
    }

    @Sendable func apiAdminNodeSet(_ request: Request, context: PanelRequestContext) async throws -> Response {
        let user = try context.requireIdentity()
        guard let body = try? await request.decode(as: NodeDTO.self, context: context) else {
            return json(["error": "bad request"], status: .badRequest)
        }
        try store.setNodeConfig(
            NodeConfig(
                name: body.name, locationID: body.locationId, hostIP: body.hostIp,
                portRangeStart: body.portRangeStart, portRangeEnd: body.portRangeEnd))
        audit(user: user.username, action: "admin.node.update", outcome: "ok", ip: context.clientIP)
        return json(["ok": true])
    }

    @Sendable func apiAdminLocationsList(_ request: Request, context: PanelRequestContext) async throws -> Response {
        _ = try context.requireIdentity()
        return encode(
            try store.listLocations().map {
                LocationDTO(id: $0.id, short: $0.short, description: $0.locationDescription)
            })
    }

    @Sendable func apiAdminLocationCreate(_ request: Request, context: PanelRequestContext) async throws -> Response {
        let user = try context.requireIdentity()
        guard let body = try? await request.decode(as: LocationDTO.self, context: context), !body.short.isEmpty else {
            return json(["error": "a short code is required"], status: .badRequest)
        }
        let id = try store.createLocation(short: body.short, description: body.description)
        audit(user: user.username, action: "admin.location.create", outcome: "ok", ip: context.clientIP)
        return encode(LocationDTO(id: id, short: body.short, description: body.description))
    }

    @Sendable func apiAdminLocationDelete(_ request: Request, context: PanelRequestContext) async throws -> Response {
        let user = try context.requireIdentity()
        try store.deleteLocation(id: try requireInt(context, "id"))
        audit(user: user.username, action: "admin.location.delete", outcome: "ok", ip: context.clientIP)
        return json(["ok": true])
    }

    @Sendable func apiAdminAllocationsList(_ request: Request, context: PanelRequestContext) async throws -> Response {
        _ = try context.requireIdentity()
        return encode(try store.listAllocations().map(AllocationDTO.init))
    }

    @Sendable func apiAdminAllocationsGenerate(_ request: Request, context: PanelRequestContext) async throws -> Response {
        let user = try context.requireIdentity()
        guard let body = try? await request.decode(as: GenerateAllocationsBody.self, context: context),
            body.portStart <= body.portEnd, (body.portEnd - body.portStart) <= 5000
        else { return json(["error": "give a valid port range (max 5000 ports)"], status: .badRequest) }
        let ip = body.ip?.isEmpty == false ? body.ip! : (try store.nodeConfig().hostIP)
        let created = try store.generateAllocations(
            ip: ip, ports: AllocationSelector.expand(ranges: [body.portStart...body.portEnd]), proto: body.proto ?? "tcp")
        audit(
            user: user.username, action: "admin.allocation.generate", outcome: "ok", ip: context.clientIP,
            detail: "\(created) added")
        return json(["created": created])
    }

    @Sendable func apiAdminAllocationDelete(_ request: Request, context: PanelRequestContext) async throws -> Response {
        let user = try context.requireIdentity()
        try store.deleteAllocation(id: try requireInt(context, "id"))
        audit(user: user.username, action: "admin.allocation.delete", outcome: "ok", ip: context.clientIP)
        return json(["ok": true])
    }

    // MARK: Nests / Eggs

    @Sendable func apiAdminNestsList(_ request: Request, context: PanelRequestContext) async throws -> Response {
        _ = try context.requireIdentity()
        return encode(
            try store.listNests().map { NestDTO(id: $0.id, name: $0.name, author: $0.author, description: $0.nestDescription) })
    }

    @Sendable func apiAdminNestCreate(_ request: Request, context: PanelRequestContext) async throws -> Response {
        let user = try context.requireIdentity()
        guard let body = try? await request.decode(as: NestDTO.self, context: context), !body.name.isEmpty else {
            return json(["error": "a nest name is required"], status: .badRequest)
        }
        let id = try store.createNest(name: body.name, author: body.author, description: body.description)
        audit(user: user.username, action: "admin.nest.create", outcome: "ok", ip: context.clientIP)
        return encode(NestDTO(id: id, name: body.name, author: body.author, description: body.description))
    }

    @Sendable func apiAdminNestDelete(_ request: Request, context: PanelRequestContext) async throws -> Response {
        let user = try context.requireIdentity()
        try store.deleteNest(id: try requireInt(context, "id"))
        audit(user: user.username, action: "admin.nest.delete", outcome: "ok", ip: context.clientIP)
        return json(["ok": true])
    }

    @Sendable func apiAdminEggsList(_ request: Request, context: PanelRequestContext) async throws -> Response {
        _ = try context.requireIdentity()
        let nestFilter = request.uri.queryParameters["nest"].flatMap { Int64($0) }
        return encode(try store.listEggs(nestID: nestFilter).map(EggSummaryDTO.init))
    }

    @Sendable func apiAdminEggDetail(_ request: Request, context: PanelRequestContext) async throws -> Response {
        _ = try context.requireIdentity()
        guard let egg = try store.egg(id: try requireInt(context, "id")) else { throw notFound() }
        let parsed = try egg.parsed()
        return encode(EggDetailDTO(stored: egg, egg: parsed))
    }

    @Sendable func apiAdminEggImport(_ request: Request, context: PanelRequestContext) async throws -> Response {
        let user = try context.requireIdentity()
        guard let body = try? await request.decode(as: ImportEggBody.self, context: context) else {
            return json(["error": "bad request"], status: .badRequest)
        }
        // Resolve or create the nest.
        let nestID: Int64
        if let existing = body.nestId, existing > 0 {
            nestID = existing
        } else if let name = body.nestName, !name.isEmpty {
            nestID = try store.createNest(name: name, author: nil, description: nil)
        } else {
            return json(["error": "choose a nest or give a new nest name"], status: .badRequest)
        }
        let egg: PterodactylEgg
        do { egg = try EggParser.parse(body.json) } catch {
            return json(["error": "that doesn't look like a valid egg export"], status: .badRequest)
        }
        let warnings = EggValidator.validate(egg).map(\.message)
        let eggID = try store.importEgg(egg, rawJSON: body.json, nestID: nestID)
        audit(
            user: user.username, action: "admin.egg.import", outcome: "ok", ip: context.clientIP, detail: egg.name)
        return encode(ImportResultDTO(eggId: eggID, name: egg.name, warnings: warnings))
    }

    @Sendable func apiAdminEggExport(_ request: Request, context: PanelRequestContext) async throws -> Response {
        _ = try context.requireIdentity()
        guard let egg = try store.egg(id: try requireInt(context, "id")) else { throw notFound() }
        return Response(
            status: .ok,
            headers: [
                .contentType: "application/json",
                .contentDisposition: "attachment; filename=\"egg-\(egg.id).json\"",
            ],
            body: .init(byteBuffer: ByteBuffer(string: egg.rawJSON)))
    }

    @Sendable func apiAdminEggDelete(_ request: Request, context: PanelRequestContext) async throws -> Response {
        let user = try context.requireIdentity()
        try store.deleteEgg(id: try requireInt(context, "id"))
        audit(user: user.username, action: "admin.egg.delete", outcome: "ok", ip: context.clientIP)
        return json(["ok": true])
    }

    // MARK: Servers

    @Sendable func apiAdminServersList(_ request: Request, context: PanelRequestContext) async throws -> Response {
        _ = try context.requireIdentity()
        let live = Set(await containers.allContainers().map(\.name))
        return encode(try store.listServerRecords().map { ServerDTO(record: $0, running: live.contains($0.name)) })
    }

    @Sendable func apiAdminServerDelete(_ request: Request, context: PanelRequestContext) async throws -> Response {
        let user = try context.requireIdentity()
        let name = try context.parameters.require("name")
        do { try await containers.deprovision(name: name) } catch {
            audit(
                user: user.username, action: "admin.server.delete", container: name, outcome: "error",
                ip: context.clientIP, detail: "\(error)")
            return json(["error": "could not remove the server: \(error)"], status: .internalServerError)
        }
        try? store.freeAllocations(serverName: name)
        try? store.deleteServerRecord(name: name)
        audit(user: user.username, action: "admin.server.delete", container: name, outcome: "ok", ip: context.clientIP)
        return json(["ok": true])
    }

    // MARK: Databases / Mounts

    @Sendable func apiAdminDatabasesList(_ request: Request, context: PanelRequestContext) async throws -> Response {
        _ = try context.requireIdentity()
        let name = try context.parameters.require("name")
        guard let server = try store.serverRecord(name: name) else { throw notFound() }
        return encode(try store.listDatabases(serverID: server.id).map(DatabaseDTO.init))
    }

    @Sendable func apiAdminDatabaseCreate(_ request: Request, context: PanelRequestContext) async throws -> Response {
        let user = try context.requireIdentity()
        let name = try context.parameters.require("name")
        guard let server = try store.serverRecord(name: name) else { throw notFound() }
        guard let body = try? await request.decode(as: CreateDatabaseBody.self, context: context), !body.name.isEmpty
        else { return json(["error": "a database name is required"], status: .badRequest) }
        let id = try store.createDatabase(
            serverID: server.id, name: body.name, host: body.host, port: body.port, username: body.username)
        audit(
            user: user.username, action: "admin.database.create", container: name, outcome: "ok", ip: context.clientIP)
        return json(["id": Int(id)])
    }

    @Sendable func apiAdminDatabaseDelete(_ request: Request, context: PanelRequestContext) async throws -> Response {
        let user = try context.requireIdentity()
        try store.deleteDatabase(id: try requireInt(context, "id"))
        audit(user: user.username, action: "admin.database.delete", outcome: "ok", ip: context.clientIP)
        return json(["ok": true])
    }

    @Sendable func apiAdminMountsList(_ request: Request, context: PanelRequestContext) async throws -> Response {
        _ = try context.requireIdentity()
        return encode(try store.listMounts().map(MountDTO.init))
    }

    @Sendable func apiAdminMountCreate(_ request: Request, context: PanelRequestContext) async throws -> Response {
        let user = try context.requireIdentity()
        guard let body = try? await request.decode(as: CreateMountBody.self, context: context),
            !body.name.isEmpty, !body.source.isEmpty, !body.target.isEmpty
        else { return json(["error": "name, source and target are required"], status: .badRequest) }
        let id = try store.createMount(
            name: body.name, source: body.source, target: body.target, readOnly: body.readOnly ?? false,
            description: body.description)
        audit(user: user.username, action: "admin.mount.create", outcome: "ok", ip: context.clientIP)
        return json(["id": Int(id)])
    }

    @Sendable func apiAdminMountDelete(_ request: Request, context: PanelRequestContext) async throws -> Response {
        let user = try context.requireIdentity()
        try store.deleteMount(id: try requireInt(context, "id"))
        audit(user: user.username, action: "admin.mount.delete", outcome: "ok", ip: context.clientIP)
        return json(["ok": true])
    }

    // MARK: Helpers

    func requireInt(_ context: PanelRequestContext, _ name: String) throws -> Int64 {
        guard let value = Int64(try context.parameters.require(name)) else { throw HTTPError(.badRequest) }
        return value
    }
}
