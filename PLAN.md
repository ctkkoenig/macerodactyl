# Macerodactyl — Phase Plan

A native macOS control panel for local Docker containers, in the spirit of
Pterodactyl: one window to see every container (compose stacks and bare
`docker run` alike), start/stop them, stream logs, edit their files, schedule
restarts, and open a console. While running, it optionally serves a phone-first
web panel with full parity (view, power, logs, files, console), real user
accounts, per-container/per-permission scoping, and an audit trail.

Architectural constraints, the web security model, and the dependency policy are
recorded in [CLAUDE.md](CLAUDE.md); this file tracks the build order.

## Phone UX for the two hard parts

- **Console**: line-based by design, which maps naturally to a phone — a
  bottom-anchored input bar with a Send key, scrollback above, tap-to-recall
  command history, and per-container quick commands. No Ctrl/Tab is ever needed
  because it is not a TTY; each line runs via `docker exec` (or RCON for
  Minecraft, auto-detected — same UI shape, `list`/`say` as quick commands).
- **File editor**: files browse as a tappable card list; editing opens a
  full-screen sheet with a monospace textarea and a keyboard accessory row
  supplying what touch keyboards lack — Tab, indent/dedent, undo, ←/→ cursor
  nudges, and find. Drafts autosave locally; Save is explicit and Apply
  (compose up) is a separate confirmed action. No mouse-dependent interactions;
  no syntax highlighting in v1.

## Phase 1 — Foundation, data model, native dashboard

- Repo, CLAUDE.md, PLAN.md.
- Skeleton: `Macerodactyl.xcodeproj` (thin SwiftUI shell, App Sandbox off) +
  `MacerodactylKit` local Swift package holding all logic and tests.
- `DockerBinaryLocator`; `DockerCLI` actor (async Process wrapper, timeouts,
  streaming variant); `docker ps -a --format '{{json .}}'` parsing including
  health extraction from the status string; `ContainerStore` actor with an
  event stream (single source of truth for native and web).
- Data model & boundary land now so nothing retrofits: SQLite layer
  (users/grants/sessions/audit schema) and the pure `Authorization` module
  (permission matrix + path confinement) with unit tests passing.
- Native dashboard: sidebar of stacks + Unmanaged; rows with status dot,
  health, image, uptime, ports; start/stop/restart per container and per stack;
  ~3s auto-refresh; explicit "Docker daemon not running" state.
- Verify with a throwaway fixture stack + a bare `docker run` container;
  `swift test`. **Stop for verification.**

## Phase 2 — Native parity: logs, consoles, files

- UI-agnostic services in the Kit (the web reuses them untouched):
  `LogStreamService` (`docker logs --follow --tail 500 --timestamps`),
  `ExecConsoleService` (stateless per-line `/bin/sh -c`), `RCONService`
  (native RCON protocol: auth type 3, command type 2), `FileService`
  (list/read/write, confinement enforced inside the service).
- Native UI: log tab (follow/pause, filter, copy, capped scrollback); console
  tab (auto-switches to RCON for Minecraft); file browser rooted at the stack's
  working_dir with a monospace editor — dirty indicator, external-change
  detection, Open in Finder, and Apply (`docker compose up -d`) after compose
  edits.
- Fixture adds `itzg/minecraft-server` with RCON; verify auth + `list`.
  **Stop for verification.**

## Phase 3 — Web panel core

- Hummingbird server whose lifecycle follows the settings toggle; routes call
  the same `ContainerStore`/services, gated per-request by `Authorization`.
- Auth flow: first-run admin creation, bcrypt, sessions, login rate limiting.
- Phone dashboard: stack/container cards, status + health, power actions with
  confirmation, SSE live updates (a phone action updates an open native window
  live, and vice versa).
- Native-side: accounts & grants management UI; audit viewer; audit recording
  on every panel action; menu bar item (panel status, copy local URL, toggle);
  settings pane (enable toggle, port, bind-address opt-in with warning, docker
  path override, refresh interval).
- Tests: HTTP-level scoping suite — filtered lists, ungranted ID → 404, every
  permission bit enforced per route, session/CSRF checks.
  **Stop for verification (desktop + phone on LAN).**

## Phase 4 — Web parity hard parts, scheduling, ship

- Web logs: SSE-streamed with follow/pause and filter.
- Web console: the phone console above (exec + RCON), gated by the console
  permission, confined to its own container.
- Web file editor: card browser + full-screen editor with keyboard accessory
  row, Save/Apply as separate confirmed actions, all paths through
  `FileService` confinement; traversal tests at the HTTP layer.
- Restart schedules: per-schedule launchd agent plists on
  `StartCalendarInterval`, managed via `launchctl bootstrap`/`bootout`;
  absolute resolved docker path embedded (launchd inherits no shell PATH);
  each run's outcome recorded to a results log the schedules UI surfaces, so
  failures while Docker is down never pass silently. Restart-only, no
  `RunAtLoad` starts.
- Polish: consistent error surfacing, empty states, daemon-down handling in
  both UIs, app icon.
- README: requirements; clone → open the xcodeproj → Signing & Capabilities →
  select a personal team (and why distribution is source-only); sandbox-off
  note; web panel setup including tunnel pointer and the localhost-default /
  LAN-warning behavior; RCON setup for Minecraft.
- Full pass with a scoped test user from a phone. **Stop for verification.**

## Verification, every phase

- `swift test` in `MacerodactylKit` (works with Command Line Tools alone) —
  includes the scoping/confinement suites from Phase 1 onward.
- Behavior exercised against live fixture containers via the docker CLI and
  `curl` against the panel where the GUI can't be driven headlessly; a human
  performs the native/phone pass per phase.
