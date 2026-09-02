import Foundation

/// A scheduled `docker restart` for one container. Restart-only by design:
/// the app is never what starts containers at boot — that's compose restart
/// policies. These run whether or not the app is open, so they live in
/// launchd, not in-app timers.
public struct RestartSchedule: Sendable, Equatable, Identifiable {
    public static let labelPrefix = "com.macerodactyl.restart."

    public let containerName: String
    public var hour: Int
    public var minute: Int
    /// launchd weekday numbers, 0 = Sunday … 6 = Saturday. Empty = every day.
    public var weekdays: Set<Int>

    public init(containerName: String, hour: Int, minute: Int, weekdays: Set<Int> = []) {
        self.containerName = containerName
        self.hour = min(max(hour, 0), 23)
        self.minute = min(max(minute, 0), 59)
        self.weekdays = Set(weekdays.filter { (0...6).contains($0) })
    }

    public var id: String { label }

    /// Docker container names are [a-zA-Z0-9_.-], so the name is filesystem-
    /// and label-safe; anything unexpected is stripped defensively.
    public var label: String {
        Self.labelPrefix + containerName.filter { $0.isLetter || $0.isNumber || "_.-".contains($0) }
    }

    public var timeDescription: String {
        let time = String(format: "%02d:%02d", hour, minute)
        if weekdays.isEmpty { return "every day at \(time)" }
        let names = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        let days = weekdays.sorted().map { names[$0] }.joined(separator: ", ")
        return "\(days) at \(time)"
    }
}

public enum ScheduleOutcome: Sendable, Equatable {
    case success
    /// docker ran and reported an error (e.g. daemon down, no such container).
    case failed
    /// docker hung and the deadline wrapper had to kill it — a stale Docker
    /// Desktop socket makes `docker restart` block forever, which would
    /// otherwise be the silent-failure case. Distinct from `failed`.
    case timedOut
}

/// Outcome of the most recent scheduled run, reconstructed from the log files
/// launchd appends to. `docker restart` prints the container name to stdout on
/// success and its error to stderr on failure; the deadline wrapper prints a
/// recognizable marker to stderr on timeout. Whichever log was written most
/// recently reflects the last run, and its final line says how it went.
public struct ScheduleRunResult: Sendable, Equatable {
    public let date: Date
    public let outcome: ScheduleOutcome
    public let message: String

    public var succeeded: Bool { outcome == .success }
}

public enum ScheduleError: Error, Equatable, Sendable {
    case launchctlFailed(String)
    case io(String)
}

public struct ScheduleService: Sendable {
    public let launchAgentsDirectory: URL
    public let logsDirectory: URL
    public let dockerPath: String
    /// Test seam: launchctl is skipped entirely when false.
    let managesLaunchd: Bool

    /// Hard deadline for a scheduled `docker restart`, in seconds. Comfortably
    /// above docker's own 10s container-stop grace so a legitimately slow
    /// restart is never mistaken for a hang.
    public static let restartDeadlineSeconds = 60

    /// Printed to stderr by the deadline wrapper when it kills a hung docker.
    public static let timeoutMarker = "macerodactyl-schedule: timed out"

    /// Deadline wrapper run by `/usr/bin/perl`. It forks `docker` and, if the
    /// child outlives the deadline, sends SIGTERM then SIGKILL — unlike the
    /// classic `alarm; exec` idiom, which a Go binary like docker ignores
    /// (docker never registers for SIGALRM, so the timer fires into nothing).
    /// Exit 124 and the stderr marker distinguish a timeout from docker's own
    /// non-zero exits. Kept to one line so it embeds cleanly in the plist argv.
    static let deadlineScript =
        "my $d=shift; my $p=fork; if($p==0){exec @ARGV or exit 127} my $to=0; "
        + "$SIG{ALRM}=sub{$to=1; kill 'TERM',$p; my $n=0; "
        + "while($n++<30 && waitpid($p,1)==0){select(undef,undef,undef,0.1)} "
        + "kill 'KILL',$p if waitpid($p,1)==0}; "
        + "alarm $d; waitpid($p,0); my $s=$?; "
        + "if($to){print STDERR \"" + timeoutMarker
        + " after ${d}s (docker did not respond; the daemon may be down or the socket is stale)\\n\"; exit 124} "
        + "exit($s>>8);"

    public init(dockerPath: String) throws {
        self.dockerPath = dockerPath
        self.launchAgentsDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/LaunchAgents")
        self.logsDirectory = try AppPaths.supportDirectory().appending(path: "schedule-logs")
        self.managesLaunchd = true
        try FileManager.default.createDirectory(at: launchAgentsDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
    }

    init(dockerPath: String, launchAgentsDirectory: URL, logsDirectory: URL, managesLaunchd: Bool) {
        self.dockerPath = dockerPath
        self.launchAgentsDirectory = launchAgentsDirectory
        self.logsDirectory = logsDirectory
        self.managesLaunchd = managesLaunchd
    }

    // MARK: Plist generation (pure)

    /// The exact plist that will be written for a schedule. ProgramArguments
    /// is a raw argv with the fully resolved docker binary path — launchd
    /// inherits no shell PATH, and nothing here passes through a shell at all.
    /// There is deliberately no RunAtLoad: absent means false, so loading the
    /// agent at login never runs a restart.
    public func plistDictionary(for schedule: RestartSchedule) -> [String: Any] {
        // The restart runs under a perl deadline wrapper (see deadlineScript)
        // so a hung docker can't sit in `state = running` forever. Every path
        // is absolute — launchd inherits no shell PATH — and nothing passes
        // through a shell.
        let programArguments = [
            "/usr/bin/perl", "-e", Self.deadlineScript, "--",
            String(Self.restartDeadlineSeconds), dockerPath, "restart", schedule.containerName,
        ]
        var dict: [String: Any] = [
            "Label": schedule.label,
            "ProgramArguments": programArguments,
            "StandardOutPath": logsDirectory.appending(path: "\(schedule.label).out.log").path,
            "StandardErrorPath": logsDirectory.appending(path: "\(schedule.label).err.log").path,
        ]
        if schedule.weekdays.isEmpty {
            dict["StartCalendarInterval"] = ["Hour": schedule.hour, "Minute": schedule.minute]
        } else {
            dict["StartCalendarInterval"] = schedule.weekdays.sorted().map {
                ["Weekday": $0, "Hour": schedule.hour, "Minute": schedule.minute]
            }
        }
        return dict
    }

    public func plistXML(for schedule: RestartSchedule) throws -> String {
        let data = try PropertyListSerialization.data(
            fromPropertyList: plistDictionary(for: schedule), format: .xml, options: 0
        )
        return String(decoding: data, as: UTF8.self)
    }

    public func plistPath(for schedule: RestartSchedule) -> URL {
        launchAgentsDirectory.appending(path: "\(schedule.label).plist")
    }

    // MARK: Lifecycle

    /// Writes the plist and loads the agent. An existing agent for the same
    /// container is booted out first so edits replace rather than duplicate.
    public func install(_ schedule: RestartSchedule) throws {
        // launchd will NOT create the log parent directory, and a missing one
        // makes the job fail to spawn — guarantee it exists before loading.
        do {
            try FileManager.default.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
        } catch {
            throw ScheduleError.io("couldn't create log directory: \(error.localizedDescription)")
        }
        let path = plistPath(for: schedule)
        if FileManager.default.fileExists(atPath: path.path) {
            try? launchctl("bootout", "gui/\(getuid())/\(schedule.label)")
        }
        do {
            let data = try PropertyListSerialization.data(
                fromPropertyList: plistDictionary(for: schedule), format: .xml, options: 0
            )
            try data.write(to: path, options: .atomic)
        } catch {
            throw ScheduleError.io(error.localizedDescription)
        }
        try launchctl("bootstrap", "gui/\(getuid())", path.path)
    }

    /// Unloads the agent and deletes its plist — never orphans either half.
    /// The bootout runs first; if the agent was already unloaded that's fine,
    /// but the plist is only deleted after launchd no longer references it.
    public func remove(containerName: String) throws {
        let schedule = RestartSchedule(containerName: containerName, hour: 0, minute: 0)
        let bootoutResult = Result { try launchctl("bootout", "gui/\(getuid())/\(schedule.label)") }
        let path = plistPath(for: schedule)
        if FileManager.default.fileExists(atPath: path.path) {
            do {
                try FileManager.default.removeItem(at: path)
            } catch {
                throw ScheduleError.io(error.localizedDescription)
            }
        }
        // "No such process" from bootout just means it wasn't loaded; any
        // other launchctl failure with the plist now gone is worth surfacing.
        if case .failure(let error as ScheduleError) = bootoutResult,
           case .launchctlFailed(let message) = error,
           !message.contains("No such process"), !message.contains("not find") {
            throw error
        }
    }

    /// Schedules currently on disk (only ours — the label prefix is the filter).
    public func list() -> [RestartSchedule] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: launchAgentsDirectory.path)) ?? []
        return files.compactMap { file -> RestartSchedule? in
            guard file.hasPrefix(RestartSchedule.labelPrefix), file.hasSuffix(".plist") else { return nil }
            return parse(plistAt: launchAgentsDirectory.appending(path: file))
        }
        .sorted { $0.containerName < $1.containerName }
    }

    public func schedule(forContainerName name: String) -> RestartSchedule? {
        list().first { $0.containerName == name }
    }

    func parse(plistAt url: URL) -> RestartSchedule? {
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let arguments = plist["ProgramArguments"] as? [String],
              let restartIndex = arguments.firstIndex(of: "restart"),
              restartIndex + 1 < arguments.count else { return nil }
        let name = arguments[restartIndex + 1]
        if let interval = plist["StartCalendarInterval"] as? [String: Int] {
            return RestartSchedule(
                containerName: name,
                hour: interval["Hour"] ?? 0, minute: interval["Minute"] ?? 0
            )
        }
        if let intervals = plist["StartCalendarInterval"] as? [[String: Int]], let first = intervals.first {
            return RestartSchedule(
                containerName: name,
                hour: first["Hour"] ?? 0, minute: first["Minute"] ?? 0,
                weekdays: Set(intervals.compactMap { $0["Weekday"] })
            )
        }
        return nil
    }

    // MARK: Agent health (stale or missing binary)

    /// The docker path baked into an installed agent's plist. The path is
    /// resolved at write time, so an agent keeps the binary it was written
    /// with even if the Docker provider is later switched or reinstalled —
    /// health() makes that visible instead of letting the schedule quietly
    /// fire into nothing.
    public func installedDockerPath(forContainerName name: String) -> String? {
        let schedule = RestartSchedule(containerName: name, hour: 0, minute: 0)
        guard let data = try? Data(contentsOf: plistPath(for: schedule)),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let arguments = plist["ProgramArguments"] as? [String] else { return nil }
        return Self.dockerPath(inProgramArguments: arguments)
    }

    /// The docker binary in a ProgramArguments array — the element right
    /// before "restart", regardless of any wrapper that precedes it.
    static func dockerPath(inProgramArguments arguments: [String]) -> String? {
        guard let restartIndex = arguments.firstIndex(of: "restart"), restartIndex > 0 else { return nil }
        return arguments[restartIndex - 1]
    }

    public enum AgentHealth: Sendable, Equatable {
        case ok
        /// The binary the agent points at no longer exists — the scheduled
        /// job will fail to spawn (producing no log output at all).
        case binaryMissing(installed: String)
        /// The binary exists but differs from the currently resolved docker —
        /// e.g. the plist predates a Docker provider switch or reinstall.
        case binaryOutdated(installed: String, current: String)
    }

    public func health(forContainerName name: String) -> AgentHealth? {
        guard let installed = installedDockerPath(forContainerName: name) else { return nil }
        if !FileManager.default.isExecutableFile(atPath: installed) {
            return .binaryMissing(installed: installed)
        }
        if installed != dockerPath {
            return .binaryOutdated(installed: installed, current: dockerPath)
        }
        return .ok
    }

    // MARK: Run results (failure surfacing)

    public func lastResult(for schedule: RestartSchedule) -> ScheduleRunResult? {
        let outURL = logsDirectory.appending(path: "\(schedule.label).out.log")
        let errURL = logsDirectory.appending(path: "\(schedule.label).err.log")
        // launchd appends across runs, so the more recently modified log
        // reflects the last run, and its final line says how it went. A
        // stderr final line carrying the wrapper's marker means a timeout;
        // any other stderr line means docker itself errored.
        let out = logInfo(outURL)
        let err = logInfo(errURL)
        func fromStderr(_ info: (date: Date, lastLine: String)) -> ScheduleRunResult {
            let outcome: ScheduleOutcome = info.lastLine.contains(Self.timeoutMarker) ? .timedOut : .failed
            return ScheduleRunResult(date: info.date, outcome: outcome, message: info.lastLine)
        }
        switch (out, err) {
        case (nil, nil):
            return nil
        case (let out?, nil):
            return ScheduleRunResult(date: out.date, outcome: .success, message: out.lastLine)
        case (nil, let err?):
            return fromStderr(err)
        case (let out?, let err?):
            return err.date > out.date
                ? fromStderr(err)
                : ScheduleRunResult(date: out.date, outcome: .success, message: out.lastLine)
        }
    }

    private func logInfo(_ url: URL) -> (date: Date, lastLine: String)? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let date = attributes[.modificationDate] as? Date,
              let size = attributes[.size] as? Int, size > 0,
              let data = try? Data(contentsOf: url) else { return nil }
        let lastLine = String(decoding: data.suffix(2048), as: UTF8.self)
            .split(separator: "\n").last.map(String.init) ?? ""
        return (date, lastLine)
    }

    // MARK: launchctl

    @discardableResult
    private func launchctl(_ args: String...) throws -> String {
        guard managesLaunchd else { return "" }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = args
        let errPipe = Pipe()
        process.standardError = errPipe
        process.standardOutput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw ScheduleError.launchctlFailed(String(describing: error))
        }
        process.waitUntilExit()
        let stderr = String(
            decoding: errPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0 else {
            throw ScheduleError.launchctlFailed(stderr.isEmpty ? "launchctl exited \(process.terminationStatus)" : stderr)
        }
        return stderr
    }
}
