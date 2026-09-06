import Foundation
import Hummingbird
import HummingbirdTesting
import MacerodactylKit
import Testing

@testable import MacerodactylPanel

/// First-run web setup — the browser-driven admin bootstrap. The load-bearing
/// property is that the endpoint is open ONLY while the panel has no account and
/// permanently closes the instant one exists, so an unauthenticated route that
/// mints an admin can never be a takeover on a live panel.
@Suite struct SetupTests {
    private func emptyApp() throws -> (PanelDataStore, Application<RouterResponder<PanelRequestContext>>) {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = try PanelDataStore(databasePath: dir.appending(path: "t.sqlite").path)
        let service = FakeContainerService(fixtures: [:])
        let server = PanelServer(store: store, containers: service)
        return (store, Application(router: server.buildRouter()))
    }

    private var csrf: HTTPFields { [.contentType: "application/json", PanelHeaders.csrf: "1"] }

    @Test func rootAndLoginRedirectToSetupWhenNoAccounts() async throws {
        let (_, app) = try emptyApp()
        try await app.test(.router) { client in
            for uri in ["/", "/login"] {
                try await client.execute(uri: uri, method: .get) { response in
                    #expect(response.status == .seeOther)
                    #expect(response.headers[.location] == "/setup")
                }
            }
            // The setup page itself serves while empty AND references the script
            // the browser will load to drive it — the served-page layer the JSON
            // API tests never see.
            try await client.execute(uri: "/setup", method: .get) { response in
                #expect(response.status == .ok)
                let body = String(buffer: response.body)
                #expect(body.contains("/assets/setup.js"))
            }
        }
    }

    @Test func setupCreatesFirstAdminAndSignsIn() async throws {
        let (store, app) = try emptyApp()
        try await app.test(.router) { client in
            let body = ByteBuffer(string: #"{"username":"root","password":"correct horse 8"}"#)
            let cookie = try await client.execute(uri: "/setup", method: .post, headers: csrf, body: body) { response in
                #expect(response.status == .ok)
                return response.headers[values: .setCookie].first { $0.hasPrefix(PanelSession.cookieName) }
            }
            #expect(cookie != nil)  // signed in immediately
            let user = try #require(try store.user(named: "root"))
            #expect(user.isAdmin)
        }
    }

    @Test func setupIsPermanentlyClosedOnceAnAccountExists() async throws {
        let (store, app) = try emptyApp()
        _ = try await AccountManager(store: store).createUser(username: "existing", password: "pw-123456789", isAdmin: true)
        try await app.test(.router) { client in
            // GET now bounces to login, not the setup form.
            try await client.execute(uri: "/setup", method: .get) { response in
                #expect(response.status == .seeOther)
                #expect(response.headers[.location] == "/login")
            }
            // POST is refused — no second admin can be minted unauthenticated.
            let body = ByteBuffer(string: #"{"username":"intruder","password":"correct horse 8"}"#)
            try await client.execute(uri: "/setup", method: .post, headers: csrf, body: body) { response in
                #expect(response.status == .forbidden)
            }
            #expect(try store.user(named: "intruder") == nil)
        }
    }

    @Test func setupValidatesUsernameAndPassword() async throws {
        let (store, app) = try emptyApp()
        try await app.test(.router) { client in
            let shortPw = ByteBuffer(string: #"{"username":"root","password":"short"}"#)
            try await client.execute(uri: "/setup", method: .post, headers: csrf, body: shortPw) {
                #expect($0.status == .badRequest)
            }
            let badName = ByteBuffer(string: #"{"username":"bad name!","password":"longenough123"}"#)
            try await client.execute(uri: "/setup", method: .post, headers: csrf, body: badName) {
                #expect($0.status == .badRequest)
            }
            #expect(try store.hasAnyUser() == false)  // nothing was created
        }
    }

    @Test func setupPostRequiresCSRF() async throws {
        let (_, app) = try emptyApp()
        try await app.test(.router) { client in
            let body = ByteBuffer(string: #"{"username":"root","password":"correct horse 8"}"#)
            // No CSRF header → blocked by the global middleware before setup runs.
            try await client.execute(
                uri: "/setup", method: .post, headers: [.contentType: "application/json"], body: body
            ) { #expect($0.status == .forbidden) }
        }
    }
}
