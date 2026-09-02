import Foundation
import Hummingbird
import HummingbirdTesting
import Testing
import MacerodactylKit
@testable import MacerodactylPanel

/// Container-feature routes over HTTP: per-permission gating, the 404/403
/// distinction, SSE, and the traversal shapes run against the HTTP file layer
/// specifically (not just the service). Reuses PanelServerTests' harness.
@Suite struct PanelContainerTests {
    let base = PanelServerTests()

    func loginToken(_ client: some TestClientProtocol, _ harness: PanelServerTests.Harness, admin: Bool = false) async throws -> String {
        let (_, cookie) = try await base.login(client,
            username: admin ? "admin" : "scoped",
            password: admin ? harness.adminPassword : harness.scopedPassword)
        return try #require(cookie)
    }

    func headers(_ token: String, csrf: Bool = false, json: Bool = false) -> HTTPFields {
        var h: HTTPFields = [.cookie: "\(PanelSession.cookieName)=\(token)"]
        if csrf { h[PanelHeaders.csrf] = "1" }
        if json { h[.contentType] = "application/json" }
        return h
    }

    // MARK: Per-permission gating

    @Test func powerRequiresPowerPermission() async throws {
        // scoped has view+power on bot → allowed.
        let harness = try await base.makeHarness(scopedGrant: ContainerGrant(view: true, power: true))
        try await harness.app.test(.router) { client in
            let token = try await loginToken(client, harness)
            try await client.execute(uri: "/api/containers/bot/power", method: .post,
                                     headers: headers(token, csrf: true, json: true),
                                     body: ByteBuffer(string: #"{"action":"restart"}"#)) { response in
                #expect(response.status == .ok)
            }
        }
        #expect(harness.service.powerCalls.contains { $0.action == .restart && $0.name == "bot" })
    }

    @Test func powerForbiddenWithoutPowerButViewable403NotHidden() async throws {
        // scoped has view but NOT power → 403 (they can see it; action forbidden).
        let harness = try await base.makeHarness(scopedGrant: ContainerGrant(view: true, power: false))
        try await harness.app.test(.router) { client in
            let token = try await loginToken(client, harness)
            try await client.execute(uri: "/api/containers/bot/power", method: .post,
                                     headers: headers(token, csrf: true, json: true),
                                     body: ByteBuffer(string: #"{"action":"stop"}"#)) { response in
                #expect(response.status == .forbidden)
            }
        }
        #expect(harness.service.powerCalls.isEmpty) // never reached the service
    }

    @Test func consoleRequiresConsolePermission() async throws {
        let harness = try await base.makeHarness(scopedGrant: ContainerGrant(view: true))
        try await harness.app.test(.router) { client in
            let token = try await loginToken(client, harness)
            // No console grant → 403.
            try await client.execute(uri: "/api/containers/bot/console", method: .post,
                                     headers: headers(token, csrf: true, json: true),
                                     body: ByteBuffer(string: #"{"command":"ls"}"#)) { response in
                #expect(response.status == .forbidden)
            }
        }
    }

    @Test func filesRequireFilesPermission() async throws {
        let harness = try await base.makeHarness(scopedGrant: ContainerGrant(view: true))
        try await harness.app.test(.router) { client in
            let token = try await loginToken(client, harness)
            try await client.execute(uri: "/api/containers/bot/files?path=", method: .get, headers: headers(token)) { response in
                #expect(response.status == .forbidden) // view but not files
            }
        }
    }

    @Test func logsStreamOverSSEForViewer() async throws {
        let harness = try await base.makeHarness(scopedGrant: ContainerGrant(view: true))
        try await harness.app.test(.router) { client in
            let token = try await loginToken(client, harness)
            try await client.execute(uri: "/api/containers/bot/logs", method: .get, headers: headers(token)) { response in
                #expect(response.status == .ok)
                #expect(response.headers[.contentType]?.contains("text/event-stream") == true)
                let body = String(buffer: response.body)
                #expect(body.contains("data: log line 1"))
                #expect(body.contains("data: log line 2"))
            }
        }
    }

    // MARK: Files gating + real read/write

    @Test func filesReadWriteWhenGranted() async throws {
        let harness = try await base.makeHarness(scopedGrant: ContainerGrant(view: true, files: true))
        try await harness.app.test(.router) { client in
            let token = try await loginToken(client, harness)
            // List the stack folder.
            try await client.execute(uri: "/api/containers/bot/files?path=", method: .get, headers: headers(token)) { response in
                #expect(response.status == .ok)
                let list = try JSONSerialization.jsonObject(with: Data(buffer: response.body)) as! [[String: Any]]
                #expect(list.contains { $0["name"] as? String == "docker-compose.yml" })
            }
            // Write a new file, then read it back.
            try await client.execute(uri: "/api/containers/bot/files/content?path=notes.txt", method: .put,
                                     headers: headers(token, csrf: true, json: true),
                                     body: ByteBuffer(string: #"{"text":"hello\n","lineEnding":"lf"}"#)) { response in
                #expect(response.status == .ok)
            }
            #expect(FileManager.default.fileExists(atPath: harness.botStackRoot.appending(path: "notes.txt").path))
        }
    }

    // MARK: Traversal shapes against the HTTP file layer

    @Test func traversalShapesBlockedOverHTTP() async throws {
        let harness = try await base.makeHarness(scopedGrant: ContainerGrant(view: true, files: true))
        // Attempts to escape the bot stack folder to the sibling secret-data dir.
        let escapes = [
            "../secret-data/creds.txt",
            "..%2fsecret-data%2fcreds.txt",
            "%2e%2e/secret-data/creds.txt",
            "/etc/passwd",
            "~/secret",
        ]
        try await harness.app.test(.router) { client in
            let token = try await loginToken(client, harness)
            for path in escapes {
                let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? path
                // Read attempt is refused (403/404), never 200 with content.
                try await client.execute(uri: "/api/containers/bot/files/content?path=\(encoded)", method: .get, headers: headers(token)) { response in
                    #expect(response.status == .forbidden || response.status == .notFound || response.status == .badRequest)
                    #expect(!String(buffer: response.body).contains("TOP SECRET"))
                }
                // Write attempt is refused and creates nothing outside the root.
                try await client.execute(uri: "/api/containers/bot/files/content?path=\(encoded)", method: .put,
                                         headers: headers(token, csrf: true, json: true),
                                         body: ByteBuffer(string: #"{"text":"HIJACK","lineEnding":"lf"}"#)) { response in
                    #expect(response.status != .ok)
                }
            }
        }
        // The secret file is untouched.
        let secret = harness.botStackRoot.deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "secret-data/creds.txt")
        #expect(try String(contentsOf: secret, encoding: .utf8) == "TOP SECRET")
    }

    // MARK: The 404 provenance proof

    @Test func ungrantedAndNonexistentAreIndistinguishable() async throws {
        let harness = try await base.makeHarness(scopedGrant: ContainerGrant(view: true, power: true))
        try await harness.app.test(.router) { client in
            let token = try await loginToken(client, harness)
            // "secret" genuinely exists but scoped isn't granted it.
            var ungrantedStatus: HTTPResponse.Status?
            var ungrantedBody = ""
            try await client.execute(uri: "/api/containers/secret", method: .get, headers: headers(token)) { response in
                ungrantedStatus = response.status; ungrantedBody = String(buffer: response.body)
            }
            // "ghost" does not exist at all — and scoped isn't granted it either.
            var ghostStatus: HTTPResponse.Status?
            var ghostBody = ""
            try await client.execute(uri: "/api/containers/ghost", method: .get, headers: headers(token)) { response in
                ghostStatus = response.status; ghostBody = String(buffer: response.body)
            }
            // Identical: both 404, same body — the scoping 404 can't be told
            // apart from the genuinely-absent 404.
            #expect(ungrantedStatus == .notFound)
            #expect(ghostStatus == .notFound)
            #expect(ungrantedStatus == ghostStatus)
            #expect(ungrantedBody == ghostBody)
        }
        // Both were recorded as denials in the audit log (existence not leaked
        // to the caller, but visible to the admin).
        let denials = try harness.store.listAudit().filter { $0.outcome == "denied" }
        #expect(denials.contains { $0.containerName == "secret" })
        #expect(denials.contains { $0.containerName == "ghost" })
    }
}
