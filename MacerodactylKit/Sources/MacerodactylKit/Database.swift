import Foundation

// The SQLite C API. macOS ships an `SQLite3` module in its SDK; Linux has no
// such module, so a small system-library target (`CSQLite`) maps <sqlite3.h>
// there. Same symbols either way.
#if canImport(SQLite3)
import SQLite3
#else
import CSQLite
#endif

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
    public static let currentVersion = 7

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
        if db.userVersion < 4 {
            // Retained resource metrics — a bounded time series per container for
            // history beyond the live stream. Pruned by age + a per-container row
            // cap so it can never fill the disk.
            try db.execute(
                """
                CREATE TABLE IF NOT EXISTS metrics (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    container TEXT NOT NULL,
                    measured_at TEXT NOT NULL,
                    cpu_percent REAL NOT NULL,
                    mem_used_bytes REAL NOT NULL,
                    mem_limit_bytes REAL NOT NULL,
                    net_rx_bytes REAL NOT NULL,
                    net_tx_bytes REAL NOT NULL,
                    pids INTEGER NOT NULL
                );
                CREATE INDEX IF NOT EXISTS idx_metrics_container_time ON metrics(container, measured_at);
                """)
            db.userVersion = 4
        }
        if db.userVersion < 5 {
            // Sixth permission: destructive per-container lifecycle (pull /
            // recreate / remove). Existing grants default to no lifecycle access.
            try db.execute("ALTER TABLE grants ADD COLUMN perm_lifecycle INTEGER NOT NULL DEFAULT 0")
            db.userVersion = 5
        }
        if db.userVersion < 6 {
            // Optional TOTP 2FA per account, and richer session rows so a user can
            // see and revoke their active sessions (where/when signed in).
            try db.execute(
                """
                ALTER TABLE users ADD COLUMN totp_secret TEXT;
                ALTER TABLE users ADD COLUMN totp_enabled INTEGER NOT NULL DEFAULT 0;
                ALTER TABLE sessions ADD COLUMN created_ip TEXT;
                ALTER TABLE sessions ADD COLUMN user_agent TEXT;
                ALTER TABLE sessions ADD COLUMN last_seen TEXT;
                """)
            db.userVersion = 6
        }
        if db.userVersion < 7 {
            // The last TOTP time-step a successful login consumed, so a captured
            // code can't be replayed within its ~30-90s validity window.
            try db.execute("ALTER TABLE users ADD COLUMN totp_last_step INTEGER NOT NULL DEFAULT 0")
            db.userVersion = 7
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
                INSERT INTO grants
                    (user_id, container_name, perm_view, perm_power, perm_files, perm_console, perm_schedules, perm_lifecycle)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(user_id, container_name) DO UPDATE SET
                    perm_view=excluded.perm_view, perm_power=excluded.perm_power,
                    perm_files=excluded.perm_files, perm_console=excluded.perm_console,
                    perm_schedules=excluded.perm_schedules, perm_lifecycle=excluded.perm_lifecycle
                """,
                [
                    .integer(userID), .text(containerName),
                    .integer(grant.view ? 1 : 0), .integer(grant.power ? 1 : 0),
                    .integer(grant.files ? 1 : 0), .integer(grant.console ? 1 : 0),
                    .integer(grant.schedules ? 1 : 0), .integer(grant.lifecycle ? 1 : 0),
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
                schedules: (row["perm_schedules"]?.asInt ?? 0) != 0,
                lifecycle: (row["perm_lifecycle"]?.asInt ?? 0) != 0
            )
        }
        return result
    }

    /// Builds the per-request authorization engine for a user.
    public func authorizationEngine(for user: PanelUser) throws -> AuthorizationEngine {
        AuthorizationEngine(isAdmin: user.isAdmin, grants: user.isAdmin ? [:] : (try grants(forUserID: user.id)))
    }

    // MARK: Sessions (tokens are stored hashed; the raw token lives only in the cookie)

    public func insertSession(
        tokenHash: String, userID: Int64, expiresAt: String, ip: String? = nil, userAgent: String? = nil
    ) throws {
        try db.run(
            "INSERT INTO sessions (token_hash, user_id, expires_at, created_ip, user_agent, last_seen) VALUES (?, ?, ?, ?, ?, ?)",
            [
                .text(tokenHash), .integer(userID), .text(expiresAt),
                ip.map(SQLValue.text) ?? .null, userAgent.map(SQLValue.text) ?? .null,
                ip == nil ? .null : .text(expiresAt),
            ]
        )
    }

    public struct SessionInfo: Sendable, Equatable {
        public let tokenHash: String
        public let createdAt: String
        public let lastSeen: String?
        public let ip: String?
        public let userAgent: String?
    }

    /// A user's active (unexpired) sessions, newest first.
    public func listSessions(userID: Int64, now: String) throws -> [SessionInfo] {
        try db.query(
            """
            SELECT token_hash, created_at, last_seen, created_ip, user_agent FROM sessions
            WHERE user_id = ? AND expires_at > ? ORDER BY created_at DESC
            """, [.integer(userID), .text(now)]
        ).map {
            SessionInfo(
                tokenHash: $0["token_hash"]?.asString ?? "", createdAt: $0["created_at"]?.asString ?? "",
                lastSeen: $0["last_seen"]?.asString, ip: $0["created_ip"]?.asString, userAgent: $0["user_agent"]?.asString)
        }
    }

    /// Updates a session's last-seen timestamp (best-effort, called on use).
    public func touchSession(tokenHash: String, at: String) throws {
        try db.run("UPDATE sessions SET last_seen = ? WHERE token_hash = ?", [.text(at), .text(tokenHash)])
    }

    /// Deletes a session ONLY if it belongs to `userID` — a user can revoke their
    /// own sessions, never someone else's. Returns whether a row was removed.
    @discardableResult
    public func deleteSession(userID: Int64, tokenHash: String) throws -> Bool {
        let existed =
            try db.query(
                "SELECT 1 AS x FROM sessions WHERE token_hash = ? AND user_id = ?",
                [.text(tokenHash), .integer(userID)]
            ).first != nil
        if existed {
            try db.run("DELETE FROM sessions WHERE token_hash = ? AND user_id = ?", [.text(tokenHash), .integer(userID)])
        }
        return existed
    }

    /// Revokes all of a user's sessions except the one given (sign out everywhere else).
    public func deleteOtherSessions(userID: Int64, keepTokenHash: String) throws {
        try db.run(
            "DELETE FROM sessions WHERE user_id = ? AND token_hash <> ?", [.integer(userID), .text(keepTokenHash)])
    }

    // MARK: TOTP 2FA

    /// (secret, enabled) for a user. A non-nil secret with enabled=false is a
    /// pending enrollment (secret generated, not yet confirmed by a valid code).
    public func totpState(userID: Int64) throws -> (secret: String?, enabled: Bool) {
        guard let row = try db.query("SELECT totp_secret, totp_enabled FROM users WHERE id = ?", [.integer(userID)]).first
        else { return (nil, false) }
        return (row["totp_secret"]?.asString, (row["totp_enabled"]?.asInt ?? 0) != 0)
    }

    public func setTOTPSecret(userID: Int64, secret: String?) throws {
        try db.run(
            "UPDATE users SET totp_secret = ? WHERE id = ?", [secret.map(SQLValue.text) ?? .null, .integer(userID)])
    }

    public func setTOTPEnabled(userID: Int64, enabled: Bool) throws {
        try db.run("UPDATE users SET totp_enabled = ? WHERE id = ?", [.integer(enabled ? 1 : 0), .integer(userID)])
    }

    /// The last consumed TOTP step (anti-replay); 0 if never used.
    public func totpLastStep(userID: Int64) throws -> Int64 {
        try db.query("SELECT totp_last_step FROM users WHERE id = ?", [.integer(userID)]).first?["totp_last_step"]?.asInt ?? 0
    }

    public func setTOTPLastStep(userID: Int64, step: Int64) throws {
        try db.run("UPDATE users SET totp_last_step = ? WHERE id = ?", [.integer(step), .integer(userID)])
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

    // MARK: Retained metrics (bounded time series)

    // Formatter is only read (its options are set once), so unsafe-nonisolated is
    // sound — matching the pattern used elsewhere in this file.
    nonisolated(unsafe) private static let metricsISO: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Appends one measured sample for a container.
    public func recordMetric(_ sample: ContainerStats) throws {
        try db.run(
            """
            INSERT INTO metrics
                (container, measured_at, cpu_percent, mem_used_bytes, mem_limit_bytes, net_rx_bytes, net_tx_bytes, pids)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [
                .text(sample.name), .text(Self.metricsISO.string(from: sample.measuredAt)),
                .real(sample.cpuPercent), .real(sample.memUsedBytes), .real(sample.memLimitBytes),
                .real(sample.netRxBytes), .real(sample.netTxBytes), .integer(Int64(sample.pids)),
            ])
    }

    /// Recent samples for a container, oldest→newest, optionally only those on or
    /// after `since`. `limit` caps how many are returned (newest kept).
    public func metrics(container: String, since: Date? = nil, limit: Int = 5_000) throws -> [ContainerStats] {
        var sql = "SELECT * FROM metrics WHERE container = ?"
        var bindings: [SQLValue] = [.text(container)]
        if let since {
            sql += " AND measured_at >= ?"
            bindings.append(.text(Self.metricsISO.string(from: since)))
        }
        sql += " ORDER BY measured_at DESC LIMIT ?"
        bindings.append(.integer(Int64(max(1, limit))))
        let rows = try db.query(sql, bindings)
        return rows.reversed().map { row in
            ContainerStats(
                name: row["container"]?.asString ?? container,
                cpuPercent: row["cpu_percent"]?.asDouble ?? 0,
                memUsedBytes: row["mem_used_bytes"]?.asDouble ?? 0,
                memLimitBytes: row["mem_limit_bytes"]?.asDouble ?? 0,
                memPercent: {
                    let limit = row["mem_limit_bytes"]?.asDouble ?? 0
                    let used = row["mem_used_bytes"]?.asDouble ?? 0
                    return limit > 0 ? used / limit * 100 : 0
                }(),
                netRxBytes: row["net_rx_bytes"]?.asDouble ?? 0,
                netTxBytes: row["net_tx_bytes"]?.asDouble ?? 0,
                pids: Int(row["pids"]?.asInt ?? 0),
                measuredAt: (row["measured_at"]?.asString).flatMap { Self.metricsISO.date(from: $0) } ?? Date())
        }
    }

    /// Enforces the retention policy: drop samples older than `maxAge`, then cap
    /// each container to its newest `maxPerContainer` rows. Both bound disk use.
    public func pruneMetrics(maxAge: TimeInterval, maxPerContainer: Int) throws {
        let cutoff = Self.metricsISO.string(from: Date().addingTimeInterval(-maxAge))
        try db.run("DELETE FROM metrics WHERE measured_at < ?", [.text(cutoff)])
        // Row cap per container: keep the newest N by id.
        try db.run(
            """
            DELETE FROM metrics WHERE id IN (
                SELECT id FROM (
                    SELECT id, ROW_NUMBER() OVER (PARTITION BY container ORDER BY id DESC) AS rn FROM metrics
                ) WHERE rn > ?
            )
            """,
            [.integer(Int64(max(1, maxPerContainer)))])
    }

    /// Total retained sample count (for tests / housekeeping visibility).
    public func metricsCount() throws -> Int {
        Int(try db.query("SELECT COUNT(*) AS c FROM metrics", []).first?["c"]?.asInt ?? 0)
    }
}
