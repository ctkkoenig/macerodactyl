import AppKit
import Foundation
import MacerodactylKit
import Observation
import SwiftUI

/// View model behind the native panel-admin UI. Talks to AccountManager and the
/// PanelController; reads the current container list (names + stack-folder
/// status) so grants can mirror the native app's file-access rule.
@MainActor
@Observable
public final class PanelAdminModel {
    public struct GrantableContainer: Sendable, Equatable {
        public let name: String
        public let filesGrantable: Bool

        public init(name: String, filesGrantable: Bool) {
            self.name = name
            self.filesGrantable = filesGrantable
        }
    }

    let store: PanelDataStore
    let controller: PanelController
    private let accounts: AccountManager

    public var enabled: Bool = AppSettings.panelEnabled
    public var port: Int = AppSettings.panelPort
    public var bindLAN: Bool = AppSettings.panelBindLAN

    public var users: [PanelUser] = []
    public var audit: [AuditEntry] = []
    public var grantableContainers: [GrantableContainer] = []
    private var grantCache: [Int64: [String: ContainerGrant]] = [:]

    public var editingUser: PanelUser?
    public var newUsername = ""
    public var newPassword = ""
    public var newIsAdmin = false
    public var accountError: String?

    public var showingFirstAdmin = false
    public var firstAdminPassword: String?

    /// Supplies the current container names + whether each has a stack folder.
    private let containerProvider: @MainActor () -> [GrantableContainer]

    public init(
        store: PanelDataStore,
        controller: PanelController,
        containerProvider: @escaping @MainActor () -> [GrantableContainer] = { [] }
    ) {
        self.store = store
        self.controller = controller
        self.accounts = AccountManager(store: store)
        self.containerProvider = containerProvider
    }

    public func reload() {
        users = (try? accounts.listUsers()) ?? []
        audit = (try? store.listAudit(limit: 200)) ?? []
        grantableContainers = containerProvider()
        grantCache = [:]
        if let password = controller.consumeFirstAdminPassword() {
            firstAdminPassword = password
            showingFirstAdmin = true
        }
    }

    public var addressDescription: String {
        "\(bindLAN ? "0.0.0.0 (LAN)" : "127.0.0.1 (local only)"):\(port)"
    }

    // MARK: Server settings

    public func setEnabled(_ on: Bool) {
        AppSettings.panelEnabled = on
        controller.applySettings()
    }

    public func setPort() {
        guard (1...65_535).contains(port) else { return }
        AppSettings.panelPort = port
        if AppSettings.panelEnabled { controller.applySettings() }
    }

    public func setBindLAN(_ on: Bool) {
        AppSettings.panelBindLAN = on
        if AppSettings.panelEnabled { controller.applySettings() }
    }

    public func copyLocalURL() { setPasteboard(controller.localURL) }
    public func copyFirstAdminPassword() { if let p = firstAdminPassword { setPasteboard(p) } }

    // MARK: Accounts

    public var canCreateUser: Bool { !newUsername.isEmpty && newPassword.count >= 8 }

    public func createUser() {
        accountError = nil
        Task {
            do {
                _ = try await accounts.createUser(username: newUsername, password: newPassword, isAdmin: newIsAdmin)
                newUsername = ""; newPassword = ""; newIsAdmin = false
                reload()
            } catch {
                accountError = "Couldn’t create account (username may be taken)."
            }
        }
    }

    public func deleteUser(_ user: PanelUser) {
        try? accounts.deleteUser(id: user.id)
        reload()
    }

    // MARK: Grants

    public func grant(for user: PanelUser, container: String) -> ContainerGrant {
        if grantCache[user.id] == nil {
            grantCache[user.id] = (try? accounts.grants(forUserID: user.id)) ?? [:]
        }
        return grantCache[user.id]?[container] ?? ContainerGrant()
    }

    public func setPermission(_ user: PanelUser, _ container: GrantableContainer, _ permission: ContainerPermission, _ on: Bool) {
        var grant = grant(for: user, container: container.name)
        switch permission {
        case .view: grant.view = on
        case .power: grant.power = on
        case .files: grant.files = on
        case .console: grant.console = on
        case .schedules: grant.schedules = on
        }
        // Turning off view removes everything — nothing works without it.
        if permission == .view, !on { grant = ContainerGrant() }
        try? accounts.setGrant(userID: user.id, containerName: container.name, grant: grant, filesGrantable: container.filesGrantable)
        grantCache[user.id] = (try? accounts.grants(forUserID: user.id)) ?? [:]
    }

    private func setPasteboard(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }
}
