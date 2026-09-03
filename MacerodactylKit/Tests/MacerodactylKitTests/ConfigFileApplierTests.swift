import Foundation
import Testing

@testable import MacerodactylKit

@Suite struct ConfigFileApplierTests {
    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func propertiesUpsertsExistingAndAppendsNew() {
        let out = ConfigFileApplier.applyProperties(
            "# header\nserver-port=25565\nmotd=hi\n",
            ["server-port": "28080", "enable-rcon": "true"])
        #expect(out.contains("server-port=28080"))
        #expect(out.contains("motd=hi"))  // untouched
        #expect(out.contains("# header"))  // comment preserved
        #expect(out.contains("enable-rcon=true"))  // appended
    }

    @Test func jsonSetsDottedPathAndCoercesTypes() {
        let out = ConfigFileApplier.applyJSON(#"{"settings":{"name":"old"}}"#, ["settings.port": "28080", "settings.name": "new"])
        let parsed = try! JSONSerialization.jsonObject(with: Data(out!.utf8)) as! [String: Any]
        let settings = parsed["settings"] as! [String: Any]
        #expect((settings["port"] as? Int) == 28080)  // numeric string → Int
        #expect((settings["name"] as? String) == "new")
    }

    @Test func fileParserDoesLiteralReplace() {
        let out = ConfigFileApplier.applyFile("bind = 0.0.0.0:PORT\n", ["PORT": "28080"])
        #expect(out == "bind = 0.0.0.0:28080\n")
    }

    @Test func substitutionResolvesServerBuildAndEnvTokens() {
        let subs = ConfigFileApplier.substitutions(environment: [
            "SERVER_PORT": "28080", "SERVER_IP": "0.0.0.0", "SERVER_JARFILE": "paper.jar",
        ])
        #expect(ConfigFileApplier.substitute("{{server.build.default.port}}", subs) == "28080")
        #expect(ConfigFileApplier.substitute("{{SERVER_PORT}}", subs) == "28080")
        #expect(ConfigFileApplier.substitute("{{server.build.env.SERVER_JARFILE}}", subs) == "paper.jar")
        #expect(ConfigFileApplier.substitute("host={{server.build.default.ip}}:{{SERVER_PORT}}", subs) == "host=0.0.0.0:28080")
    }

    @Test func applyEndToEndWritesServerPropertiesPort() throws {
        let dir = try tempDir()
        try Data("server-port=25565\n".utf8).write(to: dir.appending(path: "server.properties"))
        let egg =
            #"{"server.properties":{"parser":"properties","find":{"server-port":"{{server.build.default.port}}","query.port":"{{SERVER_PORT}}"}}}"#
        let subs = ConfigFileApplier.substitutions(environment: ["SERVER_PORT": "28080", "SERVER_IP": "0.0.0.0"])
        let result = ConfigFileApplier.apply(configFilesJSON: egg, into: dir, substitutions: subs)
        #expect(result.applied == ["server.properties"])
        let written = try String(contentsOf: dir.appending(path: "server.properties"), encoding: .utf8)
        #expect(written.contains("server-port=28080"))
        #expect(written.contains("query.port=28080"))
    }

    @Test func createsPropertiesFileWhenMissing() throws {
        let dir = try tempDir()
        let egg = #"{"server.properties":{"parser":"properties","find":{"server-port":"{{SERVER_PORT}}"}}}"#
        let subs = ConfigFileApplier.substitutions(environment: ["SERVER_PORT": "30000"])
        let result = ConfigFileApplier.apply(configFilesJSON: egg, into: dir, substitutions: subs)
        #expect(result.applied == ["server.properties"])
        let written = try String(contentsOf: dir.appending(path: "server.properties"), encoding: .utf8)
        #expect(written.trimmingCharacters(in: .whitespacesAndNewlines) == "server-port=30000")
    }

    @Test func pathEscapeIsRefused() throws {
        let dir = try tempDir()
        let egg = #"{"../evil.txt":{"parser":"file","find":{"x":"y"}}}"#
        let result = ConfigFileApplier.apply(configFilesJSON: egg, into: dir, substitutions: [:])
        #expect(result.applied.isEmpty)
        #expect(result.warnings.contains { $0.contains("escapes") })
        #expect(!FileManager.default.fileExists(atPath: dir.appending(path: "../evil.txt").path))
    }

    @Test func emptyOrGarbageConfigIsNoOp() {
        #expect(ConfigFileApplier.apply(configFilesJSON: "", into: URL(fileURLWithPath: "/tmp"), substitutions: [:]).applied.isEmpty)
        #expect(ConfigFileApplier.apply(configFilesJSON: "{}", into: URL(fileURLWithPath: "/tmp"), substitutions: [:]).applied.isEmpty)
    }
}
