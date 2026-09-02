import AppKit
import MacerodactylKit
import MacerodactylPanel
import MacerodactylUI
import SwiftUI

@main
struct MacerodactylApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store = ContainerStore()
    @State private var panel: AppPanel

    init() {
        let store = ContainerStore()
        _store = State(initialValue: store)
        _panel = State(initialValue: AppPanel(containerStore: store))
    }

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

/// Enforces a single running instance. macOS only dedupes GUI (LaunchServices)
/// launches; a binary launched directly — by Xcode, a script, or a second
/// double-click racing the first — is a separate process. On startup we look
/// for an already-running instance of the same bundle and, if one exists, bring
/// it to the front and quit ourselves, so the app can never pile up.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        let current = NSRunningApplication.current
        let bundleID = current.bundleIdentifier ?? "com.macerodactyl.app"
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != current.processIdentifier && !$0.isTerminated }
        // If another instance is already up, defer to it and exit. Comparing
        // launch dates makes the race deterministic: the earlier one survives.
        let earlierExists = others.contains { other in
            guard let theirs = other.launchDate, let mine = current.launchDate else { return true }
            return theirs <= mine
        }
        if earlierExists {
            others.first?.activate(options: [.activateAllWindows])
            exit(0)
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

    init(containerStore: ContainerStore) {
        if let path = try? AppPaths.databasePath(), let store = try? PanelDataStore(databasePath: path) {
            self.store = store
            self.controller = PanelController(store: store, containers: LiveContainerService(store: containerStore))
        } else {
            self.store = nil
            self.controller = nil
        }
    }
}
