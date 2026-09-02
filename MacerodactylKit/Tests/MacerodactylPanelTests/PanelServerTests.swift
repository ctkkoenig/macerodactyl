import Foundation
import Hummingbird
import HummingbirdTesting
import Testing
import MacerodactylKit
@testable import MacerodactylPanel

/// End-to-end HTTP tests over the real router via HummingbirdTesting — no socket
/// opened. Covers the scoping matrix, session handling, CSRF rejection, rate
/// limiting, and that proxy headers cannot influence identity.
@Suite struct PanelServerTests {
    /// A fresh store + router + seeded users for each test.
    struct Harness {
        let store: PanelDataStore
        let app: Application<RouterResponder<PanelRequestContext>>
        let service: FakeContainerService
        let botStackRoot: URL
        let admin: PanelUser
        let scoped: PanelUser
        let adminPassword = "admin-pw-123456"
        let scopedPassword = "scoped-pw-123456"
    }

    func makeHarness(scopedGrant: ContainerGrant = ContainerGrant(view: true, power: true)) async throws -> Harness {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = try PanelDataStore(databasePath: dir.appending(path: "t.sqlite").path)
        let accounts = AccountManager(store: store)
        let admin = try await accounts.createUser(username: "admin", password: "admin-pw-123456", isAdmin: true)
        let scoped = try await accounts.createUser(username: "scoped", password: "scoped-pw-123456", isAdmin: false)
        try accounts.setGrant(userID: scoped.id, containerName: "bot", grant: scopedGrant, filesGrantable: true)

        // "bot" has a real stack folder on disk so file routes exercise the real
        // FileService + confinement; "secret" exists but scoped can't view it.
        let stacks = dir.appending(path: "stacks")
        let botRoot = stacks.appending(path: "bot")
        try FileManager.default.createDirectory(at: botRoot, withIntermediateDirectories: true)
        try Data("services: {}\n".utf8).write(to: botRoot.appending(path: "docker-compose.yml"))
        let secretDir = dir.appending(path: "secret-data")
        try FileManager.default.createDirectory(at: secretDir, withIntermediateDirectories: true)
        try Data("TOP SECRET".utf8).write(to: secretDir.appending(path: "creds.txt"))

        let service = FakeContainerService(fixtures: [
            "bot": .init(container: .fixture(name: "bot", workingDir: botRoot.path), stackRoot: botRoot),
            "secret": .init(container: .fixture(name: "secret", workingDir: nil), stackRoot: nil),
        ])
        let server = PanelServer(store: store, containers: service)
        let app = Application(router: server.buildRouter())
        return Harness(store: store, app: app, service: service, botStackRoot: botRoot, admin: admin, scoped: scoped)
    }

    /// Logs in and returns the session cookie value.
    func login(_ client: some TestClientProtocol, username: String, password: String,
               csrf: Bool = true, extraHeaders: HTTPFields = [:]) async throws -> (status: HTTPResponse.Status, cookie: String?) {
        var headers: HTTPFields = [.contentType: "application/json"]
        if csrf { headers[PanelHeaders.csrf] = "1" }
        for field in extraHeaders { headers[field.name] = field.value }
        let body = ByteBuffer(string: #"{"username":"\#(username)","password":"\#(password)"}"#)
        return try await client.execute(uri: "/login", method: .post, headers: headers, body: body) { response in
            let cookie = response.headers[values: .setCookie]
                .first { $0.hasPrefix(PanelSession.cookieName) }
                .flatMap { $0.split(separator: ";").first?.split(separator: "=").last.map(String.init) }
            return (response.status, cookie)
        }
    }

    func cookieHeader(_ token: String) -> HTTPFields {
        [.cookie: "\(PanelSession.cookieName)=\(token)"]
    }

    // MARK: Session handling

    @Test func loginSetsSessionAndMeReflectsIdentity() async throws {
        let harness = try await makeHarness()
        try await harness.app.test(.router) { client in
            let (status, cookie) = try await login(client, username: "scoped", password: harness.scopedPassword)
            #expect(status == .ok)
            let token = try #require(cookie)

            try await client.execute(uri: "/api/me", method: .get, headers: cookieHeader(token)) { response in
                #expect(response.status == .ok)
                let json = try JSONSerialization.jsonObject(with: Data(buffer: response.body)) as! [String: Any]
                #expect(json["username"] as? String == "scoped")
                #expect(json["isAdmin"] as? Bool == false)
            }
        }
    }

    @Test func noSessionIsUnauthorized() async throws {
        let harness = try await makeHarness()
        try await harness.app.test(.router) { client in
            try await client.execute(uri: "/api/me", method: .get) { response in
                #expect(response.status == .unauthorized)
            }
        }
    }

    @Test func garbageCookieIsUnauthenticatedNotCrash() async throws {
        let harness = try await makeHarness()
        try await harness.app.test(.router) { client in
            try await client.execute(uri: "/api/me", method: .get, headers: cookieHeader("not-a-real-token")) { response in
                #expect(response.status == .unauthorized)
            }
        }
    }

    @Test func logoutInvalidatesSession() async throws {
        let harness = try await makeHarness()
        try await harness.app.test(.router) { client in
            let (_, cookie) = try await login(client, username: "admin", password: harness.adminPassword)
            let token = try #require(cookie)
            try await client.execute(uri: "/logout", method: .post, headers: cookieHeader(token).merging(csrf: true)) { response in
                #expect(response.status == .ok)
            }
            try await client.execute(uri: "/api/me", method: .get, headers: cookieHeader(token)) { response in
                #expect(response.status == .unauthorized)
            }
        }
    }

    // MARK: Scoping matrix

    @Test func scopedUserListShowsOnlyGrantedContainers() async throws {
        let harness = try await makeHarness()
        try await harness.app.test(.router) { client in
            let (_, cookie) = try await login(client, username: "scoped", password: harness.scopedPassword)
            let token = try #require(cookie)
            try await client.execute(uri: "/api/containers", method: .get, headers: cookieHeader(token)) { response in
                #expect(response.status == .ok)
                let list = try JSONSerialization.jsonObject(with: Data(buffer: response.body)) as! [[String: Any]]
                // Only "bot" — "secret" exists but is never revealed.
                #expect(list.map { $0["name"] as? String } == ["bot"])
            }
        }
    }

    @Test func ungrantedContainerReturns404Not403() async throws {
        let harness = try await makeHarness()
        try await harness.app.test(.router) { client in
            let (_, cookie) = try await login(client, username: "scoped", password: harness.scopedPassword)
            let token = try #require(cookie)
            // Granted container → 200.
            try await client.execute(uri: "/api/containers/bot", method: .get, headers: cookieHeader(token)) { response in
                #expect(response.status == .ok)
                let json = try JSONSerialization.jsonObject(with: Data(buffer: response.body)) as! [String: Any]
                let perms = json["permissions"] as! [String: Any]
                #expect(perms["power"] as? Bool == true)
                #expect(perms["files"] as? Bool == false)
            }
            // Ungranted container → 404 (existence not revealed), never 403.
            try await client.execute(uri: "/api/containers/secret", method: .get, headers: cookieHeader(token)) { response in
                #expect(response.status == .notFound)
            }
        }
        // The denied attempt is recorded in the audit log (admin-only surface).
        let denials = try harness.store.listAudit().filter { $0.action == "container.view" && $0.outcome == "denied" }
        #expect(denials.contains { $0.containerName == "secret" && $0.username == "scoped" })
    }

    @Test func adminSeesAllScope() async throws {
        let harness = try await makeHarness()
        try await harness.app.test(.router) { client in
            let (_, cookie) = try await login(client, username: "admin", password: harness.adminPassword)
            let token = try #require(cookie)
            // Admin can view a container no grant mentions.
            try await client.execute(uri: "/api/containers/secret", method: .get, headers: cookieHeader(token)) { response in
                #expect(response.status == .ok)
            }
            try await client.execute(uri: "/api/containers", method: .get, headers: cookieHeader(token)) { response in
                let list = try JSONSerialization.jsonObject(with: Data(buffer: response.body)) as! [[String: Any]]
                #expect(Set(list.compactMap { $0["name"] as? String }) == ["bot", "secret"])
            }
        }
    }

    // MARK: CSRF

    @Test func mutatingRequestWithoutCSRFHeaderIsRejected() async throws {
        let harness = try await makeHarness()
        try await harness.app.test(.router) { client in
            let (status, _) = try await login(client, username: "admin", password: harness.adminPassword, csrf: false)
            #expect(status == .forbidden) // login is a POST; no CSRF header → blocked before auth
        }
    }

    // MARK: Rate limiting

    @Test func repeatedFailedLoginsGetRateLimited() async throws {
        let harness = try await makeHarness()
        try await harness.app.test(.router) { client in
            var sawTooMany = false
            for _ in 0..<12 {
                let (status, _) = try await login(client, username: "admin", password: "wrong-password")
                if status == .tooManyRequests { sawTooMany = true; break }
                #expect(status == .unauthorized)
            }
            #expect(sawTooMany)
        }
    }

    // MARK: Proxy headers cannot influence identity

    @Test func proxyHeadersCannotForgeIdentity() async throws {
        let harness = try await makeHarness()
        try await harness.app.test(.router) { client in
            // No session cookie, but every "trusted proxy" header a real
            // deployment might see set to an admin. Identity must stay nil.
            var headers: HTTPFields = [:]
            headers[.init("X-Forwarded-User")!] = "admin"
            headers[.init("X-Forwarded-Email")!] = "admin@example.com"
            headers[.init("Cf-Access-Authenticated-User-Email")!] = "admin@example.com"
            headers[.init("X-Forwarded-For")!] = "10.0.0.1"
            headers[.init("Remote-User")!] = "admin"
            try await client.execute(uri: "/api/me", method: .get, headers: headers) { response in
                #expect(response.status == .unauthorized) // headers grant nothing
            }
        }
    }

    @Test func firstRunCreatesAdminOnce() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = try PanelDataStore(databasePath: dir.appending(path: "t.sqlite").path)
        let accounts = AccountManager(store: store)
        let created = try await accounts.createFirstAdminIfNeeded()
        #expect(created?.username == "admin")
        #expect((created?.password.count ?? 0) >= 16)
        // Idempotent: a second call does nothing.
        #expect(try await accounts.createFirstAdminIfNeeded() == nil)
    }
}

private extension HTTPFields {
    func merging(csrf: Bool) -> HTTPFields {
        var copy = self
        if csrf { copy[PanelHeaders.csrf] = "1" }
        return copy
    }
}
