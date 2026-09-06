import Foundation

/// One running copy of the app, reduced to what the single-instance election
/// needs: its process id and when it launched (nil if the OS won't say).
public struct InstanceInfo: Sendable, Equatable {
    public let processIdentifier: Int32
    public let launchDate: Date?
    public init(processIdentifier: Int32, launchDate: Date?) {
        self.processIdentifier = processIdentifier
        self.launchDate = launchDate
    }
}

/// Decides which of several running copies of the same bundle should survive, so
/// exactly one always does. Pure and total (no OS calls, no `exit`) so it is unit
/// testable; `AppDelegate` feeds it `NSRunningApplication` values and acts on the
/// result.
///
/// The order, from the earliest-launched surviving:
/// - **Earlier `launchDate` wins**, compared with strict `<`. Two copies with the
///   *same* date do not both yield — the tie falls through to the pid.
/// - **A nil `launchDate` is treated as "not earlier"**: it sorts after every
///   known date, so a same-bundle process that reports no launch date can never
///   make the live instance yield to it.
/// - **Ties break on the lower `processIdentifier`.** Deterministic and shared by
///   both copies, so they agree on the same survivor.
public enum SingleInstanceElection {
    /// The single instance that should survive among `instances`, or nil if the
    /// list is empty. Every caller passing the same set gets the same answer.
    public static func survivor(among instances: [InstanceInfo]) -> InstanceInfo? {
        instances.min { a, b in isEarlier(a, than: b) }
    }

    /// Whether `current` should defer (quit) given the other running copies —
    /// true exactly when some *other* instance is the elected survivor.
    public static func shouldDefer(current: InstanceInfo, others: [InstanceInfo]) -> Bool {
        survivingOther(current: current, others: others) != nil
    }

    /// The specific other instance `current` should activate before quitting, or
    /// nil when `current` itself is the survivor (and so must not quit). This is
    /// the instance to bring to the front — never an arbitrary one.
    public static func survivingOther(current: InstanceInfo, others: [InstanceInfo]) -> InstanceInfo? {
        guard let winner = survivor(among: [current] + others) else { return nil }
        return winner.processIdentifier == current.processIdentifier ? nil : winner
    }

    /// Strict "a launched before b" for the election order: earlier date first
    /// (nil date = latest), ties broken by lower pid.
    private static func isEarlier(_ a: InstanceInfo, than b: InstanceInfo) -> Bool {
        let aDate = a.launchDate ?? .distantFuture
        let bDate = b.launchDate ?? .distantFuture
        if aDate != bDate { return aDate < bDate }
        return a.processIdentifier < b.processIdentifier
    }
}
