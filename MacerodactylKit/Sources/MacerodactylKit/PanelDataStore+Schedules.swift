import Foundation

/// DB-backed scheduled restarts — the cross-platform source of truth used by the
/// server deploy (macerodactyld's in-process cron loop). On macOS the native app
/// still drives launchd directly; this table is what makes schedules fire on a
/// Linux host where launchd does not exist.
extension PanelDataStore {
    /// One persisted schedule row, plus the outcome of its most recent run.
    public struct PersistedSchedule: Sendable, Equatable, Identifiable {
        public var containerName: String
        public var hour: Int
        public var minute: Int
        /// launchd weekday numbers (0=Sun…6=Sat); empty means every day.
        public var weekdays: Set<Int>
        public var lastRunAt: String?
        public var lastOutcome: String?
        public var lastMessage: String?
        /// When the schedule was created (ISO8601), so a genuinely missed fire can
        /// be told apart from a slot that predates the schedule.
        public var createdAt: String?

        public var id: String { containerName }

        public init(
            containerName: String, hour: Int, minute: Int, weekdays: Set<Int>,
            lastRunAt: String? = nil, lastOutcome: String? = nil, lastMessage: String? = nil,
            createdAt: String? = nil
        ) {
            self.containerName = containerName
            self.hour = hour
            self.minute = minute
            self.weekdays = weekdays
            self.lastRunAt = lastRunAt
            self.lastOutcome = lastOutcome
            self.lastMessage = lastMessage
            self.createdAt = createdAt
        }
    }

    private static func encodeWeekdays(_ weekdays: Set<Int>) -> String {
        weekdays.sorted().map(String.init).joined(separator: ",")
    }

    private static func decodeWeekdays(_ text: String?) -> Set<Int> {
        Set((text ?? "").split(separator: ",").compactMap { Int($0) }.filter { (0...6).contains($0) })
    }

    private func scheduleFromRow(_ row: [String: SQLValue]) -> PersistedSchedule {
        PersistedSchedule(
            containerName: row["container_name"]?.asString ?? "",
            hour: Int(row["hour"]?.asInt ?? 0),
            minute: Int(row["minute"]?.asInt ?? 0),
            weekdays: Self.decodeWeekdays(row["weekdays"]?.asString),
            lastRunAt: row["last_run_at"]?.asString,
            lastOutcome: row["last_outcome"]?.asString,
            lastMessage: row["last_message"]?.asString,
            createdAt: row["created_at"]?.asString)
    }

    /// Creates or replaces the schedule for a container. Run history is cleared
    /// on a re-set, matching launchd (a rewritten agent has no prior result yet).
    public func upsertSchedule(containerName: String, hour: Int, minute: Int, weekdays: Set<Int>) throws {
        // created_at is refreshed on every (re)set: a schedule just defined can't
        // have "missed" a fire that occurred before it existed in this form.
        try db.run(
            """
            INSERT INTO schedules (container_name, hour, minute, weekdays, created_at)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(container_name) DO UPDATE SET
                hour=excluded.hour, minute=excluded.minute, weekdays=excluded.weekdays,
                created_at=excluded.created_at,
                last_run_at=NULL, last_outcome=NULL, last_message=NULL
            """,
            [
                .text(containerName), .integer(Int64(min(max(hour, 0), 23))),
                .integer(Int64(min(max(minute, 0), 59))), .text(Self.encodeWeekdays(weekdays)),
                .text(PanelSchema.nowISO()),
            ])
    }

    public func deleteSchedule(containerName: String) throws {
        try db.run("DELETE FROM schedules WHERE container_name = ?", [.text(containerName)])
        try db.run("DELETE FROM schedule_tasks WHERE container_name = ?", [.text(containerName)])
    }

    // MARK: Task chains

    /// A schedule's ordered task chain (empty = legacy single-restart behavior).
    public func scheduleTasks(containerName: String) throws -> [ScheduleTask] {
        try db.query(
            "SELECT * FROM schedule_tasks WHERE container_name = ? ORDER BY seq", [.text(containerName)]
        ).map { row in
            ScheduleTask(
                id: row["id"]?.asInt ?? 0,
                seq: Int(row["seq"]?.asInt ?? 0),
                action: ScheduleTask.Action(rawValue: row["action"]?.asString ?? "") ?? .power,
                payload: row["payload"]?.asString ?? "",
                offsetSeconds: Int(row["offset_seconds"]?.asInt ?? 0))
        }
    }

    /// Replaces a container's whole task chain. `seq` is reassigned from the
    /// array order, so callers just pass the tasks in the order they should run.
    public func setScheduleTasks(containerName: String, tasks: [ScheduleTask]) throws {
        try db.run("DELETE FROM schedule_tasks WHERE container_name = ?", [.text(containerName)])
        for (index, task) in tasks.enumerated() {
            try db.run(
                """
                INSERT INTO schedule_tasks (container_name, seq, action, payload, offset_seconds)
                VALUES (?, ?, ?, ?, ?)
                """,
                [
                    .text(containerName), .integer(Int64(index)), .text(task.action.rawValue),
                    .text(task.payload), .integer(Int64(max(task.offsetSeconds, 0))),
                ])
        }
    }

    public func schedule(containerName: String) throws -> PersistedSchedule? {
        try db.query("SELECT * FROM schedules WHERE container_name = ?", [.text(containerName)])
            .first.map(scheduleFromRow)
    }

    public func listSchedules() throws -> [PersistedSchedule] {
        try db.query("SELECT * FROM schedules ORDER BY container_name").map(scheduleFromRow)
    }

    /// Records the outcome of a scheduled run.
    public func recordScheduleRun(containerName: String, at iso: String, outcome: String, message: String) throws {
        try db.run(
            "UPDATE schedules SET last_run_at = ?, last_outcome = ?, last_message = ? WHERE container_name = ?",
            [.text(iso), .text(outcome), .text(message), .text(containerName)])
    }
}
