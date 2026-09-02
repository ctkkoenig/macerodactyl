# Running the panel on Linux (Docker)

The native **macOS app** is Mac-only. The **web panel** (`macerodactyld`) is
portable, so you can run it on a Linux host/server as a container. It manages the
host's Docker by shelling out to the `docker` CLI over the **mounted docker
socket** — never the socket API directly.

> Security note: the panel controls Docker on the host it can reach. Treat the
> published port like an admin surface — keep it on localhost or behind a tunnel
> that terminates TLS (the recommended setup), or enable the built-in self-signed
> HTTPS for a plain LAN bind. Identity is the panel's own accounts, never a proxy
> header.

## Build

```sh
docker build -t macerodactyl-panel .
```

This compiles **only** `macerodactyld` (the SwiftUI app/UI target is never built
on Linux) and produces a small runtime image with the Swift runtime, the docker
CLI, `openssl`, and `libsqlite3`.

## Run

```sh
docker run -d --name macerodactyl \
  -p 27180:27180 \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v /srv/stacks:/srv/stacks \
  -v macerodactyl-data:/root/.local/share/Macerodactyl \
  macerodactyl-panel
```

- `/var/run/docker.sock` — lets the panel run `docker` against the host daemon.
- `/srv/stacks` — your compose stacks (compose file + bind-mounted data), the
  same `~/stacks/<name>/` layout the mac app uses. The file manager is confined
  to a container's own stack folder under this root.
- `macerodactyl-data` — persists `panel.sqlite` (accounts, grants, audit,
  sessions, retained metrics) and `config.json` across restarts.

## Configuration

Put a `config.json` in the data volume
(`/root/.local/share/Macerodactyl/config.json`). For a container you almost
certainly want `bindLAN: true` (so the published port is reachable) and a
`stacksRoot` matching the mount:

```json
{
  "port": 27180,
  "bindLAN": true,
  "stacksRoot": "/srv/stacks",
  "dockerPathOverride": null,
  "tlsEnabled": false
}
```

Set `"tlsEnabled": true` to serve HTTPS with a self-signed certificate (generated
via `openssl`, stored in the data volume, key `0600`); browsers will warn once,
which is expected. A tunnel that terminates real TLS in front of the plain-HTTP
port remains the recommended production setup.

## First admin

On first start, if no accounts exist the panel mints an admin and writes the
one-time password to `first-admin.txt` in the data volume. Read it, sign in, then
manage further accounts and per-container grants from the panel.

```sh
docker exec macerodactyl cat /root/.local/share/Macerodactyl/first-admin.txt
```

## Notes / limitations

- Scheduled restarts on the mac use launchd; that mechanism is macOS-only. On
  Linux, schedule container restarts with the host's cron/systemd (or compose
  `restart:` policies), not through the panel's schedule tab.
- The image is built for the host architecture. Build on (or for) the
  architecture you deploy to; a published image would be multi-arch.
- The panel never starts containers at boot — that's your compose restart
  policies' job. The container only serves the panel and is always safe to stop.
