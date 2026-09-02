import XCTest

/// A smoke UI test (T6.1): launch the real app and assert it comes up with a
/// window and doesn't crash. It deliberately asserts only stable, structural
/// facts (a window exists, the app stays responsive) rather than specific
/// controls, so it's a genuine "does it launch and render" check that won't be
/// brittle as the UI evolves.
///
/// This is NOT wired into the Xcode project as a target yet — see
/// docs/UI-TESTING.md for the one-time setup (adding a UI Testing Bundle target
/// takes ~2 minutes in Xcode). It could not be added or run in the autonomous
/// session that wrote it (no GUI session to launch the app against), so it is
/// provided ready-to-wire and CI/owner-verified rather than committed as a
/// target that might not build.
final class MacerodactylUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testAppLaunchesAndShowsAWindow() throws {
        let app = XCUIApplication()
        app.launch()

        // The app must reach the running state and present a window.
        XCTAssertEqual(app.state, .runningForeground)
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10), "the main window should appear")

        // It should still be alive a moment later (didn't crash on first render,
        // e.g. from the panel controller or the container store starting up).
        Thread.sleep(forTimeInterval: 1.0)
        XCTAssertEqual(app.state, .runningForeground)
    }

    /// The Settings scene should be reachable via the standard shortcut without
    /// crashing — exercises a second window/scene path.
    func testSettingsOpens() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        app.typeKey(",", modifierFlags: .command)  // ⌘, opens Settings
        Thread.sleep(forTimeInterval: 1.0)
        XCTAssertEqual(app.state, .runningForeground)
    }
}
