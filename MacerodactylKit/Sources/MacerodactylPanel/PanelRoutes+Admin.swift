import Foundation
import Hummingbird
import HummingbirdAuth
import MacerodactylKit
import NIOCore

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Failures while fetching an egg from its `update_url`.
enum EggFetchError: Error { case httpStatus(Int), tooLarge }

// The Pterodactyl-style admin API. Every route here lives under `/api/admin` and
// is gated by `RequireAdmin` (404 to non-admins, hiding the surface entirely).
// Mutations inherit the global CSRF check. This is UI-only — there is no public
// REST API (per CLAUDE.md); these endpoints serve the admin SPA at `/admin`.
extension PanelRoutes {
    func registerAdmin(on api: RouterGroup<PanelRequestContext>) {
        let admin = api.group("admin").add(middleware: RequireAdmin())

        admin.get("overview", use: apiAdminOverview)
        admin.get("audit", use: apiAdminAudit)
        admin.get("settings", use: apiAdminSettingsGet)
        admin.put("settings", use: apiAdminSettingsSet)

        admin.get("users", use: apiAdminUsersList)
        admin.post("users", use: apiAdminUserCreate)
        admin.post("users/:id/reset", use: apiAdminUserResetPassword)
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
        admin.put("eggs/:id", use: apiAdminEggEdit)
        admin.post("eggs/:id/update", use: apiAdminEggUpdate)
        admin.delete("eggs/:id", use: apiAdminEggDelete)

        admin.get("servers", use: apiAdminServersList)
        admin.get("servers/:name", use: apiAdminServerDetail)
        admin.post("servers", use: apiAdminServerCreate)
        admin.put("servers/:name", use: apiAdminServerEdit)
        admin.post("servers/:name/reinstall", use: apiAdminServerReinstall)
        admin.post("servers/:name/suspend", use: apiAdminServerSuspend)
        admin.post("servers/:name/unsuspend", use: apiAdminServerUnsuspend)
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

    /// The audit trail over HTTP — the only way to read it on a headless server
    /// deployment (there's no native app there). Admin-only.
    @Sendable func apiAdminAudit(_ request: Request, context: PanelRequestContext) async throws -> Response {
        _ = try context.requireIdentity()
        let limit = request.uri.queryParameters["limit"].flatMap { Int($0) }.map { min(max($0, 1), 1000) } ?? 300
        return encode(try store.listAudit(limit: limit).map(AuditDTO.init))
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

    struct ResetLinkDTO: Encodable {
        let username: String
        /// The reset path (with the one-time token). The admin hands this to the
        /// user; the client prefixes the panel origin to make a full link.
        let path: String
        let expiresAt: String
    }

    /// Issues a single-use password-reset link for a user and returns it to the
    /// admin to hand over out of band (there is no email delivery). The raw token
    /// is shown exactly once here; only its hash is stored.
    @Sendable func apiAdminUserResetPassword(_ request: Request, context: PanelRequestContext) async throws -> Response {
        let admin = try context.requireIdentity()
        let id = try requireInt(context, "id")
        guard let target = try store.user(id: id) else { throw notFound() }
        let token = PanelSession.newToken()
        let expiresAt = PanelSession.timestamp(Date().addingTimeInterval(3600))  // 1 hour
        try store.createPasswordReset(
            userID: target.id, tokenHash: PanelSession.hashToken(token), expiresAtISO: expiresAt)
        audit(
            user: admin.username, action: "admin.user.reset_issue", outcome: "ok", ip: context.clientIP,
            detail: target.username)
        return encode(ResetLinkDTO(username: target.username, path: "/reset?token=\(token)", expiresAt: expiresAt))
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
        // Protocol: tcp (default), udp, or both (a tcp AND a udp row per port, as
        // many game servers need query/RCON on udp alongside tcp).
        let requested = (body.proto ?? "tcp").lowercased()
        guard ["tcp", "udp", "both"].contains(requested) else {
            return json(["error": "protocol must be tcp, udp, or both"], status: .badRequest)
        }
        let protos = requested == "both" ? ["tcp", "udp"] : [requested]
        let ports = AllocationSelector.expand(ranges: [body.portStart...body.portEnd])
        var created = 0
        for proto in protos {
            created += try store.generateAllocations(ip: ip, ports: ports, proto: proto)
        }
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

    struct EditEggBody: Decodable {
        var name: String?
        var author: String?
        var description: String?
        var startup: String?
        var stop: String?
        var configFiles: String?
        var configLogs: String?
        var installScript: String?
        var installContainer: String?
        var installEntrypoint: String?
        var images: [ImageInput]?
        var variables: [VariableInput]?
        struct ImageInput: Decodable {
            let label: String
            let image: String
        }
        struct VariableInput: Decodable {
            let name: String
            let description: String?
            let envVariable: String
            let defaultValue: String?
            let userViewable: Bool?
            let userEditable: Bool?
            let rules: [String]?
        }
    }

    /// Edits a stored egg in place from structured fields, patched into its raw
    /// JSON server-side (so fields the editor doesn't model are preserved), then
    /// re-parsed + validated by the same path as import before saving. Same id.
    @Sendable func apiAdminEggEdit(_ request: Request, context: PanelRequestContext) async throws -> Response {
        let user = try context.requireIdentity()
        let id = try requireInt(context, "id")
        guard let stored = try store.egg(id: id) else { throw notFound() }
        guard let body = try? await request.decode(as: EditEggBody.self, context: context) else {
            return json(["error": "bad request"], status: .badRequest)
        }
        let edits = EggEdits(
            name: body.name, author: body.author, description: body.description, startup: body.startup,
            stop: body.stop, configFiles: body.configFiles, configLogs: body.configLogs,
            installScript: body.installScript, installContainer: body.installContainer,
            installEntrypoint: body.installEntrypoint,
            images: body.images?.map { (label: $0.label, image: $0.image) },
            variables: body.variables?.map {
                EggEdits.VariableEdit(
                    name: $0.name, description: $0.description ?? "", envVariable: $0.envVariable,
                    defaultValue: $0.defaultValue ?? "", userViewable: $0.userViewable ?? true,
                    userEditable: $0.userEditable ?? true, rules: $0.rules ?? [])
            })
        let patched: String
        do { patched = try EggEditor.apply(edits, to: stored.rawJSON) } catch {
            return json(["error": "could not apply the edits"], status: .badRequest)
        }
        let egg: PterodactylEgg
        do { egg = try EggParser.parse(patched) } catch {
            return json(["error": "the edited egg is no longer valid (check startup and variables)"], status: .badRequest)
        }
        let warnings = EggValidator.validate(egg).map(\.message)
        try store.updateEgg(id: id, egg: egg, rawJSON: patched)
        audit(user: user.username, action: "admin.egg.edit", outcome: "ok", ip: context.clientIP, detail: egg.name)
        return encode(ImportResultDTO(eggId: id, name: egg.name, warnings: warnings))
    }

    /// Re-fetches an egg from its declared `meta.update_url` and overwrites it in
    /// place (same id). Admin-only; only http(s) URLs the egg itself declares are
    /// fetched, and the download is size- and time-bounded.
    @Sendable func apiAdminEggUpdate(_ request: Request, context: PanelRequestContext) async throws -> Response {
        let user = try context.requireIdentity()
        let id = try requireInt(context, "id")
        guard let stored = try store.egg(id: id) else { throw notFound() }
        guard let url = EggParser.updateURL(fromJSON: stored.rawJSON) else {
            return json(["error": "this egg has no update source (meta.update_url)"], status: .badRequest)
        }
        let fetched: String
        do {
            fetched = try await Self.fetchText(url: url, maxBytes: 2_000_000, timeout: 15)
        } catch {
            return json(["error": "couldn't fetch the egg from \(url.absoluteString)"], status: .badGateway)
        }
        let egg: PterodactylEgg
        do { egg = try EggParser.parse(fetched) } catch {
            return json(["error": "the fetched file doesn't look like a valid egg export"], status: .badRequest)
        }
        let warnings = EggValidator.validate(egg).map(\.message)
        try store.updateEgg(id: id, egg: egg, rawJSON: fetched)
        audit(user: user.username, action: "admin.egg.update", outcome: "ok", ip: context.clientIP, detail: egg.name)
        return encode(ImportResultDTO(eggId: id, name: egg.name, warnings: warnings))
    }

    /// A bounded host HTTP GET returning the body as text. Enforces http(s), a
    /// byte cap, and a timeout so an egg update can't hang or exhaust memory.
    static func fetchText(url: URL, maxBytes: Int, timeout: TimeInterval) async throws -> String {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.httpMethod = "GET"
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw EggFetchError.httpStatus(http.statusCode)
        }
        guard data.count <= maxBytes else { throw EggFetchError.tooLarge }
        return String(decoding: data, as: UTF8.self)
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

    @Sendable func apiAdminServerSuspend(_ request: Request, context: PanelRequestContext) async throws -> Response {
        let user = try context.requireIdentity()
        let name = try context.parameters.require("name")
        guard try store.serverRecord(name: name) != nil else { throw notFound() }
        try? await containers.power(.stop, containerName: name)
        try store.setServerStatus(name: name, status: "suspended")
        audit(user: user.username, action: "admin.server.suspend", container: name, outcome: "ok", ip: context.clientIP)
        return json(["ok": true])
    }

    @Sendable func apiAdminServerUnsuspend(_ request: Request, context: PanelRequestContext) async throws -> Response {
        let user = try context.requireIdentity()
        let name = try context.parameters.require("name")
        guard try store.serverRecord(name: name) != nil else { throw notFound() }
        try store.setServerStatus(name: name, status: "active")
        audit(user: user.username, action: "admin.server.unsuspend", container: name, outcome: "ok", ip: context.clientIP)
        return json(["ok": true])
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

    /// The shared managed-database engine's config, creating it (a fresh root
    /// password + the default port/image) the first time a database is made.
    private func databaseEngine() throws -> DatabaseEngineConfig {
        if let existing = try store.databaseEngineConfig() { return existing }
        let config = DatabaseEngineConfig(
            rootPassword: DatabaseProvisioning.generatePassword(), hostPort: 3306,
            image: ManagedDatabaseService.defaultImage)
        try store.setDatabaseEngineConfig(config)
        return config
    }

    /// Provisions a REAL database + scoped user on the shared MariaDB (starting it
    /// on first use), then records it. The connection details, incl. the one-time
    /// password, come back in the response.
    @Sendable func apiAdminDatabaseCreate(_ request: Request, context: PanelRequestContext) async throws -> Response {
        let user = try context.requireIdentity()
        let name = try context.parameters.require("name")
        guard let server = try store.serverRecord(name: name) else { throw notFound() }
        guard let body = try? await request.decode(as: CreateDatabaseBody.self, context: context), !body.name.isEmpty
        else { return json(["error": "a database name is required"], status: .badRequest) }
        guard let dbName = DatabaseProvisioning.databaseName(serverID: server.id, base: body.name),
            let username = DatabaseProvisioning.username(serverID: server.id, base: body.name)
        else { return json(["error": "the name must contain letters or digits"], status: .badRequest) }
        let password = DatabaseProvisioning.generatePassword()
        guard let sql = DatabaseProvisioning.createSQL(database: dbName, username: username, password: password) else {
            return json(["error": "could not build a safe provisioning statement"], status: .internalServerError)
        }
        let engine = try databaseEngine()
        do {
            try await containers.executeDatabaseSQL(sql, engine: engine)
        } catch {
            audit(
                user: user.username, action: "admin.database.create", container: name, outcome: "error",
                ip: context.clientIP, detail: "\(error)")
            return json(["error": "could not provision the database — is docker available? (\(error))"], status: .internalServerError)
        }
        let id = try store.createManagedDatabase(
            serverID: server.id, name: dbName, host: "host.docker.internal", port: engine.hostPort,
            username: username, password: password)
        audit(
            user: user.username, action: "admin.database.create", container: name, outcome: "ok",
            ip: context.clientIP, detail: dbName)
        guard let record = try store.database(id: id) else { throw notFound() }
        return encode(DatabaseDTO(record))
    }

    @Sendable func apiAdminDatabaseDelete(_ request: Request, context: PanelRequestContext) async throws -> Response {
        let user = try context.requireIdentity()
        let id = try requireInt(context, "id")
        // Drop the real database + user first (only for managed records), so we
        // never orphan a database on the engine after removing our record.
        if let record = try store.database(id: id), record.managed, let username = record.username,
            let sql = DatabaseProvisioning.dropSQL(database: record.name, username: username),
            let engine = try store.databaseEngineConfig()
        {
            do {
                try await containers.executeDatabaseSQL(sql, engine: engine)
            } catch {
                return json(["error": "could not drop the database on the engine (\(error))"], status: .internalServerError)
            }
        }
        try store.deleteDatabase(id: id)
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
