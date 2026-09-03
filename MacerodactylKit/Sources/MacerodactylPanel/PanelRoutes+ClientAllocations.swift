import Foundation
import Hummingbird
import MacerodactylKit

/// Client-area network (port allocation) management: a server's owner (or an
/// admin) can add a free allocation to their server, release a non-primary one,
/// or promote one to primary — each change is applied by regenerating the compose
/// file and bringing the stack back up, so the container is recreated with the new
/// ports. Gated on ownership (never a bare sub-user), the same authority as the
/// Users tab.
extension PanelRoutes {
    /// The most allocations one server may hold (a sane ceiling on a shared node).
    static let maxAllocationsPerServer = 8

    struct AllocationRowDTO: Encodable {
        let id: Int64
        let ip: String
        let port: Int
        let proto: String
        let isPrimary: Bool
    }

    struct ServerAllocationsDTO: Encodable {
        let canManage: Bool
        let limit: Int
        let assigned: [AllocationRowDTO]
        let available: [AllocationRowDTO]
    }

    private func row(_ a: PortAllocation) -> AllocationRowDTO {
        AllocationRowDTO(id: a.id, ip: a.ip, port: a.port, proto: a.proto, isPrimary: a.isPrimary)
    }

    @Sendable func apiServerAllocationsList(_ request: Request, context: PanelRequestContext) async throws -> Response {
        let user = try context.requireIdentity()
        let name = try context.parameters.require("name")
        guard canManageSubUsers(user, serverName: name) else { throw HTTPError(.forbidden) }
        let assigned = (try? store.allocations(forServer: name)) ?? []
        let available = ((try? store.listAllocations()) ?? []).filter { $0.serverName == nil }
        return encode(
            ServerAllocationsDTO(
                canManage: true, limit: Self.maxAllocationsPerServer,
                assigned: assigned.map(row), available: available.map(row)))
    }

    struct AddAllocationBody: Decodable { let id: Int64 }

    @Sendable func apiServerAllocationAdd(_ request: Request, context: PanelRequestContext) async throws -> Response {
        let user = try context.requireIdentity()
        let name = try context.parameters.require("name")
        guard canManageSubUsers(user, serverName: name) else { throw HTTPError(.forbidden) }
        guard let body = try? await request.decode(as: AddAllocationBody.self, context: context) else {
            return json(["error": "invalid request"], status: .badRequest)
        }
        let current = (try? store.allocations(forServer: name).count) ?? 0
        guard current < Self.maxAllocationsPerServer else {
            return json(["error": "this server already has the maximum of \(Self.maxAllocationsPerServer) allocations"], status: .conflict)
        }
        guard (try? store.assignAllocation(id: body.id, toServer: name)) == true else {
            return json(["error": "that allocation is no longer free"], status: .conflict)
        }
        return await applyAndRespond(serverName: name, user: user, ip: context.clientIP, detail: "add allocation \(body.id)")
    }

    @Sendable func apiServerAllocationRemove(_ request: Request, context: PanelRequestContext) async throws -> Response {
        let user = try context.requireIdentity()
        let name = try context.parameters.require("name")
        guard canManageSubUsers(user, serverName: name) else { throw HTTPError(.forbidden) }
        let allocID = try requireInt(context, "allocId")
        guard (try? store.releaseAllocation(id: allocID, fromServer: name)) == true else {
            return json(["error": "can't remove the primary allocation — make another primary first"], status: .conflict)
        }
        return await applyAndRespond(serverName: name, user: user, ip: context.clientIP, detail: "remove allocation \(allocID)")
    }

    @Sendable func apiServerAllocationPrimary(_ request: Request, context: PanelRequestContext) async throws -> Response {
        let user = try context.requireIdentity()
        let name = try context.parameters.require("name")
        guard canManageSubUsers(user, serverName: name) else { throw HTTPError(.forbidden) }
        let allocID = try requireInt(context, "allocId")
        guard (try? store.setPrimaryAllocation(id: allocID, forServer: name)) == true else {
            return json(["error": "that allocation isn't assigned to this server"], status: .badRequest)
        }
        // Primary drives SERVER_PORT, so this also regenerates + reapplies compose.
        return await applyAndRespond(serverName: name, user: user, ip: context.clientIP, detail: "primary allocation \(allocID)")
    }

    /// Regenerates the compose file from the server's current allocations and
    /// brings the stack back up (recreating the container with the new ports).
    /// Drains the reconfigure stream to completion and reports success/failure.
    private func applyAndRespond(serverName: String, user: PanelUser, ip: String, detail: String) async -> Response {
        guard let record = try? store.serverRecord(name: serverName), let spec = try? rebuildSpec(for: record)
        else {
            return json(["error": "could not rebuild the server configuration"], status: .internalServerError)
        }
        do {
            for try await _ in await containers.reconfigure(spec) {}
            audit(user: user.username, action: "container.allocation", container: serverName, outcome: "ok", ip: ip, detail: detail)
            return json(["ok": true])
        } catch {
            audit(user: user.username, action: "container.allocation", container: serverName, outcome: "error", ip: ip, detail: "\(error)")
            return json(["error": "the change was saved but applying it failed: \(error)"], status: .internalServerError)
        }
    }
}
