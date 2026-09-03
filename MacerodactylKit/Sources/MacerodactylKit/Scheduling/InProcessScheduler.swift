import Foundation

/// Pure "is this schedule due right now?" logic — no clock, no I/O, so it is
/// exhaustively testable. `weekdays` uses launchd numbering (0=Sun…6=Sat) to
/// match the rest of the schedule model; empty means every day.
public enum ScheduleEvaluator {
    /// True when a schedule set for `hour:minute` on `weekdays` is due at the
    /// given wall-clock. `calendarWeekday` is Foundation's `Calendar` weekday
    /// (1=Sun…7=Sat); it is converted to launchd numbering internally.
    public static func isDue(
        scheduleHour: Int, scheduleMinute: Int, weekdays: Set<Int>,
        nowHour: Int, nowMinute: Int, calendarWeekday: Int
    ) -> Bool {
        guard nowHour == scheduleHour, nowMinute == scheduleMinute else { return false }
        if weekdays.isEmpty { return true }
        let launchdWeekday = calendarWeekday - 1  // 1=Sun → 0=Sun
        return weekdays.contains(launchdWeekday)
    }

    /// The most recent moment at or before `now` when this schedule was due, or
    /// nil if none in the last week. Used to detect a fire the daemon MISSED
    /// while it was down: if that moment is newer than the last recorded run, the
    /// scheduled restart never happened and should be surfaced.
    public static func lastExpectedFire(
        before now: Date, scheduleHour: Int, scheduleMinute: Int, weekdays: Set<Int>, calendar: Calendar
    ) -> Date? {
        for dayOffset in 0...7 {
            guard let day = calendar.date(byAdding: .day, value: -dayOffset, to: now) else { continue }
            var comps = calendar.dateComponents([.year, .month, .day], from: day)
            comps.hour = scheduleHour
            comps.minute = scheduleMinute
            comps.second = 0
            guard let candidate = calendar.date(from: comps), candidate <= now else { continue }
            let weekday = calendar.component(.weekday, from: candidate)
            if weekdays.isEmpty || weekdays.contains(weekday - 1) { return candidate }
        }
        return nil
    }

    /// Every moment in the half-open window `(after, through]` when the schedule
    /// was due, oldest first — used to count the fires an outage skipped and to
    /// bound its window. Enumeration is capped to the last 400 days before
    /// `through` so a corrupt/ancient lower bound can't loop unboundedly.
    public static func expectedFires(
        after: Date, through: Date, scheduleHour: Int, scheduleMinute: Int, weekdays: Set<Int>, calendar: Calendar
    ) -> [Date] {
        guard after < through else { return [] }
        let floor = calendar.date(byAdding: .day, value: -400, to: through) ?? after
        let lowerBound = max(after, floor)
        var results: [Date] = []
        var day = calendar.startOfDay(for: lowerBound)
        let lastDay = calendar.startOfDay(for: through)
        while day <= lastDay {
            var comps = calendar.dateComponents([.year, .month, .day], from: day)
            comps.hour = scheduleHour
            comps.minute = scheduleMinute
            comps.second = 0
            if let candidate = calendar.date(from: comps), candidate > after, candidate <= through {
                let weekday = calendar.component(.weekday, from: candidate)
                if weekdays.isEmpty || weekdays.contains(weekday - 1) { results.append(candidate) }
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return results
    }
}

/// Outcome of firing one scheduled restart, mirroring `ScheduleOutcome` but
/// carrying the message for the run log.
public enum ScheduleFireOutcome: Sendable, Equatable {
    case success(String)
    case failed(String)
    case timedOut(String)

    var dbOutcome: String {
        switch self {
        case .success: "ok"
        case .failed: "failed"
        case .timedOut: "timedOut"
        }
    }
    var message: String {
        switch self {
        case .success(let m), .failed(let m), .timedOut(let m): m
        }
    }
}

/// The cross-platform scheduler used by the headless server deploy: a cooperative
/// cron loop that reads the DB-backed `schedules` table and fires due restarts.
/// It exists because launchd — the macOS app's scheduler — does not exist on the
/// Linux host the panel deploys to, so without this a scheduled restart set over
/// the web would silently never run.
///
/// Correctness properties:
/// - **Fires at most once per due minute per container.** The loop wakes several
///   times a minute so it never misses the target minute; a per-container
///   last-fired minute key makes the extra wakeups idempotent.
/// - **Never blocks the loop on a hung docker.** Each restart runs under the
///   injected runner's own deadline; a timeout is recorded, not awaited forever.
/// - **Deterministic under test.** The clock and the restart action are injected,
///   and `tick(at:)` performs exactly one evaluation pass, so behavior is tested
///   without real time or a real daemon.
public actor InProcessScheduler {
    private let store: PanelDataStore
    private let calendar: Calendar
    private let now: @Sendable () -> Date
    private let restart: @Sendable (String) async -> ScheduleFireOutcome
    /// Per-container "yyyy-MM-dd HH:mm" of the last minute we fired in, so the
    /// multiple wakeups within one minute fire the restart only once.
    private var lastFiredMinute: [String: String] = [:]

    public init(
        store: PanelDataStore,
        calendar: Calendar = .current,
        now: @escaping @Sendable () -> Date = { Date() },
        restart: @escaping @Sendable (String) async -> ScheduleFireOutcome
    ) {
        self.store = store
        self.calendar = calendar
        self.now = now
        self.restart = restart
    }

    private func minuteKey(_ date: Date) -> String {
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return String(
            format: "%04d-%02d-%02d %02d:%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0)
    }

    /// One evaluation pass: first surface any fire missed while the daemon was
    /// down, then fire every schedule due at `date` that hasn't already fired this
    /// minute, recording each outcome. Returns the containers fired.
    @discardableResult
    public func tick(at date: Date) async -> [String] {
        reconcileMissedRuns(now: date)
        let components = calendar.dateComponents([.hour, .minute, .weekday], from: date)
        guard let nowHour = components.hour, let nowMinute = components.minute, let weekday = components.weekday
        else { return [] }
        let schedules = (try? store.listSchedules()) ?? []
        let key = minuteKey(date)
        var fired: [String] = []
        for schedule in schedules {
            guard
                ScheduleEvaluator.isDue(
                    scheduleHour: schedule.hour, scheduleMinute: schedule.minute, weekdays: schedule.weekdays,
                    nowHour: nowHour, nowMinute: nowMinute, calendarWeekday: weekday)
            else { continue }
            if lastFiredMinute[schedule.containerName] == key { continue }  // already fired this minute
            lastFiredMinute[schedule.containerName] = key
            let outcome = await restart(schedule.containerName)
            try? store.recordScheduleRun(
                containerName: schedule.containerName, at: iso(date), outcome: outcome.dbOutcome,
                message: outcome.message)
            // A durable audit entry too, so every scheduled restart shows in the
            // server's Activity log — not just the transient last-run on the row.
            try? store.recordAudit(
                username: "scheduler", action: "container.schedules", containerName: schedule.containerName,
                outcome: outcome.dbOutcome == "ok" ? "ok" : "error", sourceIP: nil,
                detail: "scheduled restart: \(outcome.message)")
            fired.append(schedule.containerName)
        }
        return fired
    }

    /// Detects and surfaces a fire the daemon MISSED because it wasn't running at
    /// the fire time (the in-process scheduler, unlike launchd, only ticks while
    /// the daemon is up). For each schedule whose most recent due moment is newer
    /// than its last recorded run — and newer than when the schedule was created —
    /// records a durable "missed" run + audit entry, exactly once per missed slot.
    /// It never auto-fires the missed restart: starting a container the operator
    /// left stopped would violate the "never start containers at boot" rule, so a
    /// miss is made visible rather than silently acted on.
    private func reconcileMissedRuns(now: Date) {
        let schedules = (try? store.listSchedules()) ?? []
        for schedule in schedules {
            // Only a schedule that already existed can have missed a fire; an
            // unknown creation time (shouldn't happen post-migration) is not
            // flagged rather than risk a false alarm.
            guard let createdAt = parseISO(schedule.createdAt) else { continue }
            // Lower bound (exclusive): fires at/before the later of creation and
            // the last recorded run have already run or predate the schedule.
            let since = max(createdAt, parseISO(schedule.lastRunAt) ?? createdAt)
            // Every fire due in (since, now], EXCEPT the current minute — which the
            // normal tick is about to fire and so isn't a miss.
            let missed = ScheduleEvaluator.expectedFires(
                after: since, through: now, scheduleHour: schedule.hour, scheduleMinute: schedule.minute,
                weekdays: schedule.weekdays, calendar: calendar
            ).filter { minuteKey($0) != minuteKey(now) }
            guard let last = missed.last, let first = missed.first else { continue }  // nothing missed

            // ONE row per reconciliation, summarizing the whole outage: how many
            // fires were skipped and the window (first…last missed fire), so a
            // week-long outage is plainly distinct from a single skipped fire.
            let count = missed.count
            let when = String(format: "%02d:%02d", schedule.hour, schedule.minute)
            let message =
                count == 1
                ? "missed a scheduled restart at \(stamp(first)) (\(when)) — the panel was not running"
                : "missed \(count) scheduled restarts (\(when) daily) — the panel was down from "
                    + "\(stamp(first)) to \(stamp(last))"
            // last-run is stamped with the most recent missed slot, so the next
            // reconciliation's lower bound moves past it and never re-reports it.
            try? store.recordScheduleRun(
                containerName: schedule.containerName, at: iso(last), outcome: "missed", message: message)
            try? store.recordAudit(
                username: "scheduler", action: "container.schedules", containerName: schedule.containerName,
                outcome: "missed", sourceIP: nil, detail: message)
        }
    }

    /// A compact "YYYY-MM-DD HH:MM" stamp in the scheduler's calendar/timezone.
    private func stamp(_ date: Date) -> String {
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return String(
            format: "%04d-%02d-%02d %02d:%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0)
    }

    private func parseISO(_ string: String?) -> Date? {
        guard let string else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: string)
            ?? {
                let g = ISO8601DateFormatter()
                g.formatOptions = [.withInternetDateTime]
                return g.date(from: string)
            }()
    }

    /// Runs the loop until the task is cancelled. Wakes a few times a minute so a
    /// target minute is never skipped; `tick` dedupes the repeats.
    public func run(intervalSeconds: UInt64 = 20) async {
        while !Task.isCancelled {
            await tick(at: now())
            try? await Task.sleep(nanoseconds: intervalSeconds * 1_000_000_000)
        }
    }

    private func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }
}
