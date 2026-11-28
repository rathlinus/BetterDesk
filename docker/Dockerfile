# check=skip=SecretsUsedInArgOrEnv
# NeoDesk — one image, one process
# ====================================
# neodesk-server serves the signal and relay server, the API and the web
# console (DECISIONS A32). The web app is built into the binary.
#
# Published as ghcr.io/neodeskapp/neodesk (install/docker-compose.quick.single.yml
# runs it). Build it from a checkout instead, from the repository's root:
#   docker build -f docker/Dockerfile -t neodesk:local .
#   docker compose -f install/docker-compose.single.yml up -d
#
# Ports:
#   3375  - Web console (5443 with HTTPS_ENABLED); 5000 up to 3.6.0-rc.4
#   21121 - HTTP API (RustDesk client API + REST)
#   21122 - CDAP gateway (custom devices and agents)
#   21115 - NAT type test
#   21116 - Signal TCP/UDP
#   21117 - Relay TCP
#   21118 - WebSocket Signal
#   21119 - WebSocket Relay
#   21123 - Relay node control (NODE_CONTROL_PORT, 0 turns it off)

# ============= Web app build (only the build machine needs Node.js) =============
FROM node:22.23.2-alpine3.24 AS web-ui-builder

WORKDIR /web-ui

# npm 10 (bundled with Node 22) fails to resolve this dependency tree (ci.yml)
COPY web-ui/package.json web-ui/package-lock.json ./
RUN npx -y npm@11.6.2 ci --no-audit --no-fund

# The web app build generates the remote viewer's protobuf code from the
# server's schema (web-ui/vite-plugins/protos.ts reads ../neodesk-server/protos)
COPY neodesk-server/protos/ /neodesk-server/protos/
COPY web-ui/ .
RUN npm run build

# ============= Go server with the web app built in =============
FROM golang:1.26.11-alpine AS go-builder
ARG TARGETARCH

# Retry apk in case of transient DNS failures (common on AlmaLinux/CentOS Docker)
RUN apk add --no-cache git || { sleep 2 && apk add --no-cache git; }

WORKDIR /src
COPY neodesk-server/go.mod neodesk-server/go.sum ./
RUN go mod download

COPY neodesk-server/ .

# The embed step copies the web app build into the module before go build
# (DECISIONS A25), as the release binaries are built
COPY --from=web-ui-builder /web-ui/build /web-ui-build
RUN go run ./cmd/embed-webui -from /web-ui-build

# The binary's version, build date and commit (-version, the update check).
# Without build arguments: the version in VERSION and the time of the build;
# the commit only when NEODESK_COMMIT_SHA names it (the publish workflow
# and install/docker-compose.single.yml pass it).
ARG NEODESK_PRODUCT_VERSION=
ARG NEODESK_COMMIT_SHA=
ARG NEODESK_BUILD_DATE=

RUN version="${NEODESK_PRODUCT_VERSION:-$(tr -d '[:space:]' < VERSION)}" && \
    built="${NEODESK_BUILD_DATE:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}" && \
    CGO_ENABLED=0 GOOS=linux GOARCH=${TARGETARCH} go build -trimpath \
    -ldflags="-s -w -X main.Version=${version} -X main.Commit=${NEODESK_COMMIT_SHA} -X main.BuildDate=${built}" \
    -tags "netgo osusergo" \
    -o /neodesk-server .

# ============= Runtime =============
FROM alpine:3.22

LABEL maintainer="neodeskapp"
LABEL description="NeoDesk — server and web console in one process"
LABEL org.opencontainers.image.source="https://github.com/neodeskapp/neodesk"
LABEL version="3.6.7"

# Runtime packages (retry for transient DNS failures). sqlite stays for the
# admin credential bootstrap, which counts users with the sqlite3 CLI.
RUN apk add --no-cache ca-certificates curl sqlite tini su-exec shadow openssl \
    || { sleep 2 && apk add --no-cache ca-certificates curl sqlite tini su-exec shadow openssl; }

# Create neodesk user and directories
# The data volume is mounted at /opt/neodesk/data (docker/data-path.sh)
RUN addgroup -g 10001 -S neodesk && \
    adduser -u 10001 -S -G neodesk neodesk && \
    mkdir -p /opt/neodesk/data /app/data && \
    chown -R neodesk:neodesk /opt/neodesk/data /app/data

COPY --from=go-builder /neodesk-server /usr/local/bin/neodesk-server
# The same binary is the command line when called neodesk
RUN ln -s neodesk-server /usr/local/bin/neodesk

ARG NEODESK_IMAGE_VERSION=unknown
ENV NEODESK_IMAGE_VERSION=${NEODESK_IMAGE_VERSION}

COPY docker/ensure-app-user.sh /ensure-app-user.sh
COPY docker/entrypoint.sh /entrypoint.sh
COPY docker/dsn.sh /docker/dsn.sh
COPY docker/data-path.sh /docker/data-path.sh
COPY docker/healthcheck.sh /usr/local/bin/neodesk-healthcheck
COPY docker/bootstrap-admin-credentials.sh /docker/bootstrap-admin-credentials.sh
COPY docker/show-admin-credentials.sh /usr/local/bin/neodesk-show-admin-credentials
RUN chmod +x /ensure-app-user.sh /entrypoint.sh /docker/bootstrap-admin-credentials.sh /usr/local/bin/neodesk-show-admin-credentials /usr/local/bin/neodesk-healthcheck

# The console on 3375 (DECISIONS A27, A250), the API on 21121. The console's own
# client API listener stays off: the API serves RustDesk clients on 21121.
# NEODESK_SUPERVISOR: Docker's restart policy starts the process again
# after it ends with status 3 (a restart, an update or a restore from the
# panel, DECISIONS A30).
ENV NODE_ENV=production \
    CONSOLE_PORT=3375 \
    SIGNAL_PORT=21116 \
    SIGNAL_RATE_LIMIT_PER_IP=20 \
    HOST=0.0.0.0 \
    API_ENABLED=false \
    DOCKER=true \
    CONSOLE_DIR=/app \
    DATA_DIR=/app/data \
    RUSTDESK_PATH=/opt/neodesk/data \
    KEYS_PATH=/opt/neodesk/data \
    DB_PATH=/opt/neodesk/data/db_v2.sqlite3 \
    PUB_KEY_PATH=/opt/neodesk/data/id_ed25519.pub \
    API_KEY_PATH=/opt/neodesk/data/.api_key \
    HBBS_API_URL=http://127.0.0.1:21121/api \
    NEODESK_API_URL=http://127.0.0.1:21121/api \
    SERVER_BACKEND=neodesk \
    ENCRYPTED_ONLY=1 \
    RELAY_SERVERS= \
    NTP_SERVERS=pool.ntp.org,time.google.com,time.cloudflare.com \
    BILLING_MAX_CLOCK_SKEW_MS=2000 \
    BILLING_REQUIRE_SYNCED_CLOCK=1 \
    BILLING_TRUST_OS_NTP=Y \
    NEODESK_UPDATE_MODE=image \
    NEODESK_SUPERVISOR=docker

EXPOSE 3375 5443 21114 21115 21116/tcp 21116/udp 21117 21118 21119 21121 21122 21123

# The server writes files of its own (mesh_agent_server.pem) in its folder
WORKDIR /opt/neodesk/data

# The API and the web console of the one process, over HTTPS where they
# serve it (TLS_API, HTTPS_ENABLED)
HEALTHCHECK --interval=10s --timeout=10s --start-period=45s --retries=6 \
    CMD /usr/local/bin/neodesk-healthcheck

ENTRYPOINT ["/sbin/tini", "--", "/entrypoint.sh"]
CMD ["/usr/local/bin/neodesk-server", "-mode", "all", "-api-port", "21121", "-key-file", "/opt/neodesk/data/id_ed25519"]
