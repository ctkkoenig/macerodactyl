import Foundation
import MacerodactylKit

// Headless smoke checks that exercise the app's real code paths.
// Usage:
//   kitcheck                          list containers, grouped
//   kitcheck start|stop|restart NAME  power action
//   kitcheck logs NAME SECONDS        stream logs briefly, then cancel (teardown check)
//   kitcheck exec NAME CMDLINE        one line-based console command
//   kitcheck rcon NAME CMDLINE        detect + connect + run one RCON command

guard let binary = DockerBinaryLocator.resolve(override: AppSettings.dockerPathOverride) else {
    print("docker binary: NOT FOUND (checked ~/.orbstack/bin, /opt/homebrew/bin, /usr/local/bin)")
    exit(2)
}

let cli = DockerCLI(binary: binary)
let arguments = CommandLine.arguments

func listContainers() async {
    do {
        let output = try await cli.run(["ps", "-a", "--no-trunc", "--format", "{{json .}}"], timeout: .seconds(15))
        let groups = DockerPSParser.group(DockerPSParser.parse(output))
        print("daemon: ready — \(groups.stacks.count) stack(s), \(groups.unmanaged.count) unmanaged")
        for stack in groups.stacks {
            print("\nstack \(stack.name) (\(stack.runningCount)/\(stack.containers.count) running) dir=\(stack.workingDir ?? "-")")
            for container in stack.containers {
                let health = container.health.map { " [\($0.rawValue)]" } ?? ""
                print("  \(container.isRunning ? "●" : "○") \(container.name)\(health)  \(container.image)  \(container.status)")
            }
        }
        if !groups.unmanaged.isEmpty {
            print("\nunmanaged")
            for container in groups.unmanaged {
                let health = container.health.map { " [\($0.rawValue)]" } ?? ""
                print("  \(container.isRunning ? "●" : "○") \(container.name)\(health)  \(container.image)  \(container.status)")
            }
        }
    } catch DockerError.daemonUnavailable {
        print("daemon: NOT RUNNING (this is the app's daemon-down state)")
        exit(3)
    } catch {
        print("error: \(error)")
        exit(1)
    }
}

switch arguments.dropFirst().first {
case "start", "stop", "restart":
    guard arguments.count == 3 else {
        print("usage: kitcheck \(arguments[1]) NAME")
        exit(64)
    }
    do {
        try await cli.run([arguments[1], arguments[2]], timeout: .seconds(120))
        print("\(arguments[1]) \(arguments[2]): ok")
    } catch {
        print("\(arguments[1]) \(arguments[2]): FAILED — \(error)")
        exit(1)
    }
    await listContainers()

case "logs":
    guard arguments.count == 4, let seconds = Int(arguments[3]) else {
        print("usage: kitcheck logs NAME SECONDS")
        exit(64)
    }
    let name = arguments[2]
    let task = Task {
        var count = 0
        do {
            for try await line in LogStreamService.lines(for: name, cli: cli) {
                count += 1
                if count <= 5 { print("log> \(line)") }
            }
        } catch {
            print("stream error: \(error)")
        }
        return count
    }
    try? await Task.sleep(for: .seconds(seconds))
    task.cancel()
    let count = await task.value
    print("received \(count) line(s) in \(seconds)s; stream cancelled")
    // Give the termination handler a beat, then look for leaked children.
    try? await Task.sleep(for: .seconds(1))
    let check = Process()
    check.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    check.arguments = ["-fl", "docker logs"]
    let pipe = Pipe()
    check.standardOutput = pipe
    try? check.run()
    check.waitUntilExit()
    let leaked = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    if leaked.isEmpty {
        print("teardown: OK — no leaked docker logs process")
    } else {
        print("teardown: LEAK DETECTED:\n\(leaked)")
        exit(1)
    }

case "exec":
    guard arguments.count == 4 else {
        print("usage: kitcheck exec NAME CMDLINE")
        exit(64)
    }
    let entry = await ExecConsole(containerID: arguments[2], cli: cli).run(arguments[3])
    print("$ \(entry.command)\n\(entry.output)\(entry.isError ? "  [error]" : "")")

case "attach":
    // Live smoke for the interactive-console primitive: attach to a running
    // container (started with stdin open), write a line, print what streams
    // back for a couple seconds, then tear down.
    guard arguments.count == 4 else {
        print("usage: kitcheck attach CONTAINER_ID LINE")
        exit(64)
    }
    let session = cli.attach(containerID: arguments[2])
    let printer = Task {
        do {
            for try await line in session.lines { print("< \(line)") }
        } catch { print("stream error: \(error)") }
    }
    try? await Task.sleep(for: .milliseconds(300))
    print("> \(arguments[3])")
    session.write(arguments[3])
    try? await Task.sleep(for: .seconds(2))
    session.close()
    printer.cancel()

case "rcon":
    guard arguments.count == 4 else {
        print("usage: kitcheck rcon NAME CMDLINE")
        exit(64)
    }
    switch await MinecraftRCON.detect(containerID: arguments[2], cli: cli) {
    case .notMinecraft:
        print("not a Minecraft container")
        exit(1)
    case .unreachable(let reason):
        print("RCON unreachable: \(reason)")
        exit(1)
    case .available(let endpoint):
        print("RCON endpoint: \(endpoint.host):\(endpoint.port)")
        #if canImport(Network)
        let client = RCONClient(endpoint: endpoint)
        do {
            try await client.connect()
            print("auth: ok")
            let response = try await client.send(command: arguments[3])
            print("> \(arguments[3])\n\(response)")
            await client.close()
        } catch {
            print("rcon error: \(error)")
            exit(1)
        }
        #else
        print("RCON client unavailable on this platform (needs Network.framework)")
        exit(1)
        #endif
    }

case "files":
    // kitcheck files NAME list|read DIR/PATH  or  kitcheck files NAME write PATH TEXT
    guard arguments.count >= 4 else {
        print("usage: kitcheck files NAME list|read|write PATH [TEXT]")
        exit(64)
    }
    let name = arguments[2]
    let output = try await cli.run(["ps", "-a", "--no-trunc", "--format", "{{json .}}"], timeout: .seconds(15))
    guard let container = DockerPSParser.parse(output).first(where: { $0.name == name }) else {
        print("no container named \(name)")
        exit(1)
    }
    guard let service = FileService(container: container, stacksRoot: AppSettings.stacksRoot) else {
        print("file access: UNAVAILABLE (no stack folder under the stacks root) — UI shows the explanation, not a broken tab")
        exit(0)
    }
    do {
        switch arguments[3] {
        case "list":
            for entry in try service.list(arguments.count > 4 ? arguments[4] : "") {
                print("\(entry.isDirectory ? "dir " : "file") \(entry.relativePath) (\(entry.sizeBytes)b)")
            }
        case "read":
            let content = try service.read(arguments[4])
            print("read ok (\(content.lineEnding.rawValue)):\n\(content.text.prefix(300))")
        case "write":
            try service.write(arguments[4], text: arguments.count > 5 ? arguments[5] + "\n" : "test\n", lineEnding: .lf)
            print("write ok")
        default:
            print("unknown files op")
            exit(64)
        }
    } catch {
        print("REFUSED: \(error)")
        exit(4)
    }

case "schedule-preview":
    // kitcheck schedule-preview NAME HH MM — prints the exact plist install() would write, writes nothing.
    guard arguments.count == 5, let hour = Int(arguments[3]), let minute = Int(arguments[4]) else {
        print("usage: kitcheck schedule-preview NAME HH MM")
        exit(64)
    }
    let service = try ScheduleService(dockerPath: binary.path)
    let schedule = RestartSchedule(containerName: arguments[2], hour: hour, minute: minute)
    print("would write to: \(service.plistPath(for: schedule).path)")
    print("then run: launchctl bootstrap gui/\(getuid()) <that path>")
    print(String(repeating: "-", count: 60))
    print(try service.plistXML(for: schedule))

case "schedule-install":
    guard arguments.count == 5, let hour = Int(arguments[3]), let minute = Int(arguments[4]) else {
        print("usage: kitcheck schedule-install NAME HH MM")
        exit(64)
    }
    let service = try ScheduleService(dockerPath: binary.path)
    let schedule = RestartSchedule(containerName: arguments[2], hour: hour, minute: minute)
    try service.install(schedule)
    print("installed \(schedule.label) (\(schedule.timeDescription))")

case "schedule-status":
    guard arguments.count == 3 else {
        print("usage: kitcheck schedule-status NAME")
        exit(64)
    }
    let service = try ScheduleService(dockerPath: binary.path)
    guard let schedule = service.schedule(forContainerName: arguments[2]) else {
        print("no schedule for \(arguments[2])")
        exit(0)
    }
    print("schedule: \(schedule.timeDescription)")
    print("installed docker path: \(service.installedDockerPath(forContainerName: arguments[2]) ?? "?")")
    print("health: \(service.health(forContainerName: arguments[2]).map(String.init(describing:)) ?? "?")")
    if let result = service.lastResult(for: schedule) {
        let label =
            switch result.outcome {
            case .success: "OK"
            case .failed: "FAILED"
            case .timedOut: "TIMED OUT"
            case .missed: "MISSED"
            }
        print("last run: \(result.date.formatted()) \(label) — \(result.message)")
    } else {
        print("last run: never")
    }

case "schedule-remove":
    guard arguments.count == 3 else {
        print("usage: kitcheck schedule-remove NAME")
        exit(64)
    }
    let service = try ScheduleService(dockerPath: binary.path)
    try service.remove(containerName: arguments[2])
    print("removed schedule for \(arguments[2])")

case "diagnose":
    // Real-machine environment snapshot + advisories.
    let cli = DockerCLI(binary: binary)
    let daemon: DockerAvailability
    let containers: Int
    do {
        let output = try await cli.run(["ps", "-a", "--no-trunc", "--format", "{{json .}}"], timeout: .seconds(15))
        daemon = .ready
        containers = DockerPSParser.group(DockerPSParser.parse(output)).all.count
    } catch DockerError.daemonUnavailable {
        daemon = .daemonDown
        containers = 0
    } catch {
        daemon = .daemonDown
        containers = 0
    }
    let pluginWorks = daemon == .ready ? await cli.composePluginWorks() : false
    let composeAvailable =
        daemon == .ready
        ? (ComposeCommand.detect(dockerBinary: binary, pluginWorks: { _ in pluginWorks }) != nil)
        : false
    let snapshot = EnvironmentSnapshot(
        dockerResolved: true, daemon: daemon,
        composeAvailable: composeAvailable,
        perlAvailable: SystemTools().perlPath() != nil,
        stacksRootExists: AppSettings.stacksRootExists(),
        stacksRootPath: AppSettings.stacksRoot.path, containerCount: containers
    )
    print("snapshot: \(snapshot)")
    print("perl: \(SystemTools().perlPath() ?? "MISSING")")
    if let compose = ComposeCommand.detect(dockerBinary: binary, pluginWorks: { _ in false }) {
        print("standalone docker-compose: \(compose)")
    }
    print("docker compose plugin works: \(pluginWorks)")
    let advisories = StartupDiagnostics.evaluate(snapshot)
    if advisories.isEmpty {
        print("advisories: none (healthy)")
    } else {
        for advisory in advisories { print("  [\(advisory.severity)] \(advisory.title) — \(advisory.remedy)") }
    }

case "stats":
    // Snapshot (all) and, if a name is given, a few streamed samples.
    do {
        let snap = try await cli.statsSnapshot()
        print("snapshot: \(snap.count) container(s) with live readings")
        for (name, s) in snap.sorted(by: { $0.key < $1.key }) {
            print(
                "  \(name): cpu \(String(format: "%.1f", s.cpuPercent))%  mem \(ByteFormat.string(s.memUsedBytes))/\(ByteFormat.string(s.memLimitBytes)) (\(String(format: "%.1f", s.memPercent))%)  net ↓\(ByteFormat.string(s.netRxBytes)) ↑\(ByteFormat.string(s.netTxBytes))  pids \(s.pids)"
            )
        }
    } catch DockerError.daemonUnavailable {
        print("snapshot: daemon down — UI shows 'Unavailable', not zeros")
    }
    if arguments.count == 3 {
        print("\nstreaming \(arguments[2]) (3 samples)...")
        var n = 0
        for try await s in cli.statsStream(containerID: arguments[2]) {
            print("  sample: cpu \(String(format: "%.2f", s.cpuPercent))%  mem \(ByteFormat.string(s.memUsedBytes))")
            n += 1
            if n >= 3 { break }
        }
        print("stream stopped after \(n) samples")
        try? await Task.sleep(for: .seconds(1))
        let check = Process()
        check.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        check.arguments = ["-fl", "docker stats"]
        let pipe = Pipe()
        check.standardOutput = pipe
        try? check.run()
        check.waitUntilExit()
        let leaked = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(
            in: .whitespacesAndNewlines)
        print(leaked.isEmpty ? "teardown: OK — no leaked docker stats process" : "teardown: LEAK:\n\(leaked)")
    }

case "metrics":
    // Exercises the T2.4 retained-metrics pipeline against REAL docker: take a
    // live snapshot, persist each sample to a throwaway SQLite, prune, read back.
    do {
        let dir = FileManager.default.temporaryDirectory.appending(path: "kitcheck-metrics-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try PanelDataStore(databasePath: dir.appending(path: "m.sqlite").path)
        let snap = try await cli.statsSnapshot()
        for sample in snap.values { try store.recordMetric(sample) }
        try store.pruneMetrics(maxAge: 24 * 3_600, maxPerContainer: 5_000)
        print("recorded \(snap.count) sample(s); total retained = \(try store.metricsCount())")
        for name in snap.keys.sorted() {
            let series = try store.metrics(container: name)
            let last = series.last
            print(
                "  \(name): \(series.count) row(s), last cpu \(last.map { String(format: "%.1f", $0.cpuPercent) } ?? "-")% at \(last?.measuredAt.description ?? "-")"
            )
        }
        print("round-trip: OK — snapshot persisted and read back")
    } catch DockerError.daemonUnavailable {
        print("daemon down — nothing to sample")
    }

case nil:
    await listContainers()

default:
    print("unknown subcommand \(arguments[1])")
    exit(64)
}
