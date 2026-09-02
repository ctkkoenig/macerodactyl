import Foundation
import Hummingbird
import HummingbirdTesting
import MacerodactylKit
import Testing

@testable import MacerodactylPanel

/// Container-feature routes over HTTP: per-permission gating, the 404/403
/// distinction, SSE, and the traversal shapes run against the HTTP file layer
/// specifically (not just the service). Reuses PanelServerTests' harness.
@Suite struct PanelContainerTests {
    let base = PanelServerTests()

    func loginToken(_ client: some TestClientProtocol, _ harness: PanelServerTests.Harness, admin: Bool = false) async throws -> String {
        let (_, cookie) = try await base.login(
            client,
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
            try await client.execute(
                uri: "/api/containers/bot/power", method: .post,
                headers: headers(token, csrf: true, json: true),
                body: ByteBuffer(string: #"{"action":"restart"}"#)
            ) { response in
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
            try await client.execute(
                uri: "/api/containers/bot/power", method: .post,
                headers: headers(token, csrf: true, json: true),
                body: ByteBuffer(string: #"{"action":"stop"}"#)
            ) { response in
                #expect(response.status == .forbidden)
            }
        }
        #expect(harness.service.powerCalls.isEmpty)  // never reached the service
    }

    @Test func consoleRequiresConsolePermission() async throws {
        let harness = try await base.makeHarness(scopedGrant: ContainerGrant(view: true))
        try await harness.app.test(.router) { client in
            let token = try await loginToken(client, harness)
            // No console grant → 403.
            try await client.execute(
                uri: "/api/containers/bot/console", method: .post,
                headers: headers(token, csrf: true, json: true),
                body: ByteBuffer(string: #"{"command":"ls"}"#)
            ) { response in
                #expect(response.status == .forbidden)
            }
        }
    }

    @Test func schedulesRequireSchedulesPermission() async throws {
        // view but NOT schedules → 403 on both read and write.
        let harness = try await base.makeHarness(scopedGrant: ContainerGrant(view: true))
        try await harness.app.test(.router) { client in
            let token = try await loginToken(client, harness)
            try await client.execute(uri: "/api/containers/bot/schedule", method: .get, headers: headers(token)) { response in
                #expect(response.status == .forbidden)
            }
            try await client.execute(
                uri: "/api/containers/bot/schedule", method: .post,
                headers: headers(token, csrf: true, json: true),
                body: ByteBuffer(string: #"{"hour":4,"minute":30}"#)
            ) { response in
                #expect(response.status == .forbidden)
            }
        }
        #expect(harness.service.scheduleCalls.isEmpty)  // never reached the service
    }

    @Test func schedulesWorkWhenGranted() async throws {
        let harness = try await base.makeHarness(scopedGrant: ContainerGrant(view: true, schedules: true))
        try await harness.app.test(.router) { client in
            let token = try await loginToken(client, harness)
            try await client.execute(
                uri: "/api/containers/bot/schedule", method: .post,
                headers: headers(token, csrf: true, json: true),
                body: ByteBuffer(string: #"{"hour":4,"minute":30,"weekdays":[1,5]}"#)
            ) { response in
                #expect(response.status == .ok)
            }
            try await client.execute(
                uri: "/api/containers/bot/schedule", method: .delete,
                headers: headers(token, csrf: true)
            ) { response in
                #expect(response.status == .ok)
            }
        }
        #expect(harness.service.scheduleCalls.contains { $0.op == "set" && $0.name == "bot" })
        #expect(harness.service.scheduleCalls.contains { $0.op == "remove" && $0.name == "bot" })
    }

    @Test func filesRequireFilesPermission() async throws {
        let harness = try await base.makeHarness(scopedGrant: ContainerGrant(view: true))
        try await harness.app.test(.router) { client in
            let token = try await loginToken(client, harness)
            try await client.execute(uri: "/api/containers/bot/files?path=", method: .get, headers: headers(token)) { response in
                #expect(response.status == .forbidden)  // view but not files
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
            try await client.execute(
                uri: "/api/containers/bot/files/content?path=notes.txt", method: .put,
                headers: headers(token, csrf: true, json: true),
                body: ByteBuffer(string: #"{"text":"hello\n","lineEnding":"lf"}"#)
            ) { response in
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
                try await client.execute(uri: "/api/containers/bot/files/content?path=\(encoded)", method: .get, headers: headers(token)) {
                    response in
                    #expect(response.status == .forbidden || response.status == .notFound || response.status == .badRequest)
                    #expect(!String(buffer: response.body).contains("TOP SECRET"))
                }
                // Write attempt is refused and creates nothing outside the root.
                try await client.execute(
                    uri: "/api/containers/bot/files/content?path=\(encoded)", method: .put,
                    headers: headers(token, csrf: true, json: true),
                    body: ByteBuffer(string: #"{"text":"HIJACK","lineEnding":"lf"}"#)
                ) { response in
                    #expect(response.status != .ok)
                }
            }
        }
        // The secret file is untouched.
        let secret = harness.botStackRoot.deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "secret-data/creds.txt")
        #expect(try String(contentsOf: secret, encoding: .utf8) == "TOP SECRET")
    }

    // MARK: File manager mutations over HTTP (T2.3)

    @Test func fileManagerMutationsRoundTripOverHTTP() async throws {
        let harness = try await base.makeHarness(scopedGrant: ContainerGrant(view: true, files: true))
        try await harness.app.test(.router) { client in
            let token = try await loginToken(client, harness)

            // mkdir
            try await client.execute(
                uri: "/api/containers/bot/files/dir", method: .post,
                headers: headers(token, csrf: true, json: true),
                body: ByteBuffer(string: #"{"path":"mods"}"#)
            ) { #expect($0.status == .ok) }
            var isDir: ObjCBool = false
            #expect(
                FileManager.default.fileExists(
                    atPath: harness.botStackRoot.appending(path: "mods").path, isDirectory: &isDir) && isDir.boolValue)

            // upload binary bytes
            let bytes = ByteBuffer(bytes: [0x50, 0x4B, 0x03, 0x04, 0x00, 0xFF, 0xFE, 0x00])
            try await client.execute(
                uri: "/api/containers/bot/files/upload?path=mods/plugin.jar", method: .post,
                headers: headers(token, csrf: true), body: bytes
            ) { #expect($0.status == .ok) }
            #expect(FileManager.default.fileExists(atPath: harness.botStackRoot.appending(path: "mods/plugin.jar").path))

            // download it back — bytes must match exactly (binary-safe)
            try await client.execute(
                uri: "/api/containers/bot/files/download?path=mods/plugin.jar", method: .get, headers: headers(token)
            ) { response in
                #expect(response.status == .ok)
                #expect(Array(buffer: response.body) == [0x50, 0x4B, 0x03, 0x04, 0x00, 0xFF, 0xFE, 0x00])
            }

            // rename
            try await client.execute(
                uri: "/api/containers/bot/files/move", method: .post,
                headers: headers(token, csrf: true, json: true),
                body: ByteBuffer(string: #"{"from":"mods/plugin.jar","to":"mods/renamed.jar"}"#)
            ) { #expect($0.status == .ok) }
            #expect(!FileManager.default.fileExists(atPath: harness.botStackRoot.appending(path: "mods/plugin.jar").path))
            #expect(FileManager.default.fileExists(atPath: harness.botStackRoot.appending(path: "mods/renamed.jar").path))

            // delete
            try await client.execute(
                uri: "/api/containers/bot/files/entry?path=mods/renamed.jar", method: .delete,
                headers: headers(token, csrf: true)
            ) { #expect($0.status == .ok) }
            #expect(!FileManager.default.fileExists(atPath: harness.botStackRoot.appending(path: "mods/renamed.jar").path))
        }
    }

    @Test func fileManagerMutationsRequireFilesPermission() async throws {
        // view but NOT files → every mutation is 403 (visible, action forbidden).
        let harness = try await base.makeHarness(scopedGrant: ContainerGrant(view: true, files: false))
        try await harness.app.test(.router) { client in
            let token = try await loginToken(client, harness)
            let calls: [(String, HTTPRequest.Method, String?)] = [
                ("/api/containers/bot/files/dir", .post, #"{"path":"x"}"#),
                ("/api/containers/bot/files/move", .post, #"{"from":"a","to":"b"}"#),
                ("/api/containers/bot/files/entry?path=x", .delete, nil),
                ("/api/containers/bot/files/upload?path=x", .post, "data"),
                ("/api/containers/bot/files/download?path=x", .get, nil),
            ]
            for (uri, method, body) in calls {
                let mutating = method != .get
                try await client.execute(
                    uri: uri, method: method, headers: headers(token, csrf: mutating, json: body != nil),
                    body: body.map { ByteBuffer(string: $0) } ?? ByteBuffer()
                ) { #expect($0.status == .forbidden, "\(uri) should be 403 without files perm") }
            }
        }
    }

    @Test func traversalShapesBlockedOnEveryNewFileEndpoint() async throws {
        let harness = try await base.makeHarness(scopedGrant: ContainerGrant(view: true, files: true))
        let escapes = ["../secret-data/creds.txt", "..%2fsecret-data%2fcreds.txt", "%2e%2e/secret-data/creds.txt", "/etc/passwd"]
        try await harness.app.test(.router) { client in
            let token = try await loginToken(client, harness)
            for path in escapes {
                let q = path.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? path
                let jsonPath = path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
                // mkdir
                try await client.execute(
                    uri: "/api/containers/bot/files/dir", method: .post, headers: headers(token, csrf: true, json: true),
                    body: ByteBuffer(string: "{\"path\":\"\(jsonPath)\"}")
                ) { #expect($0.status != .ok) }
                // upload
                try await client.execute(
                    uri: "/api/containers/bot/files/upload?path=\(q)", method: .post, headers: headers(token, csrf: true),
                    body: ByteBuffer(string: "HIJACK")
                ) { #expect($0.status != .ok) }
                // delete
                try await client.execute(
                    uri: "/api/containers/bot/files/entry?path=\(q)", method: .delete, headers: headers(token, csrf: true)
                ) { #expect($0.status != .ok) }
                // download must never return the secret
                try await client.execute(
                    uri: "/api/containers/bot/files/download?path=\(q)", method: .get, headers: headers(token)
                ) { response in
                    #expect(response.status != .ok)
                    #expect(!String(buffer: response.body).contains("TOP SECRET"))
                }
                // move — escape at EITHER end is refused
                try await client.execute(
                    uri: "/api/containers/bot/files/move", method: .post, headers: headers(token, csrf: true, json: true),
                    body: ByteBuffer(string: "{\"from\":\"docker-compose.yml\",\"to\":\"\(jsonPath)\"}")
                ) { #expect($0.status != .ok) }
            }
        }
        let secret = harness.botStackRoot.deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "secret-data/creds.txt")
        #expect(try String(contentsOf: secret, encoding: .utf8) == "TOP SECRET")
    }

    // MARK: Lifecycle (T2.1)

    @Test func lifecycleRequiresLifecyclePermission() async throws {
        // view+power but NOT lifecycle → pull/recreate/remove all 403.
        let harness = try await base.makeHarness(scopedGrant: ContainerGrant(view: true, power: true))
        try await harness.app.test(.router) { client in
            let token = try await loginToken(client, harness)
            try await client.execute(uri: "/api/containers/bot/pull", method: .post, headers: headers(token, csrf: true)) {
                #expect($0.status == .forbidden)
            }
            try await client.execute(uri: "/api/containers/bot/recreate", method: .post, headers: headers(token, csrf: true)) {
                #expect($0.status == .forbidden)
            }
            try await client.execute(uri: "/api/containers/bot/remove", method: .delete, headers: headers(token, csrf: true)) {
                #expect($0.status == .forbidden)
            }
        }
        #expect(harness.service.lifecycleCalls.isEmpty)  // never reached the service
    }

    @Test func lifecyclePullAndRecreateStreamWhenGranted() async throws {
        let harness = try await base.makeHarness(scopedGrant: ContainerGrant(view: true, lifecycle: true))
        try await harness.app.test(.router) { client in
            let token = try await loginToken(client, harness)
            try await client.execute(uri: "/api/containers/bot/pull", method: .post, headers: headers(token, csrf: true)) {
                response in
                #expect(response.status == .ok)
                #expect(String(buffer: response.body).contains("Pull complete"))
            }
            try await client.execute(uri: "/api/containers/bot/recreate", method: .post, headers: headers(token, csrf: true)) {
                response in
                #expect(response.status == .ok)
                #expect(String(buffer: response.body).contains("Started"))
            }
        }
        #expect(harness.service.lifecycleCalls.contains { $0.op == "pull" && $0.name == "bot" })
        #expect(harness.service.lifecycleCalls.contains { $0.op == "recreate" && $0.name == "bot" })
    }

    @Test func removeRefusesRunningButSucceedsStopped() async throws {
        let harness = try await base.makeHarness(scopedGrant: ContainerGrant(view: true, lifecycle: true))
        try await harness.app.test(.router) { client in
            let token = try await loginToken(client, harness)
            // bot is running → 409 conflict, service not mutated.
            try await client.execute(uri: "/api/containers/bot/remove", method: .delete, headers: headers(token, csrf: true)) {
                #expect($0.status == .conflict)
            }
            #expect(!harness.service.lifecycleCalls.contains { $0.op == "remove" })
            // Stop it (replace the fixture with a stopped one) → remove succeeds.
            harness.service.fixtures["bot"] = .init(
                container: .fixture(name: "bot", workingDir: harness.botStackRoot.path, running: false),
                stackRoot: harness.botStackRoot)
            try await client.execute(uri: "/api/containers/bot/remove", method: .delete, headers: headers(token, csrf: true)) {
                #expect($0.status == .ok)
            }
        }
        #expect(harness.service.lifecycleCalls.contains { $0.op == "remove" && $0.name == "bot" })
    }

    @Test func composeApplyStreamsAndIsLifecycleGated() async throws {
        // Without lifecycle → 403; with it → streamed output. (T2.2)
        let denied = try await base.makeHarness(scopedGrant: ContainerGrant(view: true, files: true))
        try await denied.app.test(.router) { client in
            let token = try await loginToken(client, denied)
            try await client.execute(
                uri: "/api/containers/bot/compose/apply", method: .post, headers: headers(token, csrf: true)
            ) { #expect($0.status == .forbidden) }
        }
        let granted = try await base.makeHarness(scopedGrant: ContainerGrant(view: true, lifecycle: true))
        try await granted.app.test(.router) { client in
            let token = try await loginToken(client, granted)
            try await client.execute(
                uri: "/api/containers/bot/compose/apply", method: .post, headers: headers(token, csrf: true)
            ) { response in
                #expect(response.status == .ok)
                #expect(String(buffer: response.body).contains("Done"))
            }
        }
        #expect(granted.service.lifecycleCalls.contains { $0.op == "compose" && $0.name == "bot" })
    }

    @Test func maintenanceIsAdminOnly() async throws {
        let harness = try await base.makeHarness(scopedGrant: ContainerGrant(view: true, lifecycle: true))
        try await harness.app.test(.router) { client in
            // scoped (non-admin) → maintenance surface is 404 (existence hidden).
            let scopedToken = try await loginToken(client, harness)
            try await client.execute(uri: "/api/maintenance/disk", method: .get, headers: headers(scopedToken)) {
                #expect($0.status == .notFound)
            }
            try await client.execute(
                uri: "/api/maintenance/image-prune", method: .post, headers: headers(scopedToken, csrf: true)
            ) { #expect($0.status == .notFound) }
            // admin → allowed.
            let adminToken = try await loginToken(client, harness, admin: true)
            try await client.execute(uri: "/api/maintenance/disk", method: .get, headers: headers(adminToken)) {
                #expect($0.status == .ok)
            }
            try await client.execute(
                uri: "/api/maintenance/image-prune", method: .post, headers: headers(adminToken, csrf: true)
            ) { response in
                #expect(response.status == .ok)
                #expect(String(buffer: response.body).contains("reclaimed"))
            }
        }
        #expect(harness.service.lifecycleCalls.contains { $0.op == "image-prune" })
    }

    // MARK: Log search + download (T2.4)

    @Test func logSearchFiltersAndDownloadReturnsAttachment() async throws {
        let harness = try await base.makeHarness(scopedGrant: ContainerGrant(view: true))
        try await harness.app.test(.router) { client in
            let token = try await loginToken(client, harness)
            // Search for ERROR → only the matching line.
            try await client.execute(uri: "/api/containers/bot/logs/search?q=ERROR", method: .get, headers: headers(token)) {
                response in
                #expect(response.status == .ok)
                let obj = try JSONSerialization.jsonObject(with: Data(buffer: response.body)) as! [String: Any]
                let matches = obj["matches"] as! [String]
                #expect(matches.count == 1)
                #expect(matches[0].contains("ERROR failed to connect"))
                #expect(obj["truncated"] as? Bool == false)
            }
            // Empty query → the recent tail (all lines).
            try await client.execute(uri: "/api/containers/bot/logs/search", method: .get, headers: headers(token)) {
                response in
                let obj = try JSONSerialization.jsonObject(with: Data(buffer: response.body)) as! [String: Any]
                #expect((obj["matches"] as! [String]).count == 4)
            }
            // Download → text/plain attachment with the full log.
            try await client.execute(uri: "/api/containers/bot/logs/download", method: .get, headers: headers(token)) {
                response in
                #expect(response.status == .ok)
                #expect(response.headers[.contentDisposition]?.contains("attachment") == true)
                #expect(response.headers[.contentDisposition]?.contains("bot-logs.txt") == true)
                #expect(String(buffer: response.body).contains("listening on 8080"))
            }
        }
    }

    @Test func logSearchHiddenForUngrantedContainer() async throws {
        let harness = try await base.makeHarness(scopedGrant: ContainerGrant(view: true))
        try await harness.app.test(.router) { client in
            let token = try await loginToken(client, harness)
            try await client.execute(uri: "/api/containers/secret/logs/search?q=x", method: .get, headers: headers(token)) {
                #expect($0.status == .notFound)
            }
        }
    }

    // MARK: Retained metrics endpoint (T2.4)

    @Test func metricsHistoryReturnsRetainedSamplesForViewableContainer() async throws {
        let harness = try await base.makeHarness(scopedGrant: ContainerGrant(view: true))
        // Seed a couple of retained samples directly in the store.
        let now = Date()
        try harness.store.recordMetric(
            ContainerStats(
                name: "bot", cpuPercent: 5, memUsedBytes: 1, memLimitBytes: 2, memPercent: 50,
                netRxBytes: 0, netTxBytes: 0, pids: 1, measuredAt: now.addingTimeInterval(-120)))
        try harness.store.recordMetric(
            ContainerStats(
                name: "bot", cpuPercent: 7, memUsedBytes: 1, memLimitBytes: 2, memPercent: 50,
                netRxBytes: 0, netTxBytes: 0, pids: 1, measuredAt: now.addingTimeInterval(-10)))
        try await harness.app.test(.router) { client in
            let token = try await loginToken(client, harness)
            try await client.execute(uri: "/api/containers/bot/metrics?since=3600", method: .get, headers: headers(token)) {
                response in
                #expect(response.status == .ok)
                let arr = try JSONSerialization.jsonObject(with: Data(buffer: response.body)) as! [[String: Any]]
                #expect(arr.count == 2)
                #expect((arr.first?["cpuPercent"] as? Double) == 5)  // oldest first
                #expect(arr.first?["measuredAt"] is String)
            }
        }
    }

    @Test func metricsHistoryHiddenForUngrantedContainer() async throws {
        // scoped is NOT granted "secret" → metrics history is a 404 like everything else.
        let harness = try await base.makeHarness(scopedGrant: ContainerGrant(view: true))
        try await harness.app.test(.router) { client in
            let token = try await loginToken(client, harness)
            try await client.execute(uri: "/api/containers/secret/metrics", method: .get, headers: headers(token)) {
                #expect($0.status == .notFound)
            }
        }
    }

    // MARK: Content-Disposition is injection-safe (Tier 2 review hardening)

    @Test func attachmentDispositionStripsControlBytesAndEncodesUTF8() {
        // A crafted in-tree filename with CR/LF/quote must not break the header.
        let evil = "a\r\nb\"c.txt"
        let value = PanelRoutes.attachmentDisposition(filename: evil)
        #expect(!value.contains("\r"))
        #expect(!value.contains("\n"))
        // The quoted ASCII fallback has the quote and control bytes replaced.
        #expect(value.contains("filename=\"a__b_c.txt\""))
        // A non-ASCII name survives via RFC 6266 filename*.
        let unicode = PanelRoutes.attachmentDisposition(filename: "café.txt")
        #expect(unicode.contains("filename*=UTF-8''caf%C3%A9.txt"))
    }

    // MARK: Permission mapping is position-based, not substring-based

    @Test func requiredPermissionMapsByRoutePositionNotSubstring() {
        typealias M = ContainerScopeMiddleware
        // Normal cases.
        #expect(M.requiredPermission(path: "/api/containers/bot/files/content") == .files)
        #expect(M.requiredPermission(path: "/api/containers/bot/power") == .power)
        #expect(M.requiredPermission(path: "/api/containers/bot/console") == .console)
        #expect(M.requiredPermission(path: "/api/containers/bot/schedule") == .schedules)
        #expect(M.requiredPermission(path: "/api/containers/bot/logs") == .view)
        #expect(M.requiredPermission(path: "/api/containers/bot") == .view)
        // The fail-open edge: a container literally named after a keyword must
        // map by the ACTION segment, not because its name contains "/files".
        #expect(M.requiredPermission(path: "/api/containers/files/power") == .power)
        #expect(M.requiredPermission(path: "/api/containers/files/console") == .console)
        #expect(M.requiredPermission(path: "/api/containers/power/files/content") == .files)
        #expect(M.requiredPermission(path: "/api/containers/schedule/power") == .power)
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
                ungrantedStatus = response.status
                ungrantedBody = String(buffer: response.body)
            }
            // "ghost" does not exist at all — and scoped isn't granted it either.
            var ghostStatus: HTTPResponse.Status?
            var ghostBody = ""
            try await client.execute(uri: "/api/containers/ghost", method: .get, headers: headers(token)) { response in
                ghostStatus = response.status
                ghostBody = String(buffer: response.body)
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
