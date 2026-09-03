import Foundation
import Testing

@testable import MacerodactylKit

@Suite struct ScheduleEvaluatorTests {
    @Test func matchesExactTimeEveryDayWhenNoWeekdays() {
        // Empty weekdays = every day, so only hour+minute gate it.
        #expect(
            ScheduleEvaluator.isDue(
                scheduleHour: 4, scheduleMinute: 30, weekdays: [],
                nowHour: 4, nowMinute: 30, calendarWeekday: 3))
        #expect(
            !ScheduleEvaluator.isDue(
                scheduleHour: 4, scheduleMinute: 30, weekdays: [],
                nowHour: 4, nowMinute: 31, calendarWeekday: 3))
        #expect(
            !ScheduleEvaluator.isDue(
                scheduleHour: 4, scheduleMinute: 30, weekdays: [],
                nowHour: 5, nowMinute: 30, calendarWeekday: 3))
    }

    @Test func respectsWeekdaysWithLaunchdNumbering() {
        // launchd 0=Sun…6=Sat; Foundation calendar weekday is 1=Sun…7=Sat.
        // Schedule on Mon(1)/Wed(3). Calendar Monday = 2, Wednesday = 4.
        let weekdays: Set<Int> = [1, 3]
        #expect(
            ScheduleEvaluator.isDue(
                scheduleHour: 9, scheduleMinute: 0, weekdays: weekdays,
                nowHour: 9, nowMinute: 0, calendarWeekday: 2))  // Monday
        #expect(
            !ScheduleEvaluator.isDue(
                scheduleHour: 9, scheduleMinute: 0, weekdays: weekdays,
                nowHour: 9, nowMinute: 0, calendarWeekday: 3))  // Tuesday — not scheduled
        #expect(
            ScheduleEvaluator.isDue(
                scheduleHour: 9, scheduleMinute: 0, weekdays: weekdays,
                nowHour: 9, nowMinute: 0, calendarWeekday: 4))  // Wednesday
    }

    @Test func sundayMapsFromCalendarOne() {
        // Sunday: launchd 0, calendar 1.
        #expect(
            ScheduleEvaluator.isDue(
                scheduleHour: 0, scheduleMinute: 0, weekdays: [0],
                nowHour: 0, nowMinute: 0, calendarWeekday: 1))
        #expect(
            !ScheduleEvaluator.isDue(
                scheduleHour: 0, scheduleMinute: 0, weekdays: [0],
                nowHour: 0, nowMinute: 0, calendarWeekday: 7))  // Saturday
    }
}

@Suite struct InProcessSchedulerTests {
    private func store() throws -> PanelDataStore {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try PanelDataStore(databasePath: dir.appending(path: "s.sqlite").path)
    }

    /// A fixed UTC calendar so injected dates evaluate deterministically.
    private var utcCalendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func date(_ iso: String) -> Date {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone(identifier: "UTC")
        return f.date(from: iso)!
    }

    @Test func firesDueScheduleOncePerMinuteAndRecordsOutcome() async throws {
        let store = try store()
        try store.upsertSchedule(containerName: "bot", hour: 4, minute: 30, weekdays: [])
        let fireCount = Counter()
        let scheduler = InProcessScheduler(
            store: store, calendar: utcCalendar,
            restart: { name in
                await fireCount.bump(name)
                return .success("restarted \(name)")
            })

        // Two ticks within the same minute → fires once (idempotent wakeups).
        let t1 = date("2026-09-03T04:30:05Z")
        let t2 = date("2026-09-03T04:30:45Z")
        #expect(await scheduler.tick(at: t1) == ["bot"])
        #expect(await scheduler.tick(at: t2) == [])  // already fired this minute
        #expect(await fireCount.total == 1)

        // The run was recorded.
        #expect(try store.schedule(containerName: "bot")?.lastOutcome == "ok")

        // A tick a minute later at a non-matching time does nothing; the next
        // day's 04:30 fires again.
        #expect(await scheduler.tick(at: date("2026-09-03T04:31:00Z")) == [])
        #expect(await scheduler.tick(at: date("2026-09-04T04:30:10Z")) == ["bot"])
        #expect(await fireCount.total == 2)
    }

    @Test func doesNotFireOnAnUnscheduledWeekday() async throws {
        let store = try store()
        // Monday(1)/Fri(5) only. 2026-09-03 is a Thursday (calendar weekday 5).
        try store.upsertSchedule(containerName: "bot", hour: 8, minute: 0, weekdays: [1, 5])
        let fireCount = Counter()
        let scheduler = InProcessScheduler(
            store: store, calendar: utcCalendar,
            restart: { name in
                await fireCount.bump(name)
                return .success(name)
            })
        #expect(await scheduler.tick(at: date("2026-09-03T08:00:00Z")) == [])  // Thursday
        #expect(await scheduler.tick(at: date("2026-09-04T08:00:00Z")) == ["bot"])  // Friday
        #expect(await fireCount.total == 1)
    }

    @Test func surfacesAFireMissedWhileTheDaemonWasDown() async throws {
        // The schedule is created "now" (real time), but the scheduler's clock is
        // far in the future — so its 03:00 slot passed while nothing was running.
        let store = try store()
        try store.upsertSchedule(containerName: "bot", hour: 3, minute: 0, weekdays: [])
        let fireCount = Counter()
        let scheduler = InProcessScheduler(
            store: store, calendar: utcCalendar,
            restart: { name in
                await fireCount.bump(name)
                return .success(name)
            })

        // A tick at 09:00 sees that 03:00 was missed → records it, but does NOT
        // fire the restart (a missed restart is surfaced, never auto-run).
        _ = await scheduler.tick(at: date("2099-06-15T09:00:00Z"))
        #expect(await fireCount.total == 0)
        let row = try #require(try store.schedule(containerName: "bot"))
        #expect(row.lastOutcome == "missed")
        // It's durably in the audit trail too (survives the next run overwriting
        // the row), marked as a denial-class outcome.
        let audit = try store.listAudit(containerName: "bot")
        #expect(audit.contains { $0.action == "container.schedules" && $0.outcome == "missed" })

        // A second tick at the same time does NOT re-record the same miss.
        _ = await scheduler.tick(at: date("2099-06-15T09:00:00Z"))
        #expect(try store.listAudit(containerName: "bot").filter { $0.outcome == "missed" }.count == 1)
    }

    @Test func doesNotFlagTheCurrentMinuteAsMissedAndAuditsRealFires() async throws {
        let store = try store()
        try store.upsertSchedule(containerName: "bot", hour: 3, minute: 0, weekdays: [])
        let scheduler = InProcessScheduler(
            store: store, calendar: utcCalendar, restart: { _ in .success("ok") })
        // Ticking exactly at 03:00 fires normally and is NOT reported as missed.
        #expect(await scheduler.tick(at: date("2099-06-15T03:00:00Z")) == ["bot"])
        let audit = try store.listAudit(containerName: "bot")
        #expect(audit.contains { $0.action == "container.schedules" && $0.outcome == "ok" })
        #expect(!audit.contains { $0.outcome == "missed" })
    }

    @Test func lastExpectedFireFindsTheMostRecentPastSlot() {
        let cal = utcCalendar
        // Empty weekdays: yesterday's 04:30 when now is before today's 04:30.
        let before = date("2099-06-15T03:00:00Z")
        let e1 = ScheduleEvaluator.lastExpectedFire(
            before: before, scheduleHour: 4, scheduleMinute: 30, weekdays: [], calendar: cal)
        #expect(e1 == date("2099-06-14T04:30:00Z"))
        // After today's slot → today's.
        let e2 = ScheduleEvaluator.lastExpectedFire(
            before: date("2099-06-15T05:00:00Z"), scheduleHour: 4, scheduleMinute: 30, weekdays: [], calendar: cal)
        #expect(e2 == date("2099-06-15T04:30:00Z"))
    }

    @Test func recordsTimeoutOutcome() async throws {
        let store = try store()
        try store.upsertSchedule(containerName: "bot", hour: 1, minute: 0, weekdays: [])
        let scheduler = InProcessScheduler(
            store: store, calendar: utcCalendar,
            restart: { _ in .timedOut("hung") })
        #expect(await scheduler.tick(at: date("2026-09-03T01:00:00Z")) == ["bot"])
        #expect(try store.schedule(containerName: "bot")?.lastOutcome == "timedOut")
    }

    /// A tiny actor to count restart invocations across the concurrent closure.
    private actor Counter {
        private(set) var total = 0
        private(set) var byName: [String: Int] = [:]
        func bump(_ name: String) {
            total += 1
            byName[name, default: 0] += 1
        }
    }
}
