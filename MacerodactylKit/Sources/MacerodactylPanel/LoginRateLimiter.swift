import Foundation

/// Throttles failed logins on two independent keys — the account (username) and
/// the source IP — so neither a single account nor a single host can be brute
/// forced. Backoff grows with consecutive failures and resets on success.
public actor LoginRateLimiter {
    public struct Decision: Sendable, Equatable {
        public let allowed: Bool
        public let retryAfter: TimeInterval
    }

    private struct Bucket {
        var failures: Int = 0
        var blockedUntil: Date?
    }

    private var accounts: [String: Bucket] = [:]
    private var ips: [String: Bucket] = [:]

    /// Failures before backoff begins.
    let threshold: Int
    /// First lockout once past the threshold.
    let baseDelay: TimeInterval
    /// Ceiling on the exponential backoff.
    let maxDelay: TimeInterval
    private let now: @Sendable () -> Date

    public init(
        threshold: Int = 5,
        baseDelay: TimeInterval = 5,
        maxDelay: TimeInterval = 300,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.threshold = threshold
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
        self.now = now
    }

    /// Whether a login attempt may proceed. Blocked if *either* the account or
    /// the IP is currently locked out; the longer remaining lockout is returned.
    public func check(username: String, ip: String) -> Decision {
        let current = now()
        let accountRemaining = remaining(accounts[key(username)], at: current)
        let ipRemaining = remaining(ips[ip], at: current)
        let worst = max(accountRemaining, ipRemaining)
        return Decision(allowed: worst <= 0, retryAfter: max(worst, 0))
    }

    /// Records a failed attempt against both keys and arms backoff past the
    /// threshold: delay = baseDelay * 2^(failures - threshold), capped.
    public func recordFailure(username: String, ip: String) {
        bump(&accounts[key(username), default: Bucket()])
        bump(&ips[ip, default: Bucket()])
    }

    /// Clears both keys — a correct password ends the throttling.
    public func recordSuccess(username: String, ip: String) {
        accounts[key(username)] = nil
        ips[ip] = nil
    }

    private func bump(_ bucket: inout Bucket) {
        bucket.failures += 1
        if bucket.failures >= threshold {
            let steps = bucket.failures - threshold
            let delay = min(baseDelay * pow(2, Double(steps)), maxDelay)
            bucket.blockedUntil = now().addingTimeInterval(delay)
        }
    }

    private func remaining(_ bucket: Bucket?, at date: Date) -> TimeInterval {
        guard let until = bucket?.blockedUntil else { return 0 }
        return until.timeIntervalSince(date)
    }

    private func key(_ username: String) -> String { username.lowercased() }
}
