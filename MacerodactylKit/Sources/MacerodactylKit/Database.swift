import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public enum DatabaseError: Error {
    case openFailed(String)
    case prepareFailed(String, sql: String)
    case stepFailed(String)
}

public enum SQLValue: Sendable, Equatable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)

    var asString: String? { if case .text(let s) = self { s } else { nil } }
    var asInt: Int64? { if case .integer(let i) = self { i } else { nil } }
    var asDouble: Double? { if case .real(let d) = self { d } else { nil } }
}

/// Minimal wrapper over the system libsqlite3 (serialized mode, WAL). All
/// access is funneled through an internal lock so any thread may call in.
public final class Database: @unchecked Sendable {
    private var handle: OpaquePointer?
    private let lock = NSLock()

    public convenience init(path: String) throws {
        try self.init(path: path, readOnly: false)
    }

    /// `readOnly` opens the file with neither CREATE nor write access and skips
    /// the WAL pragma — used to validate a backup without creating an empty file
    /// for a missing path or writing WAL/SHM litter beside it.
    public init(path: String, readOnly: Bool) throws {
        let flags =
            readOnly
            ? (SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX)
            : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX)
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            throw DatabaseError.openFailed(message)
        }
        if !readOnly {
            try execute("PRAGMA journal_mode=WAL")
        }
        try execute("PRAGMA foreign_keys=ON")
    }

    deinit {
        sqlite3_close_v2(handle)
    }

    public func execute(_ sql: String) throws {
        lock.lock()
        defer { lock.unlock() }
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
            throw DatabaseError.stepFailed(String(cString: sqlite3_errmsg(handle)))
        }
    }

    @discardableResult
    public func run(_ sql: String, _ bindings: [SQLValue] = []) throws -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        let statement = try prepare(sql, bindings)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseError.stepFailed(String(cString: sqlite3_errmsg(handle)))
        }
        return sqlite3_last_insert_rowid(handle)
    }

    public func query(_ sql: String, _ bindings: [SQLValue] = []) throws -> [[String: SQLValue]] {
        lock.lock()
        defer { lock.unlock() }
        let statement = try prepare(sql, bindings)
        defer { sqlite3_finalize(statement) }

        var rows: [[String: SQLValue]] = []
        while true {
            let rc = sqlite3_step(statement)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else {
                throw DatabaseError.stepFailed(String(cString: sqlite3_errmsg(handle)))
            }
            var row: [String: SQLValue] = [:]
            for index in 0..<sqlite3_column_count(statement) {
                let name = String(cString: sqlite3_column_name(statement, index))
                switch sqlite3_column_type(statement, index) {
                case SQLITE_INTEGER: row[name] = .integer(sqlite3_column_int64(statement, index))
                case SQLITE_FLOAT: row[name] = .real(sqlite3_column_double(statement, index))
                case SQLITE_TEXT: row[name] = .text(String(cString: sqlite3_column_text(statement, index)))
                default: row[name] = .null
                }
            }
            rows.append(row)
        }
        return rows
    }

    private func prepare(_ sql: String, _ bindings: [SQLValue]) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(handle)), sql: sql)
        }
        for (offset, value) in bindings.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case .null: sqlite3_bind_null(statement, index)
            case .integer(let integer): sqlite3_bind_int64(statement, index, integer)
            case .real(let double): sqlite3_bind_double(statement, index, double)
            case .text(let text): sqlite3_bind_text(statement, index, text, -1, SQLITE_TRANSIENT)
            }
        }
        return statement
    }

    var userVersion: Int {
        get { (try? query("PRAGMA user_version").first?["user_version"]?.asInt).flatMap { Int($0) } ?? 0 }
        set { try? execute("PRAGMA user_version = \(newValue)") }
    }

    // MARK: Durability / operations

    /// Folds the write-ahead log back into the main database file and truncates
    /// it, so the WAL can't grow without bound and the main file is current.
    public func checkpoint() throws {
        try execute("PRAGMA wal_checkpoint(TRUNCATE)")
    }

    /// Runs SQLite's integrity check. Returns the raw rows — `["ok"]` when the
    /// database is healthy, otherwise one row per problem found.
    public func integrityCheck() throws -> [String] {
        try query("PRAGMA integrity_check").compactMap { $0["integrity_check"]?.asString }
    }

    public var isHealthy: Bool {
        (try? integrityCheck()) == ["ok"]
    }

    /// Writes a clean, consistent copy of the live database to `path` using
    /// `VACUUM INTO` — safe to call while the database is open and in use, and
    /// the copy is defragmented with no leftover WAL. The destination must not
    /// already exist.
    public func backup(toPath path: String) throws {
        try checkpoint()
        try run("VACUUM INTO ?", [.text(path)])
    }
}

/// Backup/restore for the panel database. Backups are made live-safe via
/// `PanelDataStore.backup(toPath:)` (VACUUM INTO); restore installs a validated
/// backup as the live database and MUST be done while the panel is stopped —
/// the GUI server and the daemon must not hold the database open, or restoring
/// under them corrupts state.
public enum PanelBackup {
    /// Validates a backup file's integrity and installs it as the live database.
    /// The current database (and any stale WAL/SHM) is moved aside first and its
    /// path returned, so a bad restore can be undone. Caller must stop the panel.
    @discardableResult
    public static func restore(from backupPath: String, to dbPath: String) throws -> String {
        let fm = FileManager.default
        // 0. The backup must actually exist. Opening a missing path read-WRITE
        //    would CREATE an empty database that then passes integrity_check —
        //    and installing THAT silently wipes the live accounts/grants/audit.
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: backupPath, isDirectory: &isDir), !isDir.boolValue else {
            throw DatabaseError.openFailed("backup file does not exist: \(backupPath)")
        }
        // 1. The backup must open READ-ONLY (never create), pass integrity_check,
        //    AND look like a panel database (a valid but foreign/empty SQLite
        //    file would otherwise install and mint a fresh admin over your data).
        let healthy: Bool
        let looksLikePanel: Bool
        do {
            let check = try Database(path: backupPath, readOnly: true)
            healthy = check.isHealthy
            looksLikePanel = check.userVersion >= 1
        }
        guard healthy else { throw DatabaseError.stepFailed("backup failed integrity check: \(backupPath)") }
        guard looksLikePanel else {
            throw DatabaseError.stepFailed("not a Macerodactyl panel backup (no schema version): \(backupPath)")
        }

        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let sidelined = "\(dbPath).pre-restore-\(stamp)"
        if fm.fileExists(atPath: dbPath) { try fm.moveItem(atPath: dbPath, toPath: sidelined) }
        // Stale WAL/SHM would otherwise be replayed onto the restored file.
        for suffix in ["-wal", "-shm"] { try? fm.removeItem(atPath: dbPath + suffix) }
        try fm.copyItem(atPath: backupPath, toPath: dbPath)
        return sidelined
    }
}

/// Schema for the panel's persistent state. Landed in Phase 1 so accounts,
/// scoping, and audit never have to be retrofitted into the data model.
public enum PanelSchema {
    public static let currentVersion = 3

    public static func migrate(_ db: Database) throws {
        if db.userVersion < 1 {
            try db.execute(
                """
                CREATE TABLE IF NOT EXISTS users (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    username TEXT NOT NULL UNIQUE COLLATE NOCASE,
                    password_hash TEXT NOT NULL,
                    is_admin INTEGER NOT NULL DEFAULT 0,
                    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
                );
                CREATE TABLE IF NOT EXISTS grants (
                    user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
                    container_name TEXT NOT NULL,
                    perm_view INTEGER NOT NULL DEFAULT 0,
                    perm_power INTEGER NOT NULL DEFAULT 0,
                    perm_files INTEGER NOT NULL DEFAULT 0,
                    perm_console INTEGER NOT NULL DEFAULT 0,
                    PRIMARY KEY (user_id, container_name)
                );
                CREATE TABLE IF NOT EXISTS sessions (
                    token_hash TEXT PRIMARY KEY,
                    user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
                    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
                    expires_at TEXT NOT NULL
                );
                CREATE TABLE IF NOT EXISTS audit (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    ts TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
                    username TEXT NOT NULL,
                    action TEXT NOT NULL,
                    container_name TEXT,
                    outcome TEXT NOT NULL,
                    source_ip TEXT,
                    detail TEXT
                );
                """)
            db.userVersion = 1
        }
        if db.userVersion < 2 {
            // Add the fifth permission (schedule management over HTTP).
            // Existing grants default to no schedule access.
            try db.execute("ALTER TABLE grants ADD COLUMN perm_schedules INTEGER NOT NULL DEFAULT 0")
            db.userVersion = 2
        }
        if db.userVersion < 3 {
            // Persist failed-login throttling so a restart isn't a brute-force
            // reset. Keyed by "acct:<username>" and "ip:<addr>".
            try db.execute(
                """
                CREATE TABLE IF NOT EXISTS rate_limits (
                    key TEXT PRIMARY KEY,
                    failures INTEGER NOT NULL DEFAULT 0,
                    blocked_until TEXT
                );
                """)
            db.userVersion = 3
        }
    }
}

public struct PanelUser: Sendable, Equatable, Identifiable {
    public let id: Int64
    public let username: String
    public let passwordHash: String
    public let isAdmin: Bool
}

public struct AuditEntry: Sendable, Equatable, Identifiable {
    public let id: Int64
    public let timestamp: String
    public let username: String
    public let action: String
    public let containerName: String?
    public let outcome: String
    public let sourceIP: String?
    public let detail: String?
}

/// Typed access to panel state (users, grants, sessions, audit) over Database.
public final class PanelDataStore: Sendable {
    private let db: Database

    public init(databasePath: String) throws {
        self.db = try Database(path: databasePath)
        try PanelSchema.migrate(db)
    }

    // MARK: Users

    @discardableResult
    public func createUser(username: String, passwordHash: String, isAdmin: Bool) throws -> PanelUser {
        let id = try db.run(
            "INSERT INTO users (username, password_hash, is_admin) VALUES (?, ?, ?)",
            [.text(username), .text(passwordHash), .integer(isAdmin ? 1 : 0)]
        )
        return PanelUser(id: id, username: username, passwordHash: passwordHash, isAdmin: isAdmin)
    }

    public func user(named username: String) throws -> PanelUser? {
        try db.query("SELECT * FROM users WHERE username = ?", [.text(username)]).first.map(Self.userFromRow)
    }

    public func user(id: Int64) throws -> PanelUser? {
        try db.query("SELECT * FROM users WHERE id = ?", [.integer(id)]).first.map(Self.userFromRow)
    }

    public func listUsers() throws -> [PanelUser] {
        try db.query("SELECT * FROM users ORDER BY username").map(Self.userFromRow)
    }

    public func hasAnyUser() throws -> Bool {
        try db.query("SELECT 1 FROM users LIMIT 1").isEmpty == false
    }

    public func deleteUser(id: Int64) throws {
        try db.run("DELETE FROM users WHERE id = ?", [.integer(id)])
    }

    public func updatePassword(userID: Int64, passwordHash: String) throws {
        try db.run("UPDATE users SET password_hash = ? WHERE id = ?", [.text(passwordHash), .integer(userID)])
    }

    private static func userFromRow(_ row: [String: SQLValue]) -> PanelUser {
        PanelUser(
            id: row["id"]?.asInt ?? 0,
            username: row["username"]?.asString ?? "",
            passwordHash: row["password_hash"]?.asString ?? "",
            isAdmin: (row["is_admin"]?.asInt ?? 0) != 0
        )
    }

    // MARK: Grants

    public func setGrant(userID: Int64, containerName: String, grant: ContainerGrant) throws {
        if grant.isEmpty {
            try db.run(
                "DELETE FROM grants WHERE user_id = ? AND container_name = ?",
                [.integer(userID), .text(containerName)]
            )
        } else {
            try db.run(
                """
                INSERT INTO grants (user_id, container_name, perm_view, perm_power, perm_files, perm_console, perm_schedules)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(user_id, container_name) DO UPDATE SET
                    perm_view=excluded.perm_view, perm_power=excluded.perm_power,
                    perm_files=excluded.perm_files, perm_console=excluded.perm_console,
                    perm_schedules=excluded.perm_schedules
                """,
                [
                    .integer(userID), .text(containerName),
                    .integer(grant.view ? 1 : 0), .integer(grant.power ? 1 : 0),
                    .integer(grant.files ? 1 : 0), .integer(grant.console ? 1 : 0),
                    .integer(grant.schedules ? 1 : 0),
                ]
            )
        }
    }

    public func grants(forUserID userID: Int64) throws -> [String: ContainerGrant] {
        var result: [String: ContainerGrant] = [:]
        for row in try db.query("SELECT * FROM grants WHERE user_id = ?", [.integer(userID)]) {
            guard let name = row["container_name"]?.asString else { continue }
            result[name] = ContainerGrant(
                view: (row["perm_view"]?.asInt ?? 0) != 0,
                power: (row["perm_power"]?.asInt ?? 0) != 0,
                files: (row["perm_files"]?.asInt ?? 0) != 0,
                console: (row["perm_console"]?.asInt ?? 0) != 0,
                schedules: (row["perm_schedules"]?.asInt ?? 0) != 0
            )
        }
        return result
    }

    /// Builds the per-request authorization engine for a user.
    public func authorizationEngine(for user: PanelUser) throws -> AuthorizationEngine {
        AuthorizationEngine(isAdmin: user.isAdmin, grants: user.isAdmin ? [:] : (try grants(forUserID: user.id)))
    }

    // MARK: Sessions (tokens are stored hashed; the raw token lives only in the cookie)

    public func insertSession(tokenHash: String, userID: Int64, expiresAt: String) throws {
        try db.run(
            "INSERT INTO sessions (token_hash, user_id, expires_at) VALUES (?, ?, ?)",
            [.text(tokenHash), .integer(userID), .text(expiresAt)]
        )
    }

    public func sessionUser(tokenHash: String, now: String) throws -> PanelUser? {
        let rows = try db.query(
            """
            SELECT u.* FROM sessions s JOIN users u ON u.id = s.user_id
            WHERE s.token_hash = ? AND s.expires_at > ?
            """, [.text(tokenHash), .text(now)])
        return rows.first.map(Self.userFromRow)
    }

    public func deleteSession(tokenHash: String) throws {
        try db.run("DELETE FROM sessions WHERE token_hash = ?", [.text(tokenHash)])
    }

    public func deleteExpiredSessions(now: String) throws {
        try db.run("DELETE FROM sessions WHERE expires_at <= ?", [.text(now)])
    }

    // MARK: Audit

    public func recordAudit(
        username: String, action: String, containerName: String?,
        outcome: String, sourceIP: String?, detail: String? = nil
    ) throws {
        try db.run(
            """
            INSERT INTO audit (username, action, container_name, outcome, source_ip, detail)
            VALUES (?, ?, ?, ?, ?, ?)
            """,
            [
                .text(username), .text(action),
                containerName.map(SQLValue.text) ?? .null,
                .text(outcome),
                sourceIP.map(SQLValue.text) ?? .null,
                detail.map(SQLValue.text) ?? .null,
            ]
        )
    }

    public func listAudit(limit: Int = 500) throws -> [AuditEntry] {
        try db.query("SELECT * FROM audit ORDER BY id DESC LIMIT ?", [.integer(Int64(limit))]).map { row in
            AuditEntry(
                id: row["id"]?.asInt ?? 0,
                timestamp: row["ts"]?.asString ?? "",
                username: row["username"]?.asString ?? "",
                action: row["action"]?.asString ?? "",
                containerName: row["container_name"]?.asString,
                outcome: row["outcome"]?.asString ?? "",
                sourceIP: row["source_ip"]?.asString,
                detail: row["detail"]?.asString
            )
        }
    }

    // MARK: Rate limiting (persisted so a restart isn't a brute-force reset)

    public struct RateLimitRow: Sendable, Equatable {
        public let failures: Int
        public let blockedUntilISO: String?
        public init(failures: Int, blockedUntilISO: String?) {
            self.failures = failures
            self.blockedUntilISO = blockedUntilISO
        }
    }

    public func rateLimit(key: String) throws -> RateLimitRow? {
        try db.query("SELECT failures, blocked_until FROM rate_limits WHERE key = ?", [.text(key)])
            .first
            .map { RateLimitRow(failures: Int($0["failures"]?.asInt ?? 0), blockedUntilISO: $0["blocked_until"]?.asString) }
    }

    public func setRateLimit(key: String, failures: Int, blockedUntilISO: String?) throws {
        try db.run(
            """
            INSERT INTO rate_limits (key, failures, blocked_until) VALUES (?, ?, ?)
            ON CONFLICT(key) DO UPDATE SET failures=excluded.failures, blocked_until=excluded.blocked_until
            """,
            [.text(key), .integer(Int64(failures)), blockedUntilISO.map(SQLValue.text) ?? .null])
    }

    public func clearRateLimit(key: String) throws {
        try db.run("DELETE FROM rate_limits WHERE key = ?", [.text(key)])
    }

    // MARK: Durability / operations (pass-throughs)

    public func checkpoint() throws { try db.checkpoint() }
    public func integrityCheck() throws -> [String] { try db.integrityCheck() }
    public var isHealthy: Bool { db.isHealthy }

    /// Writes a consistent backup copy to `path` (must not exist). Live-safe.
    public func backup(toPath path: String) throws {
        guard !FileManager.default.fileExists(atPath: path) else {
            throw DatabaseError.stepFailed("backup destination already exists: \(path)")
        }
        try db.backup(toPath: path)
    }

    /// Housekeeping: drop rows whose lockout has fully elapsed and which have no
    /// standing failure count worth keeping. Safe to call periodically.
    public func pruneRateLimits(olderThanISO: String) throws {
        try db.run("DELETE FROM rate_limits WHERE blocked_until IS NOT NULL AND blocked_until <= ?", [.text(olderThanISO)])
    }
}
