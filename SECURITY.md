# Security policy

Macerodactyl controls Docker on the machine it runs on and, when the optional web
panel is enabled, exposes that control over HTTP. Its security model is the point
of the project, so security reports are taken seriously.

## Reporting a vulnerability

Please **do not open a public issue** for a security vulnerability. Instead use
GitHub's **private vulnerability reporting** (the *Report a vulnerability* button
under the repository's **Security** tab). If that is unavailable, open a minimal
issue asking for a private contact channel — without details — and wait.

When reporting, include:

- what an attacker can do (the impact),
- the smallest reproduction you have (requests, config, versions),
- whether the web panel was enabled and how it was bound (localhost / LAN /
  tunnel / built-in HTTPS).

You can expect an acknowledgement, and a fix or a clear explanation of why the
behavior is intended. Please give a reasonable window to address the issue before
any public disclosure.

## The security model (what "a bug" means here)

These properties are load-bearing. A way to break any of them is a vulnerability:

- **Per-user scoping is the boundary.** Each account gets per-container
  permissions (view / power / files / console / schedules / lifecycle). A scoped
  user must see *nothing* about a container they aren't granted — filtered lists,
  and **404 (not 403)** for an ungranted or non-existent container, so existence
  is never revealed.
- **File access is confined** to a container's own stack folder (realpath +
  prefix check, symlink-aware). No path — `..`, percent-encoded, absolute,
  symlink — may escape it.
- **Identity is the panel's own session only.** The panel never trusts a proxy
  header (`X-Forwarded-*`, Cloudflare Access, Tailscale) to decide who you are.
- **Daemon-global actions are admin-only** (image prune, disk usage) — a scoped
  user can't reach them.
- Passwords are bcrypt-hashed (SHA-256 pre-hash so long passwords aren't
  truncated); sessions are `HttpOnly` + `SameSite=Lax` cookies with a custom
  CSRF header on every mutating request; failed logins are rate-limited and the
  limit persists across restarts.

## Operational guidance (not a vulnerability, but important)

- The web panel is **off by default** and binds `127.0.0.1`. Binding to the LAN
  is an explicit, warned opt-in.
- The recommended way to reach it remotely is a **tunnel that terminates real
  TLS** (e.g. Cloudflare Tunnel). For a plain LAN bind, turn on the built-in
  self-signed **HTTPS** so credentials aren't sent in the clear.
- Anyone who can reach the panel and sign in can control the Docker containers
  they're granted. Treat the port like an admin surface.

## Scope

This policy covers the code in this repository. It does not cover Docker itself,
your reverse proxy or tunnel, or the security of the host OS.
