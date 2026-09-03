import Foundation

/// One step in a schedule's task chain. A schedule with no tasks keeps the legacy
/// behavior (a single restart); with tasks, they run in `seq` order when the
/// schedule fires — e.g. "say restarting → wait 60s → back up → restart".
public struct ScheduleTask: Sendable, Equatable, Identifiable {
    public enum Action: String, Sendable, Codable, CaseIterable {
        /// payload is the power action: "start" | "stop" | "restart".
        case power
        /// payload is a line to send to the server console.
        case command
        /// payload is an optional backup name.
        case backup
    }

    public var id: Int64
    /// Execution order within the chain (0-based, ascending).
    public var seq: Int
    public var action: Action
    public var payload: String
    /// Seconds to wait BEFORE running this step (relative to the previous one),
    /// so a chain can pace itself — e.g. warn players, wait, then restart.
    public var offsetSeconds: Int

    public init(id: Int64 = 0, seq: Int, action: Action, payload: String, offsetSeconds: Int = 0) {
        self.id = id
        self.seq = seq
        self.action = action
        self.payload = payload
        self.offsetSeconds = offsetSeconds
    }

    /// The valid power payloads.
    public static let powerActions = ["start", "stop", "restart"]
    /// A wait longer than this is almost certainly a mistake; clamp defensively so
    /// one bad task can't park the chain for days.
    public static let maxOffsetSeconds = 86_400

    /// A cleaned-up copy with the offset clamped and the power payload lowercased,
    /// or nil if the task is invalid (unknown power action / empty command). The
    /// route uses this to reject bad input before it is stored.
    public func validated() -> ScheduleTask? {
        let offset = min(max(offsetSeconds, 0), Self.maxOffsetSeconds)
        switch action {
        case .power:
            let p = payload.lowercased()
            guard Self.powerActions.contains(p) else { return nil }
            return ScheduleTask(id: id, seq: seq, action: .power, payload: p, offsetSeconds: offset)
        case .command:
            let line = payload
            guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return ScheduleTask(id: id, seq: seq, action: .command, payload: line, offsetSeconds: offset)
        case .backup:
            return ScheduleTask(id: id, seq: seq, action: .backup, payload: payload, offsetSeconds: offset)
        }
    }
}
