# Development fixtures

Throwaway containers used to exercise Macerodactyl on a development machine.
They are **not** part of the app and are specific to whatever Mac you run them
on. The deployment target is Docker Desktop (expected binary
`/usr/local/bin/docker`); other providers work through the multi-path binary
resolution. If you find these lying around months later, they are safe to
delete.

| Fixture | What | Why |
| --- | --- | --- |
| `~/stacks/testweb/` | Compose stack: nginx (port 27980, healthcheck) + redis (healthcheck) | Compose grouping, health parsing, stack power actions, later file editing |
| `fixture-bare` | Bare `docker run` alpine running `sleep infinity` | The Unmanaged section, per-container power actions, exec console |
| `fixture-mc` | `itzg/minecraft-server`, RCON on host port 25575, password `fixturepass` | The RCON console path (Phase 2+) |

Manage them with the script:

```sh
scripts/fixtures.sh up      # create/start everything (Minecraft takes a minute or two to boot)
scripts/fixtures.sh down    # stop and delete all fixtures, including ~/stacks/testweb
```

`fixtures.sh down` removes the containers, the compose project, and the
`~/stacks/testweb` directory. It never touches anything that isn't in the table
above.
