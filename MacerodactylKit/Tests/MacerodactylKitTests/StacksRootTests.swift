import Foundation
import Testing

@testable import MacerodactylKit

/// AppSettings reads/writes the shared UserDefaults, so these run on a private
/// suite to avoid disturbing the real defaults.
@Suite(.serialized) struct StacksRootSettingsTests {
    private func withCleanDefaults(_ body: () throws -> Void) rethrows {
        let key = AppSettings.stacksRootKey
        let saved = UserDefaults.standard.string(forKey: key)
        UserDefaults.standard.removeObject(forKey: key)
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
        }
        try body()
    }

    @Test func defaultsToHomeStacks() throws {
        try withCleanDefaults {
            #expect(AppSettings.stacksRoot == AppSettings.defaultStacksRoot)
            #expect(AppSettings.stacksRoot.lastPathComponent == "stacks")
        }
    }

    @Test func honorsConfiguredPathAndReportsExistence() throws {
        try withCleanDefaults {
            let dir = FileManager.default.temporaryDirectory.appending(path: "stacks-\(UUID().uuidString)")
            AppSettings.stacksRoot = dir
            #expect(AppSettings.stacksRoot.standardizedFileURL == dir.standardizedFileURL)
            #expect(!AppSettings.stacksRootExists())  // not created yet

            try AppSettings.createStacksRoot()
            #expect(AppSettings.stacksRootExists())
            try? FileManager.default.removeItem(at: dir)
        }
    }

    @Test func settingStacksRootPostsChangeNotification() throws {
        try withCleanDefaults {
            var fired = false
            let token = NotificationCenter.default.addObserver(
                forName: .macerodactylSettingsChanged, object: nil, queue: nil
            ) { _ in fired = true }
            defer { NotificationCenter.default.removeObserver(token) }
            AppSettings.stacksRoot = FileManager.default.temporaryDirectory.appending(path: "x")
            #expect(fired)  // a live view can re-read without a restart
        }
    }
}
