import Foundation

/// How a server should be stopped, derived from an egg's `config.stop`. Docker's
/// default `SIGTERM` can corrupt a save for games that expect a specific signal
/// or a console command; this maps the egg's intent into a compose `stop_signal`
/// + `stop_grace_period`, and records a stdin command when the egg stops that way
/// (sent to the process before falling back to the signal — wired in the console
/// work). Pure and unit-tested.
public struct ServerStop: Sendable, Equatable {
    /// A docker `stop_signal` (e.g. "SIGINT"), or nil to use docker's default.
    public var signal: String?
    /// Seconds docker waits before SIGKILL. Generous by default so a graceful
    /// shutdown (modern Minecraft traps SIGTERM) has time to finish.
    public var graceSeconds: Int?
    /// A console command (e.g. "stop", "end") to send to the server's stdin on
    /// shutdown. Non-nil for command-type eggs; used once the console can write.
    public var command: String?

    public init(signal: String? = nil, graceSeconds: Int? = nil, command: String? = nil) {
        self.signal = signal
        self.graceSeconds = graceSeconds
        self.command = command
    }

    /// Named signals an egg may specify directly.
    private static let knownSignals: Set<String> = [
        "SIGTERM", "SIGINT", "SIGKILL", "SIGQUIT", "SIGHUP", "SIGSTOP", "SIGTSTP",
    ]

    public static func from(configStop raw: String) -> ServerStop {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ServerStop() }

        // Caret notation: "^C" = Ctrl-C = SIGINT, "^\\" = SIGQUIT, "^Z" = SIGTSTP.
        if trimmed.hasPrefix("^") {
            let signal: String
            switch trimmed.uppercased() {
            case "^C": signal = "SIGINT"
            case "^\\": signal = "SIGQUIT"
            case "^Z": signal = "SIGTSTP"
            default: signal = "SIGINT"
            }
            return ServerStop(signal: signal, graceSeconds: 30)
        }

        // An explicit "SIG…" signal name. NOT bare words — common stop *commands*
        // (stop, quit, kill) are signal suffixes, so only a real SIG-prefixed
        // token counts as a signal; everything else is treated as a command.
        let upper = trimmed.uppercased()
        if upper.hasPrefix("SIG"), knownSignals.contains(upper) {
            return ServerStop(signal: upper, graceSeconds: 30)
        }

        // Otherwise it's a console command (e.g. "stop"). Keep docker's default
        // signal but give it room, and record the command for stdin delivery.
        return ServerStop(signal: nil, graceSeconds: 30, command: trimmed)
    }
}
