import Foundation
import Hummingbird
import HummingbirdTesting
import MacerodactylKit
import Testing

@testable import MacerodactylPanel

/// End-to-end HTTP coverage for TOTP 2FA enrollment + login gating and for
/// session listing/revocation (T6.5).
@Suite struct TwoFactorAndSessionsTests {
    let base = PanelServerTests()

    private func jsonBody(_ buffer: ByteBuffer) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(buffer: buffer)) as? [String: Any] ?? [:]
    }
    private func headers(_ token: String, csrf: Bool = true) -> HTTPFields {
        var h: HTTPFields = [.cookie: "\(PanelSession.cookieName)=\(token)", .contentType: "application/json"]
        if csrf { h[PanelHeaders.csrf] = "1" }
        return h
    }

    @Test func totpEnrollmentGatesLoginThenCanBeDisabled() async throws {
        let harness = try await base.makeHarness()
        try await harness.app.test(.router) { client in
            let (_, cookie) = try await base.login(client, username: "scoped", password: harness.scopedPassword)
            let token = try #require(cookie)

            // begin → a secret + provisioning URI; status shows pending.
            var secret = ""
            try await client.execute(uri: "/api/2fa/begin", method: .post, headers: headers(token)) { r in
                #expect(r.status == .ok)
                let obj = try jsonBody(r.body)
                secret = obj["secret"] as! String
                #expect((obj["uri"] as! String).hasPrefix("otpauth://totp/"))
            }
            #expect(!secret.isEmpty)

            // confirm with a valid code → enabled.
            let code = TOTP.code(secret: secret)!
            try await client.execute(
                uri: "/api/2fa/confirm", method: .post, headers: headers(token),
                body: ByteBuffer(string: #"{"code":"\#(code)"}"#)
            ) { #expect($0.status == .ok) }
            try await client.execute(uri: "/api/2fa/status", method: .get, headers: headers(token, csrf: false)) { r in
                let enabled = try jsonBody(r.body)["enabled"] as? Bool
                #expect(enabled == true)
            }

            // Now a password-only login is refused with totpRequired…
            try await client.execute(
                uri: "/login", method: .post, headers: [.contentType: "application/json", PanelHeaders.csrf: "1"],
                body: ByteBuffer(string: #"{"username":"scoped","password":"\#(harness.scopedPassword)"}"#)
            ) { r in
                #expect(r.status == .ok)
                let totpRequired = try jsonBody(r.body)["totpRequired"] as? Bool
                #expect(totpRequired == true)
                #expect(r.headers[.setCookie] == nil)  // no session issued
            }
            // …a wrong code is unauthorized…
            try await client.execute(
                uri: "/login", method: .post, headers: [.contentType: "application/json", PanelHeaders.csrf: "1"],
                body: ByteBuffer(string: #"{"username":"scoped","password":"\#(harness.scopedPassword)","totp":"000000"}"#)
            ) { #expect($0.status == .unauthorized) }
            // …and a correct code logs in.
            try await client.execute(
                uri: "/login", method: .post, headers: [.contentType: "application/json", PanelHeaders.csrf: "1"],
                body: ByteBuffer(
                    string: #"{"username":"scoped","password":"\#(harness.scopedPassword)","totp":"\#(TOTP.code(secret: secret)!)"}"#)
            ) { r in
                #expect(r.status == .ok)
                #expect(r.headers[.setCookie] != nil)
            }

            // Disable requires a valid code; then login is password-only again.
            try await client.execute(
                uri: "/api/2fa/disable", method: .post, headers: headers(token),
                body: ByteBuffer(string: #"{"code":"000000"}"#)
            ) { #expect($0.status == .unauthorized) }
            try await client.execute(
                uri: "/api/2fa/disable", method: .post, headers: headers(token),
                body: ByteBuffer(string: #"{"code":"\#(TOTP.code(secret: secret)!)"}"#)
            ) { #expect($0.status == .ok) }
            try await client.execute(uri: "/api/2fa/status", method: .get, headers: headers(token, csrf: false)) { r in
                let enabled = try jsonBody(r.body)["enabled"] as? Bool
                #expect(enabled == false)
            }
        }
    }

    @Test func sessionsListAndRevoke() async throws {
        let harness = try await base.makeHarness()
        try await harness.app.test(.router) { client in
            // Two logins for the same user → two sessions.
            let (_, c1) = try await base.login(client, username: "scoped", password: harness.scopedPassword)
            let token1 = try #require(c1)
            let (_, c2) = try await base.login(client, username: "scoped", password: harness.scopedPassword)
            let token2 = try #require(c2)

            // From session 1, the list shows both, with session 1 flagged current.
            var ids: [String] = []
            try await client.execute(uri: "/api/sessions", method: .get, headers: headers(token1, csrf: false)) { r in
                let arr = try JSONSerialization.jsonObject(with: Data(buffer: r.body)) as! [[String: Any]]
                #expect(arr.count == 2)
                #expect(arr.contains { ($0["current"] as? Bool) == true })
                ids = arr.map { $0["id"] as! String }
            }

            // Revoke "others" from session 1 → session 2's token stops working.
            try await client.execute(uri: "/api/sessions/revoke-others", method: .post, headers: headers(token1)) {
                #expect($0.status == .ok)
            }
            try await client.execute(uri: "/api/me", method: .get, headers: headers(token2, csrf: false)) {
                #expect($0.status == .unauthorized)  // session 2 was revoked
            }
            try await client.execute(uri: "/api/me", method: .get, headers: headers(token1, csrf: false)) {
                #expect($0.status == .ok)  // session 1 (current) survived
            }
            _ = ids
        }
    }

    @Test func cannotRevokeAnotherUsersSession() async throws {
        let harness = try await base.makeHarness()
        try await harness.app.test(.router) { client in
            // admin logs in, gets their own session token hash to target.
            let (_, adminCookie) = try await base.login(client, username: "admin", password: harness.adminPassword)
            let adminToken = try #require(adminCookie)
            let adminHash = PanelSession.hashToken(adminToken)

            // scoped tries to revoke admin's session by its id → 404 (scoped delete).
            let (_, scopedCookie) = try await base.login(client, username: "scoped", password: harness.scopedPassword)
            let scopedToken = try #require(scopedCookie)
            try await client.execute(
                uri: "/api/sessions/\(adminHash)", method: .delete, headers: headers(scopedToken)
            ) { #expect($0.status == .notFound) }
            // admin's session still works.
            try await client.execute(uri: "/api/me", method: .get, headers: headers(adminToken, csrf: false)) {
                #expect($0.status == .ok)
            }
        }
    }
}
