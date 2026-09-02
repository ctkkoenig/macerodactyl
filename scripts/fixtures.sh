#!/bin/sh
# Create or destroy the development fixtures described in docs/dev-fixtures.md.
# Usage: scripts/fixtures.sh up|down
set -e

DOCKER=""
for candidate in "$HOME/.orbstack/bin/docker" /opt/homebrew/bin/docker /usr/local/bin/docker; do
    if [ -x "$candidate" ]; then DOCKER="$candidate"; break; fi
done
if [ -z "$DOCKER" ]; then
    echo "error: docker binary not found" >&2
    exit 1
fi

STACK_DIR="$HOME/stacks/testweb"

up() {
    mkdir -p "$STACK_DIR/html"
    cat > "$STACK_DIR/docker-compose.yml" <<'EOF'
services:
  nginx:
    image: nginx:alpine
    ports:
      - "27980:80"
    volumes:
      - ./html:/usr/share/nginx/html:ro
    healthcheck:
      test: ["CMD", "wget", "-q", "--spider", "http://localhost/"]
      interval: 5s
      timeout: 3s
      retries: 3
  redis:
    image: redis:alpine
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 5s
      timeout: 3s
      retries: 3
EOF
    echo '<h1>macerodactyl fixture</h1>' > "$STACK_DIR/html/index.html"
    "$DOCKER" compose --project-directory "$STACK_DIR" up -d

    "$DOCKER" inspect fixture-bare >/dev/null 2>&1 \
        || "$DOCKER" run -d --name fixture-bare alpine:latest sleep infinity
    "$DOCKER" start fixture-bare >/dev/null

    "$DOCKER" inspect fixture-mc >/dev/null 2>&1 \
        || "$DOCKER" run -d --name fixture-mc \
            -e EULA=TRUE \
            -e ENABLE_RCON=true \
            -e RCON_PASSWORD=fixturepass \
            -e MEMORY=1G \
            -p 25575:25575 \
            itzg/minecraft-server
    "$DOCKER" start fixture-mc >/dev/null
    echo "fixtures up (Minecraft takes a minute or two before RCON answers)"
}

down() {
    "$DOCKER" compose --project-directory "$STACK_DIR" down --remove-orphans 2>/dev/null || true
    "$DOCKER" rm -f fixture-bare fixture-mc 2>/dev/null || true
    rm -rf "$STACK_DIR"
    echo "fixtures removed"
}

case "$1" in
    up) up ;;
    down) down ;;
    *) echo "usage: $0 up|down" >&2; exit 64 ;;
esac
