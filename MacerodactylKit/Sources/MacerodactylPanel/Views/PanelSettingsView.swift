import SwiftUI
import MacerodactylKit

/// Native management surface for the web panel: enable/bind/port, first-run
/// admin, accounts + grants, and the audit log. Accounts are managed ONLY
/// here, never over the web.
public struct PanelSettingsView: View {
    @State private var model: PanelAdminModel

    public init(
        store: PanelDataStore,
        controller: PanelController,
        containerProvider: @escaping @MainActor () -> [PanelAdminModel.GrantableContainer] = { [] }
    ) {
        _model = State(initialValue: PanelAdminModel(store: store, controller: controller, containerProvider: containerProvider))
    }

    public var body: some View {
        Form {
            serverSection
            accountsSection
            auditSection
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 620)
        .task { model.reload() }
        .sheet(item: $model.editingUser) { user in
            GrantsEditor(model: model, user: user)
        }
        .alert("New admin password", isPresented: $model.showingFirstAdmin) {
            Button("Copy") { model.copyFirstAdminPassword() }
            Button("Done", role: .cancel) {}
        } message: {
            Text("Sign in as “admin” with:\n\n\(model.firstAdminPassword ?? "")\n\nThis is shown once. Store it now.")
        }
    }

    private var serverSection: some View {
        Section("Web panel") {
            Toggle("Serve the web panel while the app is running", isOn: $model.enabled)
                .onChange(of: model.enabled) { _, on in model.setEnabled(on) }

            LabeledContent("Address") {
                Text(model.addressDescription)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
            }
            if model.enabled {
                Button("Copy local URL") { model.copyLocalURL() }
                    .controlSize(.small)
            }

            HStack {
                Text("Port")
                TextField("Port", value: $model.port, format: .number.grouping(.never))
                    .frame(width: 80)
                    .onSubmit { model.setPort() }
                Button("Apply") { model.setPort() }
                    .controlSize(.small)
            }

            Toggle("Allow access from other devices on the network (LAN)", isOn: $model.bindLAN)
                .onChange(of: model.bindLAN) { _, on in model.setBindLAN(on) }
            if model.bindLAN {
                Label("The panel is reachable by any device on your local network over plain HTTP. Only enable this behind a trusted network or a tunnel (e.g. Cloudflare Tunnel).", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Text("Plain HTTP only — put TLS at a tunnel in front of it. The panel never runs after you quit the app.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var accountsSection: some View {
        Section("Accounts") {
            if model.users.isEmpty {
                Text("No accounts yet. Enable the panel to create the first admin, or add one below.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(model.users, id: \.id) { user in
                HStack {
                    Image(systemName: user.isAdmin ? "person.badge.key.fill" : "person.fill")
                        .foregroundStyle(user.isAdmin ? Color.accentColor : .secondary)
                    Text(user.username)
                    if user.isAdmin { Text("admin").font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    if !user.isAdmin {
                        Button("Grants…") { model.editingUser = user }
                            .controlSize(.small)
                    }
                    Button(role: .destructive) { model.deleteUser(user) } label: {
                        Image(systemName: "trash")
                    }
                    .controlSize(.small)
                }
            }
            DisclosureGroup("Add account") {
                TextField("Username", text: $model.newUsername)
                SecureField("Password (min 8 characters)", text: $model.newPassword)
                Toggle("Administrator", isOn: $model.newIsAdmin)
                Button("Create account") { model.createUser() }
                    .disabled(!model.canCreateUser)
                if let error = model.accountError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
        }
    }

    private var auditSection: some View {
        Section("Audit log") {
            if model.audit.isEmpty {
                Text("No activity recorded yet.").font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(model.audit, id: \.id) { entry in
                    AuditRow(entry: entry)
                }
            }
            Button("Refresh") { model.reload() }.controlSize(.small)
        }
    }
}

struct AuditRow: View {
    let entry: AuditEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack {
                Text(entry.action).font(.callout.monospaced())
                if let container = entry.containerName {
                    Text(container).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(entry.outcome)
                    .font(.caption)
                    .foregroundStyle(entry.outcome == "ok" ? Color.secondary : Color.orange)
            }
            Text("\(entry.username) · \(entry.sourceIP ?? "—") · \(entry.timestamp)")
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }
}

struct GrantsEditor: View {
    @Bindable var model: PanelAdminModel
    let user: PanelUser
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Container access for \(user.username)").font(.headline)
            Text("Grant this user access to specific containers. A container with no stack folder can’t be granted file access.")
                .font(.caption).foregroundStyle(.secondary)

            ScrollView {
                VStack(spacing: 8) {
                    ForEach(model.grantableContainers, id: \.name) { container in
                        GrantRow(model: model, user: user, container: container)
                    }
                    if model.grantableContainers.isEmpty {
                        Text("No containers are currently visible. Start Docker and your stacks, then reopen this editor.")
                            .font(.callout).foregroundStyle(.secondary).padding()
                    }
                }
            }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(18)
        .frame(width: 480, height: 460)
    }
}

struct GrantRow: View {
    @Bindable var model: PanelAdminModel
    let user: PanelUser
    let container: PanelAdminModel.GrantableContainer

    var body: some View {
        let grant = model.grant(for: user, container: container.name)
        VStack(alignment: .leading, spacing: 4) {
            Text(container.name).font(.callout.monospaced())
            HStack(spacing: 10) {
                permToggle("View", grant.view) { model.setPermission(user, container, .view, $0) }
                permToggle("Power", grant.power) { model.setPermission(user, container, .power, $0) }
                permToggle("Files", grant.files, disabled: !container.filesGrantable) { model.setPermission(user, container, .files, $0) }
                permToggle("Console", grant.console) { model.setPermission(user, container, .console, $0) }
            }
            if !container.filesGrantable {
                Text("No stack folder — file access unavailable").font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }

    private func permToggle(_ label: String, _ on: Bool, disabled: Bool = false, _ set: @escaping (Bool) -> Void) -> some View {
        Toggle(label, isOn: Binding(get: { on }, set: set))
            .toggleStyle(.checkbox)
            .disabled(disabled)
            .font(.caption)
    }
}
