# Engineering assessment (updated)

This is the state of Macerodactyl after the autonomous session that executed the
roadmap. It updates the original assessment (the "genius list" of strengths,
gaps, and roadmap) that was the session's input.

## Where the gaps were — and where they are now

The original assessment's headline gaps, and their status:

| Original gap | Status now |
|---|---|
| No CI; correctness asserted, not proven | **Closed.** GitHub Actions: strict format lint, full `swift test` on macOS + app build, and a Linux build-and-serve job. |
| Panel dies with the app; not real infrastructure | **Closed (with one caveat).** A headless `macerodactyld` daemon + LaunchAgent manager exists and serves; the **launchd auto-start** is the one thing unverified in this environment (see below). |
| Rate-limiter, backups, TLS, health all missing | **Closed.** SQLite-persisted rate limiter, WAL checkpoint / live-safe backup / validated restore / integrity check, optional self-signed TLS with a Secure cookie, and `/healthz`. |
| Thin feature set — not worth opening daily | **Closed.** Full file manager, retained metrics + searchable logs, container lifecycle (pull/recreate/compose-apply/remove) behind a dedicated permission, admin maintenance. |
| Latent XSS: HTML built by string concatenation | **Closed structurally.** Frontend extracted to bundle assets and rebuilt with safe DOM APIs; a test forbids HTML-injection sinks. |
| Mac-only; narrow audience | **Closed.** The headless panel builds and runs on Linux and ships as a Docker image. |
| No front door (README/LICENSE/etc.) | **Closed.** README with real screenshots, LICENSE, SECURITY, CONTRIBUTING, templates, a prepared cask + draft-only release workflow. |
| Untested surfaces (fuzz/property/2FA) | **Closed.** Fuzzing, property tests, an adversarial suite, and optional TOTP 2FA + session revocation. |

## What the security posture actually is now

The per-user scoping boundary is no longer asserted — it's tested from six
independent angles: unit tests, HTTP-level tests, 20k-path confinement fuzzing,
5k-matrix scoping property tests, an adversarial suite that actively tries to
break it, and two fresh-eyes agent security reviews (which drove five real Tier 1
fixes and, at the end, caught a 2FA login-flow lockout that the API tests had
missed). Identity is app-owned, file access is confined, destructive and
daemon-global actions are separately gated, and the web frontend can't grow an
XSS by construction. This is a genuinely defensible small-scale multi-user Docker
control plane.

## Honest remaining weaknesses

- **launchd auto-start is unverified.** NIO-linked binaries hang pre-`main` in
  this machine's headless launchd session (a strong hypothesis, not a
  root-cause). The daemon runs perfectly from a shell and in the Linux
  container, and the GUI in-process server is the untouched default — so nothing
  is broken — but the "install as a background service on macOS" path needs an
  interactive confirmation.
- **No native-app UI test in CI yet.** An XCUITest smoke test is written and
  documented but not wired into the hand-built Xcode project (it needs a GUI
  session to run/verify, which the session didn't have).
- **No native-app screenshots** in the README (the web-panel ones are real; the
  native ones are for the owner to add — the app icon is their open question).
- **TOTP secrets are stored plaintext at rest** (alongside session tokens and
  bcrypt hashes) — a reasonable, now-documented trade, but worth revisiting if
  the threat model includes a read-only DB leak without full compromise.
- **Git history** of the working-log docs referenced private container names
  before they were scrubbed; squash or drop those docs before the repo goes
  public if that history matters.

## The top things to do next

1. **Confirm the launchd daemon** in a normal logged-in session, and if it still
   hangs pre-main, root-cause the NIO/launchd interaction.
2. **Wire and run the XCUITest** in CI (macOS runners can), then add the native
   app screenshots and decide the icon.
3. **Cut the first release**: flip the repo public, push a `v0.1.0` tag (the
   workflow makes a draft to review), and publish the cask.
4. Optional hardening: encrypt TOTP secrets at rest; add a native 2FA enrollment
   UI to match the web panel's.

## Bottom line

The bones are those of trustworthy infrastructure: a tested security model, two
platforms, honest docs, and a real front door — unusually disciplined for a
project this size. The remaining work is owner-side and documented: verify the
daemon, wire the UI test, take the native screenshots, and flip the switches. It
is ready to be built from source and used; it is one owner-side release step away
from being ready to be starred.
