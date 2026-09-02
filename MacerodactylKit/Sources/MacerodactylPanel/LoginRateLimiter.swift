import Foundation
import MacerodactylKit

/// One throttling bucket: how many consecutive failures, and until when the key
/// is locked out.
public struct RateBucket: Sendable, Equatable {
    public var failures: Int
    public var blockedUntil: Date?
    public init(failures: Int = 0, blockedUntil: Date? = nil) {
        self.failures = failures
        self.blockedUntil = blockedUntil
    }
}

/// Where the rate limiter keeps its buckets. Two backends: in-memory (fast, for
/// tests) and SQLite (production — survives a restart so a restart isn't a
/// brute-force reset). Implementations are self-synchronizing and swallow their
/// own storage errors: a rate-limit read/write failing must never crash or
/// block a login (auth still requires the correct password).
public protocol RateLimitStore: Sendable {
    func bucket(_ key: String) -> RateBucket?
    func setBucket(_ key: String, _ bucket: RateBucket)
    func clear(_ key: String)
}

/// In-memory backend (used by tests and as a fallback).
public final class InMemoryRateLimitStore: RateLimitStore, @unchecked Sendable {
    private let lock = NSLock()
    private var buckets: [String: RateBucket] = [:]
    public init() {}
    public func bucket(_ key: String) -> RateBucket? { lock.withLock { buckets[key] } }
    public func setBucket(_ key: String, _ bucket: RateBucket) { lock.withLock { buckets[key] = bucket } }
    public func clear(_ key: String) { lock.withLock { buckets[key] = nil } }
}

/// SQLite-backed backend so throttling survives a process restart.
public struct SQLiteRateLimitStore: RateLimitStore {
    let store: PanelDataStore

    public init(store: PanelDataStore) { self.store = store }

    // Thread-safe for formatting; options set once and never mutated.
    nonisolated(unsafe) private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    public func bucket(_ key: String) -> RateBucket? {
        guard let row = try? store.rateLimit(key: key) else { return nil }
        let until = row.blockedUntilISO.flatMap { Self.iso.date(from: $0) }
        return RateBucket(failures: row.failures, blockedUntil: until)
    }

    public func setBucket(_ key: String, _ bucket: RateBucket) {
        try? store.setRateLimit(
            key: key, failures: bucket.failures,
            blockedUntilISO: bucket.blockedUntil.map { Self.iso.string(from: $0) })
    }

    public func clear(_ key: String) {
        try? store.clearRateLimit(key: key)
    }
}

/// Throttles failed logins on two independent keys — the account (username) and
/// the source IP — so neither a single account nor a single host can be brute
/// forced. Backoff grows with consecutive failures and resets on success. State
/// lives in the injected `RateLimitStore`.
public actor LoginRateLimiter {
    public struct Decision: Sendable, Equatable {
        public let allowed: Bool
        public let retryAfter: TimeInterval
    }

    private let store: RateLimitStore
    let threshold: Int
    let baseDelay: TimeInterval
    let maxDelay: TimeInterval
    private let now: @Sendable () -> Date

    public init(
        store: RateLimitStore = InMemoryRateLimitStore(),
        threshold: Int = 5,
        baseDelay: TimeInterval = 5,
        maxDelay: TimeInterval = 300,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.threshold = threshold
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
        self.now = now
    }

    private func accountKey(_ username: String) -> String { "acct:\(username.lowercased())" }
    private func ipKey(_ ip: String) -> String { "ip:\(ip)" }

    /// Whether a login attempt may proceed. Blocked if *either* the account or
    /// the IP is currently locked out; the longer remaining lockout is returned.
    public func check(username: String, ip: String) -> Decision {
        let current = now()
        let worst = max(
            remaining(store.bucket(accountKey(username)), at: current),
            remaining(store.bucket(ipKey(ip)), at: current))
        return Decision(allowed: worst <= 0, retryAfter: max(worst, 0))
    }

    /// Records a failed attempt against both keys and arms backoff past the
    /// threshold: delay = baseDelay * 2^(failures - threshold), capped.
    public func recordFailure(username: String, ip: String) {
        bump(accountKey(username))
        bump(ipKey(ip))
    }

    /// Clears both keys — a correct password ends the throttling.
    public func recordSuccess(username: String, ip: String) {
        store.clear(accountKey(username))
        store.clear(ipKey(ip))
    }

    private func bump(_ key: String) {
        var bucket = store.bucket(key) ?? RateBucket()
        bucket.failures += 1
        if bucket.failures >= threshold {
            let steps = bucket.failures - threshold
            let delay = min(baseDelay * pow(2, Double(steps)), maxDelay)
            bucket.blockedUntil = now().addingTimeInterval(delay)
        }
        store.setBucket(key, bucket)
    }

    private func remaining(_ bucket: RateBucket?, at date: Date) -> TimeInterval {
        guard let until = bucket?.blockedUntil else { return 0 }
        return until.timeIntervalSince(date)
    }
}
