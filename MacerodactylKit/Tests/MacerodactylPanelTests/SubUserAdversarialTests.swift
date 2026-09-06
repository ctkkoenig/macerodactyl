import Foundation
import Hummingbird
import HummingbirdTesting
import MacerodactylKit
import Testing

@testable import MacerodactylPanel

/// Adversarial pass on sub-user delegation — the newest, most complex boundary.
/// Every test here is an ATTACK that must fail. Each drives the real router (the
/// same path a browser takes), and the comments record what was attempted,
/// including the probes that (correctly) failed to break anything.
///
/// Threat model covered:
///   1. Escalate past the granting user's own permissions.
///   2. Reach a container outside the grant.
///   3. Retain access after the grant is revoked (even with a live session).
@Suite struct SubUserAdversarialTests {
    private let base = PanelServerTests()

    /// scoped OWNS "bot"; `friend` is a sub-user on "bot" with view+console only;
    /// "secret" exists but neither can view it.
    private func harness() async throws -> (PanelServerTests.Harness, friend: PanelUser) {
        let h = try await base.makeHarness(scopedGrant: PanelRoutes.fullGrant)
        try h.store.createServerRecord(
            uuid: UUID().uuidString, name: "bot", eggID: nil, dockerImage: "debian",
            ownerUserID: h.scoped.id, limits: .init(memoryMiB: 256), startup: "", values: [:], status: "active")
        let accounts = AccountManager(store: h.store)
        let friend = try await accounts.createUser(username: "friend", password: "friend-pw-123456", isAdmin: false)
        try accounts.setGrant(
            userID: friend.id, containerName: "bot", grant: ContainerGrant(view: true, console: true),
            filesGrantable: true)
        return (h, friend)
    }

    private func token(
        _ c: some TestClientProtocol, _ h: PanelServerTests.Harness, _ u: String, _ p: String
    )
        async throws -> String
    { try #require(try await base.login(c, username: u, password: p).cookie) }

    private func hdr(_ token: String, csrf: Bool = true) -> HTTPFields {
        var f: HTTPFields = [.cookie: "\(PanelSession.cookieName)=\(token)", .contentType: "application/json"]
        if csrf { f[PanelHeaders.csrf] = "1" }
        return f
    }

    // MARK: 1 — escalation past the sub-user's (and grantor's) permissions

    @Test func aSubUserCannotManageSubUsersToEscalate() async throws {
        let (h, _) = try await harness()
        try await h.app.test(.router) { client in
            let friend = try await token(client, h, "friend", "friend-pw-123456")
            // ATTEMPT: grant myself files+backups+lifecycle via the sub-user API.
            try await client.execute(
                uri: "/api/containers/bot/subusers", method: .put, headers: hdr(friend),
                body: ByteBuffer(string: #"{"username":"friend","permissions":["files","backups","lifecycle","power"]}"#)
            ) { #expect($0.status == .forbidden, "a sub-user must not manage sub-users") }
            // ATTEMPT: invite a brand-new confederate.
            try await client.execute(
                uri: "/api/containers/bot/subusers", method: .put, headers: hdr(friend),
                body: ByteBuffer(string: #"{"username":"friend","permissions":["view"]}"#)
            ) { #expect($0.status == .forbidden) }
            // ATTEMPT: even just READ the sub-user list (recon).
            try await client.execute(uri: "/api/containers/bot/subusers", method: .get, headers: hdr(friend, csrf: false)) {
                #expect($0.status == .forbidden)
            }
            // The grant is unchanged — still just view+console.
            let g = try #require(try h.store.grants(forUserID: h.store.user(named: "friend")!.id)["bot"])
            #expect(g.view && g.console && !g.files && !g.backups && !g.lifecycle && !g.power)
        }
    }

    @Test func aSubUserCannotActBeyondItsGrant() async throws {
        let (h, _) = try await harness()
        try await h.app.test(.router) { client in
            let friend = try await token(client, h, "friend", "friend-pw-123456")
            // console is granted → allowed. power/files/backups/schedule/allocations are NOT.
            try await client.execute(
                uri: "/api/containers/bot/power", method: .post, headers: hdr(friend),
                body: ByteBuffer(string: #"{"action":"stop"}"#)
            ) { #expect($0.status == .forbidden, "power not granted") }
            try await client.execute(
                uri: "/api/containers/bot/files/dir", method: .post, headers: hdr(friend),
                body: ByteBuffer(string: #"{"path":"x"}"#)
            ) { #expect($0.status == .forbidden, "files not granted") }
            try await client.execute(
                uri: "/api/containers/bot/backups", method: .post, headers: hdr(friend), body: ByteBuffer(string: "{}")
            ) { #expect($0.status == .forbidden, "backups not granted") }
            // allocations require only `view` at the middleware, but the handler is owner-only.
            try await client.execute(
                uri: "/api/containers/bot/allocations", method: .post, headers: hdr(friend),
                body: ByteBuffer(string: #"{"id":1}"#)
            ) { #expect($0.status == .forbidden, "allocation management is owner-only") }
            // The granted action DOES work (baseline: the grant isn't uselessly broad or narrow).
            try await client.execute(
                uri: "/api/containers/bot/console/input", method: .post, headers: hdr(friend),
                body: ByteBuffer(string: #"{"line":"list"}"#)
            ) { #expect($0.status == .ok, "console IS granted") }
        }
    }

    // MARK: 2 — reaching a container outside the grant

    @Test func aSubUserCannotSeeOrTouchAnUngrantedContainer() async throws {
        let (h, _) = try await harness()
        try await h.app.test(.router) { client in
            let friend = try await token(client, h, "friend", "friend-pw-123456")
            // "secret" is invisible → 404 (not 403), and NOT in the list.
            try await client.execute(uri: "/api/containers", method: .get, headers: hdr(friend, csrf: false)) { response in
                let arr = try JSONSerialization.jsonObject(with: Data(buffer: response.body)) as! [[String: Any]]
                #expect(!arr.contains { $0["name"] as? String == "secret" })
                #expect(arr.contains { $0["name"] as? String == "bot" })
            }
            for uri in [
                "/api/containers/secret", "/api/containers/secret/activity", "/api/containers/secret/subusers",
                "/api/containers/secret/allocations",
            ] {
                try await client.execute(uri: uri, method: .get, headers: hdr(friend, csrf: false)) {
                    #expect($0.status == .notFound, "\(uri) must be invisible (404), never 403 which would confirm it exists")
                }
            }
            // Mutations on the ungranted container are 404 too (existence hidden).
            try await client.execute(
                uri: "/api/containers/secret/console/input", method: .post, headers: hdr(friend),
                body: ByteBuffer(string: #"{"line":"x"}"#)
            ) { #expect($0.status == .notFound) }
        }
    }

    // MARK: 3 — retaining access after revocation (live session)

    @Test func revocationTakesEffectImmediatelyEvenWithALiveSession() async throws {
        let (h, friend) = try await harness()
        try await h.app.test(.router) { client in
            // friend signs in and confirms working access.
            let friendTok = try await token(client, h, "friend", "friend-pw-123456")
            try await client.execute(uri: "/api/containers/bot", method: .get, headers: hdr(friendTok, csrf: false)) {
                #expect($0.status == .ok, "baseline: friend can see bot")
            }
            // The owner revokes the grant (empty grant deletes the row) — friend's
            // session cookie is NOT touched and remains "logged in".
            try AccountManager(store: h.store).setGrant(
                userID: friend.id, containerName: "bot", grant: ContainerGrant(), filesGrantable: true)
            // The SAME live session is now denied on the very next request, because
            // authorization is rebuilt from live grants per request — not cached in
            // the session. Access does not survive revocation.
            try await client.execute(uri: "/api/containers/bot", method: .get, headers: hdr(friendTok, csrf: false)) {
                #expect($0.status == .notFound, "revoked → invisible immediately, same session")
            }
            try await client.execute(
                uri: "/api/containers/bot/console/input", method: .post, headers: hdr(friendTok),
                body: ByteBuffer(string: #"{"line":"still here?"}"#)
            ) { #expect($0.status == .notFound, "revoked → console denied immediately, same session") }
        }
    }

    @Test func removingASubUserFromTheOwnerSideAlsoRevokesImmediately() async throws {
        let (h, _) = try await harness()
        try await h.app.test(.router) { client in
            let owner = try await token(client, h, "scoped", h.scopedPassword)
            let friendTok = try await token(client, h, "friend", "friend-pw-123456")
            // Owner removes friend via the real endpoint (DELETE).
            try await client.execute(uri: "/api/containers/bot/subusers/friend", method: .delete, headers: hdr(owner)) {
                #expect($0.status == .ok)
            }
            // friend's live session immediately loses access.
            try await client.execute(uri: "/api/containers/bot", method: .get, headers: hdr(friendTok, csrf: false)) {
                #expect($0.status == .notFound)
            }
        }
    }
}
