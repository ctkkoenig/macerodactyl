# UI testing (XCUITest)

The bulk of the suite is in the `MacerodactylKit` Swift package and runs with
`swift test` (200+ tests, no Xcode needed). Those cover all the logic, the web
server, the security model, fuzzing, and property tests.

What they can't cover is the **native SwiftUI app actually launching and
rendering**. That needs an XCUITest bundle, which must run against a real GUI
session (a windowserver) — so it can't run in a headless/CI-only environment
without one, and it isn't part of `swift test`.

A ready-to-use smoke test lives in [`UITests/MacerodactylUITests.swift`](../UITests/MacerodactylUITests.swift):
it launches the app, asserts a window appears, and asserts the app is still alive
a moment later (i.e. it didn't crash on first render). It's deliberately
structural so it won't be brittle.

## Wiring it up (one-time, ~2 minutes in Xcode)

The `Macerodactyl.xcodeproj` is hand-written and intentionally minimal, so the UI
test target isn't checked in (adding one by editing `project.pbxproj` by hand is
error-prone). To enable it:

1. Open `Macerodactyl.xcodeproj`.
2. **File → New → Target… → macOS → UI Testing Bundle**. Name it
   `MacerodactylUITests`; set **Target to be Tested** to `Macerodactyl`.
3. Delete the template test file Xcode created and **add
   `UITests/MacerodactylUITests.swift`** to the new target.
4. Run with **Product → Test** (⌘U), or from the command line:

   ```sh
   xcodebuild test -project Macerodactyl.xcodeproj -scheme Macerodactyl \
     -destination 'platform=macOS'
   ```

## In CI

GitHub's `macos-15` runners have a GUI session and can run XCUITest. Once the
target above exists, add a step to the `test` job:

```yaml
- name: UI smoke test
  run: |
    xcodebuild test -project Macerodactyl.xcodeproj -scheme Macerodactyl \
      -destination 'platform=macOS' -only-testing:MacerodactylUITests
```

UI tests need the app to be signed to launch; on CI use your signing setup (or a
self-signed run destination). Keep this step non-blocking until it's proven
stable on the runner, so a flaky windowserver interaction can't red the whole
pipeline.
