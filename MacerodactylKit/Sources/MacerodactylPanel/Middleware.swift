import Foundation
import Hummingbird
import HummingbirdAuth
import HTTPTypes
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

/// Container-level scoping, applied to the whole container route group so every
/// current and future container route inherits it rather than each re-checking.
/// When a route addresses a specific container (`:name`), the caller must have
/// at least view permission — and a user who lacks it gets **404, not 403**, so
/// the existence of containers they aren't granted is never revealed.
struct ContainerScopeMiddleware: RouterMiddleware {
    typealias Context = PanelRequestContext
    let store: PanelDataStore

    func handle(_ request: Request, context: Context, next: (Request, Context) async throws -> Response) async throws -> Response {
        let user = try context.requireIdentity()
        if let name = context.parameters.get("name") {
            let engine = try store.authorizationEngine(for: user)
            guard engine.canView(containerNamed: name) else {
                // Blocked attempts are audited too — a denied access is an
                // action. The response is 404 so existence isn't revealed to
                // the caller, but the admin-only audit log records it.
                try? store.recordAudit(
                    username: user.username, action: "container.view",
                    containerName: name, outcome: "denied", sourceIP: context.clientIP
                )
                throw HTTPError(.notFound)
            }
        }
        return try await next(request, context)
    }
}
