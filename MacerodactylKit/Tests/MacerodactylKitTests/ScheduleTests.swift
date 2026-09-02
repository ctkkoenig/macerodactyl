import Foundation
import Testing

@testable import MacerodactylKit

@Suite struct ScheduleTests {
    private func makeService(
        dockerPath: String = "/fake/resolved/bin/docker",
        perlPath: String? = "/usr/bin/perl",
        managesLaunchd: Bool = false
    ) throws -> (ScheduleService, cleanup: () -> Void) {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appending(path: "sched-\(UUID().uuidString)")
        let agents = base.appending(path: "LaunchAgents")
        let logs = base.appending(path: "logs")
        try fm.createDirectory(at: agents, withIntermediateDirectories: true)
        try fm.createDirectory(at: logs, withIntermediateDirectories: true)
        let service = ScheduleService(
            dockerPath: dockerPath,
            launchAgentsDirectory: agents, logsDirectory: logs,
            managesLaunchd: managesLaunchd, perlPath: perlPath
        )
        return (service, { try? fm.removeItem(at: base) })
    }

    @Test func plistUsesAbsoluteDockerPathAndRawArgv() throws {
        let (service, cleanup) = try makeService()
        defer { cleanup() }
        let dict = service.plistDictionary(for: RestartSchedule(containerName: "fixture-mc", hour: 4, minute: 30))

        // launchd inherits no shell PATH: the argv must carry the fully
        // resolved binary, wrapped by the perl deadline runner (also an
        // absolute path). There is no shell anywhere in it.
        let args = try #require(dict["ProgramArguments"] as? [String])
        #expect(args.first == "/usr/bin/perl")
        #expect(!args.contains { $0.contains("/bin/sh") || $0.contains("bash") })
        // docker + restart + container name appear in order, with the fully
        // resolved binary right before "restart".
        let restartIndex = try #require(args.firstIndex(of: "restart"))
        #expect(args[restartIndex - 1] == "/fake/resolved/bin/docker")
        #expect(args[restartIndex + 1] == "fixture-mc")
        #expect(ScheduleService.dockerPath(inProgramArguments: args) == "/fake/resolved/bin/docker")
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
        #expect(
            intervals == [
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

    @Test func healthFlagsMissingAndOutdatedBinaries() throws {
        let (service, cleanup) = try makeService()
        defer { cleanup() }
        let schedule = RestartSchedule(containerName: "bot", hour: 2, minute: 0)
        try service.install(schedule)

        // The plist bakes the path that was resolved at write time…
        #expect(service.installedDockerPath(forContainerName: "bot") == "/fake/resolved/bin/docker")
        // …and that fake path isn't executable, so health reports BROKEN.
        #expect(service.health(forContainerName: "bot") == .binaryMissing(installed: "/fake/resolved/bin/docker"))

        // A real executable that differs from the current one → outdated.
        let realBinary = FileManager.default.temporaryDirectory.appending(path: "docker-\(UUID().uuidString)")
        try Data("#!/bin/sh\n".utf8).write(to: realBinary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: realBinary.path)
        defer { try? FileManager.default.removeItem(at: realBinary) }
        let moved = ScheduleService(
            dockerPath: realBinary.path,
            launchAgentsDirectory: service.launchAgentsDirectory,
            logsDirectory: service.logsDirectory, managesLaunchd: false
        )
        // Reinstalling under the new resolution rewrites the agent…
        try moved.install(schedule)
        #expect(moved.health(forContainerName: "bot") == .ok)
        // …and a service resolving elsewhere sees it as outdated.
        let elsewhere = ScheduleService(
            dockerPath: "/somewhere/else/docker",
            launchAgentsDirectory: service.launchAgentsDirectory,
            logsDirectory: service.logsDirectory, managesLaunchd: false
        )
        #expect(
            elsewhere.health(forContainerName: "bot")
                == .binaryOutdated(installed: realBinary.path, current: "/somewhere/else/docker"))
    }

    @Test func missingPerlDropsWrapperButStillSchedules() throws {
        let (service, cleanup) = try makeService(perlPath: nil)
        defer { cleanup() }
        let dict = service.plistDictionary(for: RestartSchedule(containerName: "bot", hour: 3, minute: 0))
        let args = try #require(dict["ProgramArguments"] as? [String])
        // No perl wrapper — docker runs directly (schedule still fires, just
        // without the hard-deadline safeguard).
        #expect(args == ["/fake/resolved/bin/docker", "restart", "bot"])
        #expect(!args.contains("/usr/bin/perl"))
        // docker-path parsing still finds it for health/repair.
        #expect(service.installedDockerPath(forContainerName: "bot") == nil)  // not installed yet
        try service.install(RestartSchedule(containerName: "bot", hour: 3, minute: 0))
        #expect(service.installedDockerPath(forContainerName: "bot") == "/fake/resolved/bin/docker")
    }

    @Test func repairRewritesStalePlistsWithCurrentPath() throws {
        // Install two schedules under an "old provider" path…
        let (oldService, cleanup) = try makeService(dockerPath: "/old/provider/bin/docker")
        defer { cleanup() }
        try oldService.install(RestartSchedule(containerName: "bot", hour: 1, minute: 0))
        try oldService.install(RestartSchedule(containerName: "scraper", hour: 2, minute: 0, weekdays: [1, 3]))

        // …then a real executable becomes the current docker (different path).
        let realDocker = FileManager.default.temporaryDirectory.appending(path: "docker-\(UUID().uuidString)")
        try Data("#!/bin/sh\n".utf8).write(to: realDocker)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: realDocker.path)
        defer { try? FileManager.default.removeItem(at: realDocker) }

        let current = ScheduleService(
            dockerPath: realDocker.path,
            launchAgentsDirectory: oldService.launchAgentsDirectory,
            logsDirectory: oldService.logsDirectory, managesLaunchd: false, perlPath: "/usr/bin/perl"
        )
        // Both are detected as needing repair (old path isn't executable).
        #expect(Set(current.schedulesNeedingRepair().map(\.containerName)) == ["bot", "scraper"])

        // One action rewrites both.
        let repaired = try current.repairAll()
        #expect(Set(repaired) == ["bot", "scraper"])
        #expect(current.schedulesNeedingRepair().isEmpty)
        #expect(current.installedDockerPath(forContainerName: "bot") == realDocker.path)
        #expect(current.installedDockerPath(forContainerName: "scraper") == realDocker.path)
        // The weekday schedule survived the rewrite intact.
        #expect(current.schedule(forContainerName: "scraper")?.weekdays == [1, 3])
    }

    @Test func repairLeavesMatchingSchedulesUntouched() throws {
        let realDocker = FileManager.default.temporaryDirectory.appending(path: "docker-\(UUID().uuidString)")
        try Data("#!/bin/sh\n".utf8).write(to: realDocker)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: realDocker.path)
        defer { try? FileManager.default.removeItem(at: realDocker) }
        let (service, cleanup) = try makeService(dockerPath: realDocker.path)
        defer { cleanup() }
        try service.install(RestartSchedule(containerName: "bot", hour: 1, minute: 0))
        #expect(service.schedulesNeedingRepair().isEmpty)
        #expect(try service.repairAll().isEmpty)
    }

    @Test func installRecreatesDeletedLogDirectory() throws {
        let (service, cleanup) = try makeService()
        defer { cleanup() }
        try FileManager.default.removeItem(at: service.logsDirectory)
        try service.install(RestartSchedule(containerName: "bot", hour: 1, minute: 0))
        var isDir: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: service.logsDirectory.path, isDirectory: &isDir))
        #expect(isDir.boolValue)
    }

    @Test func lastResultReadsFailureFromNewerStderr() throws {
        let (service, cleanup) = try makeService()
        defer { cleanup() }
        let schedule = RestartSchedule(containerName: "bot", hour: 0, minute: 0)
        let out = service.logsDirectory.appending(path: "\(schedule.label).out.log")
        let err = service.logsDirectory.appending(path: "\(schedule.label).err.log")

        #expect(service.lastResult(for: schedule) == nil)  // never run

        try Data("bot\n".utf8).write(to: out)
        let success = try #require(service.lastResult(for: schedule))
        #expect(success.outcome == .success)
        #expect(success.message == "bot")

        Thread.sleep(forTimeInterval: 0.05)
        try Data("Cannot connect to the Docker daemon at unix:///... Is the docker daemon running?\n".utf8).write(to: err)
        let failure = try #require(service.lastResult(for: schedule))
        #expect(failure.outcome == .failed)
        #expect(failure.message.contains("Cannot connect to the Docker daemon"))

        // A later success flips it back.
        Thread.sleep(forTimeInterval: 0.05)
        try Data("bot\nbot\n".utf8).write(to: out)
        #expect(service.lastResult(for: schedule)?.outcome == .success)
    }

    @Test func timeoutSurfacesAsDistinctState() throws {
        let (service, cleanup) = try makeService()
        defer { cleanup() }
        let schedule = RestartSchedule(containerName: "fixture-bare", hour: 0, minute: 0)
        let out = service.logsDirectory.appending(path: "\(schedule.label).out.log")
        let err = service.logsDirectory.appending(path: "\(schedule.label).err.log")

        // A prior successful run…
        try Data("fixture-bare\n".utf8).write(to: out)
        #expect(service.lastResult(for: schedule)?.outcome == .success)

        // …then a hung run: the deadline wrapper appends its marker to stderr.
        // This is neither a docker daemon error nor silence — it must read as
        // its own state, not the same as .failed.
        Thread.sleep(forTimeInterval: 0.05)
        let markerLine =
            "\(ScheduleService.timeoutMarker) after 60s (docker did not respond; the daemon may be down or the socket is stale)\n"
        try Data(markerLine.utf8).write(to: err)
        let result = try #require(service.lastResult(for: schedule))
        #expect(result.outcome == .timedOut)
        #expect(result.outcome != .failed)
        #expect(result.message.contains("timed out"))

        // A genuine docker error on a later run is still .failed, not .timedOut.
        Thread.sleep(forTimeInterval: 0.05)
        try Data("\(markerLine)Error response from daemon: no such container\n".utf8).write(to: err)
        #expect(service.lastResult(for: schedule)?.outcome == .failed)
    }
}
