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

    /// One evaluation pass: fire every schedule due at `date` that hasn't already
    /// fired this minute, recording each outcome. Returns the containers fired
    /// (for tests/telemetry).
    @discardableResult
    public func tick(at date: Date) async -> [String] {
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
            fired.append(schedule.containerName)
        }
        return fired
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
