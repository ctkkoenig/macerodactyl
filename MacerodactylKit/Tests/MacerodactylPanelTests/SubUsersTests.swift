import Foundation
import Hummingbird
import HummingbirdTesting
import MacerodactylKit
import Testing

@testable import MacerodactylPanel

/// The owner-managed sub-user surface — access delegation, THE multi-user
/// boundary. Verifies that only the owner (or an admin) can hand out access,
/// that a delegated grant never exceeds what was asked, and that the owner and
/// admins can't be mishandled as sub-users.
@Suite struct SubUsersTests {
    private let base = PanelServerTests()

    /// A harness where `scoped` OWNS "bot" (via a server record), plus a plain
    /// `friend` account (no grant) and a `helper` account granted view-only.
    private func makeOwnedHarness() async throws -> (PanelServerTests.Harness, friend: PanelUser, helper: PanelUser) {
        let h = try await base.makeHarness(scopedGrant: PanelRoutes.fullGrant)
        let accounts = AccountManager(store: h.store)
        try h.store.createServerRecord(
            uuid: UUID().uuidString, name: "bot", eggID: nil, dockerImage: "debian",
            ownerUserID: h.scoped.id, limits: .init(memoryMiB: 256), startup: "", values: [:], status: "active")
        let friend = try await accounts.createUser(username: "friend", password: "friend-pw-123456", isAdmin: false)
        let helper = try await accounts.createUser(username: "helper", password: "helper-pw-123456", isAdmin: false)
        try accounts.setGrant(
            userID: helper.id, containerName: "bot", grant: ContainerGrant(view: true), filesGrantable: true)
        return (h, friend, helper)
    }

    private func token(
        _ client: some TestClientProtocol, _ h: PanelServerTests.Harness, _ user: String, _ pw: String
    )
        async throws -> String
    {
        try #require(try await base.login(client, username: user, password: pw).cookie)
    }

    private func authed(_ token: String, csrf: Bool = true) -> HTTPFields {
        var f: HTTPFields = [.cookie: "\(PanelSession.cookieName)=\(token)", .contentType: "application/json"]
        if csrf { f[PanelHeaders.csrf] = "1" }
        return f
    }

    @Test func ownerGrantsExactlyTheRequestedSubset() async throws {
        let (h, friend, _) = try await makeOwnedHarness()
        try await h.app.test(.router) { client in
            let owner = try await token(client, h, "scoped", h.scopedPassword)
            let body = ByteBuffer(string: #"{"username":"friend","permissions":["console","power"]}"#)
            try await client.execute(uri: "/api/containers/bot/subusers", method: .put, headers: authed(owner), body: body) {
                #expect($0.status == .ok)
            }
            let grant = try #require(try h.store.grants(forUserID: friend.id)["bot"])
            #expect(grant.view && grant.console && grant.power)  // view implied
            #expect(!grant.files && !grant.backups && !grant.schedules && !grant.lifecycle)

            // And the list reflects it (owner excluded, friend present).
            try await client.execute(uri: "/api/containers/bot/subusers", method: .get, headers: authed(owner, csrf: false)) {
                let json = try JSONSerialization.jsonObject(with: Data(buffer: $0.body)) as! [String: Any]
                #expect(json["canManage"] as? Bool == true)
                let subs = json["subusers"] as! [[String: Any]]
                let names = subs.map { $0["username"] as! String }
                #expect(names.contains("friend"))
                #expect(!names.contains("scoped"))  // the owner is not a sub-user
                let friendRow = subs.first { $0["username"] as! String == "friend" }!
                let perms = Set(friendRow["permissions"] as! [String])
                #expect(perms == ["power", "console"])
            }
        }
    }

    @Test func nonOwnerNonAdminCannotManage() async throws {
        let (h, _, _) = try await makeOwnedHarness()
        try await h.app.test(.router) { client in
            // helper has a view grant on bot but does not own it.
            let helperTok = try await token(client, h, "helper", "helper-pw-123456")
            try await client.execute(uri: "/api/containers/bot/subusers", method: .get, headers: authed(helperTok, csrf: false)) {
                #expect($0.status == .forbidden)
            }
            let body = ByteBuffer(string: #"{"username":"friend","permissions":["console"]}"#)
            try await client.execute(uri: "/api/containers/bot/subusers", method: .put, headers: authed(helperTok), body: body) {
                #expect($0.status == .forbidden)
            }
            try await client.execute(uri: "/api/containers/bot/subusers/friend", method: .delete, headers: authed(helperTok)) {
                #expect($0.status == .forbidden)
            }
        }
    }

    @Test func cannotDelegateToAdminOrOwner() async throws {
        let (h, _, _) = try await makeOwnedHarness()
        try await h.app.test(.router) { client in
            let owner = try await token(client, h, "scoped", h.scopedPassword)
            for target in ["admin", "scoped"] {
                let body = ByteBuffer(string: #"{"username":"\#(target)","permissions":["console"]}"#)
                try await client.execute(uri: "/api/containers/bot/subusers", method: .put, headers: authed(owner), body: body) {
                    #expect($0.status == .badRequest, "delegating to \(target) must be rejected")
                }
            }
        }
    }

    @Test func unknownAccountAndPermissionRejected() async throws {
        let (h, _, _) = try await makeOwnedHarness()
        try await h.app.test(.router) { client in
            let owner = try await token(client, h, "scoped", h.scopedPassword)
            let noUser = ByteBuffer(string: #"{"username":"ghost","permissions":["console"]}"#)
            try await client.execute(uri: "/api/containers/bot/subusers", method: .put, headers: authed(owner), body: noUser) {
                #expect($0.status == .badRequest)
            }
            let badPerm = ByteBuffer(string: #"{"username":"friend","permissions":["hack"]}"#)
            try await client.execute(uri: "/api/containers/bot/subusers", method: .put, headers: authed(owner), body: badPerm) {
                #expect($0.status == .badRequest)
            }
        }
    }

    @Test func emptyPermissionsAndDeleteBothRevoke() async throws {
        let (h, friend, _) = try await makeOwnedHarness()
        try await h.app.test(.router) { client in
            let owner = try await token(client, h, "scoped", h.scopedPassword)
            let add = ByteBuffer(string: #"{"username":"friend","permissions":["console"]}"#)
            try await client.execute(uri: "/api/containers/bot/subusers", method: .put, headers: authed(owner), body: add) {
                #expect($0.status == .ok)
            }
            #expect(try h.store.grants(forUserID: friend.id)["bot"] != nil)
            // Empty permissions removes the grant.
            let empty = ByteBuffer(string: #"{"username":"friend","permissions":[]}"#)
            try await client.execute(uri: "/api/containers/bot/subusers", method: .put, headers: authed(owner), body: empty) {
                #expect($0.status == .ok)
            }
            #expect(try h.store.grants(forUserID: friend.id)["bot"] == nil)

            // Re-add, then DELETE removes it too.
            try await client.execute(uri: "/api/containers/bot/subusers", method: .put, headers: authed(owner), body: add) {
                #expect($0.status == .ok)
            }
            try await client.execute(uri: "/api/containers/bot/subusers/friend", method: .delete, headers: authed(owner)) {
                #expect($0.status == .ok)
            }
            #expect(try h.store.grants(forUserID: friend.id)["bot"] == nil)
        }
    }

    @Test func adminCanManageServerTheyDoNotOwn() async throws {
        let (h, friend, _) = try await makeOwnedHarness()
        try await h.app.test(.router) { client in
            let adminTok = try await token(client, h, "admin", h.adminPassword)
            let body = ByteBuffer(string: #"{"username":"friend","permissions":["backups"]}"#)
            try await client.execute(uri: "/api/containers/bot/subusers", method: .put, headers: authed(adminTok), body: body) {
                #expect($0.status == .ok)
            }
            let grant = try #require(try h.store.grants(forUserID: friend.id)["bot"])
            #expect(grant.view && grant.backups && !grant.power)
        }
    }
}
