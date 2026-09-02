import Foundation
import MacerodactylKit
import Testing

@testable import MacerodactylPanel

@Suite struct LoginRateLimiterTests {
    /// A controllable clock so backoff is tested without sleeping.
    final class Clock: @unchecked Sendable {
        var now = Date(timeIntervalSince1970: 1_000_000)
        func advance(_ seconds: TimeInterval) { now += seconds }
    }

    @Test func allowsUntilThresholdThenBlocks() async {
        let clock = Clock()
        let limiter = LoginRateLimiter(threshold: 3, baseDelay: 10, maxDelay: 600, now: { clock.now })
        // First three failures still allow a retry (no lockout yet).
        for _ in 0..<3 {
            #expect(await limiter.check(username: "alice", ip: "1.1.1.1").allowed)
            await limiter.recordFailure(username: "alice", ip: "1.1.1.1")
        }
        // Now locked out.
        let decision = await limiter.check(username: "alice", ip: "1.1.1.1")
        #expect(!decision.allowed)
        #expect(decision.retryAfter > 0)
    }

    @Test func backoffGrowsExponentiallyAndReleases() async {
        let clock = Clock()
        let limiter = LoginRateLimiter(threshold: 1, baseDelay: 10, maxDelay: 600, now: { clock.now })
        await limiter.recordFailure(username: "bob", ip: "2.2.2.2")  // 1 over → 10s
        #expect(await limiter.check(username: "bob", ip: "2.2.2.2").retryAfter == 10)
        await limiter.recordFailure(username: "bob", ip: "2.2.2.2")  // 2 over → 20s
        #expect(await limiter.check(username: "bob", ip: "2.2.2.2").retryAfter == 20)
        // After the lockout elapses, attempts are allowed again.
        clock.advance(21)
        #expect(await limiter.check(username: "bob", ip: "2.2.2.2").allowed)
    }

    @Test func accountAndIPAreIndependentKeys() async {
        let clock = Clock()
        let limiter = LoginRateLimiter(threshold: 1, baseDelay: 100, maxDelay: 600, now: { clock.now })
        // Fail alice from IP A enough to lock the account.
        await limiter.recordFailure(username: "alice", ip: "10.0.0.1")
        // A different user from the SAME ip is now also throttled (IP key).
        #expect(!(await limiter.check(username: "carol", ip: "10.0.0.1").allowed))
        // But alice from a fresh IP is only blocked by the account key.
        #expect(!(await limiter.check(username: "alice", ip: "10.0.0.9").allowed))
        // And an unrelated user from an unrelated IP is fine.
        #expect(await limiter.check(username: "dave", ip: "10.0.0.9").allowed)
    }

    /// Security review #3: behind a tunnel every peer is loopback, so the IP
    /// bucket must NOT throttle — otherwise five bad logins lock out everyone.
    /// The per-account bucket must still work.
    @Test func loopbackIPIsExemptButAccountStillThrottles() async {
        let clock = Clock()
        let limiter = LoginRateLimiter(threshold: 1, baseDelay: 100, maxDelay: 600, now: { clock.now })
        // alice fails from loopback → her account locks, but the shared IP bucket must not.
        await limiter.recordFailure(username: "alice", ip: "127.0.0.1")
        #expect(!(await limiter.check(username: "alice", ip: "127.0.0.1").allowed))  // account locked
        // A DIFFERENT user from the same loopback peer is NOT collateral-damaged.
        #expect(await limiter.check(username: "carol", ip: "127.0.0.1").allowed)
        #expect(await limiter.check(username: "dave", ip: "::1").allowed)
    }

    @Test func successClearsThrottle() async {
        let clock = Clock()
        let limiter = LoginRateLimiter(threshold: 1, baseDelay: 100, maxDelay: 600, now: { clock.now })
        await limiter.recordFailure(username: "eve", ip: "3.3.3.3")
        #expect(!(await limiter.check(username: "eve", ip: "3.3.3.3").allowed))
        await limiter.recordSuccess(username: "eve", ip: "3.3.3.3")
        #expect(await limiter.check(username: "eve", ip: "3.3.3.3").allowed)
    }
}

@Suite struct PasswordHasherTests {
    @Test func hashVerifyRoundTrip() async {
        let hash = await PasswordHasher.hash("correct horse battery staple")
        #expect(await PasswordHasher.verify("correct horse battery staple", hash: hash))
        #expect(!(await PasswordHasher.verify("wrong password", hash: hash)))
    }

    @Test func longPasswordsBeyond72BytesAreNotTruncated() async {
        // Two passwords identical for the first 72 bytes but differing after.
        // Without the SHA-256 prehash, bcrypt would treat them as equal.
        let base = String(repeating: "a", count: 72)
        let hash = await PasswordHasher.hash(base + "TAIL-ONE")
        #expect(await PasswordHasher.verify(base + "TAIL-ONE", hash: hash))
        #expect(!(await PasswordHasher.verify(base + "TAIL-TWO", hash: hash)))
    }

    @Test func usesCostFactor12() async {
        let hash = await PasswordHasher.hash("x")
        // bcrypt hash format: $2b$12$...
        #expect(hash.hasPrefix("$2b$12$") || hash.hasPrefix("$2a$12$") || hash.hasPrefix("$2y$12$"))
    }
}

@Suite struct SessionTokenTests {
    @Test func tokensAreRandomAndURLSafe() {
        let a = PanelSession.newToken()
        let b = PanelSession.newToken()
        #expect(a != b)
        #expect(!a.contains("+") && !a.contains("/") && !a.contains("="))
    }

    @Test func tokenHashIsStableAndNotTheToken() {
        let token = PanelSession.newToken()
        #expect(PanelSession.hashToken(token) == PanelSession.hashToken(token))
        #expect(PanelSession.hashToken(token) != token)
        #expect(PanelSession.hashToken(token).count == 64)  // hex SHA-256
    }
}

@Suite struct RateLimitPersistenceTests {
    private func tempStore() throws -> (PanelDataStore, String) {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appending(path: "rl.sqlite").path
        return (try PanelDataStore(databasePath: path), path)
    }

    @Test func lockoutSurvivesRestart() async throws {
        let (store, path) = try tempStore()
        let clock = RateLimiterClock()
        // Lock out "mallory" with a long backoff.
        let limiter = LoginRateLimiter(
            store: SQLiteRateLimitStore(store: store),
            threshold: 1, baseDelay: 100, maxDelay: 600, now: { clock.now })
        await limiter.recordFailure(username: "mallory", ip: "9.9.9.9")
        #expect(!(await limiter.check(username: "mallory", ip: "1.1.1.1").allowed))  // account locked

        // "Restart": a brand-new limiter over a brand-new store on the SAME file.
        let store2 = try PanelDataStore(databasePath: path)
        let limiter2 = LoginRateLimiter(
            store: SQLiteRateLimitStore(store: store2),
            threshold: 1, baseDelay: 100, maxDelay: 600, now: { clock.now })
        // The lockout is still in effect — a restart is NOT a brute-force reset.
        let decision = await limiter2.check(username: "mallory", ip: "1.1.1.1")
        #expect(!decision.allowed)
        #expect(decision.retryAfter > 0)

        // A correct password clears it, persistently.
        await limiter2.recordSuccess(username: "mallory", ip: "9.9.9.9")
        let store3 = try PanelDataStore(databasePath: path)
        let limiter3 = LoginRateLimiter(store: SQLiteRateLimitStore(store: store3), now: { clock.now })
        #expect(await limiter3.check(username: "mallory", ip: "1.1.1.1").allowed)
    }
}

private final class RateLimiterClock: @unchecked Sendable {
    var now = Date(timeIntervalSince1970: 2_000_000)
}
