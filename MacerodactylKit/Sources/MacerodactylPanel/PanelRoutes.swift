import Foundation
import Hummingbird
import HummingbirdAuth
import MacerodactylKit
import NIOCore

/// Caches the (relatively expensive) docker-reachability probe so an
/// unauthenticated flood of `GET /healthz` can't fan out into one `docker`
/// subprocess per request. A few seconds' staleness is fine for a liveness
/// signal.
actor HealthProbeCache {
    private var value: Bool?
    private var checkedAt: Date?
    private let ttl: TimeInterval

    init(ttl: TimeInterval = 5) { self.ttl = ttl }

    func reachable(_ probe: () async -> Bool) async -> Bool {
        if let value, let checkedAt, Date().timeIntervalSince(checkedAt) < ttl {
            return value
        }
        let result = await probe()
        value = result
        checkedAt = Date()
        return result
    }
}

struct PanelRoutes {
    let store: PanelDataStore
    let rateLimiter: LoginRateLimiter
    let containers: ContainerService
    /// Mark session cookies `Secure` (set when the server is serving HTTPS).
    var secureCookies: Bool = false
    /// Shared across requests for the lifetime of the router (see `healthz`).
    let healthProbe = HealthProbeCache()

    func register(on router: Router<PanelRequestContext>) {
        router.get("/", use: root)
        router.get("healthz", use: healthz)
        router.get("login", use: loginPage)
        router.post("login", use: login)
        router.post("logout", use: logout)
        router.get("me", use: appPage)

        // Static frontend assets (no secrets — this is the client code). Served
        // from a fixed allow-list, never a filename from the URL.
        router.get("assets/panel.css", use: { _, _ in Self.asset(.panelCSS) })
        router.get("assets/panel.js", use: { _, _ in Self.asset(.panelJS) })
        router.get("assets/login.css", use: { _, _ in Self.asset(.loginCSS) })
        router.get("assets/login.js", use: { _, _ in Self.asset(.loginJS) })

        let api = router.group("api").add(middleware: RequireAuth())
        api.get("me", use: apiMe)
        api.get("stats", use: apiStatsSnapshot)

        // Every container route inherits the scoping middleware; none re-checks.
        let scoped = api.group("containers").add(middleware: ContainerScopeMiddleware(store: store))
        scoped.get(use: apiContainers)
        scoped.get(":name", use: apiContainerDetail)
        scoped.post(":name/power", use: apiPower)
        scoped.get(":name/logs", use: apiLogs)
        scoped.get(":name/logs/search", use: apiLogsSearch)
        scoped.get(":name/logs/download", use: apiLogsDownload)
        scoped.get(":name/stats", use: apiStatsStream)
        scoped.get(":name/metrics", use: apiMetrics)
        scoped.post(":name/console", use: apiConsole)
        scoped.get(":name/files", use: apiFilesList)
        scoped.get(":name/files/content", use: apiFileRead)
        scoped.put(":name/files/content", use: apiFileWrite)
        scoped.get(":name/files/download", use: apiFileDownload)
        scoped.post(":name/files/upload", use: apiFileUpload)
        scoped.post(":name/files/dir", use: apiFileMkdir)
        scoped.post(":name/files/move", use: apiFileMove)
        scoped.delete(":name/files/entry", use: apiFileDelete)
        scoped.get(":name/schedule", use: apiScheduleGet)
        scoped.post(":name/schedule", use: apiScheduleSet)
        scoped.delete(":name/schedule", use: apiScheduleDelete)
        // Destructive lifecycle — all gated on the `.lifecycle` permission via
        // the scope middleware's path mapping. Mutating, so CSRF-protected.
        scoped.post(":name/pull", use: apiPull)
        scoped.post(":name/recreate", use: apiRecreate)
        scoped.post(":name/compose/apply", use: apiComposeApply)
        scoped.delete(":name/remove", use: apiRemove)

        // Daemon-global maintenance — admin-only (outside any container's scope).
        let admin = api.group("maintenance").add(middleware: RequireAdmin())
        admin.get("disk", use: apiDiskUsage)
        admin.post("image-prune", use: apiImagePrune)
    }

    // MARK: HTML pages

    @Sendable func root(_ request: Request, context: PanelRequestContext) async throws -> Response {
        redirect(context.identity == nil ? "/login" : "/me")
    }

    @Sendable func loginPage(_ request: Request, context: PanelRequestContext) async throws -> Response {
        if context.identity != nil { return redirect("/me") }
        return html(PanelAssets.string(.loginHTML))
    }

    @Sendable func appPage(_ request: Request, context: PanelRequestContext) async throws -> Response {
        guard context.identity != nil else { return redirect("/login") }
        return html(PanelAssets.string(.appHTML))
    }

    /// Serves a static frontend asset with its content type. `no-cache` (i.e.
    /// revalidate every load) is deliberate: the asset filenames are NOT
    /// content-hashed (no build step), so a long cache would leave browsers on a
    /// stale panel for up to that lifetime after the app is updated. The files
    /// are tiny, so revalidation is cheap.
    static func asset(_ asset: PanelAssets.Asset) -> Response {
        Response(
            status: .ok,
            headers: [.contentType: asset.contentType, .cacheControl: "no-cache"],
            body: .init(byteBuffer: ByteBuffer(string: PanelAssets.string(asset))))
    }

    struct HealthResponse: Encodable {
        let status: String
        let version: String
        let docker: String
    }

    /// Unauthenticated liveness/health endpoint for supervisors and monitoring.
    /// Reveals only server status, version, and whether docker is reachable —
    /// no accounts, no container names, no secrets. Always 200 while the server
    /// is up (that it answered is the liveness signal); `docker` reports the
    /// dependency separately so a monitor can distinguish "server up, docker
    /// down".
    @Sendable func healthz(_ request: Request, context: PanelRequestContext) async throws -> Response {
        let dockerOK = await healthProbe.reachable { await containers.dockerReachable() }
        return encode(HealthResponse(status: "ok", version: AppInfo.version, docker: dockerOK ? "ready" : "unreachable"))
    }

    // MARK: Auth

    struct LoginBody: Decodable {
        let username: String
        let password: String
    }

    @Sendable func login(_ request: Request, context: PanelRequestContext) async throws -> Response {
        let ip = context.clientIP
        let body = try? await request.decode(as: LoginBody.self, context: context)
        guard let body, !body.username.isEmpty else {
            return json(["error": "Missing credentials"], status: .badRequest)
        }

        let decision = await rateLimiter.check(username: body.username, ip: ip)
        guard decision.allowed else {
            audit(
                user: body.username, action: "login.ratelimited", outcome: "blocked", ip: ip,
                detail: "retry after \(Int(decision.retryAfter))s")
            var response = json(["error": "Too many attempts. Try again later."], status: .tooManyRequests)
            response.headers[.retryAfter] = String(Int(decision.retryAfter.rounded(.up)))
            return response
        }

        guard let user = try? store.user(named: body.username),
            await PasswordHasher.verify(body.password, hash: user.passwordHash)
        else {
            await rateLimiter.recordFailure(username: body.username, ip: ip)
            audit(user: body.username, action: "login.failure", outcome: "denied", ip: ip)
            return json(["error": "Invalid username or password"], status: .unauthorized)
        }

        await rateLimiter.recordSuccess(username: body.username, ip: ip)
        let token = PanelSession.newToken()
        try store.insertSession(tokenHash: PanelSession.hashToken(token), userID: user.id, expiresAt: PanelSession.expiry())
        audit(user: user.username, action: "login.success", outcome: "ok", ip: ip)

        var response = json(["ok": true])
        response.setCookie(sessionCookie(token: token))
        return response
    }

    @Sendable func logout(_ request: Request, context: PanelRequestContext) async throws -> Response {
        if let token = request.cookies[PanelSession.cookieName]?.value {
            try? store.deleteSession(tokenHash: PanelSession.hashToken(token))
        }
        if let user = context.identity {
            audit(user: user.username, action: "logout", outcome: "ok", ip: context.clientIP)
        }
        var response = json(["ok": true])
        response.setCookie(expiredCookie())
        return response
    }

    // MARK: API (JSON)

    struct GrantDTO: Encodable {
        let container: String
        let view, power, files, console, schedules, lifecycle: Bool
    }
    struct MeResponse: Encodable {
        let username: String
        let isAdmin: Bool
        let grants: [GrantDTO]
    }

    @Sendable func apiMe(_ request: Request, context: PanelRequestContext) async throws -> Response {
        let user = try context.requireIdentity()
        let grants = try store.grants(forUserID: user.id)
        let dto = MeResponse(
            username: user.username,
            isAdmin: user.isAdmin,
            grants: grants.map { name, grant in
                GrantDTO(
                    container: name, view: grant.view, power: grant.power, files: grant.files, console: grant.console,
                    schedules: grant.schedules, lifecycle: grant.lifecycle)
            }.sorted { $0.container < $1.container }
        )
        return encode(dto)
    }

    struct ContainerSummary: Encodable {
        let name, image, status, state: String
        let running: Bool
        let health: String?
        let stack: String?
    }

    @Sendable func apiContainers(_ request: Request, context: PanelRequestContext) async throws -> Response {
        let user = try context.requireIdentity()
        let engine = try store.authorizationEngine(for: user)
        // The list is filtered to what the caller may view — nothing else.
        let visible = engine.visible(await containers.allContainers())
        let summaries = visible.map { container in
            ContainerSummary(
                name: container.name, image: container.image, status: container.status,
                state: container.state.rawValue, running: container.isRunning,
                health: container.health?.rawValue, stack: container.composeProject
            )
        }
        return encode(summaries)
    }

    struct ContainerDetail: Encodable {
        let name, image, status, state, ports: String
        let running: Bool
        let health: String?
        let stack: String?
        let permissions: Permissions
        let filesAvailable: Bool
        struct Permissions: Encodable { let view, power, files, console, schedules, lifecycle: Bool }
    }

    @Sendable func apiContainerDetail(_ request: Request, context: PanelRequestContext) async throws -> Response {
        // The scope middleware already 404'd anyone without view permission.
        let user = try context.requireIdentity()
        let name = try context.parameters.require("name")
        guard let container = await containers.container(named: name) else { throw notFound() }
        let engine = try store.authorizationEngine(for: user)
        audit(user: user.username, action: "container.view", container: name, outcome: "ok", ip: context.clientIP)
        return encode(
            ContainerDetail(
                name: container.name, image: container.image, status: container.status,
                state: container.state.rawValue, ports: container.ports, running: container.isRunning,
                health: container.health?.rawValue, stack: container.composeProject,
                permissions: .init(
                    view: engine.can(.view, containerNamed: name), power: engine.can(.power, containerNamed: name),
                    files: engine.can(.files, containerNamed: name), console: engine.can(.console, containerNamed: name),
                    schedules: engine.can(.schedules, containerNamed: name), lifecycle: engine.can(.lifecycle, containerNamed: name)
                ),
                filesAvailable: await containers.fileService(containerName: name) != nil
            ))
    }

    // MARK: Power

    struct PowerBody: Decodable { let action: String }

    @Sendable func apiPower(_ request: Request, context: PanelRequestContext) async throws -> Response {
        let user = try context.requireIdentity()
        let name = try context.parameters.require("name")
        guard let body = try? await request.decode(as: PowerBody.self, context: context),
            let action = ContainerStore.PowerAction(rawValue: body.action)
        else {
            return json(["error": "action must be start, stop, or restart"], status: .badRequest)
        }
        guard await containers.container(named: name) != nil else { throw notFound() }
        do {
            try await containers.power(action, containerName: name)
            audit(
                user: user.username, action: "container.power", container: name, outcome: "ok",
                ip: context.clientIP, detail: action.rawValue)
            return json(["ok": true])
        } catch {
            audit(
                user: user.username, action: "container.power", container: name, outcome: "error",
                ip: context.clientIP, detail: "\(action.rawValue): \(error)")
            return json(["error": "\(error)"], status: .internalServerError)
        }
    }

    // MARK: Lifecycle (gated on .lifecycle)

    @Sendable func apiPull(_ request: Request, context: PanelRequestContext) async throws -> Response {
        let user = try context.requireIdentity()
        let name = try context.parameters.require("name")
        guard let stream = await containers.pullImage(containerName: name) else { throw notFound() }
        audit(user: user.username, action: "container.lifecycle", container: name, outcome: "ok", ip: context.clientIP, detail: "pull")
        return Self.sseResponse(payloads: stream)
    }

    @Sendable func apiRecreate(_ request: Request, context: PanelRequestContext) async throws -> Response {
        let user = try context.requireIdentity()
        let name = try context.parameters.require("name")
        guard let stream = await containers.recreate(containerName: name) else {
            // No stack folder → recreate isn't possible for this container.
            return json(["error": "This container has no compose stack, so it can't be recreated."], status: .unprocessableContent)
        }
        audit(
            user: user.username, action: "container.lifecycle", container: name, outcome: "ok", ip: context.clientIP,
            detail: "recreate")
        return Self.sseResponse(payloads: stream)
    }

    @Sendable func apiComposeApply(_ request: Request, context: PanelRequestContext) async throws -> Response {
        let user = try context.requireIdentity()
        let name = try context.parameters.require("name")
        guard let stream = await containers.composeApply(containerName: name) else {
            return json(["error": "This container has no compose stack."], status: .unprocessableContent)
        }
        audit(
            user: user.username, action: "container.lifecycle", container: name, outcome: "ok", ip: context.clientIP,
            detail: "compose apply")
        return Self.sseResponse(payloads: stream)
    }

    @Sendable func apiRemove(_ request: Request, context: PanelRequestContext) async throws -> Response {
        let user = try context.requireIdentity()
        let name = try context.parameters.require("name")
        do {
            try await containers.remove(containerName: name)
            audit(
                user: user.username, action: "container.lifecycle", container: name, outcome: "ok", ip: context.clientIP,
                detail: "remove")
            return json(["ok": true])
        } catch ContainerServiceError.notFound {
            throw notFound()
        } catch let ContainerServiceError.conflict(reason) {
            audit(
                user: user.username, action: "container.lifecycle", container: name, outcome: "denied", ip: context.clientIP,
                detail: "remove: \(reason)")
            return json(["error": reason], status: .conflict)
        } catch {
            audit(
                user: user.username, action: "container.lifecycle", container: name, outcome: "error", ip: context.clientIP,
                detail: "remove: \(error)")
            return json(["error": "\(error)"], status: .internalServerError)
        }
    }

    // MARK: Daemon-global maintenance (admin-only)

    @Sendable func apiDiskUsage(_ request: Request, context: PanelRequestContext) async throws -> Response {
        let user = try context.requireIdentity()
        let output = (try? await containers.diskUsage()) ?? ""
        audit(user: user.username, action: "maintenance.disk", container: nil, outcome: "ok", ip: context.clientIP)
        return encode(["output": output])
    }

    @Sendable func apiImagePrune(_ request: Request, context: PanelRequestContext) async throws -> Response {
        let user = try context.requireIdentity()
        do {
            let output = try await containers.imagePrune()
            audit(user: user.username, action: "maintenance.image-prune", container: nil, outcome: "ok", ip: context.clientIP)
            return encode(["output": output])
        } catch {
            audit(
                user: user.username, action: "maintenance.image-prune", container: nil, outcome: "error", ip: context.clientIP,
                detail: "\(error)")
            return json(["error": "\(error)"], status: .internalServerError)
        }
    }

    // MARK: Logs (SSE)

    @Sendable func apiLogs(_ request: Request, context: PanelRequestContext) async throws -> Response {
        let user = try context.requireIdentity()
        let name = try context.parameters.require("name")
        guard let stream = await containers.logLines(containerName: name) else { throw notFound() }
        audit(user: user.username, action: "container.logs", container: name, outcome: "ok", ip: context.clientIP)
        return Self.sseResponse(payloads: stream)
    }

    struct LogSearchResult: Encodable {
        let query: String
        let matches: [String]
        let truncated: Bool
    }

    /// Searches recent logs for a substring (case-insensitive). Reads what docker
    /// already retains via its log driver — no duplicate log store. `q` filters;
    /// empty `q` returns the recent tail. `since` (e.g. "1h", "2026-09-02T10:00")
    /// and `tail` bound the window; results are capped so the payload is bounded.
    @Sendable func apiLogsSearch(_ request: Request, context: PanelRequestContext) async throws -> Response {
        let user = try context.requireIdentity()
        let name = try context.parameters.require("name")
        let q = request.uri.queryParameters["q"].map(String.init) ?? ""
        let since = request.uri.queryParameters["since"].map(String.init)
        let tail = request.uri.queryParameters["tail"].flatMap { Int($0) }.map { min(max($0, 1), 20_000) } ?? 5_000
        guard let history = await containers.logHistory(containerName: name, tail: tail, since: since) else {
            throw notFound()
        }
        let needle = q.lowercased()
        var matches = history.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if !needle.isEmpty { matches = matches.filter { $0.lowercased().contains(needle) } }
        let cap = 2_000
        let truncated = matches.count > cap
        audit(
            user: user.username, action: "container.logs", container: name, outcome: "ok",
            ip: context.clientIP, detail: "search q=\(q) (\(matches.count) matches)")
        return encode(LogSearchResult(query: q, matches: Array(matches.suffix(cap)), truncated: truncated))
    }

    /// Downloads the recent logs as a plain-text file (what docker retains).
    @Sendable func apiLogsDownload(_ request: Request, context: PanelRequestContext) async throws -> Response {
        let user = try context.requireIdentity()
        let name = try context.parameters.require("name")
        let tail = request.uri.queryParameters["tail"].flatMap { Int($0) }.map { min(max($0, 1), 100_000) } ?? 20_000
        guard let history = await containers.logHistory(containerName: name, tail: tail, since: nil) else {
            throw notFound()
        }
        audit(
            user: user.username, action: "container.logs", container: name, outcome: "ok",
            ip: context.clientIP, detail: "download logs")
        return Response(
            status: .ok,
            headers: [
                .contentType: "text/plain; charset=utf-8",
                .contentDisposition: Self.attachmentDisposition(filename: name + "-logs.txt"),
            ],
            body: .init(byteBuffer: ByteBuffer(string: history)))
    }

    // MARK: Stats (snapshot + SSE)

    struct StatsDTO: Encodable {
        let name: String
        let cpuPercent, memUsedBytes, memLimitBytes, memPercent, netRxBytes, netTxBytes: Double
        let pids: Int
        init(_ s: ContainerStats) {
            name = s.name
            cpuPercent = s.cpuPercent
            memUsedBytes = s.memUsedBytes
            memLimitBytes = s.memLimitBytes
            memPercent = s.memPercent
            netRxBytes = s.netRxBytes
            netTxBytes = s.netTxBytes
            pids = s.pids
        }
    }

    @Sendable func apiStatsSnapshot(_ request: Request, context: PanelRequestContext) async throws -> Response {
        let user = try context.requireIdentity()
        let engine = try store.authorizationEngine(for: user)
        // Filtered to viewable containers only — no stats leak for ungranted ones.
        let all = await containers.statsSnapshot()
        let visible = all.filter { engine.canView(containerNamed: $0.key) }
        return encode(visible.values.map(StatsDTO.init).sorted { $0.name < $1.name })
    }

    struct MetricSampleDTO: Encodable {
        let measuredAt: String
        let cpuPercent, memUsedBytes, memLimitBytes, memPercent, netRxBytes, netTxBytes: Double
        let pids: Int
        init(_ s: ContainerStats) {
            measuredAt = Self.iso.string(from: s.measuredAt)
            cpuPercent = s.cpuPercent
            memUsedBytes = s.memUsedBytes
            memLimitBytes = s.memLimitBytes
            memPercent = s.memPercent
            netRxBytes = s.netRxBytes
            netTxBytes = s.netTxBytes
            pids = s.pids
        }
        nonisolated(unsafe) static let iso: ISO8601DateFormatter = {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return f
        }()
    }

    /// Retained metric history for a container (gated on view — reading stats
    /// history needs no more than seeing the container). `?since=` is seconds of
    /// look-back; default the last hour, capped so the payload stays bounded.
    @Sendable func apiMetrics(_ request: Request, context: PanelRequestContext) async throws -> Response {
        let name = try context.parameters.require("name")
        let lookback = request.uri.queryParameters["since"].flatMap { Double($0) } ?? 3_600
        let clamped = min(max(lookback, 0), 7 * 24 * 3_600)  // never more than a week
        let since = Date().addingTimeInterval(-clamped)
        let samples = (try? store.metrics(container: name, since: since)) ?? []
        return encode(samples.map(MetricSampleDTO.init))
    }

    @Sendable func apiStatsStream(_ request: Request, context: PanelRequestContext) async throws -> Response {
        let user = try context.requireIdentity()
        let name = try context.parameters.require("name")
        guard let stream = await containers.statsStream(containerName: name) else {
            // Container not running / no stats: a short-lived SSE that says so,
            // rather than 404 (the container may exist but be stopped).
            return Self.sseResponse(payloads: singleMessage("{\"unavailable\":true}"))
        }
        audit(user: user.username, action: "container.stats", container: name, outcome: "ok", ip: context.clientIP)
        // Encode each measured sample as JSON; same heartbeat + teardown as logs,
        // so this stream dies with the connection and the poll loop stops — no
        // docker stats runs after the client is gone.
        let json = stream.map { sample -> String in
            let data = (try? JSONEncoder().encode(StatsDTO(sample))) ?? Data("{}".utf8)
            return String(decoding: data, as: UTF8.self)
        }
        return Self.sseResponse(payloads: json)
    }

    private func singleMessage(_ text: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(text)
            continuation.finish()
        }
    }

    /// Wraps any async payload sequence as a heartbeat SSE response. Each
    /// payload becomes a `data:` event; a `: ping` every 10s forces a write so
    /// a vanished client is noticed, which cancels the upstream task (killing
    /// its docker process / stopping its poll loop). No stream outlives its
    /// connection.
    static func sseResponse<S: AsyncSequence & Sendable>(payloads: S) -> Response where S.Element == String {
        let body = ResponseBody(contentLength: nil) { writer in
            let events = AsyncThrowingStream<ByteBuffer, Error> { continuation in
                let producer = Task {
                    do {
                        for try await payload in payloads {
                            let event = "data: \(payload.replacingOccurrences(of: "\n", with: "\ndata: "))\n\n"
                            continuation.yield(ByteBuffer(string: event))
                        }
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
                let heartbeat = Task {
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(10))
                        continuation.yield(ByteBuffer(string: ": ping\n\n"))
                    }
                }
                continuation.onTermination = { _ in
                    producer.cancel()
                    heartbeat.cancel()
                }
            }
            do {
                for try await event in events { try await writer.write(event) }
            } catch {}
            try? await writer.finish(nil)
        }
        return Response(
            status: .ok,
            headers: [
                .contentType: "text/event-stream",
                .cacheControl: "no-cache",
                .connection: "keep-alive",
            ], body: body)
    }

    // MARK: Schedules (gated on the schedules permission)

    struct ScheduleDTO: Encodable {
        let hour, minute: Int
        let weekdays: [Int]
        let description: String
        let lastRun: LastRun?
        struct LastRun: Encodable {
            let date: String
            let outcome: String
            let message: String
        }
    }
    struct ScheduleBody: Decodable {
        let hour: Int
        let minute: Int
        let weekdays: [Int]?
    }

    @Sendable func apiScheduleGet(_ request: Request, context: PanelRequestContext) async throws -> Response {
        let name = try context.parameters.require("name")
        guard await containers.container(named: name) != nil else { throw notFound() }
        guard let (schedule, last) = await containers.schedule(containerName: name) else {
            return encode(["schedule": Optional<ScheduleDTO>.none])
        }
        let dto = ScheduleDTO(
            hour: schedule.hour, minute: schedule.minute, weekdays: schedule.weekdays.sorted(),
            description: schedule.timeDescription,
            lastRun: last.map { .init(date: PanelSession.timestamp($0.date), outcome: outcomeString($0.outcome), message: $0.message) }
        )
        return encode(["schedule": dto])
    }

    @Sendable func apiScheduleSet(_ request: Request, context: PanelRequestContext) async throws -> Response {
        let user = try context.requireIdentity()
        let name = try context.parameters.require("name")
        guard await containers.container(named: name) != nil else { throw notFound() }
        guard let body = try? await request.decode(as: ScheduleBody.self, context: context),
            (0...23).contains(body.hour), (0...59).contains(body.minute)
        else {
            return json(["error": "hour 0–23 and minute 0–59 required"], status: .badRequest)
        }
        do {
            try await containers.setSchedule(
                containerName: name, hour: body.hour, minute: body.minute,
                weekdays: Set(body.weekdays ?? []))
            audit(
                user: user.username, action: "container.schedules", container: name, outcome: "ok",
                ip: context.clientIP, detail: "set \(String(format: "%02d:%02d", body.hour, body.minute))")
            return json(["ok": true])
        } catch {
            audit(
                user: user.username, action: "container.schedules", container: name, outcome: "error",
                ip: context.clientIP, detail: "\(error)")
            return json(["error": "\(error)"], status: .internalServerError)
        }
    }

    @Sendable func apiScheduleDelete(_ request: Request, context: PanelRequestContext) async throws -> Response {
        let user = try context.requireIdentity()
        let name = try context.parameters.require("name")
        guard await containers.container(named: name) != nil else { throw notFound() }
        do {
            try await containers.removeSchedule(containerName: name)
            audit(
                user: user.username, action: "container.schedules", container: name, outcome: "ok",
                ip: context.clientIP, detail: "removed")
            return json(["ok": true])
        } catch {
            return json(["error": "\(error)"], status: .internalServerError)
        }
    }

    private func outcomeString(_ outcome: ScheduleOutcome) -> String {
        switch outcome {
        case .success: "ok"
        case .failed: "failed"
        case .timedOut: "timedOut"
        }
    }

    // MARK: Console

    struct ConsoleBody: Decodable { let command: String }

    @Sendable func apiConsole(_ request: Request, context: PanelRequestContext) async throws -> Response {
        let user = try context.requireIdentity()
        let name = try context.parameters.require("name")
        guard let body = try? await request.decode(as: ConsoleBody.self, context: context) else {
            return json(["error": "command required"], status: .badRequest)
        }
        guard let entry = await containers.runConsole(containerName: name, command: body.command) else {
            throw notFound()
        }
        audit(
            user: user.username, action: "container.console", container: name,
            outcome: entry.isError ? "error" : "ok", ip: context.clientIP, detail: body.command)
        return encode(ConsoleResult(command: entry.command, output: entry.output, isError: entry.isError))
    }
    struct ConsoleResult: Encodable {
        let command, output: String
        let isError: Bool
    }

    // MARK: Files

    struct FileEntryDTO: Encodable {
        let name, path: String
        let isDirectory: Bool
        let size: Int
    }

    @Sendable func apiFilesList(_ request: Request, context: PanelRequestContext) async throws -> Response {
        let (name, service) = try await fileService(context)
        let path = request.uri.queryParameters["path"].map(String.init) ?? ""
        do {
            let entries = try service.list(path).map {
                FileEntryDTO(name: $0.name, path: $0.relativePath, isDirectory: $0.isDirectory, size: $0.sizeBytes)
            }
            return encode(entries)
        } catch {
            return fileError(error, user: try context.requireIdentity().username, container: name, ip: context.clientIP)
        }
    }

    @Sendable func apiFileRead(_ request: Request, context: PanelRequestContext) async throws -> Response {
        let (name, service) = try await fileService(context)
        guard let path = request.uri.queryParameters["path"].map(String.init) else {
            return json(["error": "path required"], status: .badRequest)
        }
        do {
            let content = try service.read(path)
            audit(
                user: try context.requireIdentity().username, action: "container.files", container: name,
                outcome: "ok", ip: context.clientIP, detail: "read \(path)")
            return encode(FileContentDTO(path: path, text: content.text, lineEnding: content.lineEnding.rawValue))
        } catch {
            return fileError(
                error, user: try context.requireIdentity().username, container: name, ip: context.clientIP, detail: "read \(path)")
        }
    }
    struct FileContentDTO: Encodable { let path, text, lineEnding: String }

    struct FileWriteBody: Decodable {
        let text: String
        let lineEnding: String?
    }

    @Sendable func apiFileWrite(_ request: Request, context: PanelRequestContext) async throws -> Response {
        let (name, service) = try await fileService(context)
        guard let path = request.uri.queryParameters["path"].map(String.init),
            let body = try? await request.decode(as: FileWriteBody.self, context: context)
        else {
            return json(["error": "path and text required"], status: .badRequest)
        }
        let ending = LineEnding(rawValue: body.lineEnding ?? "lf") ?? .lf
        do {
            try service.write(path, text: body.text, lineEnding: ending)
            audit(
                user: try context.requireIdentity().username, action: "container.files", container: name,
                outcome: "ok", ip: context.clientIP, detail: "write \(path)")
            return json(["ok": true])
        } catch {
            return fileError(
                error, user: try context.requireIdentity().username, container: name, ip: context.clientIP, detail: "write \(path)")
        }
    }

    struct MkdirBody: Decodable { let path: String }

    @Sendable func apiFileMkdir(_ request: Request, context: PanelRequestContext) async throws -> Response {
        let (name, service) = try await fileService(context)
        guard let body = try? await request.decode(as: MkdirBody.self, context: context), !body.path.isEmpty else {
            return json(["error": "path required"], status: .badRequest)
        }
        do {
            try service.makeDirectory(body.path)
            audit(
                user: try context.requireIdentity().username, action: "container.files", container: name,
                outcome: "ok", ip: context.clientIP, detail: "mkdir \(body.path)")
            return json(["ok": true])
        } catch {
            return fileError(
                error, user: try context.requireIdentity().username, container: name, ip: context.clientIP,
                detail: "mkdir \(body.path)")
        }
    }

    struct MoveBody: Decodable {
        let from: String
        let to: String
    }

    @Sendable func apiFileMove(_ request: Request, context: PanelRequestContext) async throws -> Response {
        let (name, service) = try await fileService(context)
        guard let body = try? await request.decode(as: MoveBody.self, context: context),
            !body.from.isEmpty, !body.to.isEmpty
        else {
            return json(["error": "from and to required"], status: .badRequest)
        }
        do {
            try service.move(from: body.from, to: body.to)
            audit(
                user: try context.requireIdentity().username, action: "container.files", container: name,
                outcome: "ok", ip: context.clientIP, detail: "move \(body.from) -> \(body.to)")
            return json(["ok": true])
        } catch {
            return fileError(
                error, user: try context.requireIdentity().username, container: name, ip: context.clientIP,
                detail: "move \(body.from) -> \(body.to)")
        }
    }

    @Sendable func apiFileDelete(_ request: Request, context: PanelRequestContext) async throws -> Response {
        let (name, service) = try await fileService(context)
        guard let path = request.uri.queryParameters["path"].map(String.init), !path.isEmpty else {
            return json(["error": "path required"], status: .badRequest)
        }
        do {
            try service.delete(path)
            audit(
                user: try context.requireIdentity().username, action: "container.files", container: name,
                outcome: "ok", ip: context.clientIP, detail: "delete \(path)")
            return json(["ok": true])
        } catch {
            return fileError(
                error, user: try context.requireIdentity().username, container: name, ip: context.clientIP,
                detail: "delete \(path)")
        }
    }

    @Sendable func apiFileUpload(_ request: Request, context: PanelRequestContext) async throws -> Response {
        let (name, service) = try await fileService(context)
        guard let path = request.uri.queryParameters["path"].map(String.init), !path.isEmpty else {
            return json(["error": "path required"], status: .badRequest)
        }
        // Bound the in-memory collect to the same cap the service enforces, so an
        // oversize upload is rejected before we buffer the whole thing.
        let buffer: ByteBuffer
        do {
            buffer = try await request.body.collect(upTo: FileService.maxUploadBytes)
        } catch {
            return fileError(
                FileServiceError.tooLarge(actualBytes: FileService.maxUploadBytes + 1, limitBytes: FileService.maxUploadBytes),
                user: try context.requireIdentity().username, container: name, ip: context.clientIP, detail: "upload \(path)")
        }
        let data = Data(buffer.readableBytesView)
        do {
            try service.writeData(path, data: data)
            audit(
                user: try context.requireIdentity().username, action: "container.files", container: name,
                outcome: "ok", ip: context.clientIP, detail: "upload \(path) (\(data.count) bytes)")
            return json(["ok": true])
        } catch {
            return fileError(
                error, user: try context.requireIdentity().username, container: name, ip: context.clientIP,
                detail: "upload \(path)")
        }
    }

    @Sendable func apiFileDownload(_ request: Request, context: PanelRequestContext) async throws -> Response {
        let (name, service) = try await fileService(context)
        guard let path = request.uri.queryParameters["path"].map(String.init), !path.isEmpty else {
            return json(["error": "path required"], status: .badRequest)
        }
        let target: (url: URL, size: Int)
        do {
            target = try service.downloadTarget(path)
        } catch {
            return fileError(
                error, user: try context.requireIdentity().username, container: name, ip: context.clientIP,
                detail: "download \(path)")
        }
        audit(
            user: try context.requireIdentity().username, action: "container.files", container: name,
            outcome: "ok", ip: context.clientIP, detail: "download \(path)")
        return Self.fileDownloadResponse(url: target.url, size: target.size)
    }

    /// A safe `Content-Disposition: attachment` value. The quoted ASCII fallback
    /// has control bytes, quotes, backslashes, and non-ASCII replaced (no header
    /// splitting, no reliance on the framework's legalizer), and an RFC 6266
    /// `filename*=UTF-8''…` preserves the real (possibly non-ASCII) name.
    static func attachmentDisposition(filename: String) -> String {
        let ascii = String(
            filename.unicodeScalars.map { scalar -> Character in
                if scalar.value < 0x20 || scalar.value > 0x7E || scalar == "\"" || scalar == "\\" {
                    return "_"
                }
                return Character(scalar)
            })
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let encoded = filename.addingPercentEncoding(withAllowedCharacters: allowed) ?? ascii
        return "attachment; filename=\"\(ascii)\"; filename*=UTF-8''\(encoded)"
    }

    /// Streams a confined file from disk in bounded chunks so a large download
    /// never loads the whole file into memory. The path was already validated by
    /// `FileService.downloadTarget`. Reads at most the declared `size` so the body
    /// can never exceed the `Content-Length` even if the file grows mid-stream.
    static func fileDownloadResponse(url: URL, size: Int) -> Response {
        let disposition = attachmentDisposition(filename: url.lastPathComponent)
        let body = ResponseBody(contentLength: size) { writer in
            guard let handle = try? FileHandle(forReadingFrom: url) else {
                try await writer.finish(nil)
                return
            }
            defer { try? handle.close() }
            var remaining = size
            while remaining > 0 {
                let chunk = (try? handle.read(upToCount: min(64 * 1024, remaining))) ?? Data()
                if chunk.isEmpty { break }
                try await writer.write(ByteBuffer(bytes: chunk))
                remaining -= chunk.count
            }
            try await writer.finish(nil)
        }
        return Response(
            status: .ok,
            headers: [.contentType: "application/octet-stream", .contentDisposition: disposition],
            body: body)
    }

    /// Resolves the FileService for the addressed container, or 404 if it has no
    /// stack folder — same rule as the native app (files unavailable, not a
    /// broken route). The scope middleware has already enforced the files perm.
    private func fileService(_ context: PanelRequestContext) async throws -> (name: String, service: FileService) {
        let name = try context.parameters.require("name")
        guard let service = await containers.fileService(containerName: name) else { throw notFound() }
        return (name, service)
    }

    private func fileError(_ error: Error, user: String, container: String, ip: String, detail: String? = nil) -> Response {
        try? store.recordAudit(
            username: user, action: "container.files", containerName: container,
            outcome: "denied", sourceIP: ip, detail: detail)
        let status: HTTPResponse.Status =
            switch error {
            case FileServiceError.escapesRoot, FileServiceError.invalidPath: .forbidden
            case FileServiceError.notFound: .notFound
            case FileServiceError.tooLarge, FileServiceError.binaryFile: .unprocessableContent
            default: .badRequest
            }
        return json(["error": FileServiceMessage.describe(error)], status: status)
    }

    // MARK: helpers

    /// A bare 404 with no body — identical whether it comes from the scope
    /// middleware (ungranted) or a handler (genuinely nonexistent), so the two
    /// cases are indistinguishable to the caller.
    private func notFound() -> HTTPError { HTTPError(.notFound) }

    private func audit(user: String, action: String, container: String? = nil, outcome: String, ip: String, detail: String? = nil) {
        try? store.recordAudit(
            username: user, action: action, containerName: container,
            outcome: outcome, sourceIP: ip, detail: detail)
    }

    private func sessionCookie(token: String) -> Cookie {
        Cookie(
            name: PanelSession.cookieName, value: token,
            maxAge: PanelSession.lifetimeDays * 86_400,
            path: "/",
            secure: secureCookies,  // Secure when serving HTTPS; plain when behind a tunnel
            httpOnly: true,  // not visible to page scripts
            sameSite: .lax  // Lax, not Strict: survives the top-level return from Cloudflare Access
        )
    }

    private func expiredCookie() -> Cookie {
        Cookie(
            name: PanelSession.cookieName, value: "", maxAge: 0, path: "/",
            secure: secureCookies, httpOnly: true, sameSite: .lax)
    }

    private func redirect(_ location: String) -> Response {
        Response(status: .seeOther, headers: [.location: location])
    }

    private func html(_ body: String) -> Response {
        Response(
            status: .ok, headers: [.contentType: "text/html; charset=utf-8"],
            body: .init(byteBuffer: ByteBuffer(string: body)))
    }

    private func json(_ object: [String: some Encodable & Sendable], status: HTTPResponse.Status = .ok) -> Response {
        let data = (try? JSONSerialization.data(withJSONObject: object.mapValues { anyify($0) })) ?? Data("{}".utf8)
        return Response(
            status: status, headers: [.contentType: "application/json"],
            body: .init(byteBuffer: ByteBuffer(bytes: data)))
    }

    private func anyify(_ value: some Encodable) -> Any {
        if let bool = value as? Bool { return bool }
        if let int = value as? Int { return int }
        return String(describing: value)
    }

    private func encode(_ value: some Encodable, status: HTTPResponse.Status = .ok) -> Response {
        let data = (try? JSONEncoder().encode(value)) ?? Data("{}".utf8)
        return Response(
            status: status, headers: [.contentType: "application/json"],
            body: .init(byteBuffer: ByteBuffer(bytes: data)))
    }
}
