import Foundation
import Hummingbird
import HummingbirdTesting
import MacerodactylKit
import Testing

@testable import MacerodactylPanel

/// HTTP tests for the `/api/admin` surface: admin-only gating, egg import, the
/// SSE create-server flow (owner auto-grant, allocation lifecycle), and the
/// global 2FA policy — all over the real router via HummingbirdTesting.
@Suite struct AdminRoutesTests {
    struct Harness {
        let store: PanelDataStore
        let app: Application<RouterResponder<PanelRequestContext>>
        let service: FakeContainerService
        let adminPassword = "admin-pw-123456"
        let scopedPassword = "scoped-pw-123456"
    }

    private func makeHarness() async throws -> Harness {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = try PanelDataStore(databasePath: dir.appending(path: "t.sqlite").path)
        let accounts = AccountManager(store: store)
        _ = try await accounts.createUser(username: "admin", password: "admin-pw-123456", isAdmin: true)
        _ = try await accounts.createUser(username: "scoped", password: "scoped-pw-123456", isAdmin: false)
        let service = FakeContainerService(fixtures: [:])
        let server = PanelServer(store: store, containers: service)
        return Harness(store: store, app: Application(router: server.buildRouter()), service: service)
    }

    private func login(_ client: some TestClientProtocol, _ user: String, _ password: String) async throws -> String {
        let body = ByteBuffer(string: #"{"username":"\#(user)","password":"\#(password)"}"#)
        return try await client.execute(
            uri: "/login", method: .post, headers: [.contentType: "application/json", PanelHeaders.csrf: "1"],
            body: body
        ) { response in
            try #require(
                response.headers[values: .setCookie].first { $0.hasPrefix(PanelSession.cookieName) }
                    .flatMap { $0.split(separator: ";").first?.split(separator: "=").last.map(String.init) })
        }
    }

    private func authed(_ token: String, csrf: Bool = true) -> HTTPFields {
        var h: HTTPFields = [.cookie: "\(PanelSession.cookieName)=\(token)", .contentType: "application/json"]
        if csrf { h[PanelHeaders.csrf] = "1" }
        return h
    }

    private let sampleEgg = #"""
        {"meta":{"version":"PTDL_v2"},"name":"Paper","author":"a","description":"d",
         "docker_images":{"Java 21":"ghcr.io/pterodactyl/yolks:java_21"},
         "startup":"java -jar {{SERVER_JARFILE}} --port {{SERVER_PORT}}",
         "config":{"files":"{}","startup":"{\"done\":\"Done \"}","logs":"{}","stop":"stop"},
         "scripts":{"installation":{"script":"echo hi","container":"debian","entrypoint":"bash"}},
         "variables":[{"name":"Jar","env_variable":"SERVER_JARFILE","default_value":"server.jar",
           "user_viewable":true,"user_editable":true,"rules":"required"}]}
        """#

    @Test func adminRoutesAre404ForNonAdmins() async throws {
        let h = try await makeHarness()
        try await h.app.test(.router) { client in
            let token = try await login(client, "scoped", h.scopedPassword)
            for uri in ["/api/admin/settings", "/api/admin/servers", "/api/admin/eggs", "/api/admin/users"] {
                try await client.execute(uri: uri, method: .get, headers: authed(token, csrf: false)) { response in
                    #expect(response.status == .notFound, "\(uri) should hide from non-admins")
                }
            }
        }
    }

    @Test func settingsRoundTripForAdmin() async throws {
        let h = try await makeHarness()
        try await h.app.test(.router) { client in
            let token = try await login(client, "admin", h.adminPassword)
            let body = ByteBuffer(
                string:
                    #"{"companyName":"Tac-Alerts","require2FA":"force","defaultLanguage":"en","defaultTimezone":"UTC"}"#)
            try await client.execute(uri: "/api/admin/settings", method: .put, headers: authed(token), body: body) {
                #expect($0.status == .ok)
            }
            #expect(try h.store.globalSettings().companyName == "Tac-Alerts")
            #expect(try h.store.globalSettings().require2FA == .force)
        }
    }

    @Test func settingsMutationRequiresCSRF() async throws {
        let h = try await makeHarness()
        try await h.app.test(.router) { client in
            let token = try await login(client, "admin", h.adminPassword)
            let body = ByteBuffer(
                string: #"{"companyName":"X","require2FA":"off","defaultLanguage":"en","defaultTimezone":"UTC"}"#)
            // No CSRF header → rejected by the global middleware.
            try await client.execute(
                uri: "/api/admin/settings", method: .put,
                headers: [.cookie: "\(PanelSession.cookieName)=\(token)", .contentType: "application/json"], body: body
            ) { response in
                #expect(response.status == .forbidden)
            }
        }
    }

    @Test func eggImportListAndDetail() async throws {
        let h = try await makeHarness()
        try await h.app.test(.router) { client in
            let token = try await login(client, "admin", h.adminPassword)
            let importBody = try importPayload(nestName: "Minecraft", eggJSON: sampleEgg)
            let eggId: Int = try await client.execute(
                uri: "/api/admin/eggs/import", method: .post, headers: authed(token), body: importBody
            ) { response in
                #expect(response.status == .ok)
                let json = try JSONSerialization.jsonObject(with: Data(buffer: response.body)) as! [String: Any]
                #expect(json["name"] as? String == "Paper")
                #expect((json["warnings"] as? [Any])?.isEmpty == true)
                return json["eggId"] as! Int
            }
            // It now lists, and detail exposes the variable form.
            try await client.execute(uri: "/api/admin/eggs", method: .get, headers: authed(token, csrf: false)) {
                let arr = try JSONSerialization.jsonObject(with: Data(buffer: $0.body)) as! [[String: Any]]
                #expect(arr.contains { $0["name"] as? String == "Paper" })
            }
            try await client.execute(
                uri: "/api/admin/eggs/\(eggId)", method: .get, headers: authed(token, csrf: false)
            ) { response in
                let json = try JSONSerialization.jsonObject(with: Data(buffer: response.body)) as! [String: Any]
                let vars = json["variables"] as! [[String: Any]]
                #expect(vars.first?["envVariable"] as? String == "SERVER_JARFILE")
                #expect(
                    (json["images"] as! [[String: Any]]).first?["image"] as? String
                        == "ghcr.io/pterodactyl/yolks:java_21")
            }
        }
    }

    @Test func createServerReservesAllocationsGrantsOwnerAndActivates() async throws {
        let h = try await makeHarness()
        try await h.app.test(.router) { client in
            let token = try await login(client, "admin", h.adminPassword)
            let scoped = try #require(try h.store.user(named: "scoped"))
            // Import an egg + generate allocations.
            let eggId = try await importEgg(client, token: token, nestName: "MC", json: sampleEgg)
            try await generateAllocations(client, token: token, start: 25565, end: 25570)

            let createBody = ByteBuffer(
                string:
                    #"{"name":"mc1","eggId":\#(eggId),"ownerUserId":\#(scoped.id),"memoryMiB":1024,"values":{"SERVER_JARFILE":"paper.jar"}}"#
            )
            try await client.execute(uri: "/api/admin/servers", method: .post, headers: authed(token), body: createBody) {
                response in
                #expect(response.status == .ok)
                #expect(String(buffer: response.body).contains("created"))
            }
            // The Fake recorded a spec with the reserved primary port and resolved startup.
            let spec = try #require(h.service.provisionSpecs.first)
            #expect(spec.name == "mc1")
            #expect(spec.startup.contains("paper.jar"))
            #expect(spec.portMappings.first?.hostPort == 25565)
            // Record flipped to active, and the owner got a full grant.
            #expect(try h.store.serverRecord(name: "mc1")?.status == "active")
            let grant = try #require(try h.store.grants(forUserID: scoped.id)["mc1"])
            #expect(grant.view && grant.power && grant.files && grant.console && grant.lifecycle)
            // One allocation consumed.
            #expect(try h.store.allocations(forServer: "mc1").count == 1)
        }
    }

    @Test func createServerAttachesSelectedMounts() async throws {
        let h = try await makeHarness()
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try await h.app.test(.router) { client in
            let token = try await login(client, "admin", h.adminPassword)
            let eggId = try await importEgg(client, token: token, nestName: "MC", json: sampleEgg)
            try await generateAllocations(client, token: token, start: 25565, end: 25566)
            // Create a mount whose source is a real existing dir.
            let mBody = ByteBuffer(
                string: #"{"name":"shared","source":"\#(dir.path)","target":"/mnt/shared","readOnly":true}"#)
            let mountId: Int = try await client.execute(
                uri: "/api/admin/mounts", method: .post, headers: authed(token), body: mBody
            ) { ($0.status == .ok ? (try JSONSerialization.jsonObject(with: Data(buffer: $0.body)) as! [String: Any])["id"] as! Int : -1) }
            let createBody = ByteBuffer(
                string: #"{"name":"mc-mnt","eggId":\#(eggId),"memoryMiB":512,"mountIds":[\#(mountId)]}"#)
            try await client.execute(uri: "/api/admin/servers", method: .post, headers: authed(token), body: createBody) { _ in }
            let spec = try #require(h.service.provisionSpecs.first)
            #expect(spec.extraMounts.contains { $0.source == dir.path && $0.target == "/mnt/shared" && $0.readOnly })
        }
    }

    @Test func createServerRejectsInvalidRequiredVariable() async throws {
        let h = try await makeHarness()
        try await h.app.test(.router) { client in
            let token = try await login(client, "admin", h.adminPassword)
            let eggId = try await importEgg(client, token: token, nestName: "MC", json: sampleEgg)
            try await generateAllocations(client, token: token, start: 25565, end: 25566)
            // SERVER_JARFILE is required; an empty override must be rejected (400).
            let body = ByteBuffer(
                string: #"{"name":"badvar","eggId":\#(eggId),"memoryMiB":512,"values":{"SERVER_JARFILE":""}}"#)
            try await client.execute(uri: "/api/admin/servers", method: .post, headers: authed(token), body: body) {
                #expect($0.status == .badRequest)
            }
            #expect(h.service.provisionSpecs.isEmpty)  // never reached provisioning
        }
    }

    @Test func editServerUpdatesRecordAndReconfigures() async throws {
        let h = try await makeHarness()
        try await h.app.test(.router) { client in
            let token = try await login(client, "admin", h.adminPassword)
            let eggId = try await importEgg(client, token: token, nestName: "MC", json: sampleEgg)
            try await generateAllocations(client, token: token, start: 25565, end: 25566)
            let create = ByteBuffer(string: #"{"name":"mc1","eggId":\#(eggId),"memoryMiB":1024}"#)
            try await client.execute(uri: "/api/admin/servers", method: .post, headers: authed(token), body: create) { _ in }
            // Edit: bump memory, set a display name.
            let edit = ByteBuffer(string: #"{"memoryMiB":2048,"displayName":"My SMP"}"#)
            try await client.execute(uri: "/api/admin/servers/mc1", method: .put, headers: authed(token), body: edit) {
                #expect($0.status == .ok)
            }
            #expect(try h.store.serverRecord(name: "mc1")?.limits.memoryMiB == 2048)
            #expect(try h.store.serverRecord(name: "mc1")?.displayName == "My SMP")
            // The reconfigure spec carries the new memory limit.
            #expect(h.service.reconfigured.last?.limits.memoryMiB == 2048)
        }
    }

    @Test func suspendMakesServerReadOnlyForOwner() async throws {
        let h = try await makeHarness()
        try await h.app.test(.router) { client in
            let adminToken = try await login(client, "admin", h.adminPassword)
            let scoped = try #require(try h.store.user(named: "scoped"))
            let eggId = try await importEgg(client, token: adminToken, nestName: "MC", json: sampleEgg)
            try await generateAllocations(client, token: adminToken, start: 25565, end: 25566)
            // Create a server owned by the scoped user (auto-grants them full access).
            let create = ByteBuffer(string: #"{"name":"mc1","eggId":\#(eggId),"ownerUserId":\#(scoped.id),"memoryMiB":512}"#)
            try await client.execute(uri: "/api/admin/servers", method: .post, headers: authed(adminToken), body: create) { _ in }
            // Admin suspends it.
            try await client.execute(
                uri: "/api/admin/servers/mc1/suspend", method: .post, headers: authed(adminToken), body: ByteBuffer(string: "{}")
            ) {
                #expect($0.status == .ok)
            }
            // The owner can no longer power it (read-only while suspended).
            let scopedToken = try await login(client, "scoped", h.scopedPassword)
            try await client.execute(
                uri: "/api/containers/mc1/power", method: .post, headers: authed(scopedToken),
                body: ByteBuffer(string: #"{"action":"stop"}"#)
            ) { #expect($0.status == .forbidden) }
            // Admin unsuspends.
            try await client.execute(
                uri: "/api/admin/servers/mc1/unsuspend", method: .post, headers: authed(adminToken), body: ByteBuffer(string: "{}")
            ) {
                #expect($0.status == .ok)
            }
            #expect(try h.store.serverRecord(name: "mc1")?.status == "active")
        }
    }

    @Test func failedProvisionFreesAllocationsAndMarksFailed() async throws {
        let h = try await makeHarness()
        h.service.provisionShouldFail = true
        try await h.app.test(.router) { client in
            let token = try await login(client, "admin", h.adminPassword)
            let eggId = try await importEgg(client, token: token, nestName: "MC", json: sampleEgg)
            try await generateAllocations(client, token: token, start: 25565, end: 25566)
            let createBody = ByteBuffer(string: #"{"name":"mc2","eggId":\#(eggId),"memoryMiB":512}"#)
            try await client.execute(uri: "/api/admin/servers", method: .post, headers: authed(token), body: createBody) {
                _ in
            }
            // The allocation was released back to the pool and the record failed.
            #expect(try h.store.allocations(forServer: "mc2").isEmpty)
            #expect(try h.store.listAllocations().allSatisfy { $0.isFree })
            #expect(try h.store.serverRecord(name: "mc2")?.status == "install_failed")
        }
    }

    @Test func require2FADenyBlocksNonEnrolledNonAdmin() async throws {
        let h = try await makeHarness()
        // Admin (sole? no — two users) sets deny policy.
        try h.store.setGlobalSettings(
            PanelGlobalSettings(companyName: "X", require2FA: .denyNon2FA, defaultLanguage: "en", defaultTimezone: "UTC"))
        try await h.app.test(.router) { client in
            // The scoped, non-2FA user is denied outright.
            let body = ByteBuffer(string: #"{"username":"scoped","password":"\#(h.scopedPassword)"}"#)
            try await client.execute(
                uri: "/login", method: .post, headers: [.contentType: "application/json", PanelHeaders.csrf: "1"],
                body: body
            ) { response in
                #expect(response.status == .forbidden)
            }
        }
    }

    @Test func require2FAForceLetsAdminInWithEnrollFlag() async throws {
        let h = try await makeHarness()
        try h.store.setGlobalSettings(
            PanelGlobalSettings(companyName: "X", require2FA: .force, defaultLanguage: "en", defaultTimezone: "UTC"))
        try await h.app.test(.router) { client in
            let body = ByteBuffer(string: #"{"username":"admin","password":"\#(h.adminPassword)"}"#)
            try await client.execute(
                uri: "/login", method: .post, headers: [.contentType: "application/json", PanelHeaders.csrf: "1"],
                body: body
            ) { response in
                #expect(response.status == .ok)
                let json = try JSONSerialization.jsonObject(with: Data(buffer: response.body)) as! [String: Any]
                #expect(json["mustEnroll2FA"] as? Bool == true)
            }
        }
    }

    // MARK: helpers

    private func importPayload(nestName: String, eggJSON: String) throws -> ByteBuffer {
        let payload: [String: Any] = ["nestName": nestName, "json": eggJSON]
        return ByteBuffer(data: try JSONSerialization.data(withJSONObject: payload))
    }

    private func importEgg(
        _ client: some TestClientProtocol, token: String, nestName: String, json: String
    )
        async throws -> Int
    {
        let body = try importPayload(nestName: nestName, eggJSON: json)
        return try await client.execute(uri: "/api/admin/eggs/import", method: .post, headers: authed(token), body: body) { response in
            let j = try JSONSerialization.jsonObject(with: Data(buffer: response.body)) as! [String: Any]
            return j["eggId"] as! Int
        }
    }

    private func generateAllocations(
        _ client: some TestClientProtocol, token: String, start: Int, end: Int
    )
        async throws
    {
        let body = ByteBuffer(string: #"{"portStart":\#(start),"portEnd":\#(end)}"#)
        try await client.execute(uri: "/api/admin/allocations", method: .post, headers: authed(token), body: body) {
            #expect($0.status == .ok)
        }
    }
}
