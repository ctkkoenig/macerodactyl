import Foundation
import MacerodactylKit

/// Account and grant management. All account changes happen through here, driven
/// by the native app — never over the web. This is also where the first-run
/// admin is created.
public struct AccountManager: Sendable {
    let store: PanelDataStore

    public init(store: PanelDataStore) {
        self.store = store
    }

    public func hasAnyUser() throws -> Bool {
        try store.hasAnyUser()
    }

    public func listUsers() throws -> [PanelUser] {
        try store.listUsers()
    }

    /// Creates the first admin if no users exist, returning the generated
    /// one-time password. A no-op (returns nil) once any user exists, so it's
    /// safe to call every time the panel is enabled.
    @discardableResult
    public func createFirstAdminIfNeeded(username: String = "admin") async throws -> (username: String, password: String)? {
        guard try !store.hasAnyUser() else { return nil }
        let password = Self.generatePassword()
        let hash = await PasswordHasher.hash(password)
        try store.createUser(username: username, passwordHash: hash, isAdmin: true)
        return (username, password)
    }

    public func createUser(username: String, password: String, isAdmin: Bool) async throws -> PanelUser {
        let hash = await PasswordHasher.hash(password)
        return try store.createUser(username: username, passwordHash: hash, isAdmin: isAdmin)
    }

    public func setPassword(userID: Int64, password: String) async throws {
        try store.updatePassword(userID: userID, passwordHash: await PasswordHasher.hash(password))
    }

    public func deleteUser(id: Int64) throws {
        try store.deleteUser(id: id)
    }

    public func grants(forUserID userID: Int64) throws -> [String: ContainerGrant] {
        try store.grants(forUserID: userID)
    }

    /// Sets a user's grant for a container. `filesGrantable` reflects whether the
    /// container has a stack folder — a container with none can't be granted file
    /// access at all (matching the native file tab), so files is forced off.
    public func setGrant(userID: Int64, containerName: String, grant: ContainerGrant, filesGrantable: Bool) throws {
        var grant = grant
        if !filesGrantable { grant.files = false }
        try store.setGrant(userID: userID, containerName: containerName, grant: grant)
    }

    /// A readable 20-character random password (no ambiguous characters).
    static func generatePassword() -> String {
        let alphabet = Array("abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        return String((0..<20).map { _ in alphabet[Int.random(in: 0..<alphabet.count)] })
    }
}
