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

## Status

The **`MacerodactylUITests` target is wired into the project** (it builds, and
`build-for-testing` succeeds), and the app honours a **`-uitest`** launch
argument (`AppSettings.isUITesting`) that disables its continuous docker polling
and the single-instance guard so the app can reach an idle state under test.

It is **not in the default Test action**, and does not yet pass green, because on
this setup `XCUIApplication.launch()`'s idle-wait does not settle (the launch
times out even with polling disabled — a known macOS XCUITest friction with apps
that keep a live run loop). Running it is therefore explicit and best-effort:

```sh
# ad-hoc signed; needs a real windowserver + likely an Accessibility grant
xcodebuild test -project Macerodactyl.xcodeproj -scheme Macerodactyl \
  -destination 'platform=macOS' -only-testing:MacerodactylUITests CODE_SIGN_IDENTITY='-'
```

To get it green, the app likely needs to reach a fully-idle state under
`-uitest` (e.g. also skip starting the in-process panel server, and avoid any
continuously-updating SwiftUI view while testing). That work is left as a
follow-up; the target and the launch hook are in place for it.

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
