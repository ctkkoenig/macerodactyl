import Foundation
import Testing

@testable import MacerodactylKit

@Suite struct SchemaMigrationTests {
    private func tempDBPath() throws -> String {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: "m.sqlite").path
    }

    @Test func freshDatabaseIsAtCurrentVersionWithSchedules() throws {
        let store = try PanelDataStore(databasePath: tempDBPath())
        let user = try store.createUser(username: "a", passwordHash: "h", isAdmin: false)
        // The new permission round-trips through the DB.
        try store.setGrant(
            userID: user.id, containerName: "bot",
            grant: ContainerGrant(view: true, schedules: true))
        let grants = try store.grants(forUserID: user.id)
        #expect(grants["bot"]?.schedules == true)
    }

    @Test func updatingAnExistingGrantWritesSchedules() throws {
        // The ON CONFLICT DO UPDATE path (existing row), not just INSERT.
        let store = try PanelDataStore(databasePath: tempDBPath())
        let user = try store.createUser(username: "a", passwordHash: "h", isAdmin: false)
        try store.setGrant(
            userID: user.id, containerName: "bot",
            grant: ContainerGrant(view: true, power: true))  // schedules off
        #expect(try store.grants(forUserID: user.id)["bot"]?.schedules == false)
        // Update the same row to add schedules.
        try store.setGrant(
            userID: user.id, containerName: "bot",
            grant: ContainerGrant(view: true, power: true, schedules: true))
        #expect(try store.grants(forUserID: user.id)["bot"]?.schedules == true)
        // And turning it back off updates too.
        try store.setGrant(
            userID: user.id, containerName: "bot",
            grant: ContainerGrant(view: true, power: true, schedules: false))
        #expect(try store.grants(forUserID: user.id)["bot"]?.schedules == false)
    }

    @Test func v1DatabaseMigratesToV2PreservingGrants() throws {
        let path = try tempDBPath()
        // Build a v1 database by hand (no perm_schedules column).
        do {
            let db = try Database(path: path)
            try db.execute(
                """
                CREATE TABLE users (id INTEGER PRIMARY KEY AUTOINCREMENT, username TEXT NOT NULL UNIQUE,
                    password_hash TEXT NOT NULL, is_admin INTEGER NOT NULL DEFAULT 0,
                    created_at TEXT NOT NULL DEFAULT '');
                CREATE TABLE grants (user_id INTEGER NOT NULL, container_name TEXT NOT NULL,
                    perm_view INTEGER NOT NULL DEFAULT 0, perm_power INTEGER NOT NULL DEFAULT 0,
                    perm_files INTEGER NOT NULL DEFAULT 0, perm_console INTEGER NOT NULL DEFAULT 0,
                    PRIMARY KEY (user_id, container_name));
                CREATE TABLE sessions (token_hash TEXT PRIMARY KEY, user_id INTEGER NOT NULL, created_at TEXT, expires_at TEXT NOT NULL);
                CREATE TABLE audit (id INTEGER PRIMARY KEY AUTOINCREMENT, ts TEXT, username TEXT NOT NULL,
                    action TEXT NOT NULL, container_name TEXT, outcome TEXT NOT NULL, source_ip TEXT, detail TEXT);
                """)
            try db.run("INSERT INTO users (id, username, password_hash, is_admin) VALUES (1, 'legacy', 'h', 0)")
            try db.run("INSERT INTO grants (user_id, container_name, perm_view, perm_power) VALUES (1, 'bot', 1, 1)")
            db.userVersion = 1
        }

        // Opening through PanelDataStore runs the migration.
        let store = try PanelDataStore(databasePath: path)
        let grants = try store.grants(forUserID: 1)
        // Old grant survived, and the new permission defaulted to false.
        #expect(grants["bot"]?.view == true)
        #expect(grants["bot"]?.power == true)
        #expect(grants["bot"]?.schedules == false)

        // And the new column is writable now.
        try store.setGrant(
            userID: 1, containerName: "bot",
            grant: ContainerGrant(view: true, schedules: true))
        #expect(try store.grants(forUserID: 1)["bot"]?.schedules == true)
    }
}

@Suite struct SchedulesAuthorizationTests {
    @Test func schedulesPermissionIsIndependentAndRequiresView() {
        let engine = AuthorizationEngine(
            isAdmin: false,
            grants: [
                "bot": ContainerGrant(view: true, schedules: true),
                "other": ContainerGrant(view: false, schedules: true),  // malformed: no view
            ])
        #expect(engine.can(.schedules, containerNamed: "bot"))
        #expect(!engine.can(.power, containerNamed: "bot"))  // independent
        #expect(!engine.can(.schedules, containerNamed: "other"))  // needs view
        #expect(ContainerPermission.allCases.contains(.schedules))
    }
}

@Suite struct RateLimitSchemaTests {
    @Test func migrationAddsRateLimitsTableAndItPersists() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appending(path: "rl.sqlite").path

        let store = try PanelDataStore(databasePath: path)
        let empty = try store.rateLimit(key: "acct:x")
        #expect(empty == nil)
        try store.setRateLimit(key: "acct:x", failures: 3, blockedUntilISO: "2999-01-01T00:00:00.000Z")

        // Reopen (fresh connection): the row is still there.
        let reopened = try PanelDataStore(databasePath: path)
        let row = try #require(try reopened.rateLimit(key: "acct:x"))
        #expect(row.failures == 3)
        #expect(row.blockedUntilISO == "2999-01-01T00:00:00.000Z")

        try reopened.clearRateLimit(key: "acct:x")
        let cleared = try reopened.rateLimit(key: "acct:x")
        #expect(cleared == nil)
    }

    @Test func migrationAddsMetricsTableAndItPersists() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appending(path: "m.sqlite").path

        let store = try PanelDataStore(databasePath: path)
        try store.recordMetric(
            ContainerStats(
                name: "bot", cpuPercent: 3, memUsedBytes: 1, memLimitBytes: 2, memPercent: 50,
                netRxBytes: 0, netTxBytes: 0, pids: 1, measuredAt: Date()))
        // Reopen (fresh connection): the sample survives.
        let reopened = try PanelDataStore(databasePath: path)
        #expect(try reopened.metrics(container: "bot").count == 1)
    }

    @Test func lifecyclePermissionPersistsAcrossReopen() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appending(path: "g.sqlite").path
        do {
            let store = try PanelDataStore(databasePath: path)
            let user = try store.createUser(username: "a", passwordHash: "h", isAdmin: false)
            try store.setGrant(userID: user.id, containerName: "bot", grant: ContainerGrant(view: true, lifecycle: true))
        }
        let reopened = try PanelDataStore(databasePath: path)
        let user = try #require(try reopened.user(named: "a"))
        #expect(try reopened.grants(forUserID: user.id)["bot"]?.lifecycle == true)
    }

    @Test func currentVersionMatchesLatestMigration() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = try PanelDataStore(databasePath: dir.appending(path: "v.sqlite").path)
        // A fresh DB should be exactly at the schema's declared current version,
        // and recording a metric proves the v4 table is present.
        try store.recordMetric(
            ContainerStats(
                name: "x", cpuPercent: 0, memUsedBytes: 0, memLimitBytes: 0, memPercent: 0,
                netRxBytes: 0, netTxBytes: 0, pids: 0, measuredAt: Date()))
        #expect(PanelSchema.currentVersion == 9)
    }

    @Test func migratesToV9AddingBackupsPermissionAndTable() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = try PanelDataStore(databasePath: dir.appending(path: "v9.sqlite").path)
        let user = try store.createUser(username: "a", passwordHash: "h", isAdmin: false)
        // The 7th permission round-trips.
        try store.setGrant(userID: user.id, containerName: "bot", grant: ContainerGrant(view: true, backups: true))
        #expect(try store.grants(forUserID: user.id)["bot"]?.backups == true)
        // The backups table is present + writable.
        #expect(try store.listBackups(containerName: "bot").isEmpty)
    }

    @Test func migratesV7ToV8SeedingTheSelfNodeAndProvisioningTables() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appending(path: "v8.sqlite").path
        // A minimal pre-v8 database (just enough of the v1 base + user_version=7).
        do {
            let db = try Database(path: path)
            try db.execute(
                """
                CREATE TABLE users (id INTEGER PRIMARY KEY AUTOINCREMENT, username TEXT NOT NULL UNIQUE,
                    password_hash TEXT NOT NULL, is_admin INTEGER NOT NULL DEFAULT 0, created_at TEXT);
                CREATE TABLE grants (user_id INTEGER NOT NULL, container_name TEXT NOT NULL,
                    perm_view INTEGER NOT NULL DEFAULT 0, perm_power INTEGER NOT NULL DEFAULT 0,
                    perm_files INTEGER NOT NULL DEFAULT 0, perm_console INTEGER NOT NULL DEFAULT 0,
                    perm_schedules INTEGER NOT NULL DEFAULT 0, perm_lifecycle INTEGER NOT NULL DEFAULT 0,
                    PRIMARY KEY (user_id, container_name));
                """)
            db.userVersion = 7
        }
        // Opening runs the v8 migration.
        let store = try PanelDataStore(databasePath: path)
        // The single self-node row is seeded with defaults.
        let node = try store.nodeConfig()
        #expect(node.hostIP == "127.0.0.1")
        #expect(node.portRangeStart == 25565)
        #expect(node.portRangeEnd == 25700)
        // The new tables exist and are writable.
        let nest = try store.createNest(name: "Minecraft", author: nil, description: nil)
        #expect(try store.listNests().count == 1)
        #expect(nest > 0)
        // Global settings default cleanly with no rows.
        #expect(try store.globalSettings().require2FA == .off)
    }
}
