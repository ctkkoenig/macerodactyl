# Macerodactyl headless panel — Linux server image.
#
# The native macOS app is Mac-only; this packages ONLY the headless web panel
# (`macerodactyld`) so it can run on a Linux host/server. It manages the host's
# Docker by shelling out to the `docker` CLI over the mounted docker socket —
# never the socket API directly (same rule as the mac build).
#
# Build:  docker build -t macerodactyl-panel .
# Run:    docker run -d --name macerodactyl \
#           -p 27180:27180 \
#           -v /var/run/docker.sock:/var/run/docker.sock \
#           -v /srv/stacks:/srv/stacks \
#           -v macerodactyl-data:/root/.local/share/Macerodactyl \
#           macerodactyl-panel
#
# Provide a config.json in the data volume (see docs/DOCKER.md) with
# "bindLAN": true and "stacksRoot": "/srv/stacks" so the panel is reachable on
# the published port and can edit files in your stacks.

# ---- build stage ------------------------------------------------------------
FROM swift:6.1-jammy AS build
RUN apt-get update \
 && apt-get install -y --no-install-recommends libsqlite3-dev \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /build
# Resolve dependencies first for better layer caching.
COPY MacerodactylKit/Package.swift MacerodactylKit/Package.resolved ./
RUN swift package resolve
COPY MacerodactylKit/Sources ./Sources
# The manifest declares test targets; SwiftPM validates their source paths exist
# even when building only a product, so the directories must be present. (They
# are not compiled — only `macerodactyld` and its deps are.)
COPY MacerodactylKit/Tests ./Tests
# Build ONLY the server product — the SwiftUI app/UI target is never built here.
# `--static-swift-stdlib` links the Swift runtime statically, which also resolves
# the dynamic libswiftObservation → swift::threading::fatal reference that fails
# to link against the shared runtime on Linux.
RUN swift build -c release --static-swift-stdlib --product macerodactyld
# Collect the binary and its resource bundles into one directory.
RUN mkdir -p /out \
 && cp .build/release/macerodactyld /out/ \
 && cp -r .build/release/*.resources /out/ 2>/dev/null || true

# ---- runtime stage ----------------------------------------------------------
FROM swift:6.1-jammy-slim AS runtime
# libsqlite3, openssl (self-signed TLS), and the docker CLI (the panel shells
# out to it) + ca-certificates for image pulls.
RUN apt-get update \
 && apt-get install -y --no-install-recommends libsqlite3-0 openssl ca-certificates docker.io \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY --from=build /out/ /app/
ENV PATH="/app:${PATH}"
EXPOSE 27180
# The panel never starts containers at boot (that's compose restart policies);
# it only serves. It stays in the foreground so Docker supervises it directly.
ENTRYPOINT ["/app/macerodactyld"]
