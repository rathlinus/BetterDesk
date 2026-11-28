#!/bin/sh
# NeoDesk — container entrypoint
# Prepares the volumes and settings, then runs neodesk-server (signal,
# relay, API and web console in one process) as the neodesk user.
set -e

# shellcheck source=/dev/null
. /ensure-app-user.sh
ensure_neodesk_user
# shellcheck source=docker/dsn.sh
. /docker/dsn.sh

# The ports the server listens on as SIGNAL_PORT and RELAY_PORT set them:
# the NAT test one below the signal port, each WebSocket port two above
# its TCP port, the API on 21121 (the image's -api-port). A value that is
# no number is shown as it is.
server_ports() {
    signal="${SIGNAL_PORT:-21116}" relay="${RELAY_PORT:-21117}"
    case "$signal$relay" in
        *[!0-9]*) echo "signal $signal, relay $relay, API 21121"; return ;;
    esac
    echo "NAT test $((signal - 1)), signal $signal, WebSocket signal $((signal + 2)), relay $relay, WebSocket relay $((relay + 2)), API 21121"
}

echo "========================================"
echo "  NeoDesk"
echo "  Version: ${NEODESK_IMAGE_VERSION:-3.6.7}"
echo "========================================"
echo ""
echo "  Server:       $(server_ports)"
echo "  Web console:  port ${CONSOLE_PORT:-3375}"
echo "  DATA_DIR:     ${DATA_DIR:-/app/data}"
echo ""

# The data volume: the server's keys, its SQLite database and the files
# below, at /opt/neodesk/data (DATA_PATH), or where a compose file of
# 3.6.0-rc.4 or older still mounts it; the server's arguments follow
# shellcheck source=docker/data-path.sh
. /docker/data-path.sh
choose_data_path
for arg do
    shift
    set -- "$@" "$(on_data_path "$arg")"
done

# Ensure data directories exist and have correct permissions
mkdir -p "$DATA_PATH" /app/data 2>/dev/null || true
chown -R neodesk:neodesk "$DATA_PATH" /app/data 2>/dev/null || true

# Shared bootstrap password of the admin account.
# shellcheck source=/docker/bootstrap-admin-credentials.sh
. /docker/bootstrap-admin-credentials.sh

# Write a file as neodesk. Fresh named volumes inherit image ownership
# (UID 10001 by default, or PUID after remap); with compose cap_drop:ALL root
# has no CAP_DAC_OVERRIDE and cannot create files there (Permission denied on
# .api_key).
write_as_neodesk() {
    # usage: write_as_neodesk <path> <content>
    printf '%s\n' "$2" | su-exec neodesk sh -c "umask 077; cat > \"$1\""
}

# API key of the server's API
API_KEY_FILE="$DATA_PATH/.api_key"
if [ -z "${API_KEY:-}" ] && ! file_exists_as_neodesk "$API_KEY_FILE"; then
    API_KEY=$(openssl rand -hex 32)
    write_as_neodesk "$API_KEY_FILE" "$API_KEY"
    echo "Auto-generated API key → $API_KEY_FILE"
elif [ -n "${API_KEY:-}" ] && ! file_exists_as_neodesk "$API_KEY_FILE"; then
    write_as_neodesk "$API_KEY_FILE" "$API_KEY"
    echo "API key from env → $API_KEY_FILE"
fi

# Key of the vault that holds the passwords of RDP and VNC targets: made at
# the first start and kept in the data volume, unless REMOTE_TARGET_VAULT_KEY
# is set
VAULT_KEY_FILE="$DATA_PATH/.remote_target_vault_key"
if [ -z "${REMOTE_TARGET_VAULT_KEY:-}" ]; then
    if ! file_exists_as_neodesk "$VAULT_KEY_FILE"; then
        write_as_neodesk "$VAULT_KEY_FILE" "$(openssl rand -hex 32)"
        echo "Made the remote target vault key → $VAULT_KEY_FILE"
    fi
    REMOTE_TARGET_VAULT_KEY=$(su-exec neodesk cat "$VAULT_KEY_FILE")
fi
export REMOTE_TARGET_VAULT_KEY

# Default enrollment policy. The server stores the mode of its first start
# and keeps the one saved in the console from then on; ENROLLMENT_MODE is
# only that first default (ENROLLMENT_MODE_ENV_OVERRIDE=Y forces it at
# every start).
# Fresh volumes default to "managed": stock RustDesk clients are queued for
# operator approval instead of connecting silently. Pre-existing installs keep
# their current behavior (Go default "open", or whatever was set via the panel
# and persisted in the database). A volume that already contains a server key
# or SQLite database is treated as pre-existing.
if [ -z "${ENROLLMENT_MODE:-}" ]; then
    ENROLLMENT_SENTINEL="$DATA_PATH/.enrollment_initialized"
    if ! file_exists_as_neodesk "$ENROLLMENT_SENTINEL"; then
        if file_exists_as_neodesk "$DATA_PATH/db_v2.sqlite3" \
            || file_exists_as_neodesk "$DATA_PATH/id_ed25519"; then
            echo "Enrollment:   preserving existing policy (pre-existing volume)"
        else
            export ENROLLMENT_MODE="managed"
            echo "Enrollment:   managed (fresh install — new devices need approval)"
        fi
        su-exec neodesk touch "$ENROLLMENT_SENTINEL" 2>/dev/null || true
    fi
fi

# Verify write access — SQLite WAL mode requires writable directory
_app_uid="${PUID:-10001}"
_app_gid="${PGID:-10001}"
if ! su-exec neodesk touch "$DATA_PATH/.write_test" 2>/dev/null; then
    echo ""
    echo "ERROR: $DATA_PATH is NOT writable by the neodesk user (UID ${_app_uid})."
    echo "  SQLite WAL mode requires write access to the database directory."
    echo "  If using bind mounts, either set PUID/PGID to the host owner, or run:"
    echo "    chown -R ${_app_uid}:${_app_gid} /path/to/your/data"
    echo "  Or use Docker named volumes instead of bind mounts."
    echo ""
fi
rm -f "$DATA_PATH/.write_test" 2>/dev/null || true
# Fix private key permissions (volume mounts may preserve wrong UID/mode)
if file_exists_as_neodesk "$DATA_PATH/id_ed25519"; then
    chmod 600 "$DATA_PATH/id_ed25519" 2>/dev/null || true
    chown neodesk:neodesk "$DATA_PATH/id_ed25519" 2>/dev/null || true
fi

# Warn about weak default secrets
if [ -n "${SESSION_SECRET}" ] && [ ${#SESSION_SECRET} -lt 32 ]; then
    echo "WARNING [SECURITY]: SESSION_SECRET is shorter than 32 characters — generate a stronger secret"
fi
if [ -n "${ADMIN_PASSWORD}" ] && [ ${#ADMIN_PASSWORD} -lt 12 ]; then
    echo "WARNING [SECURITY]: ADMIN_PASSWORD is shorter than 12 characters — use a stronger password"
fi

# The server's database: DB_URL, the SQLite path or the postgres:// URI. A
# separate auth.db of an older install (AUTH_DB_PATH) is imported into it at
# the first start. Log lines name the database without its credentials.
# DATABASE_URL names the database by its scheme; DB_TYPE=postgres is still
# read for older compose files.
case "${DATABASE_URL:-}" in
    postgres://*|postgresql://*) DB_TYPE=postgres ;;
esac
if [ "${DB_TYPE:-}" = "postgres" ] || [ "${DB_TYPE:-}" = "postgresql" ]; then
    if [ -n "${DATABASE_URL:-}" ]; then
        export DB_URL="${DATABASE_URL}"
        echo "Database:     PostgreSQL ($(dsn_for_log "$DATABASE_URL"))"
    else
        echo "WARNING: DB_TYPE=postgres but DATABASE_URL not set — falling back to SQLite"
        export DB_URL="$DATA_PATH/db_v2.sqlite3"
    fi
else
    export DB_URL="${DB_PATH:-$DATA_PATH/db_v2.sqlite3}"
    export AUTH_DB_PATH="${AUTH_DB_PATH:-/app/data/auth.db}"
    echo "Database:     SQLite ($(dsn_for_log "$DB_URL"))"
fi

# Wait for PostgreSQL if configured
if [ "${DB_TYPE:-}" = "postgres" ] || [ "${DB_TYPE:-}" = "postgresql" ]; then
    if [ -n "${DATABASE_URL:-}" ]; then
        echo "Waiting for PostgreSQL..."
        PG_HOST=$(dsn_host "$DATABASE_URL")
        PG_PORT=$(dsn_port "$DATABASE_URL")
        RETRIES=0
        MAX_RETRIES=30
        while [ "$RETRIES" -lt "$MAX_RETRIES" ]; do
            if nc -z "$PG_HOST" "$PG_PORT" 2>/dev/null; then
                echo "  PostgreSQL is ready ($PG_HOST:$PG_PORT)"
                break
            fi
            RETRIES=$((RETRIES + 1))
            echo "  Waiting... ($RETRIES/$MAX_RETRIES)"
            sleep 2
        done
        if [ "$RETRIES" -ge "$MAX_RETRIES" ]; then
            echo "  WARNING: PostgreSQL not reachable — starting anyway"
        fi
    fi
fi

# The signal port is SIGNAL_PORT, never the PORT an older compose file sets
export SIGNAL_PORT="${SIGNAL_PORT:-21116}"
export SIGNAL_RATE_LIMIT_PER_IP="${SIGNAL_RATE_LIMIT_PER_IP:-20}"
export HOST="${HOST:-0.0.0.0}"

# Relay server address: if not explicitly set, try to auto-detect public IP.
# Inside Docker, the Go server's own detection may return the container's
# internal IP (172.x.x.x) which is unreachable by remote clients.
if [ -z "${RELAY_SERVERS:-}" ]; then
    DETECTED_IP=""
    if command -v curl >/dev/null 2>&1; then
        DETECTED_IP=$(curl -4 -sf --max-time 5 https://checkip.amazonaws.com 2>/dev/null \
            || curl -4 -sf --max-time 5 https://api.ipify.org 2>/dev/null \
            || curl -4 -sf --max-time 5 https://ifconfig.me/ip 2>/dev/null || true)
        DETECTED_IP=$(echo "$DETECTED_IP" | tr -d '[:space:]')
    fi
    if [ -n "$DETECTED_IP" ]; then
        # Verify it's not a private/Docker IP
        case "$DETECTED_IP" in
            10.*|172.1[6-9].*|172.2[0-9].*|172.3[0-1].*|192.168.*|127.*)
                echo "WARNING: Auto-detected IP ($DETECTED_IP) is private — relay may fail for remote clients."
                echo "         Set RELAY_SERVERS=YOUR.PUBLIC.IP in the .env next to the compose file, then run docker compose up -d"
                ;;
            *)
                export RELAY_SERVERS="$DETECTED_IP"
                echo "Relay IP:     $DETECTED_IP (auto-detected)"
                ;;
        esac
    else
        echo "WARNING: Could not auto-detect public IP for relay."
        echo "         Set RELAY_SERVERS=YOUR.PUBLIC.IP in the .env next to the compose file, then run docker compose up -d"
    fi
else
    echo "Relay IP:     $RELAY_SERVERS (from env)"
fi
export RELAY_SERVERS="${RELAY_SERVERS:-}"

echo ""
if [ "${HTTPS_ENABLED:-false}" = "true" ]; then
    echo "  Web console:  https://localhost:${HTTPS_PORT:-5443}"
    echo "  HTTP redirect: http://localhost:${CONSOLE_PORT:-3375} → https://…:${HTTPS_PORT:-5443}"
else
    echo "  Web console:  http://localhost:${CONSOLE_PORT:-3375}"
fi
echo "  API:          http://localhost:21121/api"
echo "========================================"
echo ""

# One process as neodesk. tini passes its exit on; status 3 is a restart
# request and the restart policy starts the container again.
# The server writes files of its own (mesh_agent_server.pem) in its
# folder, the image's working folder; in an older place of the data volume
# it changes there as neodesk (with cap_drop: ALL root may not)
if [ "$DATA_PATH" != "$NEW_DATA_PATH" ]; then
    exec su-exec neodesk sh -c 'cd "$0" && exec "$@"' "$DATA_PATH" "$@"
fi
exec su-exec neodesk "$@"
