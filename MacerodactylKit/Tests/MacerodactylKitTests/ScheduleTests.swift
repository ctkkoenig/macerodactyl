import Foundation
import Testing
@testable import MacerodactylKit

@Suite struct ScheduleTests {
    private func makeService(managesLaunchd: Bool = false) throws -> (ScheduleService, cleanup: () -> Void) {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appending(path: "sched-\(UUID().uuidString)")
        let agents = base.appending(path: "LaunchAgents")
        let logs = base.appending(path: "logs")
        try fm.createDirectory(at: agents, withIntermediateDirectories: true)
        try fm.createDirectory(at: logs, withIntermediateDirectories: true)
        let service = ScheduleService(
            dockerPath: "/fake/resolved/bin/docker",
            launchAgentsDirectory: agents, logsDirectory: logs, managesLaunchd: managesLaunchd
        )
        return (service, { try? fm.removeItem(at: base) })
    }

    @Test func plistUsesAbsoluteDockerPathAndRawArgv() throws {
        let (service, cleanup) = try makeService()
        defer { cleanup() }
        let dict = service.plistDictionary(for: RestartSchedule(containerName: "fixture-mc", hour: 4, minute: 30))

        // launchd inherits no shell PATH: the argv must carry the fully
        // resolved binary, and there is no shell anywhere in it.
        let args = dict["ProgramArguments"] as? [String]
        #expect(args == ["/fake/resolved/bin/docker", "restart", "fixture-mc"])
        #expect(dict["Label"] as? String == "com.macerodactyl.restart.fixture-mc")
        // Restart-only, never a boot starter: no RunAtLoad at all.
        #expect(dict["RunAtLoad"] == nil)
        // Failure surfacing: both streams land in files the app reads.
        #expect((dict["StandardOutPath"] as? String)?.hasSuffix("com.macerodactyl.restart.fixture-mc.out.log") == true)
        #expect((dict["StandardErrorPath"] as? String)?.hasSuffix("com.macerodactyl.restart.fixture-mc.err.log") == true)
        let interval = dict["StartCalendarInterval"] as? [String: Int]
        #expect(interval == ["Hour": 4, "Minute": 30])
    }

    @Test func weekdaySchedulesBecomeIntervalArrays() throws {
        let (service, cleanup) = try makeService()
        defer { cleanup() }
        let schedule = RestartSchedule(containerName: "bot", hour: 6, minute: 0, weekdays: [1, 5])
        let intervals = service.plistDictionary(for: schedule)["StartCalendarInterval"] as? [[String: Int]]
        #expect(intervals == [
            ["Weekday": 1, "Hour": 6, "Minute": 0],
            ["Weekday": 5, "Hour": 6, "Minute": 0],
        ])
        #expect(schedule.timeDescription == "Mon, Fri at 06:00")
    }

    @Test func plistXMLIsValidAndParsesBack() throws {
        let (service, cleanup) = try makeService()
        defer { cleanup() }
        let schedule = RestartSchedule(containerName: "web-nginx-1", hour: 3, minute: 15, weekdays: [0, 6])
        let xml = try service.plistXML(for: schedule)
        #expect(xml.contains("<?xml"))

        // Round trip through install (launchctl disabled) → list.
        try service.install(schedule)
        let listed = service.list()
        #expect(listed == [schedule])
        #expect(service.schedule(forContainerName: "web-nginx-1") == schedule)
    }

    @Test func removeDeletesThePlist() throws {
        let (service, cleanup) = try makeService()
        defer { cleanup() }
        let schedule = RestartSchedule(containerName: "bot", hour: 1, minute: 0)
        try service.install(schedule)
        #expect(FileManager.default.fileExists(atPath: service.plistPath(for: schedule).path))
        try service.remove(containerName: "bot")
        #expect(!FileManager.default.fileExists(atPath: service.plistPath(for: schedule).path))
        #expect(service.list().isEmpty)
    }

    @Test func foreignPlistsAreIgnored() throws {
        let (service, cleanup) = try makeService()
        defer { cleanup() }
        try Data("not ours".utf8).write(
            to: service.launchAgentsDirectory.appending(path: "com.example.other.plist"))
        #expect(service.list().isEmpty)
    }

    @Test func labelStripsUnexpectedCharacters() {
        let schedule = RestartSchedule(containerName: "ok_name.1-2/../evil", hour: 0, minute: 0)
        #expect(schedule.label == "com.macerodactyl.restart.ok_name.1-2..evil")
        #expect(!schedule.label.contains("/"))
    }

    @Test func lastResultReadsFailureFromNewerStderr() throws {
        let (service, cleanup) = try makeService()
        defer { cleanup() }
        let schedule = RestartSchedule(containerName: "bot", hour: 0, minute: 0)
        let out = service.logsDirectory.appending(path: "\(schedule.label).out.log")
        let err = service.logsDirectory.appending(path: "\(schedule.label).err.log")

        #expect(service.lastResult(for: schedule) == nil) // never run

        try Data("bot\n".utf8).write(to: out)
        let success = try #require(service.lastResult(for: schedule))
        #expect(success.success)
        #expect(success.message == "bot")

        Thread.sleep(forTimeInterval: 0.05)
        try Data("Cannot connect to the Docker daemon at unix:///... Is the docker daemon running?\n".utf8).write(to: err)
        let failure = try #require(service.lastResult(for: schedule))
        #expect(!failure.success)
        #expect(failure.message.contains("Cannot connect to the Docker daemon"))

        // A later success flips it back.
        Thread.sleep(forTimeInterval: 0.05)
        try Data("bot\nbot\n".utf8).write(to: out)
        #expect(service.lastResult(for: schedule)?.success == true)
    }
}
