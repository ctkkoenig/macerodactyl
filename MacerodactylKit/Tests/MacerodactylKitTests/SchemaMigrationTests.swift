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
        try store.setGrant(userID: user.id, containerName: "bot",
                          grant: ContainerGrant(view: true, schedules: true))
        let grants = try store.grants(forUserID: user.id)
        #expect(grants["bot"]?.schedules == true)
    }

    @Test func updatingAnExistingGrantWritesSchedules() throws {
        // The ON CONFLICT DO UPDATE path (existing row), not just INSERT.
        let store = try PanelDataStore(databasePath: tempDBPath())
        let user = try store.createUser(username: "a", passwordHash: "h", isAdmin: false)
        try store.setGrant(userID: user.id, containerName: "bot",
                          grant: ContainerGrant(view: true, power: true)) // schedules off
        #expect(try store.grants(forUserID: user.id)["bot"]?.schedules == false)
        // Update the same row to add schedules.
        try store.setGrant(userID: user.id, containerName: "bot",
                          grant: ContainerGrant(view: true, power: true, schedules: true))
        #expect(try store.grants(forUserID: user.id)["bot"]?.schedules == true)
        // And turning it back off updates too.
        try store.setGrant(userID: user.id, containerName: "bot",
                          grant: ContainerGrant(view: true, power: true, schedules: false))
        #expect(try store.grants(forUserID: user.id)["bot"]?.schedules == false)
    }

    @Test func v1DatabaseMigratesToV2PreservingGrants() throws {
        let path = try tempDBPath()
        // Build a v1 database by hand (no perm_schedules column).
        do {
            let db = try Database(path: path)
            try db.execute("""
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
        try store.setGrant(userID: 1, containerName: "bot",
                          grant: ContainerGrant(view: true, schedules: true))
        #expect(try store.grants(forUserID: 1)["bot"]?.schedules == true)
    }
}

@Suite struct SchedulesAuthorizationTests {
    @Test func schedulesPermissionIsIndependentAndRequiresView() {
        let engine = AuthorizationEngine(isAdmin: false, grants: [
            "bot": ContainerGrant(view: true, schedules: true),
            "other": ContainerGrant(view: false, schedules: true), // malformed: no view
        ])
        #expect(engine.can(.schedules, containerNamed: "bot"))
        #expect(!engine.can(.power, containerNamed: "bot"))       // independent
        #expect(!engine.can(.schedules, containerNamed: "other")) // needs view
        #expect(ContainerPermission.allCases.contains(.schedules))
    }
}
