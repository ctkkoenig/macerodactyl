import Foundation
import Hummingbird
import HummingbirdAuth
import MacerodactylKit
import NIOCore

struct PanelRoutes {
    let store: PanelDataStore
    let rateLimiter: LoginRateLimiter
    let containers: ContainerService

    func register(on router: Router<PanelRequestContext>) {
        router.get("/", use: root)
        router.get("login", use: loginPage)
        router.post("login", use: login)
        router.post("logout", use: logout)
        router.get("me", use: appPage)

        let api = router.group("api").add(middleware: RequireAuth())
        api.get("me", use: apiMe)
        api.get("stats", use: apiStatsSnapshot)

        // Every container route inherits the scoping middleware; none re-checks.
        let scoped = api.group("containers").add(middleware: ContainerScopeMiddleware(store: store))
        scoped.get(use: apiContainers)
        scoped.get(":name", use: apiContainerDetail)
        scoped.post(":name/power", use: apiPower)
        scoped.get(":name/logs", use: apiLogs)
        scoped.get(":name/stats", use: apiStatsStream)
        scoped.post(":name/console", use: apiConsole)
        scoped.get(":name/files", use: apiFilesList)
        scoped.get(":name/files/content", use: apiFileRead)
        scoped.put(":name/files/content", use: apiFileWrite)
        scoped.get(":name/schedule", use: apiScheduleGet)
        scoped.post(":name/schedule", use: apiScheduleSet)
        scoped.delete(":name/schedule", use: apiScheduleDelete)
    }

    // MARK: HTML pages

    @Sendable func root(_ request: Request, context: PanelRequestContext) async throws -> Response {
        redirect(context.identity == nil ? "/login" : "/me")
    }

    @Sendable func loginPage(_ request: Request, context: PanelRequestContext) async throws -> Response {
        if context.identity != nil { return redirect("/me") }
        return html(PanelHTML.login())
    }

    @Sendable func appPage(_ request: Request, context: PanelRequestContext) async throws -> Response {
        guard context.identity != nil else { return redirect("/login") }
        return html(PanelHTML.app())
    }

    // MARK: Auth

    struct LoginBody: Decodable { let username: String; let password: String }

    @Sendable func login(_ request: Request, context: PanelRequestContext) async throws -> Response {
        let ip = context.clientIP
        let body = try? await request.decode(as: LoginBody.self, context: context)
        guard let body, !body.username.isEmpty else {
            return json(["error": "Missing credentials"], status: .badRequest)
        }

        let decision = await rateLimiter.check(username: body.username, ip: ip)
        guard decision.allowed else {
            audit(user: body.username, action: "login.ratelimited", outcome: "blocked", ip: ip,
                  detail: "retry after \(Int(decision.retryAfter))s")
            var response = json(["error": "Too many attempts. Try again later."], status: .tooManyRequests)
            response.headers[.retryAfter] = String(Int(decision.retryAfter.rounded(.up)))
            return response
        }

        guard let user = try? store.user(named: body.username),
              await PasswordHasher.verify(body.password, hash: user.passwordHash) else {
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
        let view, power, files, console: Bool
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
                GrantDTO(container: name, view: grant.view, power: grant.power, files: grant.files, console: grant.console)
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
        struct Permissions: Encodable { let view, power, files, console: Bool }
    }

    @Sendable func apiContainerDetail(_ request: Request, context: PanelRequestContext) async throws -> Response {
        // The scope middleware already 404'd anyone without view permission.
        let user = try context.requireIdentity()
        let name = try context.parameters.require("name")
        guard let container = await containers.container(named: name) else { throw notFound() }
        let engine = try store.authorizationEngine(for: user)
        audit(user: user.username, action: "container.view", container: name, outcome: "ok", ip: context.clientIP)
        return encode(ContainerDetail(
            name: container.name, image: container.image, status: container.status,
            state: container.state.rawValue, ports: container.ports, running: container.isRunning,
            health: container.health?.rawValue, stack: container.composeProject,
            permissions: .init(
                view: engine.can(.view, containerNamed: name), power: engine.can(.power, containerNamed: name),
                files: engine.can(.files, containerNamed: name), console: engine.can(.console, containerNamed: name)
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
              let action = ContainerStore.PowerAction(rawValue: body.action) else {
            return json(["error": "action must be start, stop, or restart"], status: .badRequest)
        }
        guard await containers.container(named: name) != nil else { throw notFound() }
        do {
            try await containers.power(action, containerName: name)
            audit(user: user.username, action: "container.power", container: name, outcome: "ok",
                  ip: context.clientIP, detail: action.rawValue)
            return json(["ok": true])
        } catch {
            audit(user: user.username, action: "container.power", container: name, outcome: "error",
                  ip: context.clientIP, detail: "\(action.rawValue): \(error)")
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

    // MARK: Stats (snapshot + SSE)

    struct StatsDTO: Encodable {
        let name: String
        let cpuPercent, memUsedBytes, memLimitBytes, memPercent, netRxBytes, netTxBytes: Double
        let pids: Int
        init(_ s: ContainerStats) {
            name = s.name; cpuPercent = s.cpuPercent; memUsedBytes = s.memUsedBytes
            memLimitBytes = s.memLimitBytes; memPercent = s.memPercent
            netRxBytes = s.netRxBytes; netTxBytes = s.netTxBytes; pids = s.pids
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
                continuation.onTermination = { _ in producer.cancel(); heartbeat.cancel() }
            }
            do {
                for try await event in events { try await writer.write(event) }
            } catch {}
            try? await writer.finish(nil)
        }
        return Response(status: .ok, headers: [
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
        struct LastRun: Encodable { let date: String; let outcome: String; let message: String }
    }
    struct ScheduleBody: Decodable { let hour: Int; let minute: Int; let weekdays: [Int]? }

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
              (0...23).contains(body.hour), (0...59).contains(body.minute) else {
            return json(["error": "hour 0–23 and minute 0–59 required"], status: .badRequest)
        }
        do {
            try await containers.setSchedule(containerName: name, hour: body.hour, minute: body.minute,
                                             weekdays: Set(body.weekdays ?? []))
            audit(user: user.username, action: "container.schedules", container: name, outcome: "ok",
                  ip: context.clientIP, detail: "set \(String(format: "%02d:%02d", body.hour, body.minute))")
            return json(["ok": true])
        } catch {
            audit(user: user.username, action: "container.schedules", container: name, outcome: "error",
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
            audit(user: user.username, action: "container.schedules", container: name, outcome: "ok",
                  ip: context.clientIP, detail: "removed")
            return json(["ok": true])
        } catch {
            return json(["error": "\(error)"], status: .internalServerError)
        }
    }

    private func outcomeString(_ outcome: ScheduleOutcome) -> String {
        switch outcome { case .success: "ok"; case .failed: "failed"; case .timedOut: "timedOut" }
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
        audit(user: user.username, action: "container.console", container: name,
              outcome: entry.isError ? "error" : "ok", ip: context.clientIP, detail: body.command)
        return encode(ConsoleResult(command: entry.command, output: entry.output, isError: entry.isError))
    }
    struct ConsoleResult: Encodable { let command, output: String; let isError: Bool }

    // MARK: Files

    struct FileEntryDTO: Encodable { let name, path: String; let isDirectory: Bool; let size: Int }

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
            audit(user: try context.requireIdentity().username, action: "container.files", container: name,
                  outcome: "ok", ip: context.clientIP, detail: "read \(path)")
            return encode(FileContentDTO(path: path, text: content.text, lineEnding: content.lineEnding.rawValue))
        } catch {
            return fileError(error, user: try context.requireIdentity().username, container: name, ip: context.clientIP, detail: "read \(path)")
        }
    }
    struct FileContentDTO: Encodable { let path, text, lineEnding: String }

    struct FileWriteBody: Decodable { let text: String; let lineEnding: String? }

    @Sendable func apiFileWrite(_ request: Request, context: PanelRequestContext) async throws -> Response {
        let (name, service) = try await fileService(context)
        guard let path = request.uri.queryParameters["path"].map(String.init),
              let body = try? await request.decode(as: FileWriteBody.self, context: context) else {
            return json(["error": "path and text required"], status: .badRequest)
        }
        let ending = LineEnding(rawValue: body.lineEnding ?? "lf") ?? .lf
        do {
            try service.write(path, text: body.text, lineEnding: ending)
            audit(user: try context.requireIdentity().username, action: "container.files", container: name,
                  outcome: "ok", ip: context.clientIP, detail: "write \(path)")
            return json(["ok": true])
        } catch {
            return fileError(error, user: try context.requireIdentity().username, container: name, ip: context.clientIP, detail: "write \(path)")
        }
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
        try? store.recordAudit(username: user, action: "container.files", containerName: container,
                              outcome: "denied", sourceIP: ip, detail: detail)
        let status: HTTPResponse.Status = switch error {
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
        try? store.recordAudit(username: user, action: action, containerName: container,
                               outcome: outcome, sourceIP: ip, detail: detail)
    }

    private func sessionCookie(token: String) -> Cookie {
        Cookie(
            name: PanelSession.cookieName, value: token,
            maxAge: PanelSession.lifetimeDays * 86_400,
            path: "/",
            secure: false,      // plain HTTP hop behind the tunnel
            httpOnly: true,     // not visible to page scripts
            sameSite: .lax      // Lax, not Strict: survives the top-level return from Cloudflare Access
        )
    }

    private func expiredCookie() -> Cookie {
        Cookie(name: PanelSession.cookieName, value: "", maxAge: 0, path: "/", secure: false, httpOnly: true, sameSite: .lax)
    }

    private func redirect(_ location: String) -> Response {
        Response(status: .seeOther, headers: [.location: location])
    }

    private func html(_ body: String) -> Response {
        Response(status: .ok, headers: [.contentType: "text/html; charset=utf-8"],
                 body: .init(byteBuffer: ByteBuffer(string: body)))
    }

    private func json(_ object: [String: some Encodable & Sendable], status: HTTPResponse.Status = .ok) -> Response {
        let data = (try? JSONSerialization.data(withJSONObject: object.mapValues { anyify($0) })) ?? Data("{}".utf8)
        return Response(status: status, headers: [.contentType: "application/json"],
                        body: .init(byteBuffer: ByteBuffer(data: data)))
    }

    private func anyify(_ value: some Encodable) -> Any {
        if let bool = value as? Bool { return bool }
        if let int = value as? Int { return int }
        return String(describing: value)
    }

    private func encode(_ value: some Encodable, status: HTTPResponse.Status = .ok) -> Response {
        let data = (try? JSONEncoder().encode(value)) ?? Data("{}".utf8)
        return Response(status: status, headers: [.contentType: "application/json"],
                        body: .init(byteBuffer: ByteBuffer(data: data)))
    }
}
