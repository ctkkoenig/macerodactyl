import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import MacerodactylKit
import Testing

@testable import MacerodactylPanel

/// The adversarial pass (T6.4): each test is an ATTACK that must fail. Together
/// they actively try to break every load-bearing boundary — identity, CSRF,
/// scoping, permission separation, injection — and assert it holds. See
/// docs/ADVERSARIAL.md for the full list of what was tried, including the
/// attacks that (correctly) got nowhere.
@Suite struct AdversarialTests {
    let base = PanelServerTests()
    func headers(_ token: String?, csrf: Bool = false, extra: [(HTTPField.Name, String)] = []) -> HTTPFields {
        var h = HTTPFields()
        if let token { h[.cookie] = "\(PanelSession.cookieName)=\(token)" }
        if csrf { h[PanelHeaders.csrf] = "1" }
        h[.contentType] = "application/json"
        for (k, v) in extra { h[k] = v }
        return h
    }

    /// Attack: forge identity via a proxy/remote-user header instead of a real
    /// session. Must be ignored — identity comes only from the session cookie.
    @Test func proxyHeadersCannotForgeIdentity() async throws {
        let harness = try await base.makeHarness()
        try await harness.app.test(.router) { client in
            let spoofs: [(HTTPField.Name, String)] = [
                (HTTPField.Name("X-Forwarded-User")!, "admin"),
                (HTTPField.Name("X-Remote-User")!, "admin"),
                (HTTPField.Name("X-Forwarded-For")!, "10.0.0.1"),
                (HTTPField.Name("X-Auth-Request-User")!, "admin"),
                (HTTPField.Name("Cf-Access-Authenticated-User-Email")!, "admin@example.com"),
            ]
            try await client.execute(uri: "/api/me", method: .get, headers: headers(nil, extra: spoofs)) {
                #expect($0.status == .unauthorized)  // no cookie ⇒ nobody, whatever the headers claim
            }
        }
    }

    /// Attack: present a made-up or malformed session cookie. Must not authenticate.
    @Test func forgedSessionCookiesAreRejected() async throws {
        let harness = try await base.makeHarness()
        try await harness.app.test(.router) { client in
            for fake in ["", "abcdef", String(repeating: "a", count: 200), "../../etc", "{\"user\":\"admin\"}"] {
                try await client.execute(uri: "/api/me", method: .get, headers: headers(fake)) {
                    #expect($0.status == .unauthorized)
                }
            }
        }
    }

    /// Attack: perform a mutating action without the CSRF header (a cross-site
    /// form post can't set custom headers). Must be blocked before the action.
    @Test func mutatingRequestsWithoutCSRFHeaderAreBlocked() async throws {
        let harness = try await base.makeHarness(scopedGrant: ContainerGrant(view: true, power: true, lifecycle: true))
        try await harness.app.test(.router) { client in
            let (_, cookie) = try await base.login(client, username: "scoped", password: harness.scopedPassword)
            let token = try #require(cookie)
            // Same request WITH csrf works; WITHOUT it is forbidden.
            try await client.execute(
                uri: "/api/containers/bot/power", method: .post, headers: headers(token, csrf: false),
                body: ByteBuffer(string: #"{"action":"restart"}"#)
            ) { #expect($0.status == .forbidden) }
            #expect(harness.service.powerCalls.isEmpty)  // never reached the service
        }
    }

    /// Attack: address containers with SQL metacharacters / injection payloads in
    /// the name. Must be treated as an (ungranted, non-existent) name → 404, and
    /// the database must be intact afterward (bound parameters, no injection).
    @Test func sqlInjectionInContainerNamesDoesNothing() async throws {
        let harness = try await base.makeHarness(scopedGrant: ContainerGrant(view: true))
        try await harness.app.test(.router) { client in
            let (_, cookie) = try await base.login(client, username: "scoped", password: harness.scopedPassword)
            let token = try #require(cookie)
            let payloads = [
                "'; DROP TABLE users;--", "' OR '1'='1", "bot' UNION SELECT * FROM users--",
                "%27%20OR%201=1", "bot\"; DELETE FROM grants;--",
            ]
            for p in payloads {
                let encoded = p.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? p
                try await client.execute(uri: "/api/containers/\(encoded)", method: .get, headers: headers(token)) {
                    #expect($0.status == .notFound)
                }
            }
            // The users + grants tables are intact — the scoped account still exists
            // and its grant still resolves. (Injection would have dropped them.)
            #expect(try harness.store.user(named: "scoped") != nil)
            #expect(try harness.store.user(named: "admin") != nil)
            #expect(try harness.store.grants(forUserID: harness.scoped.id)["bot"]?.view == true)
        }
    }

    /// Attack: a single-permission user tries every OTHER action, plus a container
    /// they aren't granted at all. Escalation must be impossible: 403 for a
    /// visible-but-forbidden action, 404 for an ungranted container.
    @Test func noPrivilegeEscalationAcrossTheMatrix() async throws {
        // scoped has files ONLY (plus the required view) on "bot".
        let harness = try await base.makeHarness(scopedGrant: ContainerGrant(view: true, files: true))
        try await harness.app.test(.router) { client in
            let (_, cookie) = try await base.login(client, username: "scoped", password: harness.scopedPassword)
            let token = try #require(cookie)
            // Actions requiring a permission the user lacks → 403.
            let forbidden: [(String, HTTPRequest.Method, String?)] = [
                ("/api/containers/bot/power", .post, #"{"action":"stop"}"#),
                ("/api/containers/bot/console", .post, #"{"command":"whoami"}"#),
                ("/api/containers/bot/schedule", .post, #"{"hour":1,"minute":0}"#),
                ("/api/containers/bot/pull", .post, nil),
                ("/api/containers/bot/remove", .delete, nil),
            ]
            for (uri, method, body) in forbidden {
                try await client.execute(
                    uri: uri, method: method, headers: headers(token, csrf: method != .get, extra: []),
                    body: body.map { ByteBuffer(string: $0) } ?? ByteBuffer()
                ) { #expect($0.status == .forbidden, "\(uri) must be 403 for a files-only user") }
            }
            // A container the user isn't granted at all → 404 (existence hidden),
            // and daemon-global maintenance → 404 (admin-only).
            try await client.execute(uri: "/api/containers/secret", method: .get, headers: headers(token)) {
                #expect($0.status == .notFound)
            }
            try await client.execute(uri: "/api/maintenance/disk", method: .get, headers: headers(token)) {
                #expect($0.status == .notFound)
            }
        }
    }
}
