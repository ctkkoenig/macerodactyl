import Foundation
import Hummingbird
import HummingbirdAuth
import MacerodactylKit
import NIOCore

struct PanelRoutes {
    let store: PanelDataStore
    let rateLimiter: LoginRateLimiter

    func register(on router: Router<PanelRequestContext>) {
        router.get("/", use: root)
        router.get("login", use: loginPage)
        router.post("login", use: login)
        router.post("logout", use: logout)
        router.get("me", use: identityPage)

        let api = router.group("api").add(middleware: RequireAuth())
        api.get("me", use: apiMe)

        let containers = api.group("containers").add(middleware: ContainerScopeMiddleware(store: store))
        containers.get(use: apiContainers)
        containers.get(":name", use: apiContainerDetail)
    }

    // MARK: HTML pages

    @Sendable func root(_ request: Request, context: PanelRequestContext) async throws -> Response {
        redirect(context.identity == nil ? "/login" : "/me")
    }

    @Sendable func loginPage(_ request: Request, context: PanelRequestContext) async throws -> Response {
        if context.identity != nil { return redirect("/me") }
        return html(PanelHTML.login())
    }

    @Sendable func identityPage(_ request: Request, context: PanelRequestContext) async throws -> Response {
        guard let user = context.identity else { return redirect("/login") }
        let grants = try store.grants(forUserID: user.id)
        return html(PanelHTML.identity(user: user, grants: grants))
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

    struct ContainersResponse: Encodable {
        let scope: String        // "all" for admins, "granted" for scoped users
        let containers: [String]
    }

    @Sendable func apiContainers(_ request: Request, context: PanelRequestContext) async throws -> Response {
        let user = try context.requireIdentity()
        if user.isAdmin {
            // Admins can see everything; the live container list arrives with
            // container features next phase, so nothing is enumerated here yet.
            return encode(ContainersResponse(scope: "all", containers: []))
        }
        // A scoped user sees only the containers they can view — nothing else.
        let names = try store.grants(forUserID: user.id)
            .filter { $0.value.view }.keys.sorted()
        return encode(ContainersResponse(scope: "granted", containers: names))
    }

    struct ContainerDetail: Encodable {
        let name: String
        let view, power, files, console: Bool
    }

    @Sendable func apiContainerDetail(_ request: Request, context: PanelRequestContext) async throws -> Response {
        // The scope middleware already 404'd anyone without view permission.
        let user = try context.requireIdentity()
        let name = try context.parameters.require("name")
        let engine = try store.authorizationEngine(for: user)
        audit(user: user.username, action: "container.view", container: name, outcome: "ok", ip: context.clientIP)
        return encode(ContainerDetail(
            name: name,
            view: engine.can(.view, containerNamed: name),
            power: engine.can(.power, containerNamed: name),
            files: engine.can(.files, containerNamed: name),
            console: engine.can(.console, containerNamed: name)
        ))
    }

    // MARK: helpers

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
