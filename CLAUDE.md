# Macerodactyl — project constraints

Native macOS (SwiftUI) control panel for local Docker containers, plus an optional
phone-first web panel served by the app. These constraints are load-bearing; do not
relax them without asking.

## Docker access
- Shell out to the `docker` CLI via `Process`. **Never** talk to the Unix socket:
  its log endpoint frames every chunk with an 8-byte header, and there is no good
  Swift Docker SDK. The CLI already handles all of that.
- Pass arguments as arrays. No shell string interpolation of user input, ever.
- GUI apps do **not** inherit the shell PATH — a bare `docker` lookup works in
  Terminal and fails when launched from Finder. Resolve the binary by explicit
  path: user override setting → `~/.orbstack/bin/docker` → `/opt/homebrew/bin/docker`
  → `/usr/local/bin/docker`. The same applies to generated launchd plists: always
  embed the absolute resolved path.

## Container model
- Compose stacks are detected via the labels `com.docker.compose.project`,
  `com.docker.compose.service`, and `com.docker.compose.project.working_dir`.
  Group by project; containers without those labels go in an **Unmanaged** section.
- Health is **not** a separate `docker ps` field. It lives inside the status string
  in parentheses: "Up 3 days (healthy)". Beware: "Exited (1) 2 hours ago" has a
  parenthesized *exit code*, not health — only healthy / unhealthy / health: starting
  count.
- The app excludes any container of itself (name or image `macerodactyl`) from
  every list, native and web.
- Stacks live in `~/stacks/<name>/` with the compose file and bind-mounted data
  beside it; that layout is what makes file editing possible.

## Two rules that are easy to get backwards
1. The app is **never** what starts containers at boot — that is the job of compose
   restart policies. The app must always be safe to quit. Scheduled restarts are
   launchd agents (they run `docker restart` on a calendar interval and survive app
   quit), never `RunAtLoad` container starts.
2. Minecraft's console is **RCON** (native protocol client), not `docker exec` —
   exec gives you a shell, not the server prompt. Detect via the
   `itzg/minecraft-server` image or `RCON_PASSWORD`/`RCON_PORT` env from
   `docker inspect`; read credentials at runtime, never store them in the repo.

## App configuration
- **App Sandbox stays OFF.** It blocks `Process` and reading outside the container.
  Do not add an entitlements file that enables it.
- macOS 15+ target. Thin app shell in `App/`; all logic, the web server, web
  resources, and tests live in the `MacerodactylKit` local Swift package so
  `swift build` / `swift test` work with Command Line Tools alone (no Xcode).

## Web panel (security boundary)
- Off by default; toggle in settings. Binds `127.0.0.1` by default; LAN binding is
  an explicit opt-in with a visible warning. Default port 27180. Plain HTTP only —
  TLS terminates at the tunnel (e.g. Cloudflare); never implement certificate
  handling.
- Real accounts, bcrypt-hashed passwords. Sessions in `HttpOnly` + `SameSite=Lax`
  cookies (`Strict` breaks the return navigation from Cloudflare Access) plus a
  custom-header CSRF check on mutating requests. Rate-limit failed logins.
- **Identity comes only from the app's own session. Never trust a proxy header**
  (Cloudflare Access, Tailscale, X-Forwarded-*) — the audit trail requires an
  identity the app owns.
- Per-user scoping is **the** security boundary: per container, separate view /
  power / files / console permissions. A scoped user sees *nothing* about
  ungranted containers — filtered lists, and 404 (not 403) for ungranted IDs.
  File access is confined to that container's own stack folder (realpath + prefix
  check); containers with no compose working_dir under the stacks root get **no**
  file access (permission greyed out, never granted-then-failing). Console access
  is confined to its own container. The `Authorization` module stays pure and has
  dedicated tests; keep them passing.
- Audit records who/what/which container/when/outcome/source IP for every panel
  action; viewable in the native app only. Accounts and grants are managed from
  the native app.
- No public REST API — the HTTP layer serves this UI only.

## Dependencies
Frozen at **Hummingbird 2** (HTTP server) and **Bcrypt via hummingbird-auth**
(user-approved). SQLite via system `libsqlite3`. Web frontend is vanilla
HTML/CSS/JS embedded in the bundle — no npm, no build toolchain. **Ask before
adding any other dependency.**

## Distribution & hygiene
- Source-only: no DMG, no notarization, no release pipeline (no paid Apple
  Developer account, and macOS 15 removed the Control-click Gatekeeper bypass).
  The README must explain selecting a personal team in Xcode's Signing &
  Capabilities — that is where people get stuck.
- The repo goes public later: keep local usernames, absolute home paths, and
  hostnames out of every committed file and commit message. No secrets in the repo.
