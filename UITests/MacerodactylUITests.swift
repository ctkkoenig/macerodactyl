import XCTest

/// A smoke UI test (T6.1): launch the real app and assert it comes up with a
/// window and doesn't crash. Structural on purpose — it asserts the app renders,
/// not specific controls, so it won't be brittle as the UI evolves.
///
/// The app is launched with `-uitest`, which makes it skip its continuous docker
/// polling and single-instance guard so `XCUIApplication.launch()` can settle
/// into an idle, testable state (otherwise the launch idle-wait times out). It
/// deliberately avoids synthesizing key/mouse events, which would require the
/// runner to hold macOS Accessibility permission.
///
/// See docs/UI-TESTING.md. This runs from Xcode / a signed CI job; it can't run
/// headless without a windowserver.
@MainActor
final class MacerodactylUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testAppLaunchesAndShowsAWindow() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest"]
        app.launch()

        // The app reaches the running state and presents a window.
        XCTAssertEqual(app.state, .runningForeground)
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15), "the main window should appear")

        // Still alive a moment later — didn't crash on first render (panel
        // controller / container store startup).
        Thread.sleep(forTimeInterval: 1.0)
        XCTAssertEqual(app.state, .runningForeground)

        app.terminate()
    }
}
