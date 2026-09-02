# Contributing to Macerodactyl

Thanks for your interest. This is a focused project with a few load-bearing rules
that keep it trustworthy; PRs that respect them are very welcome.

## Getting set up

Everything except the thin app shell lives in the `MacerodactylKit` Swift
package, so you can build and test the whole core with the Command Line Tools —
**no Xcode required**:

```sh
cd MacerodactylKit
swift build
swift test          # the full suite
```

To build the macOS app you need Xcode (see the README's build-from-source
section — selecting a personal team is the step people get stuck on). The headless
web panel also builds and runs on Linux (see `docs/DOCKER.md`).

## Before you open a PR

- **The full test suite must pass** (`swift test`). CI runs it on every push and
  PR, plus a strict formatter lint and a Linux server build.
- **Format your code**: `swift format --in-place --recursive MacerodactylKit/Sources MacerodactylKit/Tests`
  (config in `.swift-format`, 4-space, 140 columns). CI fails on unformatted code.
- **Add tests** for behavior you change — especially anything touching the
  security model. New endpoints must re-run the path-traversal / scoping shapes.
- Keep commits conventional (`feat:`, `fix:`, `docs:`, `refactor:`, …) and
  focused.

## Rules that are not up for negotiation

These are the reason the project exists; a PR that weakens one won't be merged:

- **Talk to the `docker` CLI, never the socket API.** Pass arguments as arrays —
  never interpolate user input into a shell.
- **Per-user scoping is the security boundary.** Don't add a route that skips the
  scope middleware; don't turn a 404 (ungranted/absent) into a 403. Keep the
  `Authorization` module pure and its tests passing.
- **File access stays confined** to a container's stack folder via the existing
  `PathConfinement` — never a parallel path.
- **Identity comes only from the app's own session** — never a proxy header.
- **The web frontend builds DOM with safe APIs** (the `h()` helper /
  `textContent`), never `innerHTML` with data. A test enforces this; keep it
  green.
- **The app is always safe to quit.** It never starts containers at boot — that's
  compose restart policies. Scheduled restarts are launchd agents, not
  `RunAtLoad` container starts.

## Dependencies

Frozen at Hummingbird 2 + Bcrypt (hummingbird-auth), swift-nio-ssl (TLS),
swift-crypto (Linux SHA-256), and system `libsqlite3`. The web frontend is
vanilla HTML/CSS/JS in the bundle — no npm, no build toolchain. **Please open an
issue to discuss before adding any other dependency.**

## Reporting security issues

Not through a public issue — see [SECURITY.md](SECURITY.md).
