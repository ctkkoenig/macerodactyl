import Foundation
import Testing

@testable import MacerodactylKit

@Suite struct DatabaseDurabilityTests {
    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func integrityCheckAndCheckpoint() throws {
        let db = try PanelDataStore(databasePath: (try tempDir()).appending(path: "d.sqlite").path)
        _ = try db.createUser(username: "a", passwordHash: "h", isAdmin: false)
        #expect(try db.integrityCheck() == ["ok"])
        #expect(db.isHealthy)
        try db.checkpoint()  // must not throw
        #expect(db.isHealthy)
    }

    @Test func backupIsConsistentAndRestorable() throws {
        let dir = try tempDir()
        let dbPath = dir.appending(path: "live.sqlite").path
        let backupPath = dir.appending(path: "backup.sqlite").path

        // Seed the live DB.
        do {
            let store = try PanelDataStore(databasePath: dbPath)
            let user = try store.createUser(username: "keeper", passwordHash: "h", isAdmin: true)
            try store.setGrant(userID: user.id, containerName: "bot", grant: ContainerGrant(view: true, power: true))
            try store.recordAudit(username: "keeper", action: "x", containerName: nil, outcome: "ok", sourceIP: nil)
            try store.backup(toPath: backupPath)
        }
        #expect(FileManager.default.fileExists(atPath: backupPath))

        // The backup opens and is healthy, with the data.
        let backup = try PanelDataStore(databasePath: backupPath)
        #expect(backup.isHealthy)
        #expect(try backup.user(named: "keeper")?.isAdmin == true)
        #expect(try backup.grants(forUserID: 1)["bot"]?.power == true)
    }

    @Test func backupRefusesExistingDestination() throws {
        let dir = try tempDir()
        let store = try PanelDataStore(databasePath: dir.appending(path: "live.sqlite").path)
        let dest = dir.appending(path: "exists.sqlite").path
        try Data("x".utf8).write(to: URL(fileURLWithPath: dest))
        #expect(throws: (any Error).self) { try store.backup(toPath: dest) }
    }

    @Test func restoreInstallsValidatedBackupAndSidelinesCurrent() throws {
        let dir = try tempDir()
        let dbPath = dir.appending(path: "live.sqlite").path
        let backupPath = dir.appending(path: "good.sqlite").path

        // Make a backup that has "alice".
        do {
            let store = try PanelDataStore(databasePath: dbPath)
            _ = try store.createUser(username: "alice", passwordHash: "h", isAdmin: false)
            try store.backup(toPath: backupPath)
            // Then mutate live so it differs from the backup.
            _ = try store.createUser(username: "bob", passwordHash: "h", isAdmin: false)
        }

        // Restore (panel is "stopped" — no open store here).
        let sidelined = try PanelBackup.restore(from: backupPath, to: dbPath)
        #expect(FileManager.default.fileExists(atPath: sidelined))  // old DB kept

        let restored = try PanelDataStore(databasePath: dbPath)
        #expect(try restored.user(named: "alice") != nil)
        #expect(try restored.user(named: "bob") == nil)  // bob was after the backup
    }

    @Test func restoreRejectsCorruptBackup() throws {
        let dir = try tempDir()
        let dbPath = dir.appending(path: "live.sqlite").path
        _ = try PanelDataStore(databasePath: dbPath)
        let junk = dir.appending(path: "corrupt.sqlite").path
        try Data("not a sqlite database".utf8).write(to: URL(fileURLWithPath: junk))
        #expect(throws: (any Error).self) { try PanelBackup.restore(from: junk, to: dbPath) }
    }

    /// Security review #1: a missing backup path must NOT open-create an empty DB
    /// and wipe the live one. Restore must throw AND leave the live DB intact.
    @Test func restoreFromMissingPathThrowsAndPreservesLiveData() throws {
        let dir = try tempDir()
        let dbPath = dir.appending(path: "live.sqlite").path
        do {
            let store = try PanelDataStore(databasePath: dbPath)
            _ = try store.createUser(username: "keeper", passwordHash: "h", isAdmin: true)
        }
        let missing = dir.appending(path: "does-not-exist.sqlite").path
        #expect(throws: (any Error).self) { try PanelBackup.restore(from: missing, to: dbPath) }
        // The live database and its data must be untouched.
        let after = try PanelDataStore(databasePath: dbPath)
        #expect(try after.user(named: "keeper")?.isAdmin == true)
        // No empty DB was created at the (missing) backup path.
        #expect(!FileManager.default.fileExists(atPath: missing))
    }

    /// Security review #1 (related): a structurally-valid but non-panel SQLite
    /// file (no schema version) must be rejected, not installed over live data.
    @Test func restoreRejectsForeignSQLiteWithoutSchema() throws {
        let dir = try tempDir()
        let dbPath = dir.appending(path: "live.sqlite").path
        do {
            let store = try PanelDataStore(databasePath: dbPath)
            _ = try store.createUser(username: "keeper", passwordHash: "h", isAdmin: true)
        }
        // A valid SQLite file with user_version 0 and none of our tables.
        let foreign = dir.appending(path: "foreign.sqlite").path
        let other = try Database(path: foreign)
        try other.execute("CREATE TABLE unrelated (x INTEGER)")
        #expect(other.userVersion == 0)
        #expect(throws: (any Error).self) { try PanelBackup.restore(from: foreign, to: dbPath) }
        let after = try PanelDataStore(databasePath: dbPath)
        #expect(try after.user(named: "keeper") != nil)
    }
}
