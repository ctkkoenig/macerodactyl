import Foundation
import Hummingbird
import HummingbirdTesting
import MacerodactylKit
import Testing

@testable import MacerodactylPanel

/// The admin-issued, single-use password-reset flow (no email delivery). Verifies
/// an admin can mint a reset link, the link sets a new password exactly once,
/// consuming it evicts the user's existing sessions, and a non-admin can't issue
/// resets.
@Suite struct PasswordResetTests {
    struct Harness {
        let store: PanelDataStore
        let app: Application<RouterResponder<PanelRequestContext>>
        let target: PanelUser
    }

    private func makeHarness() async throws -> Harness {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = try PanelDataStore(databasePath: dir.appending(path: "t.sqlite").path)
        let accounts = AccountManager(store: store)
        _ = try await accounts.createUser(username: "admin", password: "admin-pw-123456", isAdmin: true)
        _ = try await accounts.createUser(username: "scoped", password: "scoped-pw-123456", isAdmin: false)
        let target = try await accounts.createUser(username: "target", password: "old-pw-123456", isAdmin: false)
        let service = FakeContainerService(fixtures: [:])
        let server = PanelServer(store: store, containers: service)
        return Harness(store: store, app: Application(router: server.buildRouter()), target: target)
    }

    private func login(_ client: some TestClientProtocol, _ user: String, _ pw: String) async throws -> String {
        let body = ByteBuffer(string: #"{"username":"\#(user)","password":"\#(pw)"}"#)
        return try await client.execute(
            uri: "/login", method: .post, headers: [.contentType: "application/json", PanelHeaders.csrf: "1"], body: body
        ) { response in
            try #require(
                response.headers[values: .setCookie].first { $0.hasPrefix(PanelSession.cookieName) }
                    .flatMap { $0.split(separator: ";").first?.split(separator: "=").last.map(String.init) })
        }
    }

    private func authed(_ token: String) -> HTTPFields {
        [.cookie: "\(PanelSession.cookieName)=\(token)", .contentType: "application/json", PanelHeaders.csrf: "1"]
    }

    /// Pulls the raw token out of the issued `/reset?token=…` path.
    private func token(fromPath path: String) -> String? {
        URLComponents(string: path)?.queryItems?.first(where: { $0.name == "token" })?.value
    }

    @Test func adminIssuesLinkAndUserResetsPasswordOnce() async throws {
        let h = try await makeHarness()
        try await h.app.test(.router) { client in
            let admin = try await login(client, "admin", "admin-pw-123456")
            // Admin issues the reset link.
            let path = try await client.execute(
                uri: "/api/admin/users/\(h.target.id)/reset", method: .post, headers: authed(admin)
            ) { response in
                #expect(response.status == .ok)
                let json = try JSONSerialization.jsonObject(with: Data(buffer: response.body)) as! [String: Any]
                #expect(json["username"] as? String == "target")
                return json["path"] as! String
            }
            let raw = try #require(token(fromPath: path))

            // The target still has an old session that should be evicted on reset.
            let oldSession = try await login(client, "target", "old-pw-123456")

            // Consume the link → set a new password.
            let reset = ByteBuffer(string: #"{"token":"\#(raw)","password":"brand-new-pw-1"}"#)
            try await client.execute(
                uri: "/reset", method: .post, headers: [.contentType: "application/json", PanelHeaders.csrf: "1"],
                body: reset
            ) { #expect($0.status == .ok) }

            // Old password no longer works; new one does.
            let bad = ByteBuffer(string: #"{"username":"target","password":"old-pw-123456"}"#)
            try await client.execute(
                uri: "/login", method: .post, headers: [.contentType: "application/json", PanelHeaders.csrf: "1"],
                body: bad
            ) { #expect($0.status == .unauthorized) }
            _ = try await login(client, "target", "brand-new-pw-1")  // succeeds (would throw otherwise)

            // The pre-reset session was invalidated.
            try await client.execute(
                uri: "/api/me", method: .get, headers: [.cookie: "\(PanelSession.cookieName)=\(oldSession)"]
            ) { #expect($0.status == .unauthorized) }

            // The link is single-use: a second consume fails.
            try await client.execute(
                uri: "/reset", method: .post, headers: [.contentType: "application/json", PanelHeaders.csrf: "1"],
                body: ByteBuffer(string: #"{"token":"\#(raw)","password":"another-pw-99"}"#)
            ) { #expect($0.status == .badRequest) }
        }
    }

    @Test func nonAdminCannotIssueResets() async throws {
        let h = try await makeHarness()
        try await h.app.test(.router) { client in
            let scoped = try await login(client, "scoped", "scoped-pw-123456")
            try await client.execute(
                uri: "/api/admin/users/\(h.target.id)/reset", method: .post, headers: authed(scoped)
            ) { #expect($0.status == .notFound) }  // admin surface hidden from non-admins
        }
    }

    @Test func invalidTokenIsRejected() async throws {
        let h = try await makeHarness()
        try await h.app.test(.router) { client in
            try await client.execute(
                uri: "/reset", method: .post, headers: [.contentType: "application/json", PanelHeaders.csrf: "1"],
                body: ByteBuffer(string: #"{"token":"not-a-real-token","password":"whatever-123"}"#)
            ) { #expect($0.status == .badRequest) }
        }
    }

    @Test func resetRequiresCSRF() async throws {
        let h = try await makeHarness()
        try await h.app.test(.router) { client in
            try await client.execute(
                uri: "/reset", method: .post, headers: [.contentType: "application/json"],
                body: ByteBuffer(string: #"{"token":"x","password":"whatever-123"}"#)
            ) { #expect($0.status == .forbidden) }
        }
    }
}
