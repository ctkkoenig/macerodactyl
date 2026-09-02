# Macerodactyl — Autonomous Execution Log

Append-only. Newest at bottom. Each entry: date, item, what I did, decisions
(fork→choice→why), what I rejected, verification result.

---

## 2026-09-02 — Session start / orientation
- Baseline: `main` @ `d287594`, clean tree, **131 tests green**. Repo PRIVATE (confirmed via gh). Docker daemon up. Swift 6.3.3, Xcode active.
- Wrote `docs/AUTONOMOUS-PLAN.md` (ordered checklist + acceptance criteria) and this log. These are my memory across resets.
- Constraints internalized: fixtures I own = testweb / fixture-bare / fixture-mc; NEVER touch workload-a or workload-b; repo stays private, no release publish; don't touch icon/logo; green-only commits; no coverage cuts; no security weakening.
- Environment deltas since last work: toolchain moved 6.2 → 6.3.3 (watch for new warnings-as-errors or format differences). `swiftlint`/`swift-format` not installed standalone; will prefer toolchain `swift format`.
- Plan for Tier 0 next: CI workflow (macOS runner, swift test), format/lint gate, integration job. Cannot execute GitHub Actions from here, so acceptance = validate each step runs locally + YAML is correct; the owner will see it run on push (I will NOT push to a public remote; origin is private, pushing to the private origin is allowed and desired).

## 2026-09-02 — Tier 0 CI (T0.1–T0.3)
- **Did**: adopted `swift format` (config-to-existing 4-space rather than churn to its 2-space default; PanelHTML.swift marked `swift-format-ignore-file` since Tier 3 replaces it). Formatted all sources; repo lints clean. Added `.github/workflows/ci.yml`: lint (Linux swift:6.0 container — format only parses, no SDK), test+build (macos-15), integration (macos-15 + colima real dockerd → kitcheck end-to-end).
- **Decision (T0.3 fork)**: macOS runners can't run Docker Desktop → used **colima** for a real daemon; the full HTTP e2e (server+curl) waits for the standalone daemon (Tier 1) since the GUI can't run headless. kitcheck exercises the docker-CLI core now.
- **Verified locally**: YAML parses (ruby), strict lint exit 0, `xcodebuild ... CODE_SIGNING_ALLOWED=NO` BUILD SUCCEEDED, kitcheck subcommands present. Pushed to PRIVATE origin; CI run 33590033578 triggered (monitoring in background). Rejected: pushing every commit (macOS minutes cost) → will push at tier boundaries.

## 2026-09-02 — Tier 1 architecture decisions (before building)
- **Decouple = a real headless daemon executable** (`macerodactyld`) that serves the panel independently of the GUI. Prior design ran Hummingbird as a Task inside the GUI process (dies on quit).
- **Fork: LaunchAgent vs LaunchDaemon → chose LaunchAgent.** Why: Docker Desktop is a *per-user* service (socket at `~/.docker/run/docker.sock`); a system LaunchDaemon (root) can't cleanly reach it. Owner runs autologin, so a LaunchAgent is effectively always-on (starts at auto-login, `KeepAlive` restarts on crash, survives app quit; reboot re-logs-in and relaunches). LaunchDaemon's only gain (logout survival) is moot under autologin, at the cost of docker access. RunAtLoad starts only the SERVER, never a container — respects "never starts containers at boot."
- **Fork: GUI-as-client vs GUI-reads-docker-directly → chose the daemon reads docker directly; GUI keeps its own direct-docker ContainerStore for native display.** Why: making the native SwiftUI a pure HTTP client of the daemon is a full rewrite that loses live SwiftUI observation. Instead the *shared source of truth is docker itself* + the shared `panel.sqlite` (accounts/grants/audit/sessions, WAL = multi-process safe). Tradeoff: a phone action now reflects in the native window within the GUI's ~3s poll instead of instantly. Documented regression; a GUI↔daemon event channel is future work. The GUI stops hosting the server and instead installs/monitors the LaunchAgent.
- **Config sharing**: daemon has its own UserDefaults domain, so it can't read the GUI's `AppSettings`. Introduce a shared **`PanelConfig` JSON** at `~/Library/Application Support/Macerodactyl/config.json` both read; GUI writes the daemon-relevant subset (port, bindLAN, dockerPathOverride, stacksRoot) on change.
- **New: `DaemonContainerService`** — a `ContainerService` backed by `DockerCLI` directly (no `@MainActor`/`ContainerStore`), so the daemon (and later the Linux build) needs no SwiftUI. Mirrors `LiveContainerService` behavior sourcing containers from `docker ps`.
- Staging: (A) PanelConfig + DaemonContainerService + tests; (B) macerodactyld exe + PanelDaemonManager (launchd plist install/uninstall/status) + LIVE verify (kill -9 → KeepAlive restart, quit GUI → curl still 200); (C) GUI wiring + bundle the daemon binary via an Xcode copy phase.
