import SwiftUI
import MacerodactylKit
import MacerodactylPanel

@main
struct MacerodactylApp: App {
    @State private var store = ContainerStore()
    @State private var panel = AppPanel()

    var body: some Scene {
        WindowGroup {
            DashboardRootView(store: store)
                .task { panel.controller?.applySettings() }
                .onReceive(NotificationCenter.default.publisher(for: .macerodactylPanelSettingsChanged)) { _ in
                    panel.controller?.applySettings()
                }
        }

        Settings {
            TabView {
                MacerodactylSettingsView(store: store)
                    .tabItem { Label("General", systemImage: "gearshape") }
                if let controller = panel.controller, let panelStore = panel.store {
                    PanelSettingsView(
                        store: panelStore,
                        controller: controller,
                        containerProvider: { grantableContainers() }
                    )
                    .tabItem { Label("Web Panel", systemImage: "globe") }
                }
            }
            .frame(width: 600, height: 660)
        }
    }

    /// Maps the current containers into grant candidates, marking which can be
    /// granted file access (those with a stack folder under the stacks root).
    private func grantableContainers() -> [PanelAdminModel.GrantableContainer] {
        store.groups.all.map { container in
            PanelAdminModel.GrantableContainer(
                name: container.name,
                filesGrantable: PathConfinement.fileRoot(for: container, stacksRoot: AppSettings.stacksRoot) != nil
            )
        }
    }
}

/// Holds the panel data store and controller, created once. Kept out of the
/// App struct's stored @State initializer so a failure to open the database
/// doesn't crash launch — the Web Panel tab just doesn't appear.
@MainActor
@Observable
final class AppPanel {
    let store: PanelDataStore?
    let controller: PanelController?

    init() {
        if let path = try? AppPaths.databasePath(), let store = try? PanelDataStore(databasePath: path) {
            self.store = store
            self.controller = PanelController(store: store)
        } else {
            self.store = nil
            self.controller = nil
        }
    }
}
