import Foundation
import Hummingbird
import MacerodactylKit

/// Owner-managed sub-users: a server's **owner** (or an admin) may grant another
/// existing account a subset of the per-container permissions on *that* server,
/// and revoke them. This is the delegation surface behind the panel's multi-user
/// pitch — the only place a non-admin can hand out access.
///
/// Two invariants keep it from becoming an escalation path:
/// - **Only the owner or an admin may manage sub-users** (checked in every
///   handler; the scope middleware only proves `view`, which every party has).
/// - **Granted ⊆ granter's ceiling.** A sub-user's grant is intersected with the
///   granter's own effective permissions on the server, so no one can hand out
///   more than they hold. Owner/admin ceilings are full; the intersection still
///   documents intent and stays correct if the ceiling ever narrows.
///
/// The owner and admins are never themselves listed or editable as sub-users:
/// the owner already has the full grant, and admins see everything unconditionally.
extension PanelRoutes {
    struct SubUserDTO: Encodable {
        let username: String
        let permissions: [String]
    }

    struct SubUsersResponse: Encodable {
        /// Whether the caller may edit this list (owner or admin). The client
        /// hides the whole Users tab when false.
        let canManage: Bool
        /// Files can only be granted when the container has a stack folder; the
        /// client greys the files checkbox out otherwise.
        let filesGrantable: Bool
        /// The permission keys the client should render, in display order.
        let permissionKeys: [String]
        let subusers: [SubUserDTO]
    }

    struct SetSubUserBody: Decodable {
        let username: String
        /// Permission keys to grant. Empty revokes the sub-user entirely. `view`
        /// is implied whenever any permission is granted.
        let permissions: [String]
    }

    /// The permission keys offered in the sub-user editor, in a stable display
    /// order. `view` is implicit (any grant carries it) so it isn't a checkbox.
    static let subUserPermissionKeys: [String] = ["power", "console", "files", "schedules", "backups", "lifecycle"]

    /// True when `user` may manage sub-users on `serverName`: an admin, or the
    /// server's recorded owner. A server with no owner record (or a bare
    /// container that was never provisioned) is admin-only.
    func canManageSubUsers(_ user: PanelUser, serverName: String) -> Bool {
        if user.isAdmin { return true }
        guard let record = try? store.serverRecord(name: serverName) else { return false }
        return record.ownerUserID == user.id
    }

    /// The granter's own effective grant on the server — the ceiling a delegated
    /// grant may not exceed. Owner and admin hold everything; anyone else holds
    /// exactly their stored grant.
    private func ceilingGrant(_ user: PanelUser, serverName: String) -> ContainerGrant {
        if user.isAdmin { return Self.fullGrant }
        if let record = try? store.serverRecord(name: serverName), record.ownerUserID == user.id {
            return Self.fullGrant
        }
        return (try? store.grants(forUserID: user.id)[serverName]) ?? ContainerGrant()
    }

    static let fullGrant = ContainerGrant(
        view: true, power: true, files: true, console: true, schedules: true, lifecycle: true, backups: true)

    private func grantKeys(_ grant: ContainerGrant) -> [String] {
        Self.subUserPermissionKeys.filter { ContainerPermission(rawValue: $0).map(grant.allows) ?? false }
    }

    // MARK: List

    @Sendable func apiSubUsersList(_ request: Request, context: PanelRequestContext) async throws -> Response {
        let user = try context.requireIdentity()
        let name = try context.parameters.require("name")
        guard canManageSubUsers(user, serverName: name) else { throw HTTPError(.forbidden) }
        let ownerID = (try? store.serverRecord(name: name))?.ownerUserID
        let filesGrantable = await containers.fileService(containerName: name) != nil

        var subusers: [SubUserDTO] = []
        for entry in (try? store.grantsForContainer(named: name)) ?? [] {
            // The owner and admins are not sub-users.
            if entry.userID == ownerID { continue }
            guard let account = try? store.user(id: entry.userID), !account.isAdmin else { continue }
            subusers.append(SubUserDTO(username: account.username, permissions: grantKeys(entry.grant)))
        }
        subusers.sort { $0.username.lowercased() < $1.username.lowercased() }
        return encode(
            SubUsersResponse(
                canManage: true, filesGrantable: filesGrantable,
                permissionKeys: Self.subUserPermissionKeys, subusers: subusers))
    }

    // MARK: Set (add or update)

    @Sendable func apiSubUserSet(_ request: Request, context: PanelRequestContext) async throws -> Response {
        let user = try context.requireIdentity()
        let name = try context.parameters.require("name")
        guard canManageSubUsers(user, serverName: name) else { throw HTTPError(.forbidden) }
        guard let body = try? await request.decode(as: SetSubUserBody.self, context: context) else {
            return json(["error": "invalid request body"], status: .badRequest)
        }
        let username = body.username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let target = try? store.user(named: username) else {
            return json(["error": "no account named “\(username)”"], status: .badRequest)
        }
        // Admins already see everything; the owner already holds the full grant.
        if target.isAdmin {
            return json(["error": "administrators already have full access"], status: .badRequest)
        }
        let ownerID = (try? store.serverRecord(name: name))?.ownerUserID
        if target.id == ownerID {
            return json(["error": "the owner already has full access"], status: .badRequest)
        }

        // Validate requested keys, then intersect with the granter's ceiling.
        var requested = ContainerGrant()
        for key in body.permissions {
            guard let perm = ContainerPermission(rawValue: key), perm != .view else {
                return json(["error": "unknown permission “\(key)”"], status: .badRequest)
            }
            requested.set(perm, true)
        }
        // Empty selection means "remove this sub-user".
        if requested.isEmpty {
            try store.setGrant(userID: target.id, containerName: name, grant: ContainerGrant())
            audit(
                user: user.username, action: "container.subuser", container: name, outcome: "ok",
                ip: context.clientIP, detail: "remove \(target.username)")
            return json(["ok": true, "removed": true])
        }
        requested.view = true  // any grant implies visibility
        let granted = requested.intersection(with: ceilingGrant(user, serverName: name))
        let filesGrantable = await containers.fileService(containerName: name) != nil
        try AccountManager(store: store).setGrant(
            userID: target.id, containerName: name, grant: granted, filesGrantable: filesGrantable)
        audit(
            user: user.username, action: "container.subuser", container: name, outcome: "ok",
            ip: context.clientIP, detail: "set \(target.username): \(grantKeys(granted).joined(separator: ","))")
        return json(["ok": true])
    }

    // MARK: Activity log

    struct ActivityDTO: Encodable {
        let at: String
        let user: String
        let action: String
        let outcome: String
        let detail: String?
    }

    /// This server's recent activity, newest first — who did what and whether it
    /// succeeded. Gated on `view` by the scope middleware. Source IPs are
    /// deliberately omitted: they stay in the admin-only native audit view.
    @Sendable func apiActivity(_ request: Request, context: PanelRequestContext) async throws -> Response {
        _ = try context.requireIdentity()
        let name = try context.parameters.require("name")
        let entries = (try? store.listAudit(containerName: name, limit: 200)) ?? []
        return encode(
            entries.map {
                ActivityDTO(at: $0.timestamp, user: $0.username, action: $0.action, outcome: $0.outcome, detail: $0.detail)
            })
    }

    // MARK: Remove

    @Sendable func apiSubUserRemove(_ request: Request, context: PanelRequestContext) async throws -> Response {
        let user = try context.requireIdentity()
        let name = try context.parameters.require("name")
        guard canManageSubUsers(user, serverName: name) else { throw HTTPError(.forbidden) }
        let username = try context.parameters.require("username")
        guard let target = try? store.user(named: username) else {
            return json(["error": "no such account"], status: .badRequest)
        }
        try store.setGrant(userID: target.id, containerName: name, grant: ContainerGrant())
        audit(
            user: user.username, action: "container.subuser", container: name, outcome: "ok",
            ip: context.clientIP, detail: "remove \(target.username)")
        return json(["ok": true])
    }
}
