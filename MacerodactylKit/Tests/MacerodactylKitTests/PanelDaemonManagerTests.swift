import Foundation
import Testing

@testable import MacerodactylKit

@Suite struct PanelDaemonManagerTests {
    private func makeManager() throws -> (PanelDaemonManager, cleanup: () -> Void) {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appending(path: "daemon-\(UUID().uuidString)")
        let agents = base.appending(path: "LaunchAgents")
        let logs = base.appending(path: "logs")
        try fm.createDirectory(at: agents, withIntermediateDirectories: true)
        try fm.createDirectory(at: logs, withIntermediateDirectories: true)
        let manager = PanelDaemonManager(launchAgentsDirectory: agents, logsDirectory: logs, managesLaunchd: false)
        return (manager, { try? fm.removeItem(at: base) })
    }

    /// A throwaway executable file to satisfy install()'s executability check.
    private func makeExecutable() throws -> (URL, cleanup: () -> Void) {
        let fm = FileManager.default
        let url = fm.temporaryDirectory.appending(path: "macerodactyld-\(UUID().uuidString)")
        try Data("#!/bin/sh\n".utf8).write(to: url)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return (url, { try? fm.removeItem(at: url) })
    }

    @Test func plistIsSupervisedAndServerOnly() throws {
        let (manager, cleanup) = try makeManager()
        defer { cleanup() }
        let dict = manager.plistDictionary(daemonBinaryPath: "/opt/mac/macerodactyld")
        #expect(dict["Label"] as? String == "com.macerodactyl.panel")
        #expect(dict["ProgramArguments"] as? [String] == ["/opt/mac/macerodactyld"])
        // Supervised: restarts on crash, starts when loaded.
        #expect(dict["KeepAlive"] as? Bool == true)
        #expect(dict["RunAtLoad"] as? Bool == true)
        // Server-only: the ONLY program argument is the daemon — never a docker
        // command, so loading the panel never starts a container.
        let args = dict["ProgramArguments"] as? [String] ?? []
        #expect(!args.contains { $0.contains("docker") || $0.contains("restart") || $0.contains("start") })
        #expect((dict["StandardErrorPath"] as? String)?.hasSuffix("panel.err.log") == true)
    }

    @Test func plistXMLIsValidPropertyList() throws {
        let (manager, cleanup) = try makeManager()
        defer { cleanup() }
        let xml = try manager.plistXML(daemonBinaryPath: "/opt/mac/macerodactyld")
        #expect(xml.contains("<?xml"))
        let reparsed =
            try PropertyListSerialization.propertyList(
                from: Data(xml.utf8), format: nil) as? [String: Any]
        #expect(reparsed?["Label"] as? String == "com.macerodactyl.panel")
    }

    @Test func installWritesPlistAndUninstallRemovesIt() throws {
        let (manager, cleanupM) = try makeManager()
        defer { cleanupM() }
        let (binary, cleanupB) = try makeExecutable()
        defer { cleanupB() }

        #expect(!manager.isInstalled)
        try manager.install(daemonBinaryPath: binary.path)
        #expect(manager.isInstalled)
        #expect(manager.installedBinaryPath() == binary.path)

        try manager.uninstall()
        #expect(!manager.isInstalled)
    }

    @Test func installRejectsNonExecutableBinary() throws {
        let (manager, cleanup) = try makeManager()
        defer { cleanup() }
        #expect(throws: DaemonError.binaryNotExecutable("/does/not/exist")) {
            try manager.install(daemonBinaryPath: "/does/not/exist")
        }
        #expect(!manager.isInstalled)
    }
}
