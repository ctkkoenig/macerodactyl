import Foundation
import Testing

@testable import MacerodactylKit

@Suite struct DatabaseProvisioningTests {
    @Test func sanitizeStripsToTheAllowList() {
        #expect(DatabaseProvisioning.sanitize("MyStats", maxLength: 48) == "mystats")
        #expect(DatabaseProvisioning.sanitize("game-data 2!", maxLength: 48) == "gamedata2")
        // Must start with a letter/underscore.
        #expect(DatabaseProvisioning.sanitize("123", maxLength: 48) == nil)
        #expect(DatabaseProvisioning.sanitize("!!!", maxLength: 48) == nil)
        #expect(DatabaseProvisioning.sanitize("", maxLength: 48) == nil)
        // Length cap.
        #expect(DatabaseProvisioning.sanitize(String(repeating: "a", count: 100), maxLength: 10)?.count == 10)
    }

    @Test func injectionAttemptsAreNeutralized() {
        // A classic injection payload sanitizes down to safe letters only.
        let evil = "db`; DROP DATABASE important; --"
        let clean = DatabaseProvisioning.sanitize(evil, maxLength: 48)
        #expect(clean == "dbdropdatabaseimportant")  // back-tick/;/space/- all gone
        #expect(DatabaseProvisioning.isSafeIdentifier(clean!))

        // The SQL builder refuses anything not on the allow-list, belt-and-suspenders.
        #expect(DatabaseProvisioning.createSQL(database: "ok`bad", username: "u", password: "p") == nil)
        #expect(DatabaseProvisioning.createSQL(database: "db", username: "u'x", password: "p") == nil)
        #expect(DatabaseProvisioning.createSQL(database: "db", username: "u", password: "pa'ss") == nil)
        #expect(DatabaseProvisioning.dropSQL(database: "db;drop", username: "u") == nil)
    }

    @Test func generatedNamesAreScopedAndSafe() {
        let db = try! #require(DatabaseProvisioning.databaseName(serverID: 7, base: "Stats"))
        #expect(db == "s7_stats")
        let user = try! #require(DatabaseProvisioning.username(serverID: 7, base: "Stats"))
        #expect(user == "u7_stats")
        #expect(user.count <= 32)
        // Two servers don't collide on the same base name.
        #expect(DatabaseProvisioning.databaseName(serverID: 8, base: "Stats") == "s8_stats")
    }

    @Test func generatedPasswordIsInjectionSafe() {
        for _ in 0..<50 {
            let p = DatabaseProvisioning.generatePassword()
            #expect(p.count == 24)
            #expect(p.allSatisfy { $0.isLetter || $0.isNumber })  // no quote/backtick/backslash
        }
    }

    @Test func createAndDropSQLAreWellFormed() {
        let create = try! #require(
            DatabaseProvisioning.createSQL(database: "s1_app", username: "u1_app", password: "abc123XYZ"))
        #expect(create.contains("CREATE DATABASE IF NOT EXISTS `s1_app`;"))
        #expect(create.contains("CREATE USER IF NOT EXISTS 'u1_app'@'%' IDENTIFIED BY 'abc123XYZ';"))
        #expect(create.contains("GRANT ALL PRIVILEGES ON `s1_app`.* TO 'u1_app'@'%';"))
        #expect(create.contains("FLUSH PRIVILEGES;"))

        let drop = try! #require(DatabaseProvisioning.dropSQL(database: "s1_app", username: "u1_app"))
        #expect(drop.contains("DROP DATABASE IF EXISTS `s1_app`;"))
        #expect(drop.contains("DROP USER IF EXISTS 'u1_app'@'%';"))
    }
}
