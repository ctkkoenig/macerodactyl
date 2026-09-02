import Foundation
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
