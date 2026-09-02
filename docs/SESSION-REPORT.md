# Autonomous session report

One continuous autonomous session took Macerodactyl from a working v0.1 to
something intended to stand as trustworthy infrastructure. This is the summary;
`AUTONOMOUS-LOG.md` has the dated, per-item detail and every decision.

## Headline

- **Seven tiers of work completed** (CI → trustworthiness → daily-use features →
  ending the XSS liability → Linux/Docker → shopfront → hardening).
- **Test suite ~115 → 208** (`swift test`), plus fuzz + property + adversarial
  suites. Every commit is green; CI (lint + macOS test/build + a Linux
  build-and-serve job) is in place.
- **Two mid-session security reviews** (Tier 1, Tier 2) by fresh-eyes agents; the
  Tier 1 one found and drove fixes for five real bugs.
- Nothing was published: the repo stays private, no release was cut, the Homebrew
  cask and release workflow are prepared for the owner to flip.

## What landed, by tier

**Tier 0 — prove the work.** GitHub Actions CI: strict `swift format` lint, the
full `swift test` suite on macOS, and an app build. A `.swift-format` config
matching the codebase's 4-space/140-col style.

**Tier 1 — make it trustworthy.** A headless `macerodactyld` daemon + a
LaunchAgent manager (so the panel can outlive the app); the login rate-limiter
moved to SQLite (a restart is no longer a brute-force reset); an unauthenticated
`/healthz`; WAL checkpoint / live-safe backup (`VACUUM INTO`) / validated restore
/ integrity check; and first-class optional TLS (self-signed, `Secure` cookie).
A five-fix security-hardening pass from the tier review: restore no longer wipes
the live DB from a bad path, TLS fails closed instead of downgrading to plaintext,
loopback is exempt from the (now-persisted) IP rate-limit, `/healthz` caches its
docker probe, and secret files are created `0600`.

**Tier 2 — worth opening daily.** A real file manager (mkdir/rename/delete/
upload/download, all through the same path confinement); retained metrics (a
bounded SQLite ring-buffer + a read-only sampler) and searchable logs + download;
container lifecycle (pull / recreate / compose-apply / remove) behind a new,
sixth `lifecycle` permission kept separate from `power`; and admin-only
daemon-global maintenance (image prune, disk usage). The tier review found no
exploitable issue; two low hardening notes were actioned (RFC 6266
Content-Disposition, capped download length).

**Tier 3 — end the XSS liability.** The 375-line hand-built HTML/JS string was
extracted to bundle assets and rewritten with a safe-DOM `h()` helper: untrusted
data can only become text nodes or attribute values, never parsed markup — a
missed escape is now impossible by construction, and a test enforces the absence
of HTML-injection sinks. Verified live in Chrome against an isolated instance;
caught and fixed a real CSS class-collision bug only a live render surfaces.

**Tier 4 — widen the audience.** The headless panel now builds and runs on
Linux (CSQLite systemLibrary for SQLite, swift-crypto fallback for CryptoKit,
`canImport(Network)`-gated RCON, cross-platform NIO byte buffers) and ships as a
multi-stage Docker image. Verified live: the container serves `/healthz`
(`docker: ready` over the mounted socket), the login page, and bundled assets. CI
gained the Linux build-and-serve job.

**Tier 5 — the shopfront.** README (with real phone-panel screenshots), LICENSE
(MIT), SECURITY.md, CONTRIBUTING.md, issue/PR templates, a Homebrew cask
template, and a release workflow that only ever creates a *draft* release. All
prepared; nothing published.

**Tier 6 — harden the untested.** Fuzzing (20k adversarial paths never escape
confinement; 10k garbage inputs never crash the parsers), property tests (5k
random grant matrices uphold every scoping invariant), an adversarial suite
(identity forgery, forged cookies, CSRF, SQL-injection names, escalation — all
blocked) with `docs/ADVERSARIAL.md`, optional TOTP 2FA + session
listing/revocation (RFC-vector-tested, live-verified UI), and a ready-to-wire
XCUITest smoke test.

## The one documented blocker — now RESOLVED

> Update: verified in an interactive logged-in session — `macerodactyld` installs under launchd, launches (state `S`, not hung pre-`main`), and serves `/healthz` (`docker: ready`). The earlier hang was specific to the headless/asleep session. The test agent was uninstalled afterward; the real `panel.sqlite` was untouched.


`macerodactyld` under **launchd auto-start** could not be verified in this
session: NIO-linked binaries hang pre-`main` in the machine's headless launchd
session (ruled out SwiftUI, debug/release, signing, and more; a Foundation-only
binary and a Network-only binary both run fine there). Strong hypothesis: the
asleep/headless GUI session lacks services the runtime blocks on. The daemon runs
perfectly from a shell and in the Linux container. **Owner: please run
`macerodactyld` (or install it via `PanelTool daemon install`) during a normal
logged-in session** — if it serves, the daemon path is good; if it still hangs
pre-main, it needs an interactive root-cause. The GUI's in-process server is
untouched and remains the default, so nothing is broken by this.

## What's left for the owner (deliberately not done)

- **Flip it public / cut a release.** The repo is private, no release exists, the
  cask/workflow are prepared. All of that is yours to trigger.
- **The app icon / logo** is your open question — untouched.
- **Wire the XCUITest** target (2 minutes in Xcode; see `docs/UI-TESTING.md`) —
  it needs a GUI session this session didn't have.
- **Native app screenshots** for the README — not taken (won't screenshot your
  desktop). The README uses the web-panel shots; add native ones when convenient.
- **Confirm the launchd daemon** interactively (above).

## Verification discipline used throughout

Every tier: full suite + a security review + a docs-match-reality check + a
portability check. Live checks against **real** things — the daemon serving over
a socket, a TLS handshake, a backup of the real `panel.sqlite`, the metrics
pipeline against real fixtures, the web panel driven in Chrome, the Linux
container serving. Fixtures only (`testweb`, `fixture-bare`, `fixture-mc`); the
real workloads (your real workloads) and the real `panel.sqlite` were never
touched — verified by mtime at the end.

## The final review earned its keep

The finish-line fresh-eyes review (a third independent agent) caught a
**high-severity bug the 208-test suite had missed**: the served 2FA login page
had no code field and the login script treated the "code required" response as
success — so enabling 2FA locked a user out with no in-product recovery. The
API-level tests drove the JSON endpoint directly (with a code field), never the
served page, so they stayed green over an unusable feature. It also flagged the
owner's private container names leaking into committed working-logs. Both are now
fixed and verified (the full 2FA login was driven end-to-end through the running
container; the names are scrubbed), along with three smaller hardening items
(TOTP replay protection, a safe-DOM invariant, a documented secret-at-rest note).
This is exactly why the review step exists.

## Assessment

The updated engineering assessment is in [`ASSESSMENT.md`](ASSESSMENT.md). In
short: the security model is now tested from several independent angles (unit,
HTTP, fuzz, property, adversarial, three agent reviews) rather than asserted; the
code builds and runs on two platforms; and the project has a real front door. The
honest remaining gaps are the unverified launchd auto-start, the un-wired
XCUITest, and the absence of native-app screenshots — all owner-side, all
documented.
