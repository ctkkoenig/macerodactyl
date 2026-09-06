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
            #expect(grant.schedules && grant.backups)  // owner gets every permission on their server
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
            // The owner can no longer mutate it through ANY route a browser can
            // reach — not just power. Every non-idempotent method is frozen,
            // INCLUDING subusers and allocations (which require only `view` but
            // whose mutations would change grants or, worse, restart the stopped
            // container by recreating it). GET routes still work (read-only).
            let scopedToken = try await login(client, "scoped", h.scopedPassword)
            let blocked: [(String, HTTPRequest.Method, String?)] = [
                ("/api/containers/mc1/power", .post, #"{"action":"stop"}"#),
                ("/api/containers/mc1/console/input", .post, #"{"line":"help"}"#),
                ("/api/containers/mc1/files/dir", .post, #"{"path":"x"}"#),
                ("/api/containers/mc1/backups", .post, #"{}"#),
                ("/api/containers/mc1/schedule", .post, #"{"hour":1,"minute":0,"weekdays":[]}"#),
                ("/api/containers/mc1/subusers", .put, #"{"username":"x","permissions":["console"]}"#),
                ("/api/containers/mc1/allocations", .post, #"{"id":1}"#),
                ("/api/containers/mc1/allocations/1/primary", .post, nil),
                ("/api/containers/mc1/recreate", .post, nil),
            ]
            for (uri, method, body) in blocked {
                try await client.execute(
                    uri: uri, method: method, headers: authed(scopedToken),
                    body: body.map { ByteBuffer(string: $0) }
                ) { #expect($0.status == .forbidden, "\(method) \(uri) must be frozen while suspended") }
            }
            // A read still succeeds while suspended.
            try await client.execute(
                uri: "/api/containers/mc1/activity", method: .get,
                headers: [.cookie: "\(PanelSession.cookieName)=\(scopedToken)"]
            ) { #expect($0.status == .ok) }
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

    @Test func transferringOwnershipRevokesTheOldOwnersGrant() async throws {
        let h = try await makeHarness()
        try await h.app.test(.router) { client in
            let adminToken = try await login(client, "admin", h.adminPassword)
            let oldOwner = try #require(try h.store.user(named: "scoped"))
            let newOwner = try await AccountManager(store: h.store).createUser(
                username: "newowner", password: "newowner-pw-1", isAdmin: false)
            let eggId = try await importEgg(client, token: adminToken, nestName: "MC", json: sampleEgg)
            try await generateAllocations(client, token: adminToken, start: 25565, end: 25566)
            let create = ByteBuffer(string: #"{"name":"mc1","eggId":\#(eggId),"ownerUserId":\#(oldOwner.id),"memoryMiB":512}"#)
            try await client.execute(uri: "/api/admin/servers", method: .post, headers: authed(adminToken), body: create) { _ in }
            #expect(try h.store.grants(forUserID: oldOwner.id)["mc1"] != nil)  // owner was granted

            // Admin transfers ownership to newOwner.
            let edit = ByteBuffer(string: #"{"ownerUserId":\#(newOwner.id)}"#)
            try await client.execute(uri: "/api/admin/servers/mc1", method: .put, headers: authed(adminToken), body: edit) { _ in }

            // The OUTGOING owner's grant is gone; the new owner holds a full grant.
            #expect(try h.store.grants(forUserID: oldOwner.id)["mc1"] == nil, "removed owner must not retain access")
            let ng = try #require(try h.store.grants(forUserID: newOwner.id)["mc1"])
            #expect(ng.view && ng.power && ng.files && ng.console && ng.schedules && ng.lifecycle && ng.backups)
        }
    }

    @Test func managedDatabaseProvisionAndDrop() async throws {
        let h = try await makeHarness()
        try await h.app.test(.router) { client in
            let token = try await login(client, "admin", h.adminPassword)
            let scoped = try #require(try h.store.user(named: "scoped"))
            let eggId = try await importEgg(client, token: token, nestName: "MC", json: sampleEgg)
            try await generateAllocations(client, token: token, start: 25565, end: 25566)
            let create = ByteBuffer(string: #"{"name":"mc1","eggId":\#(eggId),"ownerUserId":\#(scoped.id),"memoryMiB":512}"#)
            try await client.execute(uri: "/api/admin/servers", method: .post, headers: authed(token), body: create) { _ in }
            let sid = try #require(try h.store.serverRecord(name: "mc1")).id

            // Create a database named "Stats".
            try await client.execute(
                uri: "/api/admin/servers/mc1/databases", method: .post, headers: authed(token),
                body: ByteBuffer(string: #"{"name":"Stats"}"#)
            ) { response in
                #expect(response.status == .ok)
                let json = try JSONSerialization.jsonObject(with: Data(buffer: response.body)) as! [String: Any]
                #expect(json["managed"] as? Bool == true)
                #expect(json["name"] as? String == "s\(sid)_stats")
                #expect(json["username"] as? String == "u\(sid)_stats")
                #expect((json["password"] as? String)?.count == 24)  // creds surfaced once
                #expect(json["host"] as? String == "host.docker.internal")
            }
            // The engine actually received a safe CREATE statement.
            let createSQL = try #require(h.service.databaseSQL.first)
            #expect(createSQL.contains("CREATE DATABASE IF NOT EXISTS `s\(sid)_stats`;"))
            #expect(createSQL.contains("GRANT ALL PRIVILEGES ON `s\(sid)_stats`.* TO 'u\(sid)_stats'@'%';"))
            // An engine config with a root password was created on first use.
            #expect(try h.store.databaseEngineConfig()?.rootPassword.isEmpty == false)

            // It lists, then delete drops it on the engine and removes the record.
            let dbID = try #require(try h.store.listDatabases(serverID: sid).first).id
            try await client.execute(uri: "/api/admin/databases/\(dbID)", method: .delete, headers: authed(token)) {
                #expect($0.status == .ok)
            }
            #expect(h.service.databaseSQL.contains { $0.contains("DROP DATABASE IF EXISTS `s\(sid)_stats`;") })
            #expect(try h.store.listDatabases(serverID: sid).isEmpty)
        }
    }

    @Test func managedDatabaseCreateFailsCleanlyWhenEngineUnavailable() async throws {
        let h = try await makeHarness()
        h.service.databaseSQLShouldFail = true
        try await h.app.test(.router) { client in
            let token = try await login(client, "admin", h.adminPassword)
            let eggId = try await importEgg(client, token: token, nestName: "MC", json: sampleEgg)
            try await generateAllocations(client, token: token, start: 25565, end: 25566)
            try await client.execute(
                uri: "/api/admin/servers", method: .post, headers: authed(token),
                body: ByteBuffer(string: #"{"name":"mc1","eggId":\#(eggId),"memoryMiB":512}"#)
            ) { _ in }
            let sid = try #require(try h.store.serverRecord(name: "mc1")).id
            try await client.execute(
                uri: "/api/admin/servers/mc1/databases", method: .post, headers: authed(token),
                body: ByteBuffer(string: #"{"name":"stats"}"#)
            ) { #expect($0.status == .internalServerError) }
            // No record was stored when provisioning failed.
            #expect(try h.store.listDatabases(serverID: sid).isEmpty)
        }
    }

    @Test func eggEditPatchesFieldsInPlace() async throws {
        let h = try await makeHarness()
        try await h.app.test(.router) { client in
            let token = try await login(client, "admin", h.adminPassword)
            let eggId = try await importEgg(client, token: token, nestName: "MC", json: sampleEgg)
            // Edit startup + a variable default via the structured editor.
            let body = ByteBuffer(
                string: #"""
                    {"startup":"java -Xmx2G -jar {{SERVER_JARFILE}}",
                     "variables":[{"name":"Jar","envVariable":"SERVER_JARFILE","defaultValue":"paper.jar",
                       "userViewable":true,"userEditable":true,"rules":["required"]}]}
                    """#)
            try await client.execute(uri: "/api/admin/eggs/\(eggId)", method: .put, headers: authed(token), body: body) { response in
                #expect(response.status == .ok)
                let json = try JSONSerialization.jsonObject(with: Data(buffer: response.body)) as! [String: Any]
                #expect(json["name"] as? String == "Paper")
            }
            // The change persisted (same id), and re-parses from the stored JSON.
            let egg = try #require(try h.store.egg(id: Int64(eggId))).parsed()
            #expect(egg.startup.contains("-Xmx2G"))
            #expect(egg.variables.first?.defaultValue == "paper.jar")

            // An edit that breaks the egg (empty startup) is rejected, leaving it intact.
            try await client.execute(
                uri: "/api/admin/eggs/\(eggId)", method: .put, headers: authed(token),
                body: ByteBuffer(string: #"{"startup":""}"#)
            ) { #expect($0.status == .badRequest) }
            #expect(try #require(try h.store.egg(id: Int64(eggId))).parsed().startup.contains("-Xmx2G"))
        }
    }

    @Test func eggUpdateRejectsAnEggWithNoSource() async throws {
        let h = try await makeHarness()
        try await h.app.test(.router) { client in
            let token = try await login(client, "admin", h.adminPassword)
            // sampleEgg carries no meta.update_url.
            let eggID = try await importEgg(client, token: token, nestName: "MC", json: sampleEgg)
            try await client.execute(
                uri: "/api/admin/eggs/\(eggID)/update", method: .post, headers: authed(token)
            ) { #expect($0.status == .badRequest) }
            // A missing egg is 404.
            try await client.execute(
                uri: "/api/admin/eggs/99999/update", method: .post, headers: authed(token)
            ) { #expect($0.status == .notFound) }
        }
    }

    @Test func generatesUDPAndBothProtocolAllocations() async throws {
        let h = try await makeHarness()
        try await h.app.test(.router) { client in
            let token = try await login(client, "admin", h.adminPassword)
            // UDP-only over one port.
            try await client.execute(
                uri: "/api/admin/allocations", method: .post, headers: authed(token),
                body: ByteBuffer(string: #"{"portStart":7000,"portEnd":7000,"proto":"udp"}"#)
            ) { #expect($0.status == .ok) }
            // "both" over one port → a tcp AND a udp row.
            try await client.execute(
                uri: "/api/admin/allocations", method: .post, headers: authed(token),
                body: ByteBuffer(string: #"{"portStart":7001,"portEnd":7001,"proto":"both"}"#)
            ) { response in
                #expect(response.status == .ok)
                let json = try JSONSerialization.jsonObject(with: Data(buffer: response.body)) as! [String: Any]
                #expect(json["created"] as? Int == 2)
            }
            // An unknown protocol is rejected.
            try await client.execute(
                uri: "/api/admin/allocations", method: .post, headers: authed(token),
                body: ByteBuffer(string: #"{"portStart":7002,"portEnd":7002,"proto":"sctp"}"#)
            ) { #expect($0.status == .badRequest) }

            let all = try h.store.listAllocations()
            #expect(all.contains { $0.port == 7000 && $0.proto == "udp" })
            #expect(all.contains { $0.port == 7001 && $0.proto == "tcp" })
            #expect(all.contains { $0.port == 7001 && $0.proto == "udp" })
            #expect(!all.contains { $0.port == 7002 })  // rejected, nothing created
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
