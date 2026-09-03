import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdAuth
import MacerodactylKit

/// The custom header a mutating request must carry (CSRF defense).
enum PanelHeaders {
    static let csrf = HTTPField.Name("X-Macerodactyl-CSRF")!
}

/// Populates `identity` from the session cookie — the ONLY source of identity.
/// A missing or invalid cookie simply leaves the request unauthenticated; it
/// never reads a proxy header to decide who the caller is.
struct SessionAuthenticator: RouterMiddleware {
    typealias Context = PanelRequestContext
    let store: PanelDataStore

    func handle(_ request: Request, context: Context, next: (Request, Context) async throws -> Response) async throws -> Response {
        guard let token = request.cookies[PanelSession.cookieName]?.value else {
            return try await next(request, context)
        }
        let tokenHash = PanelSession.hashToken(token)
        guard let user = try? store.sessionUser(tokenHash: tokenHash, now: PanelSession.timestamp()) else {
            return try await next(request, context)
        }
        var context = context
        context.identity = user
        return try await next(request, context)
    }
}

/// Rejects mutating requests (POST/PUT/PATCH/DELETE) that lack the custom CSRF
/// header. Because browsers won't attach a custom header on a cross-site form
/// post, requiring one blocks cross-site request forgery — including against
/// the login endpoint, which runs before any session exists.
struct CSRFMiddleware: RouterMiddleware {
    typealias Context = PanelRequestContext

    func handle(_ request: Request, context: Context, next: (Request, Context) async throws -> Response) async throws -> Response {
        let mutating: Set<HTTPRequest.Method> = [.post, .put, .patch, .delete]
        if mutating.contains(request.method), request.headers[PanelHeaders.csrf] == nil {
            throw HTTPError(.forbidden, message: "Missing CSRF header")
        }
        return try await next(request, context)
    }
}

/// Requires an authenticated identity; otherwise 401 for API routes.
struct RequireAuth: RouterMiddleware {
    typealias Context = PanelRequestContext

    func handle(_ request: Request, context: Context, next: (Request, Context) async throws -> Response) async throws -> Response {
        _ = try context.requireIdentity()
        return try await next(request, context)
    }
}

/// Requires an admin identity; otherwise 404 (existence of the maintenance
/// surface is not revealed to non-admins). Used for daemon-global operations
/// (image prune, disk usage) that fall outside any single container's scope and
/// so must never be reachable by a scoped user.
struct RequireAdmin: RouterMiddleware {
    typealias Context = PanelRequestContext

    func handle(_ request: Request, context: Context, next: (Request, Context) async throws -> Response) async throws -> Response {
        let user = try context.requireIdentity()
        guard user.isAdmin else { throw HTTPError(.notFound) }
        return try await next(request, context)
    }
}

/// Container-level scoping, applied to the whole container route group so every
/// current and future container route inherits it — no route re-implements its
/// own check. The permission a route requires is derived here from its path and
/// method, in one place.
///
/// Two distinct outcomes:
/// - **No view permission → 404.** The existence of a container the caller
///   isn't granted is never revealed; this response is identical to the one for
///   a container that genuinely doesn't exist (see PanelRoutes' not-found).
/// - **Has view but lacks the action's permission → 403.** The caller already
///   knows the container exists (they can view it), so power/files/console
///   being forbidden is an honest 403, not a hidden 404.
struct ContainerScopeMiddleware: RouterMiddleware {
    typealias Context = PanelRequestContext
    let store: PanelDataStore

    func handle(_ request: Request, context: Context, next: (Request, Context) async throws -> Response) async throws -> Response {
        let user = try context.requireIdentity()
        guard let name = context.parameters.get("name") else {
            return try await next(request, context)  // list route: no container to scope
        }
        let engine = try store.authorizationEngine(for: user)
        let required = Self.requiredPermission(path: request.uri.path)

        // Existence gate first: without view, the container is invisible → 404.
        guard engine.canView(containerNamed: name) else {
            try? store.recordAudit(
                username: user.username, action: auditAction(for: required),
                containerName: name, outcome: "denied", sourceIP: context.clientIP)
            throw HTTPError(.notFound)
        }
        // Action gate: viewable, but this specific action may still be forbidden.
        if required != .view, !engine.can(required, containerNamed: name) {
            try? store.recordAudit(
                username: user.username, action: auditAction(for: required),
                containerName: name, outcome: "denied", sourceIP: context.clientIP)
            throw HTTPError(.forbidden)
        }
        // Suspension gate: a suspended server is read-only for everyone except an
        // admin (who needs to manage/unsuspend it). View-only routes still pass.
        if required != .view, !user.isAdmin {
            let record = (try? store.serverRecord(name: name)) ?? nil
            if record?.status == "suspended" {
                try? store.recordAudit(
                    username: user.username, action: auditAction(for: required),
                    containerName: name, outcome: "denied", sourceIP: context.clientIP, detail: "suspended")
                throw HTTPError(.forbidden)
            }
        }
        return try await next(request, context)
    }

    /// Maps a container route path to the permission it requires — the single
    /// place this mapping lives. Matches on the fixed route position
    /// (`/api/containers/<name>/<action>/…`) rather than substring-containment,
    /// so a container literally named `files`/`power`/`console`/`schedule`
    /// cannot make an action mis-map to the wrong (weaker) permission.
    static func requiredPermission(path: String) -> ContainerPermission {
        let comps = path.split(separator: "/").map(String.init)
        // Fixed mount: ["api", "containers", <name>, <action>, …]. Anything
        // shorter is the list/detail route and needs only view.
        guard comps.count >= 4, comps[0] == "api", comps[1] == "containers" else {
            return .view
        }
        switch comps[3] {
        case "files": return .files
        case "schedule": return .schedules
        case "console": return .console
        case "power": return .power
        case "backups": return .backups
        case "pull", "recreate", "remove", "compose": return .lifecycle
        default: return .view  // detail, logs, stats, metrics
        }
    }

    private func auditAction(for permission: ContainerPermission) -> String {
        switch permission {
        case .view: "container.view"
        case .power: "container.power"
        case .files: "container.files"
        case .console: "container.console"
        case .schedules: "container.schedules"
        case .lifecycle: "container.lifecycle"
        case .backups: "container.backups"
        }
    }
}
