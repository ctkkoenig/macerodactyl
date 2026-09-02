import SwiftUI
import MacerodactylKit

@main
struct MacerodactylApp: App {
    @State private var store = ContainerStore()

    var body: some Scene {
        WindowGroup {
            DashboardRootView(store: store)
        }

        Settings {
            MacerodactylSettingsView(store: store)
        }
    }
}
