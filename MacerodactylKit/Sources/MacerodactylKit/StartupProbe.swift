import Foundation

/// Distinguishes a server that is booting ("starting") from one that has finished
/// and is ready ("online") — the state Pterodactyl shows while an egg runs its
/// startup before the "Done" line appears. Pure and on-demand: no background log
/// watcher, so there is nothing to leak or supervise.
public enum StartupProbe {
    public enum State: String, Sendable, Equatable {
        case starting
        case online
    }

    /// Whether any of the egg's done markers appears in the log text. Pterodactyl
    /// treats `config.startup.done` as a plain substring (parkervcp eggs use
    /// literals like ")! For help,"), so this is a case-sensitive contains.
    public static func isDone(logText: String, doneStrings: [String]) -> Bool {
        let markers = doneStrings.filter { !$0.isEmpty }
        guard !markers.isEmpty else { return false }
        return markers.contains { logText.contains($0) }
    }

    /// The startup state of a RUNNING container:
    /// - `online` if a done marker is in the recent log, OR the container has been
    ///   up past `graceSeconds` (the done line likely scrolled out of the tail —
    ///   a server up for minutes is not still "starting").
    /// - `starting` otherwise.
    /// Callers only invoke this when the egg actually declares done markers; with
    /// none, there is no "starting" phase to show.
    public static func evaluate(
        logText: String, doneStrings: [String], uptimeSeconds: Double?, graceSeconds: Double = 180
    ) -> State {
        if isDone(logText: logText, doneStrings: doneStrings) { return .online }
        if let uptimeSeconds, uptimeSeconds > graceSeconds { return .online }
        return .starting
    }
}
