# Adversarial pass

This records the attacks tried against the web panel's security boundaries —
including the ones that (correctly) got nowhere. Each item that is exercised in
code points to the test that keeps it from regressing. This is a living document;
the goal is to write down *what was attempted*, not just what's covered.

## Attacks attempted, and the result

| # | Attack | Expected | Result | Guarded by |
|---|--------|----------|--------|-----------|
| 1 | Forge identity with proxy/SSO headers (`X-Forwarded-User`, `X-Remote-User`, `X-Auth-Request-User`, `Cf-Access-Authenticated-User-Email`) instead of a session | Ignored — 401 | Held | `AdversarialTests.proxyHeadersCannotForgeIdentity`; identity is set only from the session cookie (`SessionAuthenticator`), `clientIP` only from the socket (`PanelRequestContext`) |
| 2 | Present a forged / malformed / JSON / oversized session cookie | 401 | Held | `AdversarialTests.forgedSessionCookiesAreRejected`; the cookie value is SHA-256-hashed and looked up, an unknown hash is nobody |
| 3 | Mutating request (power) without the custom CSRF header | 403 before the action | Held | `AdversarialTests.mutatingRequestsWithoutCSRFHeaderAreBlocked`; global `CSRFMiddleware` on every POST/PUT/PATCH/DELETE |
| 4 | SQL injection via container name (`'; DROP TABLE users;--`, `' OR '1'='1`, UNION, …) | Treated as an ungranted name → 404; DB intact | Held | `AdversarialTests.sqlInjectionInContainerNamesDoesNothing`; every query uses bound parameters |
| 5 | Privilege escalation: a files-only user invokes power / console / schedule / pull / remove, and reaches an ungranted container and admin maintenance | 403 for a forbidden action, 404 for an ungranted container / admin surface | Held | `AdversarialTests.noPrivilegeEscalationAcrossTheMatrix`; per-container scope middleware + `RequireAdmin` |
| 6 | Path traversal on every file endpoint (`../`, `%2e%2e`, `..%2f`, absolute, `~`, NUL, symlinked destination parent) | Rejected, nothing outside the stack folder touched | Held | `PanelContainerTests.traversalShapesBlockedOnEveryNewFileEndpoint`, `FileServiceTests`, and 20k random paths in `FuzzTests` |
| 7 | Reveal existence of an ungranted container (compare 404s) | 404 for ungranted == 404 for non-existent, identical body | Held | `PanelContainerTests.ungrantedAndNonexistentAreIndistinguishable` |
| 8 | 2FA bypass: with TOTP enabled, log in with no code / a wrong code / a **replayed** code (reuse a valid code within its window) | No session; wrong/absent code denied; a code whose time-step was already consumed is rejected | Held | `TwoFactorAndSessionsTests` (incl. `totpCodeCannotBeReplayed`), `TOTPTests`; login records the matched step and rejects any code at that step or earlier |
| 9 | Brute-force the TOTP: many wrong codes | Each wrong code is a failed attempt that counts toward the same per-account rate limit as a bad password | Held | login gating calls `recordFailure` on a bad code; `RateLimiterTests` |
| 10 | Revoke another user's session by its id | 404 — a user can only revoke their own | Held | `TwoFactorAndSessionsTests.cannotRevokeAnotherUsersSession`; `deleteSession(userID:tokenHash:)` is scoped |
| 11 | Header injection via a crafted download filename (CR/LF/quotes) | Sanitized; no header split | Held | `PanelContainerTests.attachmentDispositionStripsControlBytesAndEncodesUTF8` |
| 12 | Make a container action mis-map to a weaker permission by naming a container `files`/`power`/`console`/`compose` | Mapping is by fixed route position, not substring | Held | `PanelContainerTests.requiredPermissionMapsByRoutePositionNotSubstring` |
| 13 | Crash a parser with garbage `docker` output (ps/stats/health/labels/inspect) | Best-effort parse, never a trap | Held | `ParserFuzzTests` (10k random inputs) |
| 14 | Escape file confinement with a symlink swapped in after validation (TOCTOU) | Not reachable — no endpoint creates symlinks, and `resolve` blocks traversing any pre-existing one | Held (by construction) | reviewed in the Tier 2 security pass; `PathConfinement` |

## Two independent fresh-eyes reviews

Beyond these tests, the Tier 1 and Tier 2 changes each went through a dedicated
adversarial review by a separate agent tasked with breaking the four load-bearing
properties. Tier 1 surfaced five real issues (all fixed: a restore data-loss bug,
a TLS→plaintext downgrade, a persisted-loopback rate-limit DoS, a healthz
subprocess fan-out, and secret file-mode races). Tier 2 found no exploitable
issue and two low hardening notes (both actioned). See `AUTONOMOUS-LOG.md`.

## Known, accepted limitations (not vulnerabilities)

- Anyone who can reach the panel and sign in controls the containers they're
  granted — that's the product. Keep the port behind a tunnel or on localhost.
- The Minecraft RCON console on the Linux build falls back to `docker exec`
  (Network.framework is macOS-only).
- Assets aren't content-hashed, so they're served `no-cache` (revalidate) rather
  than cached long — a deliberate trade to avoid stale-panel-after-update.
