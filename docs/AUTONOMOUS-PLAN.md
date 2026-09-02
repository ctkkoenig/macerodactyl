# Macerodactyl — Autonomous Execution Plan

> This file + `AUTONOMOUS-LOG.md` are my memory across context resets. If you are
> a fresh instance: read both, run `swift test` in `MacerodactylKit/` to confirm
> green, then resume at the first unchecked item. Assume nothing else.

## Mission
Take Macerodactyl from working v0.1 to trustworthy infrastructure a stranger
would star. Execute the roadmap in `macerodactyl-assessment` (strengths/gaps/
roadmap). Autonomous: decide, record, continue. Never stop except out of work.

## Hard constraints (override everything)
- **Fixtures I own**: `testweb` stack (`~/stacks/testweb`), `fixture-bare`, `fixture-mc`. NEVER touch the two real (non-fixture) workloads — no stop/kill/restart/modify/delete of them or their files.
- Only modify files under `~/Documents/GitHub/macerodactyl` and fixture folders under `~/stacks`. Never read/touch Desktop, other Documents, `.ssh`, `.aws`, `.env`, credentials.
- Repo stays **private**. Never push to a public remote. Never publish a release. Prepare, stop short.
- **Do not change app icon/logo artwork** (`App/Assets.xcassets/AppIcon.appiconset`, `Resources/wordmark-*.png`, `assets/`). Owner's open question.
- **Never commit a red build.** Every commit: full `swift test` green. If broken and unfixable in reasonable effort → revert to last green, log why.
- Never reduce coverage / delete a test to pass. Wrong test → fix + log.
- Never weaken a security property: scoping boundary, path confinement, app-owned identity, 404-not-403. Feature loses if it needs a weaken.
- Don't delete owner accounts or change passwords. My test accounts: `admin` / `<redacted>`, `scoped` / `<redacted>` (mine to manage).

## Working method (per item)
Explore → Plan (record fork+choice) → Build → Verify (tests + REAL process/stream/launchd checks) → Audit own diff (loosened security? silent error path? leaked resource? machine-hardcoded value?) → Commit (conventional) → update plan+log. Between tiers: full suite, security review of the tier, docs-match-reality check, portability check; spend an /ultrareview at tier boundaries.

## Environment notes
- Swift 6.3.3 (toolchain updated from 6.2). Xcode at `/Applications/Xcode.app`. `xcode-select -p` → Xcode.
- `swiftlint`/`swift-format` not installed as separate binaries; `swift format` subcommand ships with the toolchain (verify). Prefer toolchain `swift format`.
- Docker Desktop is the target (`/usr/local/bin/docker`). Daemon currently up.
- Repo: github.com/ctkkoenig/macerodactyl (PRIVATE). gh authed as the owner.
- Panel DB: `~/Library/Application Support/Macerodactyl/panel.sqlite` (schema v2). Port 27180. LAN IP 192.168.4.166.
- Native app built via: `xcodebuild -project Macerodactyl.xcodeproj -scheme Macerodactyl -configuration Debug -derivedDataPath <scratch>/dd build CODE_SIGN_IDENTITY=-`.
- Kit tests: `cd MacerodactylKit && swift test`. Headless smoke: `swift run kitcheck ...` / `PanelTool ...`.

## Tiers & tasks (check as done)

### Tier 0 — prove the work (CI)
- [x] T0.1 GitHub Actions workflow: `swift test` (full suite) on macOS runner every push/PR. AC: `.github/workflows/ci.yml` exists; job builds Kit + runs tests; would go green (validate YAML + logic locally; can't run Actions here, so verify by `act`-style reasoning + a local dry run of each step).
- [x] T0.2 Formatting + lint gate. AC: `swift format lint` (or bundled) runs in CI and locally clean; a `.swift-format` config committed. Decide swift-format vs swiftlint (prefer toolchain swift-format — no extra dep).
- [x] T0.3 Integration job: stand up real Docker on the runner, exercise end-to-end (kitcheck against a fixture container + a curl pass against the panel). AC: a separate CI job using a docker-on-macos approach (colima) OR document why macOS runners can't and provide a Linux-server integration job once Tier 4 lands. Record decision.

### Tier 1 — make it trustworthy
- [x] T1.1 Decouple panel into a supervised process surviving app quit/logout/crash, self-restarting; GUI becomes a client. Decide LaunchAgent vs LaunchDaemon (weigh autologin). AC: quitting the GUI leaves the panel serving; killing the panel process → it restarts; still never starts containers at boot; GUI reflects live state via the running server. Real verification: kill -9 the daemon, confirm relaunch; quit GUI, confirm curl still 200.
- [x] T1.2 Rate-limiter → SQLite (survives restart). AC: fail logins to lockout, restart the server process, lockout persists; unit test with a persistent store.
- [x] T1.3 Health endpoint `/healthz` (unauthenticated, minimal: ok + version + daemon reachability). AC: returns 200 JSON; no secrets; tested.
- [x] T1.4 WAL checkpointing, DB backup/restore, integrity checks. AC: a backup command produces a restorable copy; `PRAGMA integrity_check` wired; documented; tested.
- [x] T1.5 First-class TLS for LAN bind (self-signed or ACME) + `Secure` cookie when bound LAN. Tunnel stays recommended default. AC: enabling LAN can offer HTTPS; cookie gains Secure over TLS; verify a real TLS handshake locally (curl -k). **Done** 2026-09-02: self-signed via openssl, HummingbirdTLS/NIOSSL, Secure cookie, GUI toggle; verified live handshake; 149 tests green.

### Tier 2 — worth opening daily
- [x] T2.1 Container lifecycle: create, recreate, remove, image pull/prune, volumes, networks, env editing. Each: confirmation + audit + permission gate. Decide if the 5 perms suffice or lifecycle needs its own. AC: gated (403 without), audited, destructive ops confirmed server-side too; traversal/argv-injection safe.
- [x] T2.2 Compose: view + apply compose file with streamed output. AC: gated on files or a new perm; streamed via SSE; confined to stack folder.
- [x] T2.3 Real file manager: upload, download, mkdir, rename, delete, binary handling — all via existing confinement. AC: re-run ALL traversal shapes against EVERY new endpoint (HTTP-level tests); binary download works; no parallel path.
- [x] T2.4 Retained metrics (ring-buffer stats → SQLite) + persistent searchable logs + download. Retention policy w/ safe default (won't fill disk). AC: retention enforced + tested; disk cost bounded; search works.

### Tier 3 — end the XSS liability
- [x] T3.1 Extract web frontend from the Swift string. Decide: build-step SPA vs server-rendered+htmx (no npm in build for source-only). AC: a missed escape is no longer a latent XSS (auto-escaping templating or framework); tests; a11y pass.

### Tier 4 — widen the audience
- [x] T4.1 Ship the server on Linux (headless). Verify it ACTUALLY builds+runs for Linux (SwiftPM Linux build; the app target excluded). AC: `swift build` for the server product on Linux (via docker swift image) succeeds; server runs and serves; a Docker image of the panel.

### Tier 5 — the shopfront
- [x] T5.1 README (real screenshots I captured), LICENSE, CONTRIBUTING, SECURITY, issue/PR templates, build-from-source w/ personal-team signing. AC: all present; README shows real screenshots; no notarization promised (no paid account).
- [x] T5.2 Homebrew cask + release workflow PREPARED, not published. AC: files exist, documented as manual-flip; distribution designed around no-notarization.

### Tier 6 — harden untested
- [x] T6.1 XCUITest for views. AC: at least a smoke UI test that launches and asserts key screens (may be limited by headless CI; record).
- [x] T6.2 Fuzzing for path-confinement + stats/ps parsers. AC: a fuzz harness (swift) that throws random/adversarial inputs; no crash, no escape.
- [x] T6.3 Property tests for the scoping matrix. AC: randomized grant sets, invariant: no view ⇒ nothing; independent perms; admin all.
- [x] T6.4 Adversarial pass: actively try to break the boundaries; log everything tried incl. what failed to break.
- [x] T6.5 TOTP 2FA (HummingbirdOTP) + session listing/revocation. Skip OIDC. AC: enroll TOTP, login requires it, gated; sessions listable + revocable; tested.

### If finished
- [ ] Fresh-eyes review: error messages, weakest tests, dead code, updated assessment.

### Final
- [ ] `docs/SESSION-REPORT.md`: built, decisions+reasoning, chose-not-to + why, bugs found in own prior work, uncertainties for owner, next steps. Honest about weak spots.

## Decisions log (fork → choice → why) — appended as I go
(see AUTONOMOUS-LOG.md for dated detail)
