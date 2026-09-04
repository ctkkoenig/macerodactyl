import Foundation

// MARK: - Provisioning + admin models

/// Global panel policy/settings (the "Settings" admin screen). Stored as a small
/// key/value table so adding a knob never needs a migration.
public struct PanelGlobalSettings: Sendable, Equatable {
    public enum Require2FA: String, Sendable, CaseIterable {
        case off, force, denyNon2FA = "deny_non_2fa"
    }
    public var companyName: String
    public var require2FA: Require2FA
    public var defaultLanguage: String
    public var defaultTimezone: String

    public static let `default` = PanelGlobalSettings(
        companyName: "Macerodactyl", require2FA: .off, defaultLanguage: "en", defaultTimezone: "UTC")

    public init(companyName: String, require2FA: Require2FA, defaultLanguage: String, defaultTimezone: String) {
        self.companyName = companyName
        self.require2FA = require2FA
        self.defaultLanguage = defaultLanguage
        self.defaultTimezone = defaultTimezone
    }
}

/// The single machine this panel runs on, shown as the one "node".
public struct NodeConfig: Sendable, Equatable {
    public var name: String
    public var locationID: Int64?
    public var hostIP: String
    public var portRangeStart: Int
    public var portRangeEnd: Int
    public var ranges: [ClosedRange<Int>] {
        portRangeStart <= portRangeEnd ? [portRangeStart...portRangeEnd] : []
    }
    public init(name: String, locationID: Int64?, hostIP: String, portRangeStart: Int, portRangeEnd: Int) {
        self.name = name
        self.locationID = locationID
        self.hostIP = hostIP
        self.portRangeStart = portRangeStart
        self.portRangeEnd = portRangeEnd
    }
}

public struct Location: Sendable, Equatable, Identifiable {
    public let id: Int64
    public var short: String
    public var locationDescription: String?
}

public struct Nest: Sendable, Equatable, Identifiable {
    public let id: Int64
    public var uuid: String
    public var name: String
    public var author: String?
    public var nestDescription: String?
}

/// A stored egg. The denormalized columns support listing/wizards; `rawJSON` is
/// the byte-faithful source of truth, re-parsed via `parsed()` for provisioning.
public struct StoredEgg: Sendable, Equatable, Identifiable {
    public let id: Int64
    public var nestID: Int64
    public var uuid: String?
    public var name: String
    public var author: String?
    public var eggDescription: String?
    public var metaVersion: String?
    public var startup: String
    public var dockerImagesJSON: String
    public var rawJSON: String

    public func parsed() throws -> PterodactylEgg { try EggParser.parse(rawJSON) }
    public var dockerImages: [PterodactylEgg.ImageOption] {
        (try? parsed().dockerImages) ?? []
    }
}

/// A provisioned server's persistent record (the "Servers" admin list). The
/// live container is the compose stack named `name`; this row holds the create
/// spec (limits, egg, owner, startup template) for display and future rebuild.
public struct ServerRecord: Sendable, Equatable, Identifiable {
    public let id: Int64
    public var uuid: String
    /// The immutable slug identity (== container name == stack folder == grant key).
    public var name: String
    /// A human-editable label; falls back to `name` when unset.
    public var displayName: String?
    public var eggID: Int64?
    public var dockerImage: String
    public var ownerUserID: Int64?
    public var limits: ServerLimits
    public var startup: String
    public var status: String
    public var createdAt: String
}

public struct ServerDatabaseRecord: Sendable, Equatable, Identifiable {
    public let id: Int64
    public var serverID: Int64
    public var name: String
    public var host: String? = nil
    public var port: Int? = nil
    public var username: String? = nil
    public var remote: String? = nil
    /// The scoped user's password — present only for a database Macerodactyl
    /// actually provisioned (`managed`). Shown once in the connection details.
    public var password: String? = nil
    /// True when Macerodactyl created the real database + user (so deleting it
    /// drops them); false for a legacy bookkeeping-only record.
    public var managed: Bool = false
}

/// The shared managed-database engine (one MariaDB container). Its root password
/// and published port live in the panel DB; the panel uses them to create/drop
/// databases and to show connection details.
public struct DatabaseEngineConfig: Sendable, Equatable {
    public var rootPassword: String
    public var hostPort: Int
    public var image: String
    public init(rootPassword: String, hostPort: Int, image: String) {
        self.rootPassword = rootPassword
        self.hostPort = hostPort
        self.image = image
    }
}

public struct MountRecord: Sendable, Equatable, Identifiable {
    public let id: Int64
    public var name: String
    public var source: String
    public var target: String
    public var readOnly: Bool
    public var mountDescription: String?
}

public enum ProvisioningStoreError: Error, Equatable {
    case allocationPoolExhausted
    case eggNotFound
    case serverNotFound
}

// MARK: - CRUD

extension PanelDataStore {
    // MARK: Global settings

    public func settingString(_ key: String) throws -> String? {
        try db.query("SELECT value FROM panel_settings WHERE key = ?", [.text(key)]).first?["value"]?.asString
    }

    public func setSetting(_ key: String, _ value: String) throws {
        try db.run(
            "INSERT INTO panel_settings (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            [.text(key), .text(value)])
    }

    public func globalSettings() throws -> PanelGlobalSettings {
        let d = PanelGlobalSettings.default
        return PanelGlobalSettings(
            companyName: try settingString("company_name") ?? d.companyName,
            require2FA: PanelGlobalSettings.Require2FA(rawValue: try settingString("require_2fa") ?? "")
                ?? d.require2FA,
            defaultLanguage: try settingString("default_language") ?? d.defaultLanguage,
            defaultTimezone: try settingString("default_timezone") ?? d.defaultTimezone)
    }

    public func setGlobalSettings(_ s: PanelGlobalSettings) throws {
        try setSetting("company_name", s.companyName)
        try setSetting("require_2fa", s.require2FA.rawValue)
        try setSetting("default_language", s.defaultLanguage)
        try setSetting("default_timezone", s.defaultTimezone)
    }

    // MARK: Node (single self-row)

    public func nodeConfig() throws -> NodeConfig {
        let row = try db.query("SELECT * FROM nodes WHERE id = 1").first
        return NodeConfig(
            name: row?["name"]?.asString ?? "local",
            locationID: row?["location_id"]?.asInt,
            hostIP: row?["host_ip"]?.asString ?? "127.0.0.1",
            portRangeStart: Int(row?["port_range_start"]?.asInt ?? 25565),
            portRangeEnd: Int(row?["port_range_end"]?.asInt ?? 25700))
    }

    public func setNodeConfig(_ node: NodeConfig) throws {
        try db.run(
            """
            UPDATE nodes SET name = ?, location_id = ?, host_ip = ?, port_range_start = ?, port_range_end = ?
            WHERE id = 1
            """,
            [
                .text(node.name),
                node.locationID.map { SQLValue.integer($0) } ?? .null,
                .text(node.hostIP),
                .integer(Int64(node.portRangeStart)),
                .integer(Int64(node.portRangeEnd)),
            ])
    }

    // MARK: Locations

    public func listLocations() throws -> [Location] {
        try db.query("SELECT * FROM locations ORDER BY short").map {
            Location(
                id: $0["id"]!.asInt!, short: $0["short"]?.asString ?? "",
                locationDescription: $0["description"]?.asString)
        }
    }

    @discardableResult
    public func createLocation(short: String, description: String?) throws -> Int64 {
        try db.run(
            "INSERT INTO locations (short, description) VALUES (?, ?)",
            [.text(short), description.map { SQLValue.text($0) } ?? .null])
    }

    public func deleteLocation(id: Int64) throws {
        try db.run("DELETE FROM locations WHERE id = ?", [.integer(id)])
    }

    // MARK: Allocations

    public func listAllocations() throws -> [PortAllocation] {
        try db.query("SELECT * FROM allocations ORDER BY ip, port").map(Self.allocationFromRow)
    }

    public func allocations(forServer name: String) throws -> [PortAllocation] {
        try db.query(
            "SELECT * FROM allocations WHERE server_name = ? ORDER BY is_primary DESC, port",
            [.text(name)]
        ).map(Self.allocationFromRow)
    }

    /// Adds allocation rows to the pool. Ports already present (same ip/port/proto)
    /// are skipped. Returns how many were newly created.
    @discardableResult
    public func generateAllocations(ip: String, ports: [Int], proto: String = "tcp") throws -> Int {
        // Count against the existing rows rather than trusting run()'s return
        // (which is last_insert_rowid, not rows-affected — an ignored INSERT OR
        // IGNORE would otherwise look like a real insert).
        let existing = Set(
            try db.query(
                "SELECT port FROM allocations WHERE ip = ? AND proto = ?", [.text(ip), .text(proto)]
            ).compactMap { $0["port"]?.asInt.map(Int.init) })
        var created = 0
        for port in ports where !existing.contains(port) {
            try db.run(
                "INSERT OR IGNORE INTO allocations (ip, port, proto) VALUES (?, ?, ?)",
                [.text(ip), .integer(Int64(port)), .text(proto)])
            created += 1
        }
        return created
    }

    public func deleteAllocation(id: Int64) throws {
        try db.run("DELETE FROM allocations WHERE id = ? AND server_name IS NULL", [.integer(id)])
    }

    /// Atomically reserves `count` free allocations for `serverName`, avoiding
    /// ports currently published by live containers. The lowest reserved port is
    /// marked primary. A single-statement UPDATE claims the rows so two concurrent
    /// creates can't grab the same port (statements are serialized by the DB lock).
    public func reserveAllocations(
        serverName: String, count: Int, excludingPorts: Set<Int> = []
    ) throws -> [PortAllocation] {
        guard count > 0 else { return [] }
        var sql =
            "UPDATE allocations SET server_name = ? WHERE id IN (SELECT id FROM allocations WHERE server_name IS NULL"
        var bindings: [SQLValue] = [.text(serverName)]
        if !excludingPorts.isEmpty {
            let placeholders = excludingPorts.map { _ in "?" }.joined(separator: ",")
            sql += " AND port NOT IN (\(placeholders))"
            bindings += excludingPorts.map { SQLValue.integer(Int64($0)) }
        }
        sql += " ORDER BY port LIMIT ?)"
        bindings.append(.integer(Int64(count)))
        try db.run(sql, bindings)

        let reserved = try allocations(forServer: serverName)
        guard reserved.count >= count else {
            // Pool couldn't satisfy the request — release whatever we grabbed.
            try freeAllocations(serverName: serverName)
            throw ProvisioningStoreError.allocationPoolExhausted
        }
        if let primary = reserved.min(by: { $0.port < $1.port }) {
            try db.run("UPDATE allocations SET is_primary = 1 WHERE id = ?", [.integer(primary.id)])
        }
        return try allocations(forServer: serverName)
    }

    public func freeAllocations(serverName: String) throws {
        try db.run(
            "UPDATE allocations SET server_name = NULL, is_primary = 0 WHERE server_name = ?",
            [.text(serverName)])
    }

    // MARK: Per-allocation assignment (client-managed networking)

    /// Assigns one currently-free allocation to a server. Returns false if the
    /// allocation doesn't exist or is already taken (the WHERE guards the claim,
    /// and the DB lock serializes it so two clients can't grab the same row).
    @discardableResult
    public func assignAllocation(id: Int64, toServer serverName: String) throws -> Bool {
        try db.run(
            "UPDATE allocations SET server_name = ? WHERE id = ? AND server_name IS NULL",
            [.text(serverName), .integer(id)])
        return try allocationOwner(id: id) == serverName
    }

    /// Releases one allocation from a server (only if it belongs to it and isn't
    /// the primary — the primary is released only when the server is deprovisioned).
    /// Returns false if it isn't the server's, or is its primary.
    @discardableResult
    public func releaseAllocation(id: Int64, fromServer serverName: String) throws -> Bool {
        try db.run(
            "UPDATE allocations SET server_name = NULL WHERE id = ? AND server_name = ? AND is_primary = 0",
            [.integer(id), .text(serverName)])
        return try allocationOwner(id: id) == nil
    }

    /// Makes one of a server's allocations its primary, clearing the flag on its
    /// siblings. Returns false if the allocation isn't assigned to that server.
    @discardableResult
    public func setPrimaryAllocation(id: Int64, forServer serverName: String) throws -> Bool {
        guard try allocationOwner(id: id) == serverName else { return false }
        try db.run("UPDATE allocations SET is_primary = 0 WHERE server_name = ?", [.text(serverName)])
        try db.run("UPDATE allocations SET is_primary = 1 WHERE id = ? AND server_name = ?", [.integer(id), .text(serverName)])
        return true
    }

    private func allocationOwner(id: Int64) throws -> String? {
        try db.query("SELECT server_name FROM allocations WHERE id = ?", [.integer(id)]).first?["server_name"]?.asString
    }

    private static func allocationFromRow(_ row: [String: SQLValue]) -> PortAllocation {
        PortAllocation(
            id: row["id"]!.asInt!,
            ip: row["ip"]?.asString ?? "127.0.0.1",
            port: Int(row["port"]?.asInt ?? 0),
            proto: row["proto"]?.asString ?? "tcp",
            serverName: row["server_name"]?.asString,
            isPrimary: (row["is_primary"]?.asInt ?? 0) != 0,
            notes: row["notes"]?.asString)
    }

    // MARK: Nests

    public func listNests() throws -> [Nest] {
        try db.query("SELECT * FROM nests ORDER BY name").map(Self.nestFromRow)
    }

    public func nest(id: Int64) throws -> Nest? {
        try db.query("SELECT * FROM nests WHERE id = ?", [.integer(id)]).first.map(Self.nestFromRow)
    }

    @discardableResult
    public func createNest(
        name: String, author: String?, description: String?, uuid: String = UUID().uuidString
    ) throws
        -> Int64
    {
        try db.run(
            "INSERT INTO nests (uuid, name, author, description) VALUES (?, ?, ?, ?)",
            [
                .text(uuid), .text(name), author.map { SQLValue.text($0) } ?? .null,
                description.map { SQLValue.text($0) } ?? .null,
            ])
    }

    public func deleteNest(id: Int64) throws {
        try db.run("DELETE FROM nests WHERE id = ?", [.integer(id)])
    }

    private static func nestFromRow(_ row: [String: SQLValue]) -> Nest {
        Nest(
            id: row["id"]!.asInt!, uuid: row["uuid"]?.asString ?? "", name: row["name"]?.asString ?? "",
            author: row["author"]?.asString, nestDescription: row["description"]?.asString)
    }

    // MARK: Eggs

    /// Imports a parsed egg (with its faithful raw JSON) under a nest, storing the
    /// denormalized columns and the variable cache. Returns the new egg id.
    @discardableResult
    public func importEgg(_ egg: PterodactylEgg, rawJSON: String, nestID: Int64, uuid: String? = nil) throws -> Int64 {
        let imagesJSON = Self.encodeJSON(egg.dockerImages.map { ["label": $0.label, "image": $0.image] }) ?? "[]"
        let doneJSON = Self.encodeJSON(egg.doneStrings) ?? "[]"
        let featuresJSON = Self.encodeJSON(egg.features) ?? "[]"
        let denylistJSON = Self.encodeJSON(egg.fileDenylist) ?? "[]"
        let eggID = try db.run(
            """
            INSERT INTO eggs (nest_id, uuid, name, author, description, meta_version, docker_images_json,
                startup, config_files, done_strings_json, config_logs, config_stop,
                script_install, script_container, script_entrypoint, features_json, file_denylist_json, raw_json)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [
                .integer(nestID), uuid.map { SQLValue.text($0) } ?? .null, .text(egg.name),
                .text(egg.author), .text(egg.eggDescription), .text(egg.metaVersion), .text(imagesJSON),
                .text(egg.startup), .text(egg.configFiles), .text(doneJSON), .text(egg.configLogs),
                .text(egg.configStop), .text(egg.install.script), .text(egg.install.container),
                .text(egg.install.entrypoint), .text(featuresJSON), .text(denylistJSON), .text(rawJSON),
            ])
        for (index, variable) in egg.variables.enumerated() {
            try db.run(
                """
                INSERT INTO egg_variables (egg_id, name, description, env_variable, default_value,
                    user_viewable, user_editable, rules, sort)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                [
                    .integer(eggID), .text(variable.name), .text(variable.variableDescription),
                    .text(variable.envVariable), .text(variable.defaultValue),
                    .integer(variable.userViewable ? 1 : 0), .integer(variable.userEditable ? 1 : 0),
                    .text(variable.rules.joined(separator: "|")), .integer(Int64(index)),
                ])
        }
        return eggID
    }

    /// Overwrites an existing egg in place from a re-fetched export, keeping its
    /// id (so provisioned servers keep referring to the same egg) and its nest.
    /// Its variables are fully replaced — a variable dropped upstream goes away,
    /// a new one appears — which is what "update from source" means.
    public func updateEgg(id: Int64, egg: PterodactylEgg, rawJSON: String) throws {
        let imagesJSON = Self.encodeJSON(egg.dockerImages.map { ["label": $0.label, "image": $0.image] }) ?? "[]"
        let doneJSON = Self.encodeJSON(egg.doneStrings) ?? "[]"
        let featuresJSON = Self.encodeJSON(egg.features) ?? "[]"
        let denylistJSON = Self.encodeJSON(egg.fileDenylist) ?? "[]"
        try db.run(
            """
            UPDATE eggs SET name = ?, author = ?, description = ?, meta_version = ?, docker_images_json = ?,
                startup = ?, config_files = ?, done_strings_json = ?, config_logs = ?, config_stop = ?,
                script_install = ?, script_container = ?, script_entrypoint = ?, features_json = ?,
                file_denylist_json = ?, raw_json = ?
            WHERE id = ?
            """,
            [
                .text(egg.name), .text(egg.author), .text(egg.eggDescription), .text(egg.metaVersion),
                .text(imagesJSON), .text(egg.startup), .text(egg.configFiles), .text(doneJSON),
                .text(egg.configLogs), .text(egg.configStop), .text(egg.install.script),
                .text(egg.install.container), .text(egg.install.entrypoint), .text(featuresJSON),
                .text(denylistJSON), .text(rawJSON), .integer(id),
            ])
        try db.run("DELETE FROM egg_variables WHERE egg_id = ?", [.integer(id)])
        for (index, variable) in egg.variables.enumerated() {
            try db.run(
                """
                INSERT INTO egg_variables (egg_id, name, description, env_variable, default_value,
                    user_viewable, user_editable, rules, sort)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                [
                    .integer(id), .text(variable.name), .text(variable.variableDescription),
                    .text(variable.envVariable), .text(variable.defaultValue),
                    .integer(variable.userViewable ? 1 : 0), .integer(variable.userEditable ? 1 : 0),
                    .text(variable.rules.joined(separator: "|")), .integer(Int64(index)),
                ])
        }
    }

    public func listEggs(nestID: Int64? = nil) throws -> [StoredEgg] {
        let rows: [[String: SQLValue]]
        if let nestID {
            rows = try db.query("SELECT * FROM eggs WHERE nest_id = ? ORDER BY name", [.integer(nestID)])
        } else {
            rows = try db.query("SELECT * FROM eggs ORDER BY name")
        }
        return rows.map(Self.eggFromRow)
    }

    public func egg(id: Int64) throws -> StoredEgg? {
        try db.query("SELECT * FROM eggs WHERE id = ?", [.integer(id)]).first.map(Self.eggFromRow)
    }

    public func deleteEgg(id: Int64) throws {
        try db.run("DELETE FROM eggs WHERE id = ?", [.integer(id)])
    }

    private static func eggFromRow(_ row: [String: SQLValue]) -> StoredEgg {
        StoredEgg(
            id: row["id"]!.asInt!, nestID: row["nest_id"]?.asInt ?? 0, uuid: row["uuid"]?.asString,
            name: row["name"]?.asString ?? "", author: row["author"]?.asString,
            eggDescription: row["description"]?.asString, metaVersion: row["meta_version"]?.asString,
            startup: row["startup"]?.asString ?? "", dockerImagesJSON: row["docker_images_json"]?.asString ?? "[]",
            rawJSON: row["raw_json"]?.asString ?? "{}")
    }

    // MARK: Servers

    @discardableResult
    public func createServerRecord(
        uuid: String, name: String, eggID: Int64?, dockerImage: String, ownerUserID: Int64?,
        limits: ServerLimits, startup: String, values: [String: String], status: String = "installing"
    ) throws -> Int64 {
        let serverID = try db.run(
            """
            INSERT INTO server_records (uuid, name, egg_id, docker_image, owner_user_id, memory_mib, swap_mib,
                disk_mib, cpu_percent, cpu_pinning, io_weight, pids_limit, oom_disabled, startup, status)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [
                .text(uuid), .text(name), eggID.map { SQLValue.integer($0) } ?? .null, .text(dockerImage),
                ownerUserID.map { SQLValue.integer($0) } ?? .null, .integer(Int64(limits.memoryMiB)),
                .integer(Int64(limits.swapMiB)), .integer(Int64(limits.diskMiB)),
                .integer(Int64(limits.cpuPercent)), limits.cpuPinning.map { SQLValue.text($0) } ?? .null,
                limits.ioWeight.map { SQLValue.integer(Int64($0)) } ?? .null,
                limits.pidsLimit.map { SQLValue.integer(Int64($0)) } ?? .null,
                .integer(limits.oomKillDisable ? 1 : 0), .text(startup), .text(status),
            ])
        for (env, value) in values {
            try db.run(
                "INSERT INTO server_variables (server_id, env_variable, value) VALUES (?, ?, ?)",
                [.integer(serverID), .text(env), .text(value)])
        }
        return serverID
    }

    public func setServerStatus(name: String, status: String) throws {
        try db.run("UPDATE server_records SET status = ? WHERE name = ?", [.text(status), .text(name)])
    }

    public func listServerRecords() throws -> [ServerRecord] {
        try db.query("SELECT * FROM server_records ORDER BY created_at DESC").map(Self.serverFromRow)
    }

    public func serverRecord(name: String) throws -> ServerRecord? {
        try db.query("SELECT * FROM server_records WHERE name = ?", [.text(name)]).first.map(Self.serverFromRow)
    }

    public func deleteServerRecord(name: String) throws {
        try db.run("DELETE FROM server_records WHERE name = ?", [.text(name)])
    }

    /// The stored service-variable values for a server (env_variable → value).
    public func serverVariables(serverID: Int64) throws -> [String: String] {
        var out: [String: String] = [:]
        for row in try db.query("SELECT env_variable, value FROM server_variables WHERE server_id = ?", [.integer(serverID)]) {
            if let key = row["env_variable"]?.asString { out[key] = row["value"]?.asString ?? "" }
        }
        return out
    }

    /// Applies an edit to a server's mutable fields (the slug `name` never changes).
    public func updateServer(
        name: String, displayName: String?, dockerImage: String, ownerUserID: Int64?, limits: ServerLimits,
        startup: String, values: [String: String]
    ) throws {
        try db.run(
            """
            UPDATE server_records SET display_name = ?, docker_image = ?, owner_user_id = ?, memory_mib = ?,
                swap_mib = ?, disk_mib = ?, cpu_percent = ?, cpu_pinning = ?, io_weight = ?, pids_limit = ?,
                oom_disabled = ?, startup = ? WHERE name = ?
            """,
            [
                displayName.map { SQLValue.text($0) } ?? .null, .text(dockerImage),
                ownerUserID.map { SQLValue.integer($0) } ?? .null, .integer(Int64(limits.memoryMiB)),
                .integer(Int64(limits.swapMiB)), .integer(Int64(limits.diskMiB)), .integer(Int64(limits.cpuPercent)),
                limits.cpuPinning.map { SQLValue.text($0) } ?? .null,
                limits.ioWeight.map { SQLValue.integer(Int64($0)) } ?? .null,
                limits.pidsLimit.map { SQLValue.integer(Int64($0)) } ?? .null,
                .integer(limits.oomKillDisable ? 1 : 0), .text(startup), .text(name),
            ])
        if let server = try serverRecord(name: name) {
            try db.run("DELETE FROM server_variables WHERE server_id = ?", [.integer(server.id)])
            for (env, value) in values {
                try db.run(
                    "INSERT INTO server_variables (server_id, env_variable, value) VALUES (?, ?, ?)",
                    [.integer(server.id), .text(env), .text(value)])
            }
        }
    }

    private static func serverFromRow(_ row: [String: SQLValue]) -> ServerRecord {
        ServerRecord(
            id: row["id"]!.asInt!, uuid: row["uuid"]?.asString ?? "", name: row["name"]?.asString ?? "",
            displayName: row["display_name"]?.asString,
            eggID: row["egg_id"]?.asInt, dockerImage: row["docker_image"]?.asString ?? "",
            ownerUserID: row["owner_user_id"]?.asInt,
            limits: ServerLimits(
                memoryMiB: Int(row["memory_mib"]?.asInt ?? 0), swapMiB: Int(row["swap_mib"]?.asInt ?? 0),
                diskMiB: Int(row["disk_mib"]?.asInt ?? 0), cpuPercent: Int(row["cpu_percent"]?.asInt ?? 0),
                cpuPinning: row["cpu_pinning"]?.asString, ioWeight: row["io_weight"]?.asInt.map(Int.init),
                pidsLimit: row["pids_limit"]?.asInt.map(Int.init),
                oomKillDisable: (row["oom_disabled"]?.asInt ?? 0) != 0),
            startup: row["startup"]?.asString ?? "", status: row["status"]?.asString ?? "unknown",
            createdAt: row["created_at"]?.asString ?? "")
    }

    // MARK: Databases

    private func databaseFromRow(_ row: [String: SQLValue], serverID: Int64) -> ServerDatabaseRecord {
        ServerDatabaseRecord(
            id: row["id"]!.asInt!, serverID: serverID, name: row["name"]?.asString ?? "",
            host: row["host"]?.asString, port: row["port"]?.asInt.map(Int.init),
            username: row["username"]?.asString, remote: row["remote"]?.asString,
            password: row["password"]?.asString, managed: (row["managed"]?.asInt ?? 0) != 0)
    }

    public func listDatabases(serverID: Int64) throws -> [ServerDatabaseRecord] {
        try db.query("SELECT * FROM server_databases WHERE server_id = ? ORDER BY name", [.integer(serverID)])
            .map { databaseFromRow($0, serverID: serverID) }
    }

    public func database(id: Int64) throws -> ServerDatabaseRecord? {
        try db.query("SELECT * FROM server_databases WHERE id = ?", [.integer(id)])
            .first.map { databaseFromRow($0, serverID: $0["server_id"]?.asInt ?? 0) }
    }

    /// Records a database Macerodactyl actually provisioned (with the generated
    /// user + password), marked `managed` so deleting it drops the real database.
    @discardableResult
    public func createManagedDatabase(
        serverID: Int64, name: String, host: String, port: Int, username: String, password: String
    ) throws -> Int64 {
        try db.run(
            """
            INSERT INTO server_databases (server_id, name, host, port, username, password, managed)
            VALUES (?, ?, ?, ?, ?, ?, 1)
            """,
            [
                .integer(serverID), .text(name), .text(host), .integer(Int64(port)),
                .text(username), .text(password),
            ])
    }

    // MARK: Managed-database engine (shared MariaDB)

    public func databaseEngineConfig() throws -> DatabaseEngineConfig? {
        try db.query("SELECT * FROM db_engine WHERE id = 1").first.map {
            DatabaseEngineConfig(
                rootPassword: $0["root_password"]?.asString ?? "", hostPort: Int($0["host_port"]?.asInt ?? 0),
                image: $0["image"]?.asString ?? "")
        }
    }

    public func setDatabaseEngineConfig(_ config: DatabaseEngineConfig) throws {
        try db.run(
            """
            INSERT INTO db_engine (id, root_password, host_port, image) VALUES (1, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET root_password=excluded.root_password,
                host_port=excluded.host_port, image=excluded.image
            """,
            [.text(config.rootPassword), .integer(Int64(config.hostPort)), .text(config.image)])
    }

    @discardableResult
    public func createDatabase(
        serverID: Int64, name: String, host: String?, port: Int?, username: String?
    ) throws
        -> Int64
    {
        try db.run(
            "INSERT INTO server_databases (server_id, name, host, port, username) VALUES (?, ?, ?, ?, ?)",
            [
                .integer(serverID), .text(name), host.map { SQLValue.text($0) } ?? .null,
                port.map { SQLValue.integer(Int64($0)) } ?? .null, username.map { SQLValue.text($0) } ?? .null,
            ])
    }

    public func deleteDatabase(id: Int64) throws {
        try db.run("DELETE FROM server_databases WHERE id = ?", [.integer(id)])
    }

    // MARK: Mounts

    public func listMounts() throws -> [MountRecord] {
        try db.query("SELECT * FROM mounts ORDER BY name").map {
            MountRecord(
                id: $0["id"]!.asInt!, name: $0["name"]?.asString ?? "", source: $0["source"]?.asString ?? "",
                target: $0["target"]?.asString ?? "", readOnly: ($0["read_only"]?.asInt ?? 0) != 0,
                mountDescription: $0["description"]?.asString)
        }
    }

    @discardableResult
    public func createMount(
        name: String, source: String, target: String, readOnly: Bool, description: String?
    ) throws
        -> Int64
    {
        try db.run(
            "INSERT INTO mounts (name, source, target, read_only, description) VALUES (?, ?, ?, ?, ?)",
            [
                .text(name), .text(source), .text(target), .integer(readOnly ? 1 : 0),
                description.map { SQLValue.text($0) } ?? .null,
            ])
    }

    public func deleteMount(id: Int64) throws {
        try db.run("DELETE FROM mounts WHERE id = ?", [.integer(id)])
    }

    /// Associates a mount with a server (for display/management; the actual bind
    /// is written into the server's compose at create time).
    public func linkServerMount(serverID: Int64, mountID: Int64) throws {
        try db.run(
            "INSERT OR IGNORE INTO server_mounts (server_id, mount_id) VALUES (?, ?)",
            [.integer(serverID), .integer(mountID)])
    }

    public func mountsForServer(serverID: Int64) throws -> [MountRecord] {
        try db.query(
            """
            SELECT m.* FROM mounts m JOIN server_mounts sm ON sm.mount_id = m.id
            WHERE sm.server_id = ? ORDER BY m.name
            """, [.integer(serverID)]
        ).map {
            MountRecord(
                id: $0["id"]!.asInt!, name: $0["name"]?.asString ?? "", source: $0["source"]?.asString ?? "",
                target: $0["target"]?.asString ?? "", readOnly: ($0["read_only"]?.asInt ?? 0) != 0,
                mountDescription: $0["description"]?.asString)
        }
    }

    // MARK: JSON helper

    static func encodeJSON(_ value: Any) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: value) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
