#!/bin/bash
#===============================================================================
#
#   NeoDesk Console Manager v3.6.6
#   All-in-One Interactive Tool for Linux
#
#   Features:
#     - Fresh installation: one service, neodesk-server, that serves the
#       signal and relay server, the API and the web console
#     - Minimal installation (the same server with its web console off)
#     - Update an installation (release binaries checked by SHA-256 and the
#       release signature)
#     - Repair/fix issues (enhanced with graceful shutdown)
#     - Validate installation
#     - Backup & restore
#     - Reset admin password
#     - Build & deploy server (rebuild Go binary with rollback)
#     - Full diagnostics
#     - SHA-256 and signature checks of release binaries
#     - Auto mode (non-interactive)
#     - Enhanced service management with health verification
#     - Port conflict detection
#     - Fixed ban system (device-specific, not IP-based)
#     - RustDesk Client API (login, address book sync)
#     - TOTP Two-Factor Authentication
#     - SSL/TLS certificate configuration
#     - PostgreSQL database support
#     - SQLite to PostgreSQL migration
#     - CDAP (Custom Device API Protocol) support
#
#   Usage: 
#     Interactive: sudo ./neodesk.sh
#     Auto mode:   sudo ./neodesk.sh --auto
#     PostgreSQL:  sudo ./neodesk.sh --auto --postgresql
#     Update:      sudo ./neodesk.sh --update
#
#===============================================================================

set -e

# Version
VERSION="3.6.6"
# Bump when installer control-flow changes must apply mid-session after Update.
NEODESK_SH_REVISION="20261125-console-port-3375-309"
# Where people ask for help: the NeoDesk Discord
NEODESK_HELP_URL="https://discord.gg/nwERSawufr"
# The console's port when the install's settings name none (the server's
# default): 3375 since 3.6.0-rc.5 (DECISIONS A250), 5000 before
CONSOLE_DEFAULT_PORT=3375
CONSOLE_OLD_DEFAULT_PORT=5000
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The repository's root when this script runs from a checkout (its install/
# folder), else the script's own folder
REPO_DIR="$SCRIPT_DIR"
[ -d "$SCRIPT_DIR/../neodesk-server" ] && REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# This file; empty when the script is piped into bash
NEODESK_SELF="${BASH_SOURCE[0]:-}"
# Preserve argv before shift — used to re-exec after installer self-update.
NEODESK_ORIG_ARGV=("$@")

# This installer as a command, for updates and the uninstall later:
# neodesk-setup. neodesk is the command line, a copy of the server binary
# that is root's own and that every user may run (the server folder stays
# closed), which hands the installer's options (neodesk --update, ...) and
# a bare `sudo neodesk` on a terminal to neodesk-setup. Up to 3.6.0-rc.4
# the installer itself was /usr/local/sbin/neodesk.
MANAGER_COMMAND="/usr/local/sbin/neodesk-setup"
OLD_MANAGER_COMMAND="/usr/local/sbin/neodesk"
CLI_COMMAND="/usr/local/bin/neodesk"

# binary_hands_over BIN: BIN is a server binary whose command line hands
# the installer's options to neodesk-setup (it names it). An older one
# would take neodesk --update for a command of its own.
binary_hands_over() {
    [ -x "$1" ] && grep -a -q -F 'neodesk-setup' "$1" 2>/dev/null
}

# is_old_manager FILE: FILE is a copy of this installer, not a link
is_old_manager() {
    [ -f "$1" ] && [ ! -L "$1" ] && grep -q '^NEODESK_SH_REVISION=' "$1" 2>/dev/null
}

# is_our_cli FILE: FILE is the command line this installer placed: a copy
# of the server binary (it names neodesk-setup), or the link to a
# neodesk-server that builds before 3.6.0-rc.5 placed
is_our_cli() {
    if [ -L "$1" ]; then
        [ "$(basename "$(readlink "$1")")" = neodesk-server ]
        return
    fi
    [ -f "$1" ] && binary_hands_over "$1" && ! grep -q '^NEODESK_SH_REVISION=' "$1" 2>/dev/null
}

# place_cli BIN: the command line neodesk as a copy of BIN, mode 755 and
# root's own, by a rename in its folder: any user may run it, while the
# server folder stays closed and only root changes the copy
place_cli() {
    local dir tmp
    dir=$(dirname "$CLI_COMMAND")
    mkdir -p "$dir" || return 1
    tmp=$(mktemp "$dir/.$(basename "$CLI_COMMAND").XXXXXX") || return 1
    if cp "$1" "$tmp" && chmod 755 "$tmp" && { [ "$(id -u)" != 0 ] || chown 0:0 "$tmp"; } \
        && mv -f "$tmp" "$CLI_COMMAND"; then
        return 0
    fi
    rm -f "$tmp"
    return 1
}

# replace_file SRC DEST: DEST becomes a copy of SRC (mode 755) by a rename
# in DEST's folder, never by writing over it: bash reads a script while it
# runs, and a copy that runs from DEST reads on from the file it opened.
replace_file() {
    local dir tmp
    dir=$(dirname "$2")
    mkdir -p "$dir" || return 1
    tmp=$(mktemp "$dir/.$(basename "$2").XXXXXX") || return 1
    if cp "$1" "$tmp" && chmod 755 "$tmp" && mv -f "$tmp" "$2"; then
        return 0
    fi
    rm -f "$tmp"
    return 1
}

# place_manager_commands SRC BIN: the installer SRC as neodesk-setup, the
# command line neodesk as a copy of the server binary BIN, and the old
# manager at /usr/local/sbin/neodesk gone, since it comes first in root's
# PATH. Returns 0 for that, 1 when neodesk-setup could not be written, 2
# when BIN does not hand the installer's options over yet and 3 when
# another program has neodesk's place. With 2 and 3 an old manager stays,
# as the newest installer, so sudo neodesk keeps working.
place_manager_commands() {
    local src=$1 bin=$2 rc=0
    replace_file "$src" "$MANAGER_COMMAND" || return 1
    if ! binary_hands_over "$bin"; then
        rc=2
    elif { [ -e "$CLI_COMMAND" ] || [ -L "$CLI_COMMAND" ]; } && ! is_our_cli "$CLI_COMMAND"; then
        rc=3
    elif ! place_cli "$bin"; then
        rc=4
    fi
    if is_old_manager "$OLD_MANAGER_COMMAND"; then
        if [ "$rc" = 0 ]; then
            rm -f "$OLD_MANAGER_COMMAND"
        elif [ "$(readlink -f "$src")" != "$(readlink -f "$OLD_MANAGER_COMMAND")" ]; then
            replace_file "$src" "$OLD_MANAGER_COMMAND" || true
        fi
    fi
    return "$rc"
}

# installed_server_binary: the binary the service runs (the ExecStart of
# its unit), else the default place
installed_server_binary() {
    local unit="${SERVER_UNIT:-/etc/systemd/system/neodesk-server.service}" bin=""
    [ ! -f "$unit" ] || bin=$(sed -n 's/^ExecStart=\([^ ]*\).*/\1/p' "$unit" | head -n 1)
    printf '%s\n' "${bin:-/opt/neodesk/neodesk-server}"
}

# Run from the manager's old place: an update by an older copy (3.6.0-rc.4
# or older) saved this installer as /usr/local/sbin/neodesk. As root, it
# finishes the move before anything else and hands this call to neodesk,
# which gives the installer's options back to neodesk-setup. The file it
# runs from is unlinked, never written over.
if [ -n "$NEODESK_SELF" ] && [ "$EUID" -eq 0 ] \
    && [ "$(readlink -f "$NEODESK_SELF" 2>/dev/null)" = "$(readlink -f "$OLD_MANAGER_COMMAND" 2>/dev/null)" ]; then
    if place_manager_commands "$NEODESK_SELF" "$(installed_server_binary)"; then
        echo "The installer's manager is neodesk-setup now, and neodesk is the command line (neodesk --help)." >&2
        exec "$CLI_COMMAND" "$@"
    fi
fi

# Auto mode flag
AUTO_MODE=false
SKIP_VERIFY=false
MINIMAL_MODE=false
UNINSTALL_MODE=false
PURGE_MODE=false
CHECK_CAPABILITIES=false
REPAIR_PERMISSIONS=false
MANAGED_CONFIG_CHANGES=()
UPDATE_MODE=false
RESET_PASSWORD_MODE=false
RESET_TWO_FACTOR=false
# Where the server binary comes from: a file (--binary), a build of this
# checkout (--from-source), else the release of the update channel.
SERVER_BINARY_FILE="${SERVER_BINARY_FILE:-}"
FROM_SOURCE=false
# --node: this machine becomes a relay node of a site (do_node_install),
# with the console's join string and the addresses devices dial it at
NODE_MODE=false
NODE_JOIN="${NODE_JOIN:-}"
NODE_LAN_ADDR="${NODE_LAN_ADDR:-}"
NODE_PUBLIC_ADDR="${NODE_PUBLIC_ADDR:-}"
# The release key (DECISIONS A152): the public half of the ed25519 key
# that signs each release's manifest. A binary with verify-release carries
# the same key; without one, openssl checks a download with this copy.
RELEASE_PUBLIC_KEY_PEM='-----BEGIN PUBLIC KEY-----
MCowBQYDK2VwAyEAiwissiXvSjeFFsG8SdKEZq11uAtRLWCrD7Ky1vfY2n4=
-----END PUBLIC KEY-----'

# Relay server selection mode:
#   auto   - detect public IP (default, best for internet-facing servers)
#   local  - use the server's LAN IP (best for LAN-only deployments)
#   public - force public IP detection
# RELAY_SERVERS env var (or --relay-servers) always overrides this with a fixed value.
RELAY_MODE="${RELAY_MODE:-auto}"

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --auto|-a)
            AUTO_MODE=true
            shift
            ;;
        --skip-verify)
            SKIP_VERIFY=true
            shift
            ;;
        --minimal)
            MINIMAL_MODE=true
            shift
            ;;
        --uninstall)
            UNINSTALL_MODE=true
            shift
            ;;
        --purge)
            PURGE_MODE=true
            shift
            ;;
        --check-permissions|--check-capabilities)
            CHECK_CAPABILITIES=true
            shift
            ;;
        --repair-permissions)
            REPAIR_PERMISSIONS=true
            shift
            ;;
        --set-config)
            if [ $# -lt 2 ] || [[ "$2" != *=* ]]; then
                echo "ERROR: --set-config requires KEY=VALUE"
                exit 1
            fi
            MANAGED_CONFIG_CHANGES+=("$2")
            shift 2
            ;;
        --nodejs|--flask)
            echo "NOTE: $1 is no longer needed: the web console is part of neodesk-server"
            shift
            ;;
        --update)
            UPDATE_MODE=true
            shift
            ;;
        --reset-password)
            RESET_PASSWORD_MODE=true
            shift
            ;;
        --reset-two-factor)
            # Part of the password reset: alone it is one too
            RESET_TWO_FACTOR=true
            RESET_PASSWORD_MODE=true
            shift
            ;;
        --binary)
            if [ $# -lt 2 ] || [ ! -f "$2" ]; then
                echo "ERROR: --binary needs the path of a neodesk-server binary"
                exit 1
            fi
            SERVER_BINARY_FILE="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"
            shift 2
            ;;
        --from-source)
            FROM_SOURCE=true
            shift
            ;;
        --node)
            NODE_MODE=true
            shift
            ;;
        --join|--lan-addr|--public-addr)
            if [ $# -lt 2 ] || [ -z "$2" ]; then
                echo "ERROR: $1 needs a value"
                exit 1
            fi
            case $1 in
                --join) NODE_JOIN="$2" ;;
                --lan-addr) NODE_LAN_ADDR="$2" ;;
                --public-addr) NODE_PUBLIC_ADDR="$2" ;;
            esac
            shift 2
            ;;
        --channel)
            case "${2:-}" in
                stable|main) UPDATE_GITHUB_BRANCH=main ;;
                dev|development) UPDATE_GITHUB_BRANCH=dev ;;
                *)
                    echo "ERROR: --channel must be 'stable' or 'dev'"
                    exit 1
                    ;;
            esac
            export UPDATE_GITHUB_BRANCH
            shift 2
            ;;
        --postgresql|--postgres)
            USE_POSTGRESQL=true
            shift
            ;;
        --relay-mode)
            RELAY_MODE="$2"
            if [ "$RELAY_MODE" != "auto" ] && [ "$RELAY_MODE" != "local" ] && [ "$RELAY_MODE" != "lan" ] && [ "$RELAY_MODE" != "public" ] && [ "$RELAY_MODE" != "wan" ]; then
                echo "ERROR: --relay-mode must be 'auto', 'local' (lan) or 'public' (wan)"
                exit 1
            fi
            shift 2
            ;;
        --relay-servers|--relay)
            RELAY_SERVERS="$2"
            shift 2
            ;;
        --protocol)
            echo "NOTE: --protocol does nothing; switch HTTP and HTTPS with sudo neodesk-setup, Toggle HTTP/HTTPS"
            shift 2
            ;;
        --pg-uri)
            POSTGRESQL_URI="$2"
            USE_POSTGRESQL=true
            shift 2
            ;;
        --help|-h)
            echo "NeoDesk Console Manager v$VERSION"
            echo ""
            echo "Usage: sudo neodesk-setup [OPTIONS]   (from a checkout: sudo ./neodesk.sh [OPTIONS])"
            echo ""
            echo "Options:"
            echo "  --auto, -a       Run in automatic mode (non-interactive): install, or update"
            echo "                   the install that is there"
            echo "  --update         Update without questions"
            echo "  --reset-password Give the admin account a new password (ADMIN_PASSWORD, else"
            echo "                   a random one) and show it once"
            echo "  --reset-two-factor  With --reset-password, also turn off the admin's two-factor"
            echo "                   sign-in (lost authenticator and recovery codes)"
            echo "  --binary FILE    Install this neodesk-server binary instead of the release"
            echo "  --channel C      Release channel: 'stable' (default, the newest release) or"
            echo "                   'dev' (the development build); kept for later updates. Without"
            echo "                   it, a repository with no stable release yet installs 'dev'"
            echo "  --from-source    Build neodesk-server from this checkout (needs Go, and"
            echo "                   Node.js unless web-ui/build exists)"
            echo "  --uninstall      Stop and remove the service, after a backup; the data stays,"
            echo "                   and the end lists what is left on the machine"
            echo "  --purge          With --uninstall, also remove the data, keys and the commands"
            echo "                   neodesk-setup and neodesk; on a terminal it offers to remove"
            echo "                   the backups too"
            echo "  --check-permissions  Report panel/update/config/restart capabilities"
            echo "  --repair-permissions Repair NeoDesk ownership and service access"
            echo "  --set-config K=V Apply an allowlisted .env setting (repeatable)"
            echo "  --skip-verify    Skip the SHA-256 and signature checks of a downloaded binary"
            echo "  --minimal        Install the server with its web console off"
            echo "  --postgresql     Use PostgreSQL instead of SQLite"
            echo "  --pg-uri URI     PostgreSQL connection URI (implies --postgresql)"
            echo "  --relay-mode M   Relay IP selection: 'auto' (public, default), 'local' (LAN), 'public'"
            echo "  --relay-servers IP  Force a fixed relay server address (IP or host[:port])"
            echo "  --node           Make this machine a relay node of a site (neodesk-relay-node.service):"
            echo "                   the server binary in node mode, without database or console. A server"
            echo "                   install here stays as it is. Run again to update the node; with"
            echo "                   --uninstall it removes the node (--purge also its key)"
            echo "  --join STRING    The join string the console shows under Sites (first install only)"
            echo "  --lan-addr H:P   Where devices in the LAN dial the relay (default: this machine's"
            echo "                   LAN address, port 21117)"
            echo "  --public-addr H:P  Where devices outside the LAN dial it, through a port forward"
            echo "                   (default: none, only LAN devices use the node)"
            echo "  --help, -h       Show this help message"
            echo ""
            echo "Environment variables:"
            echo "  USE_POSTGRESQL=true     Use PostgreSQL"
            echo "  POSTGRESQL_URI=...      PostgreSQL connection URI"
            echo "  POSTGRESQL_USER=...     PostgreSQL username (default: neodesk)"
            echo "  POSTGRESQL_PASS=...     PostgreSQL password (auto-generated if empty)"
            echo "  POSTGRESQL_DB=...       PostgreSQL database (default: neodesk)"
            echo "  POSTGRESQL_HOST=...     PostgreSQL host (default: localhost)"
            echo "  POSTGRESQL_PORT=...     PostgreSQL port (default: 5432)"
            echo "  RELAY_MODE=auto|local|public  Relay IP selection mode (default: auto)"
            echo "  RELAY_SERVERS=...       Force a fixed relay server address (overrides RELAY_MODE)"
            echo "  STORE_ADMIN_CREDENTIALS=true  Persist admin password to .admin_credentials (not recommended)"
            echo "  ADMIN_PASSWORD=...      Set custom admin password (default: auto-generated)"
            echo "  UPDATE_GITHUB_BRANCH=main|dev  Update channel: stable (main) or development (dev)"
            echo "  UPDATE_GITHUB_OWNER=... / UPDATE_GITHUB_REPO=...  Repository the releases come from"
            echo "  RELEASE_BASE_URL=...    Folder URL with the release files (SHA256SUMS, manifest.json,"
            echo "                          manifest.sig, the binaries and neodesk.sh)"
            echo "  SSL_DOMAIN=...          Host name for the self-signed certificate and the console's address"
            echo "  RUSTDESK_PATH=... / CONSOLE_PATH=... / BACKUP_DIR=...  Install folders"
            echo "                          (default /opt/neodesk, /opt/NeoDeskConsole, /opt/neodesk-backups)"
            echo "  BACKUP_KEEP=5           How many of the installer's backups stay (0: all of them)"
            echo "  GO_API_PORT=21114 / CLIENT_API_PORT=21121  The server's own API port and the client API port"
            echo "  SIGNAL_RATE_LIMIT_PER_IP=20  Signal registrations per address and minute (0: no limit)"
            echo ""
            echo "Install with one command:  curl -fsSL https://neode.sk/neodesk.sh | sudo bash"
            echo "Later:                     sudo neodesk-setup (menu), sudo neodesk-setup --update, sudo neodesk-setup --uninstall"
            echo "The command line:          neodesk --help (sudo neodesk and these options reach neodesk-setup too)"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Go server source directory
GO_SERVER_SOURCE="$REPO_DIR/neodesk-server"

# Minimum Go version required for compilation (must match neodesk-server/go.mod).
GO_MIN_VERSION="1.26.11"
# Point release downloaded when system Go is missing/outdated (must exist on go.dev/dl).
GO_DOWNLOAD_VERSION="1.26.11"
# Maximum time allowed for the first module download on a native install.
GO_MODULE_DOWNLOAD_TIMEOUT="${GO_MODULE_DOWNLOAD_TIMEOUT:-600}"
# Maximum time allowed to validate the downloaded module graph.
GO_MODULE_GRAPH_TIMEOUT="${GO_MODULE_GRAPH_TIMEOUT:-120}"
# Maximum time allowed to compile the Go server.
GO_BUILD_TIMEOUT="${GO_BUILD_TIMEOUT:-1800}"
# Heartbeat/deadline settings for bounded Go commands.
GO_COMMAND_HEARTBEAT_INTERVAL="${GO_COMMAND_HEARTBEAT_INTERVAL:-15}"
GO_COMMAND_KILL_AFTER="${GO_COMMAND_KILL_AFTER:-15}"
# Short HTTPS probe before go mod download (fail fast on blocked proxy/DNS).
GO_MODULE_PREFLIGHT_TIMEOUT="${GO_MODULE_PREFLIGHT_TIMEOUT:-20}"
# Set when preflight detects IPv4 OK but IPv6 broken (common on GCP VMs).
GO_FORCE_IPV4=0
# Toolchain for native compile (override with NEODESK_GOTOOLCHAIN; default local).
NEODESK_GOTOOLCHAIN="${NEODESK_GOTOOLCHAIN:-local}"

# Default paths (can be overridden by environment variables)
RUSTDESK_PATH="${RUSTDESK_PATH:-}"
CONSOLE_PATH="${CONSOLE_PATH:-}"
CONSOLE_TYPE="none"  # none, go (the console in neodesk-server), nodejs (the old console)
# The installer's backups. Up to 3.6.0-rc.4 they went to /opt/rustdesk-backups;
# the next run as root moves them here (move_backup_folder). A BACKUP_DIR
# given to the installer is used as it is.
BACKUP_DIR_GIVEN="${BACKUP_DIR:-}"
BACKUP_DIR="${BACKUP_DIR:-/opt/neodesk-backups}"
OLD_BACKUP_DIR="/opt/rustdesk-backups"

# API: the server's own API on GO_API_PORT (21114). The web console inside the
# server listens on CONSOLE_PORT (3375), and on CLIENT_API_PORT (21121) for
# RustDesk clients when API_ENABLED is true.
GO_API_PORT="${GO_API_PORT:-21114}"
CLIENT_API_PORT="${CLIENT_API_PORT:-21121}"
API_PORT="${API_PORT:-$GO_API_PORT}"
STORE_ADMIN_CREDENTIALS="${STORE_ADMIN_CREDENTIALS:-false}"

# The one service. It runs as SERVICE_USER, so the binary lives in the
# server folder, which that user may write: the in-app updater replaces the
# binary by rename and keeps the old one as neodesk-server.prev.
SERVER_SERVICE="neodesk-server"
SERVER_UNIT="/etc/systemd/system/neodesk-server.service"
SERVICE_USER="neodesk"
# The unit of the old Node.js console. An install that still runs it is
# not upgraded (refuse_node_era_install).
LEGACY_CONSOLE_SERVICE="neodesk-console"
LEGACY_CONSOLE_UNIT="/etc/systemd/system/neodesk-console.service"

# Database configuration
USE_POSTGRESQL="${USE_POSTGRESQL:-false}"  # true = PostgreSQL, false = SQLite
POSTGRESQL_URI="${POSTGRESQL_URI:-}"       # postgres://user:pass@host:5432/dbname
POSTGRESQL_DB_CREATED=false                # this run created the (empty) database
POSTGRESQL_USER="${POSTGRESQL_USER:-neodesk}"
POSTGRESQL_PASS="${POSTGRESQL_PASS:-}"
POSTGRESQL_DB="${POSTGRESQL_DB:-neodesk}"
POSTGRESQL_HOST="${POSTGRESQL_HOST:-localhost}"
POSTGRESQL_PORT="${POSTGRESQL_PORT:-5432}"

# Common installation paths to search
COMMON_RUSTDESK_PATHS=(
    "/opt/neodesk"
    "/opt/rustdesk"
    "/usr/local/rustdesk"
    "/var/lib/rustdesk"
    "/home/rustdesk"
    "$HOME/rustdesk"
)

COMMON_CONSOLE_PATHS=(
    "/opt/NeoDeskConsole"
    "/opt/neodesk"
    "/var/lib/neodesk"
    "$HOME/NeoDeskConsole"
)

# Colours: 24-bit where the terminal says it has them (COLORTERM), else the
# 16 basic ones; none when the output is not a terminal, NO_COLOR is set or
# TERM is dumb (COLOR_DEPTH 24bit, 16 or empty). In 24-bit, RED, GREEN,
# YELLOW and CYAN keep at least 3.8:1 on black, on PowerShell's blue and on
# white. WHITE is bold in the terminal's own text colour.
COLOR_DEPTH=""
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-}" != dumb ]; then
    case "${COLORTERM:-}" in
        truecolor|24bit) COLOR_DEPTH=24bit ;;
        *) COLOR_DEPTH=16 ;;
    esac
fi
case "$COLOR_DEPTH" in
    24bit)
        RED='\033[38;2;228;75;69m'
        GREEN='\033[38;2;37;149;46m'
        YELLOW='\033[38;2;178;116;9m'
        CYAN='\033[38;2;26;143;147m'
        ;;
    16)
        RED='\033[0;31m'
        GREEN='\033[0;32m'
        YELLOW='\033[0;33m'
        CYAN='\033[0;36m'
        ;;
    *)
        RED='' GREEN='' YELLOW='' CYAN=''
        ;;
esac
if [ -n "$COLOR_DEPTH" ]; then
    WHITE='\033[1m'
    NC='\033[0m' # No Color
    BOLD='\033[1m'
    DIM='\033[2m'
else
    WHITE='' NC='' BOLD='' DIM=''
fi

# Logging
LOG_FILE="/tmp/neodesk_$(date +%Y%m%d_%H%M%S).log"

#===============================================================================
# Helper Functions
#===============================================================================

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

# The NeoDesk logo, drawn in half blocks: 15 lines with colour tokens
# {N}; ND_LOGO_24[N] and ND_LOGO_16[N] are the token's codes in 24-bit
# and in the 16 colours.
ND_LOGO_LINES=(
    '             {0}▄▄███████▄▄'
    '           {0}▄█████████████▄'
    '         {0}▄█████████████████▄'
    '        {0}▄███████████████████▄                                                  {1}▄▄▄                          ▄▄▄'
    '  {2}▄▄████{3}█████████{4}▀▀{0}██████████                                                  {1}███                          ███'
    ' {2}███████{3}████████████{0}█████████    {1}▄▄▄▄▄ ▄▄▄▄▄     ▄▄▄▄▄▄▄     ▄▄▄▄▄▄▄     ▄▄▄▄▄▄███     ▄▄▄▄▄▄▄    ▄▄▄▄▄▄▄▄  ███    ▄▄▄▄'
    '{2}████████{3}█████████████{0}████████    {1}██████▀▀▀███▄ ▄███▀▀▀███▄ ▄███▀▀▀███▄ ▄███▀▀▀████   ▄███▀▀▀███▄ ███▀▀▀▀███ ███  ▄███▀'
    '{2}█████████{3}████████████{0}███████       {1}███     ███ ███▄▄▄▄▄███ ███     ███ ███     ███   ███▄▄▄▄▄███ ███▄▄▄▄▄▄  ███▄███▀'
    '{2}██████████{5}▀{3}██████████{0}█████▀        {1}███     ███ ███▀▀▀▀▀▀▀▀ ███     ███ ███     ███   ███▀▀▀▀▀▀▀▀ ▀█████████ ███▀▀███▄'
    '{2}████████████{5}▀{3}████████{0}███▀          {1}███     ███ ███▄   ▄▄▄▄ ███▄   ▄███ ███▄   ▄███▄▄ ███▄   ▄▄▄▄ ▄▄▄    ███ ███  ▀███▄'
    '{2}███████████████{5}▀▀▀▀▀▀{0}▀             {1}███     ███  ▀███████▀   ▀███████▀   ▀█████▀█████  ▀███████▀  ▀████████▀ ███   ▀███▄'
    '{2}█████████████████████'
    '{2}▀███████████████████▀'
    ' {2}▀█████████████████▀'
    '    {2}▀▀▀▀▀▀▀▀▀▀▀▀▀'
)
ND_LOGO_24=('38;2;163;230;53' '38;2;228;231;231' '38;2;88;166;255' '38;2;63;208;196' '38;2;163;230;53;48;2;63;208;196' '38;2;63;208;196;48;2;88;166;255')
ND_LOGO_16=('92' '39' '96' '36' '92;46' '36;106')

# draw_logo TITLE: the NeoDesk logo, with TITLE beside the mark on the
# second line under the wordmark, starting under the foot of the n. A
# terminal narrower than the logo gets the name and TITLE on one line.
draw_logo() {
    local cols=${COLUMNS:-} codes line i n
    [ -n "$cols" ] || cols=$(tput cols 2>/dev/null) || cols=''
    case $cols in '' | *[!0-9]* | 0) cols=80 ;; esac
    if [ "$cols" -lt 119 ]; then
        printf '\033[1mNeoDesk\033[0m %s\n' "$1"
        return 0
    fi
    if [ "$COLOR_DEPTH" = 24bit ]; then codes=("${ND_LOGO_24[@]}"); else codes=("${ND_LOGO_16[@]}"); fi
    for ((i = 0; i < ${#ND_LOGO_LINES[@]}; i++)); do
        line=${ND_LOGO_LINES[i]}
        for ((n = 0; n < ${#codes[@]}; n++)); do
            line=${line//"{$n}"/$'\033[0m\033['"${codes[n]}m"}
        done
        line+=$'\033[0m'
        if [ "$i" = 12 ]; then line+="              $1"; fi
        printf '%s\n' "$line"
    done
}

# print_header: clears the terminal and shows the NeoDesk logo with
# what this script is and its version. Without colour (no
# terminal, NO_COLOR) it is one plain line.
print_header() {
    local title="Server installer ${VERSION}"
    if [ -z "$COLOR_DEPTH" ]; then
        printf 'NeoDesk %s\n' "$title"
        return 0
    fi
    # Without TERM, clear fails; the run goes on
    clear 2>/dev/null || true
    printf '\n'
    draw_logo "$title"
    printf '\n'
}

print_success() { echo -e "${GREEN}✓${NC} $1"; log "SUCCESS: $1"; }
print_error() { echo -e "${RED}✗${NC} $1"; log "ERROR: $1"; }
print_warning() { echo -e "${YELLOW}!${NC} $1"; log "WARNING: $1"; }
print_info() { echo -e "${CYAN}i${NC} $1"; log "INFO: $1"; }
print_step() { echo -e "${BOLD}▶${NC} $1"; log "STEP: $1"; }

#===============================================================================
# Management capabilities and allowlisted runtime configuration
#===============================================================================

# The server binary of this install.
server_binary_path() {
    printf '%s\n' "$RUSTDESK_PATH/neodesk-server"
}

# True when the installed binary carries the commands of the release with
# the console inside (upgrade-env, env merge, config, reset-password, check,
# update). Read from the file: an older binary would take an unknown
# command for its own arguments and start a server.
binary_has_subcommands() {
    local bin="${1:-$(server_binary_path)}"
    [ -x "$bin" ] && grep -a -q -F 'upgrade-env --from FILE' "$bin" 2>/dev/null
}

# run_as_service_user CMD...: runs a command as the service account, with the
# rights the running server has.
run_as_service_user() {
    if [ "$(id -u)" -ne 0 ] || ! id "$SERVICE_USER" &>/dev/null; then
        "$@"
    elif command -v runuser &>/dev/null; then
        runuser -u "$SERVICE_USER" -- "$@"
    else
        setpriv --reuid="$SERVICE_USER" --regid="$SERVICE_USER" --init-groups -- "$@"
    fi
}

# server_cmd [--as-service] COMMAND ARGS...: a command of the installed
# binary with the console's env file. --as-service runs it as the service
# account.
server_cmd() {
    local as_service=false
    if [ "${1:-}" = "--as-service" ]; then
        as_service=true
        shift
    fi
    local bin
    bin="$(server_binary_path)"
    if ! binary_has_subcommands "$bin"; then
        print_error "$bin is not a release with the console inside; update first"
        return 1
    fi
    if [ "$as_service" = true ]; then
        run_as_service_user env NEODESK_ENV_FILE="$CONSOLE_PATH/.env" NEODESK_CONSOLE_PATH="$CONSOLE_PATH" \
            NEODESK_PATH="$RUSTDESK_PATH" "$bin" "$@"
    else
        NEODESK_ENV_FILE="$CONSOLE_PATH/.env" NEODESK_CONSOLE_PATH="$CONSOLE_PATH" \
            NEODESK_PATH="$RUSTDESK_PATH" "$bin" "$@"
    fi
}

check_management_capabilities() {
    if ! binary_has_subcommands; then
        print_error "Management capability check needs an installed neodesk-server"
        return 1
    fi
    print_step "Checking NeoDesk management capabilities..."
    server_cmd --as-service config check || {
        print_warning "One or more management capabilities are blocked; see the report above"
        return 1
    }
    print_success "NeoDesk management capabilities are ready"
}

repair_management_permissions() {
    print_step "Repairing NeoDesk management permissions..."
    ensure_service_user || true
    if [ -d "$CONSOLE_PATH" ]; then
        own_by_service_user "$CONSOLE_PATH"
        chmod 700 "$CONSOLE_PATH/data" 2>/dev/null || true
        chmod 600 "$CONSOLE_PATH/.env" 2>/dev/null || true
    fi
    if [ -d "$RUSTDESK_PATH" ]; then
        set_server_folder_permissions
    fi
    systemctl daemon-reload 2>/dev/null || true
    check_management_capabilities || true
}

# apply_managed_config: the KEY=VALUE pairs of MANAGED_CONFIG_CHANGES go
# into .env through the server's allowlist (config set). The run names the
# keys it set and restarts the server once; when .env is the same as
# before it keeps running. The server's report goes to the log, and on a
# refusal to the screen.
apply_managed_config() {
    if [ "${#MANAGED_CONFIG_CHANGES[@]}" -eq 0 ]; then
        print_error "No allowlisted configuration changes supplied"
        return 1
    fi
    local out changed env_before
    env_before=$(sha256sum "$CONSOLE_PATH/.env" 2>/dev/null | awk '{ print $1 }')
    if ! out=$(server_cmd --as-service config set "${MANAGED_CONFIG_CHANGES[@]}" 2>&1); then
        printf '%s\n' "$out"
        print_error "The settings were not changed"
        return 1
    fi
    log "neodesk-server config set: $out"
    # The keys of the "changed" list in the report
    changed=$(printf '%s\n' "$out" | awk '
        /"changed": \[\]/ { exit }
        /"changed": \[/ { inside = 1; next }
        inside && /\]/ { exit }
        inside { gsub(/[",[:space:]]/, ""); if ($0 != "") printf "%s%s", sep, $0; sep = ", " }')
    if [ -z "$changed" ] || [ "$env_before" = "$(sha256sum "$CONSOLE_PATH/.env" 2>/dev/null | awk '{ print $1 }')" ]; then
        print_success "Nothing changed: $CONSOLE_PATH/.env has these values already"
        return 0
    fi
    print_success "Changed in $CONSOLE_PATH/.env: $changed"
    systemctl daemon-reload 2>/dev/null || true
    start_services_with_verification
}

configure_management() {
    print_header
    echo -e "${WHITE}${BOLD}══════════ MANAGEMENT CAPABILITIES ══════════${NC}"
    echo ""
    check_management_capabilities || true
    echo ""
    local _menu_items=(
        $'Repair permissions\tRepair console user, data paths, TLS and broker'
        $'Change .env settings\tApply allowlisted KEY=VALUE pairs and restart'
        $'Recheck capabilities\tRun the read-only capability report again'
        $'Back\tReturn to the main menu'
    )
    local _menu_returns=( 1 2 3 0 )
    menu_choose "NeoDesk Management" "Only allowlisted NeoDesk operations are available"
    case "${MENU_CHOICE:-0}" in
        1)
            repair_management_permissions
            press_enter
            ;;
        2)
            MANAGED_CONFIG_CHANGES=()
            while true; do
                echo -ne "Enter KEY=VALUE (empty to apply): "
                local item
                read -r item
                [ -z "$item" ] && break
                if [[ "$item" != *=* ]]; then
                    print_warning "Use KEY=VALUE"
                else
                    MANAGED_CONFIG_CHANGES+=("$item")
                fi
            done
            apply_managed_config || print_error "Configuration change failed"
            press_enter
            ;;
        3)
            check_management_capabilities || true
            press_enter
            ;;
        *) return ;;
    esac
}

# has_terminal: standard input is a terminal, so a question gets an answer.
has_terminal() { [ -t 0 ]; }

# Without a terminal (piped from curl, cron, CI) nothing waits for a key,
# and a question without an answer (end of input) takes its default.
press_enter() {
    [ -t 0 ] || return 0
    echo ""
    echo -e "${CYAN}Press Enter to continue...${NC}"
    read -r || true
}

confirm() {
    local prompt="${1:-Continue?}"
    echo -e "${YELLOW}${prompt} [y/N]${NC} "
    read -r response || return 1
    [[ "$response" =~ ^[TtYy]$ ]]
}

# default_to_auto_without_terminal: a run without a terminal installs or
# updates without questions, as --auto does.
default_to_auto_without_terminal() {
    if [ "$AUTO_MODE" != true ] && [ ! -t 0 ]; then
        AUTO_MODE=true
        print_info "No terminal: installing or updating without questions (--auto)"
    fi
}

# installer_release_base: the folder of the release neodesk-setup comes
# from: RELEASE_BASE_URL, else the one this run downloaded the binary from,
# else the release of the installed binary's version, or the "dev"
# release on the development channel.
installer_release_base() {
    if [ -n "${RELEASE_BASE_URL:-}" ]; then
        printf '%s\n' "${RELEASE_BASE_URL%/}"
        return 0
    fi
    if [ -n "${RELEASE_FOLDER_USED:-}" ]; then
        printf '%s\n' "$RELEASE_FOLDER_USED"
        return 0
    fi
    local releases="https://github.com/${UPDATE_GITHUB_OWNER}/${UPDATE_GITHUB_REPO}/releases/download" version
    read_update_github_branch_from_env
    if [ "$UPDATE_GITHUB_BRANCH" = dev ]; then
        printf '%s\n' "$releases/dev"
        return 0
    fi
    version=$(timeout 10 "$(server_binary_path)" -version 2>/dev/null | awk 'NR == 1 { print $2 }')
    [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$ ]] || return 1
    printf '%s\n' "$releases/v$version"
}

# verify_release_list DIR NAME: DIR/NAME is the file of that name the
# release's SHA256SUMS (DIR/SHA256SUMS) lists, and the list's signature
# (DIR/SHA256SUMS.sig) verifies: by the installed neodesk-server when it
# can (verify-release --sums), else by openssl with RELEASE_PUBLIC_KEY_PEM.
# Returns 0 when checked, 1 when refused, 2 when this machine cannot check
# an ed25519 signature.
verify_release_list() {
    local dir="$1" name="$2" installed work rc=0
    installed=$(server_binary_path)
    if [ -x "$installed" ] && grep -a -q -F 'verify-release --sums FILE' "$installed" 2>/dev/null; then
        "$installed" verify-release --sums "$dir/SHA256SUMS" --signature "$dir/SHA256SUMS.sig" \
            --name "$name" "$dir/$name" >/dev/null 2>&1 || return 1
        return 0
    fi
    [ -s "$dir/SHA256SUMS.sig" ] || return 1
    ensure_openssl || return 2
    openssl pkeyutl -help 2>&1 | grep -q -- '-rawin' || return 2
    work=$(mktemp -d) || return 1
    printf '%s\n' "$RELEASE_PUBLIC_KEY_PEM" > "$work/key.pem"
    { printf 'neodesk-release-files-v1\n'; cat "$dir/SHA256SUMS"; } > "$work/payload"
    if ! tr -d '[:space:]' < "$dir/SHA256SUMS.sig" | base64 -d > "$work/sig" 2>/dev/null \
        || ! openssl pkeyutl -verify -pubin -inkey "$work/key.pem" -rawin -in "$work/payload" -sigfile "$work/sig" >/dev/null 2>&1; then
        rc=1
    fi
    rm -rf -- "${work:?}"
    return "$rc"
}

# fetch_release_installer DEST: neodesk.sh of the release
# (installer_release_base) into DEST, when the release's SHA256SUMS names
# it and the list's signature verifies (verify_release_list; with
# --skip-verify its SHA-256 only). Returns 1 when the release has no
# neodesk.sh (3.6.0-rc.4 and older), 2 when a check refused it.
fetch_release_installer() {
    local dest="$1" base work code expected rc=0
    base=$(installer_release_base) || return 1
    work=$(mktemp -d) || return 1
    code=$(fetch_release_file "$base" SHA256SUMS "$work/SHA256SUMS")
    expected=""
    [ "$code" = 200 ] && expected=$(awk '$2 == "neodesk.sh" || $2 == "*neodesk.sh" { print tolower($1); exit }' "$work/SHA256SUMS")
    if [ -z "$expected" ] || [ "$(fetch_release_file "$base" neodesk.sh "$work/neodesk.sh")" != 200 ]; then
        rm -rf -- "${work:?}"
        return 1
    fi
    [ "$(fetch_release_file "$base" SHA256SUMS.sig "$work/SHA256SUMS.sig")" = 200 ] || rm -f -- "$work/SHA256SUMS.sig"
    if [ "$(sha256sum "$work/neodesk.sh" | awk '{ print $1 }')" != "$expected" ] || ! grep -q '^NEODESK_SH_REVISION=' "$work/neodesk.sh"; then
        rc=2
    elif [ "$SKIP_VERIFY" = true ]; then
        print_warning "The signature of the release's neodesk.sh is not checked (--skip-verify)"
    else
        verify_release_list "$work" neodesk.sh || rc=$?
        if [ "$rc" = 2 ]; then
            print_warning "The signature of the release's neodesk.sh cannot be checked here (no OpenSSL 3), only its SHA-256"
            rc=0
        elif [ "$rc" != 0 ]; then
            rc=2
        fi
    fi
    [ "$rc" = 0 ] && cp "$work/neodesk.sh" "$dest"
    rm -rf -- "${work:?}"
    return "$rc"
}

# install_manager_command: this installer as the command neodesk-setup,
# for updates, repairs and the uninstall later, and neodesk as the command
# line (place_manager_commands). Run from a file that is not the installed
# copy (a download, a checkout), it takes itself. Run as neodesk-setup (an
# update) or piped from curl, it takes neodesk.sh of the release it
# installs (fetch_release_installer), and keeps itself when that release
# has none or it does not pass the check.
install_manager_command() {
    local self="$NEODESK_SELF" tmp real rc=0 got=0
    tmp=$(mktemp) || return 0
    real=$(readlink -f "$self" 2>/dev/null || true)
    if [ -n "$self" ] && [ -f "$self" ] && [ "$real" != "$(readlink -f "$MANAGER_COMMAND" 2>/dev/null)" ] \
        && [ "$real" != "$(readlink -f "$OLD_MANAGER_COMMAND" 2>/dev/null)" ]; then
        cp "$self" "$tmp"
    else
        fetch_release_installer "$tmp" || got=$?
    fi
    if [ "$got" != 0 ]; then
        if [ "$got" = 2 ]; then
            print_warning "The release's neodesk.sh did not pass its check, so $(basename "$MANAGER_COMMAND") stays as it is"
        fi
        if [ -n "$self" ] && [ -f "$self" ]; then
            cp "$self" "$tmp"
        else
            rm -f "$tmp"
            [ -x "$MANAGER_COMMAND" ] || print_warning "Could not save the neodesk-setup command; run this installer again for updates"
            return 0
        fi
    fi
    place_manager_commands "$tmp" "$(server_binary_path)" || rc=$?
    rm -f "$tmp"
    case "$rc" in
        0) print_info "Manage this install with: sudo $(basename "$MANAGER_COMMAND"); the command line: neodesk --help" ;;
        2) print_info "Manage this install with: sudo $(basename "$MANAGER_COMMAND") (the command line neodesk comes with the next server update)" ;;
        3) print_warning "$CLI_COMMAND is another program, so it stays; the command line is $(server_binary_path) cli" ;;
        4) print_warning "Could not copy the server binary to $CLI_COMMAND; the command line is $(server_binary_path) cli (as root)" ;;
        *) print_warning "Could not save the neodesk-setup command; run this installer again for updates" ;;
    esac
    return 0
}

#===============================================================================
# Interactive TUI (arrow-key navigable menu) — pure bash, no dependencies
#===============================================================================
# Result of tui_select() is returned in the global TUI_RESULT.
# Returns 0 on selection, 1 when TUI is unavailable (caller falls back to text).
TUI_RESULT=""

# Detect whether the modern arrow-key interface can be used.
tui_available() {
    [ "${NEODESK_CLASSIC_MENU:-0}" = "1" ] && return 1
    [ -t 0 ] && [ -t 1 ] || return 1
    return 0
}

# Cleanup helper: always restore the cursor when leaving the TUI.
_tui_restore() { printf '\033[?25h' 2>/dev/null; stty echo 2>/dev/null; }

# tui_select "Title" "Subtitle" item1 item2 ...
# Each item may embed a description after a literal $'\t' (tab).
# Navigation: ↑/↓ or k/j to move, Enter/→ to choose, q/Esc/0 to cancel.
tui_select() {
    local title="$1"; shift
    local subtitle="$1"; shift
    local items=("$@")
    local count=${#items[@]}
    local sel=0 key rest

    if ! tui_available || [ "$count" -eq 0 ]; then
        TUI_RESULT=""
        return 1
    fi

    printf '\033[?25l'                       # hide cursor
    trap '_tui_restore' INT TERM

    clear
    while true; do
        # Build the whole frame in a single buffer, then emit it with one
        # write. Terminals (notably the VS Code integrated terminal with GPU
        # acceleration) drop individual glyphs when a full-screen TUI is redrawn
        # via many separate printf calls after each keypress. One write avoids it.
        local buf=""
        buf+="\033[H"   # move cursor home instead of clearing (less flicker)
        buf+="${CYAN}${BOLD}+--------------------------------------------------------------+${NC}\033[K\n"
        buf+="$(printf "${CYAN}${BOLD}|${NC} ${WHITE}${BOLD}%-60s${NC} ${CYAN}${BOLD}|${NC}" "$title")\033[K\n"
        if [ -n "$subtitle" ]; then
            buf+="$(printf "${CYAN}${BOLD}|${NC} ${DIM}%-60s${NC} ${CYAN}${BOLD}|${NC}" "$subtitle")\033[K\n"
        fi
        buf+="${CYAN}${BOLD}+--------------------------------------------------------------+${NC}\033[K\n"
        buf+="\033[K\n"

        local i label desc pad line
        for i in "${!items[@]}"; do
            label="${items[$i]%%$'\t'*}"
            desc=""
            [[ "${items[$i]}" == *$'\t'* ]] && desc="${items[$i]#*$'\t'}"
            # Manual padding by character count keeps columns aligned reliably.
            pad=$(( 32 - ${#label} ))
            [ "$pad" -lt 1 ] && pad=1
            if [ "$i" -eq "$sel" ]; then
                line="$(printf "  ${GREEN}${BOLD}>${NC} ${GREEN}${BOLD}%s${NC}%*s${DIM}%s${NC}" "$label" "$pad" "" "$desc")"
            else
                line="$(printf "    ${WHITE}%s${NC}%*s${DIM}%s${NC}" "$label" "$pad" "" "$desc")"
            fi
            buf+="${line}\033[K\n"
        done

        buf+="\033[K\n"
        buf+="  ${DIM}Up/Down navigate   Enter select   q/Esc back${NC}\033[K\n"
        buf+="\033[J"   # clear anything below the menu

        printf '%b' "$buf"

        # Read a single keypress (with escape-sequence handling)
        IFS= read -rsn1 key 2>/dev/null
        if [[ "$key" == $'\033' ]]; then
            read -rsn2 -t 0.05 rest 2>/dev/null
            key+="$rest"
        fi

        case "$key" in
            $'\033[A'|'k') sel=$(( (sel - 1 + count) % count )) ;;
            $'\033[B'|'j') sel=$(( (sel + 1) % count )) ;;
            ''|$'\033[C') TUI_RESULT="$sel"; _tui_restore; trap - INT TERM; return 0 ;;  # Enter / →
            'q'|'Q'|'0'|$'\033') TUI_RESULT=""; _tui_restore; trap - INT TERM; return 2 ;;
            [1-9])
                # Numeric shortcut jumps straight to that 1-based entry
                local idx=$(( key - 1 ))
                if [ "$idx" -lt "$count" ]; then
                    TUI_RESULT="$idx"; _tui_restore; trap - INT TERM; return 0
                fi
                ;;
        esac
    done
}

#===============================================================================
# Modern UI helpers shared by every sub-menu
#===============================================================================
# ui_panel_header "Title" "Subtitle"
# Draws a clean ASCII box header (single buffered write to avoid glyph drops).
ui_panel_header() {
    local title="$1" subtitle="$2"
    clear 2>/dev/null || true
    local buf=""
    buf+="${CYAN}${BOLD}+--------------------------------------------------------------+${NC}\n"
    buf+="$(printf "${CYAN}${BOLD}|${NC} ${WHITE}${BOLD}%-60s${NC} ${CYAN}${BOLD}|${NC}" "$title")\n"
    if [ -n "$subtitle" ]; then
        buf+="$(printf "${CYAN}${BOLD}|${NC} ${DIM}%-60s${NC} ${CYAN}${BOLD}|${NC}" "$subtitle")\n"
    fi
    buf+="${CYAN}${BOLD}+--------------------------------------------------------------+${NC}\n"
    printf '%b' "$buf"
    echo ""
}

# ui_section "Title"  — a lightweight section divider for output screens.
ui_section() {
    echo ""
    echo -e "  ${CYAN}${BOLD}== $1 ==${NC}"
    echo ""
}

# menu_choose "Title" "Subtitle"
# Caller must pre-populate two parallel arrays:
#   _menu_items=( "Label\tDescription" ... )   # what the user sees
#   _menu_returns=( "1" "2" ... "0" )          # value returned for each entry
# The chosen value is stored in MENU_CHOICE. On cancel (q/Esc) the LAST entry's
# value is returned (by convention the final item is "Back"/"Exit").
# Uses the arrow-key TUI when available, otherwise a styled numeric menu.
MENU_CHOICE=""
menu_choose() {
    local title="$1" subtitle="$2"
    MENU_CHOICE=""
    local last_idx=$(( ${#_menu_returns[@]} - 1 ))
    [ "$last_idx" -lt 0 ] && last_idx=0

    if tui_available; then
        tui_select "$title" "$subtitle" "${_menu_items[@]}"
        local rc=$?
        if [ "$rc" -eq 0 ] && [ -n "$TUI_RESULT" ]; then
            MENU_CHOICE="${_menu_returns[$TUI_RESULT]}"
        else
            MENU_CHOICE="${_menu_returns[$last_idx]}"
        fi
        return 0
    fi

    # Styled numeric fallback (no TTY / classic mode)
    ui_panel_header "$title" "$subtitle"
    local i label desc
    for i in "${!_menu_items[@]}"; do
        label="${_menu_items[$i]%%$'\t'*}"
        desc=""
        [[ "${_menu_items[$i]}" == *$'\t'* ]] && desc="${_menu_items[$i]#*$'\t'}"
        printf "  ${GREEN}${BOLD}%2s${NC}) ${WHITE}%-28s${NC} ${DIM}%s${NC}\n" \
            "${_menu_returns[$i]}" "$label" "$desc"
    done
    echo ""
    echo -ne "  ${CYAN}Select option:${NC} "
    read -r MENU_CHOICE
}

get_public_ip() {
    local ip
    ip=$(curl -4 -s --max-time 5 ifconfig.me 2>/dev/null) && [ -n "$ip" ] && echo "$ip" && return
    ip=$(curl -4 -s --max-time 5 icanhazip.com 2>/dev/null) && [ -n "$ip" ] && echo "$ip" && return
    ip=$(curl -s --max-time 5 ifconfig.me 2>/dev/null) && [ -n "$ip" ] && echo "$ip" && return
    ip=$(curl -s --max-time 5 icanhazip.com 2>/dev/null) && [ -n "$ip" ] && echo "$ip" && return
    echo "127.0.0.1"
}

# Detect the server's primary LAN/private IPv4 address.
# Used for LAN-only deployments where the public IP is unreachable by clients.
get_local_ip() {
    local ip
    # Primary: source address used to reach the default gateway
    ip=$(ip -4 route get 1.1.1.1 2>/dev/null | grep -oP 'src \K[0-9.]+' | head -1)
    [ -n "$ip" ] && echo "$ip" && return
    # Fallback: first non-loopback global-scope address
    ip=$(ip -4 addr show scope global 2>/dev/null | grep -oP 'inet \K[0-9.]+' | head -1)
    [ -n "$ip" ] && echo "$ip" && return
    # Last resort: hostname resolution
    ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    [ -n "$ip" ] && echo "$ip" && return
    echo "127.0.0.1"
}

# ask_connection_mode: in an interactive run, asks once whether sessions
# try a direct connection first or always go through the relay.
ask_connection_mode() {
    CONNECTION_MODE="${CONNECTION_MODE:-p2p_first}"
    [ "$AUTO_MODE" = false ] && [ -z "${CONNECTION_MODE_SET:-}" ] || return 0
    echo ""
    print_info "Connection strategy: P2P hole punch vs relay-only routing."
    echo -e "  ${CYAN}1)${NC} P2P first (recommended) — try direct connection, fall back to relay"
    echo -e "  ${CYAN}2)${NC} Relay only — route all sessions through the relay server"
    echo -ne "  ${CYAN}Select connection mode [1]:${NC} "
    read -r _conn_choice
    case "$_conn_choice" in
        2) CONNECTION_MODE="relay_only" ;;
        *) CONNECTION_MODE="p2p_first" ;;
    esac
    CONNECTION_MODE_SET=1
    echo ""
}

# Resolve P2P/relay connection strategy env vars for systemd/NSSM.
resolve_connection_mode_env() {
    ask_connection_mode

    P2P_FALLBACK_MS="${P2P_FALLBACK_MS:-2000}"
    SAME_NAT_RELAY="${SAME_NAT_RELAY:-Y}"

    case "$CONNECTION_MODE" in
        relay_only)
            P2P_FIRST_ENV=N
            ALWAYS_USE_RELAY_ENV=Y
            ;;
        *)
            P2P_FIRST_ENV=Y
            ALWAYS_USE_RELAY_ENV=N
            ;;
    esac

    CONNECTION_MODE_ENV_BLOCK="Environment=P2P_FIRST=$P2P_FIRST_ENV
Environment=ALWAYS_USE_RELAY=$ALWAYS_USE_RELAY_ENV
Environment=P2P_FALLBACK_MS=$P2P_FALLBACK_MS
Environment=SAME_NAT_RELAY=$SAME_NAT_RELAY"
    print_info "Connection mode: ${CONNECTION_MODE} (P2P_FIRST=$P2P_FIRST_ENV, ALWAYS_USE_RELAY=$ALWAYS_USE_RELAY_ENV)"
}

# Resolve the relay server address according to RELAY_MODE / RELAY_SERVERS.
# Prints the resolved address to stdout; warnings/info go to stderr so the
# captured value (server_ip=$(resolve_relay_ip)) stays clean.
resolve_relay_ip() {
    # Explicit override always wins
    if [ -n "$RELAY_SERVERS" ]; then
        echo "Using fixed relay address (RELAY_SERVERS): $RELAY_SERVERS" >&2
        echo "$RELAY_SERVERS"
        return
    fi

    local ip
    case "${RELAY_MODE:-auto}" in
        local|lan)
            ip=$(get_local_ip)
            echo "Relay mode 'local': using LAN IP $ip (LAN-only deployment)" >&2
            ;;
        public|wan)
            ip=$(get_public_ip)
            echo "Relay mode 'public': using public IP $ip" >&2
            ;;
        auto|*)
            ip=$(get_public_ip)
            # Warn if auto-detection returned a private/loopback address — relay
            # will not work for remote clients unless this is a LAN-only setup.
            if [ "$ip" = "127.0.0.1" ] || [[ "$ip" == 10.* ]] || [[ "$ip" == 192.168.* ]] || [[ "$ip" == 172.1[6-9].* ]] || [[ "$ip" == 172.2[0-9].* ]] || [[ "$ip" == 172.3[0-1].* ]]; then
                echo "WARNING: Auto-detected private/loopback IP: $ip" >&2
                echo "WARNING: Remote (internet) clients will NOT connect via relay with this address." >&2
                echo "         For LAN-only use, this is fine. For internet access, run with:" >&2
                echo "           --relay-servers YOUR.PUBLIC.IP   (or RELAY_SERVERS env var)" >&2
                echo "         To silence this and use the LAN IP explicitly, run with:" >&2
                echo "           --relay-mode local" >&2
            fi
            ;;
    esac
    echo "$ip"
}

sql_escape_literal() {
    # Escape single quotes for SQL string literals: ' -> ''
    local value="$1"
    printf "%s" "${value//\'/\'\'}"
}

is_valid_pg_identifier() {
    # PostgreSQL unquoted identifier compatible pattern.
    # Keeps installation scripts safe from SQL injection in CREATE/ALTER statements.
    local ident="$1"
    [[ "$ident" =~ ^[A-Za-z_][A-Za-z0-9_]{0,62}$ ]]
}

is_local_postgresql_host() {
    case "${POSTGRESQL_HOST,,}" in
        localhost|127.0.0.1|::1)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

postgresql_hba_file_path() {
    local hba_file
    hba_file=$(sudo -u postgres psql -v ON_ERROR_STOP=1 -Atqc "SHOW hba_file;" 2>/dev/null) || return 1
    hba_file="${hba_file//$'\r'/}"
    [ -n "$hba_file" ] || return 1
    printf '%s\n' "$hba_file"
}

ensure_postgresql_local_hba_rules() {
    if ! is_local_postgresql_host; then
        print_info "PostgreSQL host '$POSTGRESQL_HOST' is remote; leaving pg_hba.conf unchanged"
        return 0
    fi

    local hba_file
    if ! hba_file=$(postgresql_hba_file_path); then
        print_error "Could not determine PostgreSQL pg_hba.conf path"
        return 1
    fi
    if [ ! -f "$hba_file" ]; then
        print_error "PostgreSQL pg_hba.conf was not found at: $hba_file"
        return 1
    fi

    local rule_ipv4="host    $POSTGRESQL_DB    $POSTGRESQL_USER    127.0.0.1/32    scram-sha-256"
    local rule_ipv6="host    $POSTGRESQL_DB    $POSTGRESQL_USER    ::1/128         scram-sha-256"
    local has_ipv4=false
    local has_ipv6=false

    if awk -v db="$POSTGRESQL_DB" -v user="$POSTGRESQL_USER" '
        $1 !~ /^#/ && $1 == "host" && $2 == db && $3 == user &&
        $4 == "127.0.0.1/32" && $5 == "scram-sha-256" { found=1 }
        END { exit !found }
    ' "$hba_file"; then
        has_ipv4=true
    fi
    if awk -v db="$POSTGRESQL_DB" -v user="$POSTGRESQL_USER" '
        $1 !~ /^#/ && $1 == "host" && $2 == db && $3 == user &&
        $4 == "::1/128" && $5 == "scram-sha-256" { found=1 }
        END { exit !found }
    ' "$hba_file"; then
        has_ipv6=true
    fi

    if [ "$has_ipv4" = true ] && [ "$has_ipv6" = true ]; then
        print_info "PostgreSQL localhost authentication rules already configured"
        return 0
    fi

    local backup_file="${hba_file}.neodesk-backup-$(date +%Y%m%d%H%M%S)"
    if ! sudo cp -p "$hba_file" "$backup_file" || ! sudo chmod 600 "$backup_file"; then
        print_error "Could not back up PostgreSQL pg_hba.conf before editing"
        return 1
    fi

    local temp_file
    if ! temp_file=$(mktemp "${TMPDIR:-/tmp}/neodesk-pg-hba.XXXXXX"); then
        print_error "Could not create a temporary PostgreSQL pg_hba.conf"
        return 1
    fi

    local add_ipv4=0
    local add_ipv6=0
    [ "$has_ipv4" = false ] && add_ipv4=1
    [ "$has_ipv6" = false ] && add_ipv6=1

    if ! awk \
        -v add_ipv4="$add_ipv4" \
        -v add_ipv6="$add_ipv6" \
        -v rule_ipv4="$rule_ipv4" \
        -v rule_ipv6="$rule_ipv6" '
        function add_rules() {
            if (inserted) {
                return
            }
            if (add_ipv4) {
                print rule_ipv4
            }
            if (add_ipv6) {
                print rule_ipv6
            }
            inserted=1
        }
        {
            if ($0 !~ /^[[:space:]]*#/ && $0 !~ /^[[:space:]]*$/) {
                add_rules()
            }
            print
        }
        END {
            if (!inserted) {
                add_rules()
            }
        }
    ' "$hba_file" > "$temp_file"; then
        rm -f "$temp_file"
        print_error "Could not prepare PostgreSQL pg_hba.conf"
        return 1
    fi

    if ! sudo cp "$temp_file" "$hba_file"; then
        rm -f "$temp_file"
        print_error "Could not update PostgreSQL pg_hba.conf"
        print_info "The original file remains available at: $backup_file"
        return 1
    fi
    rm -f "$temp_file"

    if ! systemctl reload postgresql 2>/dev/null && ! service postgresql reload 2>/dev/null; then
        print_error "Could not reload PostgreSQL after updating pg_hba.conf"
        print_info "The original file remains available at: $backup_file"
        return 1
    fi

    print_success "Configured PostgreSQL localhost authentication for NeoDesk"
    return 0
}

#===============================================================================
# Service Management Functions (Enhanced v2.1.2)
#===============================================================================

# Wait for a service to fully stop with timeout
wait_for_service_stop() {
    local service_name="$1"
    local timeout="${2:-30}"
    local elapsed=0
    
    while [ $elapsed -lt $timeout ]; do
        if ! systemctl is-active --quiet "$service_name" 2>/dev/null; then
            return 0
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done
    
    print_warning "Service $service_name did not stop within ${timeout}s"
    return 1
}

# Kill any stale processes that might be holding files/ports
# Free NeoDesk ports when systemd stop left orphan listeners.
# port_listener_pids PORT: the processes listening on a TCP port.
port_listener_pids() {
    ss -ltnpH "sport = :$1" 2>/dev/null | grep -o 'pid=[0-9]*' | cut -d= -f2 | sort -u
}

# is_neodesk_process PID: the server, the old Rust servers, or the old
# Node.js console of this install.
is_neodesk_process() {
    local comm args
    comm=$(cat "/proc/$1/comm" 2>/dev/null) || return 1
    args=$(tr '\0' ' ' < "/proc/$1/cmdline" 2>/dev/null)
    case "$comm" in
        neodesk-serv*|hbbs|hbbr|hbbs-v8-api) return 0 ;;
        node) [[ "$args" == *"$CONSOLE_PATH"* || "$args" == *"server.js"* ]] && return 0 ;;
    esac
    return 1
}

# kill_processes_holding_ports: NeoDesk's own processes left on its
# ports are stopped. A port another program holds is named in
# FOREIGN_PORT_HOLDERS and that program is left alone.
kill_processes_holding_ports() {
    local port pid name
    FOREIGN_PORT_HOLDERS=""
    for port in $(signal_port) $(relay_port) $(resolve_panel_http_port) $(resolve_panel_https_port); do
        [ "$port" = 0 ] && continue
        for pid in $(port_listener_pids "$port"); do
            if is_neodesk_process "$pid"; then
                print_warning "Port ${port} is still held by an old NeoDesk process (pid $pid): stopping it"
                kill -TERM "$pid" 2>/dev/null || true
                sleep 1
                kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null
            else
                name=$(cat "/proc/$pid/comm" 2>/dev/null || echo unknown)
                FOREIGN_PORT_HOLDERS="${FOREIGN_PORT_HOLDERS:+$FOREIGN_PORT_HOLDERS, }$port ($name, pid $pid)"
            fi
        done
    done
    if [ -n "$FOREIGN_PORT_HOLDERS" ]; then
        print_error "Ports NeoDesk needs are taken by other programs: $FOREIGN_PORT_HOLDERS"
        print_info "Stop those programs, or give NeoDesk other ports: SIGNAL_PORT, RELAY_PORT, CONSOLE_PORT or HTTPS_PORT in $CONSOLE_PATH/.env"
    fi
    return 0
}

kill_stale_processes() {
    local process_name="$1"
    # The program itself, as the first word of the command line: a process
    # that only names it in its arguments (this installer run with
    # --binary .../neodesk-server-linux-amd64) is left alone
    local pattern="^([^ ]*/)?${process_name}( |$)"

    # Find and kill any remaining processes
    local pids
    pids=$(pgrep -f "$pattern" 2>/dev/null || true)

    if [ -n "$pids" ]; then
        print_warning "Found stale $process_name processes: $pids"

        # Try graceful termination first
        for pid in $pids; do
            kill -TERM "$pid" 2>/dev/null || true
        done
        sleep 2

        # Force kill if still running
        pids=$(pgrep -f "$pattern" 2>/dev/null || true)
        if [ -n "$pids" ]; then
            for pid in $pids; do
                kill -9 "$pid" 2>/dev/null || true
            done
            sleep 1
        fi
        
        print_info "Cleaned up stale $process_name processes"
    fi
}

# Check if a port is available
check_port_available() {
    local port="$1"
    local service_name="${2:-unknown}"
    
    if ss -tlnp 2>/dev/null | grep -q ":${port} " || \
       netstat -tlnp 2>/dev/null | grep -q ":${port} "; then
        local process=$(ss -tlnp 2>/dev/null | grep ":${port} " | awk '{print $NF}' || \
                       netstat -tlnp 2>/dev/null | grep ":${port} " | awk '{print $NF}')
        print_error "Port $port is already in use by: $process"
        return 1
    fi
    return 0
}

# Verify that a service is healthy (running and listening on expected port)
_tcp_port_is_listening() {
    local port="$1"
    # Match :PORT followed by whitespace or end — covers ss/netstat layouts
    # like "0.0.0.0:80", "*:80", "[::]:80".
    ss -tlnH 2>/dev/null | grep -qE ":${port}([[:space:]]|$)" || \
        ss -tln 2>/dev/null | grep -qE ":${port}([[:space:]]|$)" || \
        netstat -tln 2>/dev/null | grep -qE ":${port}([[:space:]]|$)"
}

# Hint when .env requests a privileged panel port but Node bound a fallback.
_hint_panel_privileged_port_mismatch() {
    local expected_port="$1"
    local https_enabled
    https_enabled=$(read_effective_console_setting HTTPS_ENABLED false)

    if [ "$(echo "$https_enabled" | tr '[:upper:]' '[:lower:]')" != "true" ]; then
        return 0
    fi

    if [ "$expected_port" = "443" ] && _tcp_port_is_listening 5443; then
        print_info "  Panel is listening on :5443 instead of configured :443"
        print_info "  → Run Repair → Repair permissions (adds CAP_NET_BIND_SERVICE), then restart neodesk-server"
        print_info "  → Or set HTTPS_PORT=5443 and use a reverse proxy on :443 (https://neode.sk/docs/operations/reverse-proxy-tls)"
        return 0
    fi

    if [ "$expected_port" = "80" ] && _tcp_port_is_listening "$CONSOLE_DEFAULT_PORT"; then
        print_info "  HTTP redirect is on :$CONSOLE_DEFAULT_PORT instead of configured :80 — set PORT=80 and run Repair → Repair permissions"
    fi
}

verify_service_health() {
    local service_name="$1"
    local expected_port="$2"
    local timeout="${3:-10}"
    local elapsed=0
    
    # First check if service is active
    if ! systemctl is-active --quiet "$service_name" 2>/dev/null; then
        print_error "Service $service_name is not running"
        show_service_logs "$service_name" 20
        return 1
    fi
    
    # If port specified, wait for it to be bound
    if [ -n "$expected_port" ]; then
        while [ $elapsed -lt $timeout ]; do
            if _tcp_port_is_listening "$expected_port"; then
                return 0
            fi
            sleep 1
            elapsed=$((elapsed + 1))
        done
        
        print_error "Service $service_name is running but not listening on port $expected_port"
        if [ "$service_name" = "$SERVER_SERVICE" ] || [ "$service_name" = "$LEGACY_CONSOLE_SERVICE" ]; then
            _hint_panel_privileged_port_mismatch "$expected_port"
        fi
        show_service_logs "$service_name" 20
        return 1
    fi
    
    return 0
}

# Show recent service logs for debugging
show_service_logs() {
    local service_name="$1"
    local lines="${2:-30}"
    
    echo ""
    echo -e "${YELLOW}═══ Recent logs for $service_name ═══${NC}"
    journalctl -u "$service_name" -n "$lines" --no-pager 2>/dev/null || \
        print_warning "Could not retrieve logs for $service_name"
    echo -e "${YELLOW}═══════════════════════════════════════${NC}"
    echo ""
}

# Gracefully stop all NeoDesk services with proper cleanup
graceful_stop_services() {
    print_step "Stopping services gracefully..."
    
    local services=("neodesk-server")
    # Legacy services (for migration)
    local legacy_services=("neodesk" "rustdesksignal" "rustdeskrelay" "neodesk-api" "neodesk-go")
    
    # Stop current services
    for service in "${services[@]}"; do
        if systemctl is-active --quiet "$service" 2>/dev/null; then
            print_info "Stopping $service..."
            systemctl stop "$service" 2>/dev/null || true
        fi
    done
    
    # Stop legacy services if they exist
    for service in "${legacy_services[@]}"; do
        if systemctl is-active --quiet "$service" 2>/dev/null; then
            print_info "Stopping legacy $service..."
            systemctl stop "$service" 2>/dev/null || true
        fi
    done
    
    # Wait for services to stop
    for service in "${services[@]}" "${legacy_services[@]}"; do
        wait_for_service_stop "$service" 15
    done
    
    # Kill any stale processes (Go and legacy Rust)
    kill_stale_processes "neodesk-server"
    kill_stale_processes "hbbs"
    kill_stale_processes "hbbr"
    kill_processes_holding_ports
    
    print_success "All services stopped"
}

# Read a console setting as the running console sees it. The server with its
# console takes its unit's Environment= first and fills the rest from .env.
# The Node.js console's unit had EnvironmentFile=, which overrides
# Environment=, so there .env comes first.
read_effective_console_setting() {
    local key="$1"
    local default="${2:-}"
    local env_file="${CONSOLE_PATH}/.env"
    local val=""

    if is_go_only_install; then
        val=$(unit_env_value "$SERVER_UNIT" "$key")
        [ -n "$val" ] || val=$(env_file_value "$env_file" "$key")
    else
        val=$(env_file_value "$env_file" "$key")
        if [ -z "$val" ] && [ -f "$LEGACY_CONSOLE_UNIT" ]; then
            val=$(unit_env_value "$LEGACY_CONSOLE_UNIT" "$key")
        fi
    fi
    if [ -z "$val" ]; then
        val="$default"
    fi
    echo "$val"
}

# The service that serves the web console.
console_service_name() {
    if is_go_only_install; then
        echo "$SERVER_SERVICE"
    else
        echo "$LEGACY_CONSOLE_SERVICE"
    fi
}

# set_panel_http_port PORT: the console's HTTP port in .env. The server reads
# CONSOLE_PORT; PORT keeps the same value for the record and a rollback.
set_panel_http_port() {
    local env_file="${CONSOLE_PATH}/.env"
    _upsert_env_line "$env_file" PORT "$1"
    if is_go_only_install || grep -q '^CONSOLE_PORT=' "$env_file" 2>/dev/null; then
        _upsert_env_line "$env_file" CONSOLE_PORT "$1"
    fi
}

_upsert_env_line() {
    local file="$1" key="$2" value="$3"
    [ -f "$file" ] || touch "$file"
    if grep -q "^${key}=" "$file" 2>/dev/null; then
        sed -i "s|^${key}=.*|${key}=${value}|" "$file"
    else
        echo "${key}=${value}" >> "$file"
    fi
}

_remove_env_line() {
    local file="$1" key="$2"
    [ -f "$file" ] && sed -i "/^${key}=/d" "$file"
}

_upsert_systemd_env() {
    local file="$1" key="$2" value="$3"
    [ -f "$file" ] || return 0
    if grep -q "Environment=${key}=" "$file" 2>/dev/null; then
        sed -i "s|Environment=${key}=.*|Environment=${key}=${value}|" "$file"
    else
        sed -i "/^\[Service\]/a Environment=${key}=${value}" "$file"
    fi
}

_remove_systemd_env() {
    local file="$1" key="$2"
    [ -f "$file" ] && sed -i "/Environment=${key}=/d" "$file"
}

# Infer RUSTDESK_API_TLS / ALLOW_SELF_SIGNED_CERTS from certificate path (LE vs self-signed).
infer_tls_mode_from_cert() {
    local cert_path="$1"
    local resolved
    resolved=$(readlink -f "$cert_path" 2>/dev/null || echo "$cert_path")
    if [[ "$resolved" == *"/etc/letsencrypt/"* ]]; then
        INFERRED_RUSTDESK_API_TLS="true"
        INFERRED_ALLOW_SELF_SIGNED="false"
    else
        INFERRED_RUSTDESK_API_TLS="false"
        INFERRED_ALLOW_SELF_SIGNED="true"
    fi
}

# Resolve Let's Encrypt live/ dir from .env, paths, symlinks, LE_CERT_DOMAIN, or cert SAN.
resolve_le_cert_live_dir() {
    local env_file="${1:-${CONSOLE_PATH}/.env}"
    local cert_hint="${2:-$RUSTDESK_PATH/ssl/neodesk.crt}"
    local ssl_key_env ssl_cert_env le_live_dir le_domain dns_name

    le_live_dir=$(grep -m1 '^LE_CERT_LIVE_DIR=' "$env_file" 2>/dev/null | cut -d= -f2- || true)
    ssl_cert_env=$(grep -m1 '^SSL_CERT_PATH=' "$env_file" 2>/dev/null | cut -d= -f2- || true)
    ssl_key_env=$(grep -m1 '^SSL_KEY_PATH=' "$env_file" 2>/dev/null | cut -d= -f2- || true)

    if [ -z "$le_live_dir" ] && [[ "$ssl_cert_env" == *"/etc/letsencrypt/"* ]]; then
        le_live_dir=$(dirname "$(readlink -f "$ssl_cert_env" 2>/dev/null || echo "$ssl_cert_env")")
    fi
    if [ -z "$le_live_dir" ] && [[ "$ssl_key_env" == *"/etc/letsencrypt/"* ]]; then
        le_live_dir=$(dirname "$(readlink -f "$ssl_key_env" 2>/dev/null || echo "$ssl_key_env")")
    fi
    if [ -z "$le_live_dir" ] && [ -L "$cert_hint" ]; then
        le_live_dir=$(dirname "$(readlink -f "$cert_hint" 2>/dev/null || echo "")")
    fi
    if [ -z "$le_live_dir" ]; then
        le_domain=$(grep -m1 '^LE_CERT_DOMAIN=' "$env_file" 2>/dev/null | cut -d= -f2- || true)
        if [ -n "$le_domain" ] && [ -d "/etc/letsencrypt/live/$le_domain" ]; then
            le_live_dir="/etc/letsencrypt/live/$le_domain"
        fi
    fi
    if [ -z "$le_live_dir" ] && [ -f "$cert_hint" ] && command -v openssl &>/dev/null; then
        dns_name=$(openssl x509 -in "$cert_hint" -noout -ext subjectAltName 2>/dev/null | \
            grep -oE 'DNS:[^, ]+' | head -1 | cut -d: -f2- || true)
        if [ -n "$dns_name" ] && [ -d "/etc/letsencrypt/live/$dns_name" ]; then
            le_live_dir="/etc/letsencrypt/live/$dns_name"
        fi
    fi
    echo "$le_live_dir"
}

# Copy a TLS file to dest as a real file (not a symlink).
# - If dest is already the same real file as src (self-signed generated in place),
#   do nothing — deleting dest would remove src and break cp.
# - If dest is a symlink that resolves to src (LE live dir), remove the symlink
#   and copy content so the console user can read it.
_safe_cp_tls_file() {
    local src="$1"
    local dest="$2"
    local src_real dest_real tmp

    [ -f "$src" ] || return 1
    src_real=$(readlink -f "$src" 2>/dev/null || echo "$src")
    if [ -e "$dest" ]; then
        dest_real=$(readlink -f "$dest" 2>/dev/null || echo "$dest")
        if [ "$src_real" = "$dest_real" ]; then
            if [ -L "$dest" ]; then
                # Symlink to src → replace with a real copy
                rm -f "$dest"
            else
                # Already a real file at dest (self-signed path) — no copy needed
                return 0
            fi
        fi
    fi
    tmp="${dest}.neodesk.$$.tmp"
    cp -L "$src" "$tmp" || return 1
    mv -f "$tmp" "$dest" || { rm -f "$tmp"; return 1; }
    return 0
}

# The server reads PORT as its signal port when SIGNAL_PORT is missing, and
# the console's .env sets PORT for the console: .env names the
# signal and relay ports (the admin's values stay), and the API port stays
# on the unit. While an install runs the Node.js console, the server's own
# console stays off (CONSOLE_PORT=0): Node holds its port.
ensure_go_server_signal_ports() {
    local go_svc_file="$SERVER_UNIT"
    local changed=0
    local go_api_port="${GO_API_PORT:-21114}"

    [ -f "$go_svc_file" ] || return 1

    if is_node_era_install && ! grep -q '^Environment=CONSOLE_PORT=' "$go_svc_file" 2>/dev/null; then
        _upsert_systemd_env "$go_svc_file" CONSOLE_PORT 0
        changed=1
    fi
    if [ -f "$CONSOLE_PATH/.env" ]; then
        if [ -z "$(env_file_value "$CONSOLE_PATH/.env" SIGNAL_PORT)" ] && [ -z "$(unit_env_value "$go_svc_file" SIGNAL_PORT)" ]; then
            _upsert_env_line "$CONSOLE_PATH/.env" SIGNAL_PORT 21116
            changed=1
        fi
        if [ -z "$(env_file_value "$CONSOLE_PATH/.env" RELAY_PORT)" ] && [ -z "$(unit_env_value "$go_svc_file" RELAY_PORT)" ]; then
            _upsert_env_line "$CONSOLE_PATH/.env" RELAY_PORT 21117
            changed=1
        fi
    fi
    if ! grep -q "^Environment=GO_API_PORT=${go_api_port}" "$go_svc_file" 2>/dev/null; then
        _upsert_systemd_env "$go_svc_file" GO_API_PORT "$go_api_port"
        changed=1
    fi
    if [ -f "$go_svc_file" ] && grep -qE '\-api-port[[:space:]]+21121\b' "$go_svc_file" 2>/dev/null; then
        print_info "Migrating Go -api-port 21121 → ${go_api_port} (handlers on Go; clients stay on :${CLIENT_API_PORT:-21121} proxy)"
        sed -i "s/-api-port 21121/-api-port ${go_api_port}/" "$go_svc_file"
        changed=1
    fi
    if [ "$changed" -eq 1 ]; then
        systemctl daemon-reload 2>/dev/null || true
        print_info "Server ports: signal $(signal_port), relay $(relay_port), API ${go_api_port} (PORT and API_PORT in .env are the console's)"
    fi
    [ "$changed" -eq 1 ]
}

# Copy TLS material into $RUSTDESK_PATH/ssl/ as real files (not symlinks) so the
# neodesk console user can read them. LE live dirs are root-only.
deploy_ssl_material_to_rustdesk_dir() {
    local cert_src="$1"
    local key_src="$2"
    local le_live_dir="${3:-}"
    local ssl_dir="$RUSTDESK_PATH/ssl"
    local svc_user="neodesk"
    local env_file="${CONSOLE_PATH}/.env"

    if [ ! -f "$cert_src" ] || [ ! -f "$key_src" ]; then
        print_error "Certificate or key source not found: cert=$cert_src key=$key_src"
        return 1
    fi

    mkdir -p "$ssl_dir"
    if ! _safe_cp_tls_file "$cert_src" "$ssl_dir/neodesk.crt"; then
        print_error "Failed to deploy certificate to $ssl_dir/neodesk.crt"
        return 1
    fi
    if ! _safe_cp_tls_file "$key_src" "$ssl_dir/neodesk.key"; then
        print_error "Failed to deploy private key to $ssl_dir/neodesk.key"
        return 1
    fi

    if id "$svc_user" &>/dev/null; then
        chown root:"$svc_user" "$ssl_dir/neodesk.crt" "$ssl_dir/neodesk.key" 2>/dev/null || true
    fi
    chmod 640 "$ssl_dir/neodesk.crt" "$ssl_dir/neodesk.key" 2>/dev/null || true

    if [ -n "$le_live_dir" ]; then
        _upsert_env_line "$env_file" LE_CERT_LIVE_DIR "$le_live_dir"
        _upsert_env_line "$env_file" LE_CERT_DOMAIN "$(basename "$le_live_dir")"
        install_le_certbot_renew_hook
    fi

    return 0
}

# certbot deploy hook: re-copy renewed LE certs then restart NeoDesk services.
install_le_certbot_renew_hook() {
    local hook_dir="/etc/letsencrypt/renewal-hooks/deploy"
    local hook="$hook_dir/neodesk-reload.sh"
    local conf="$hook_dir/neodesk-reload.conf"
    mkdir -p "$hook_dir"

    cat > "$conf" <<EOF
RUSTDESK_PATH=${RUSTDESK_PATH}
CONSOLE_PATH=${CONSOLE_PATH}
EOF
    chmod 640 "$conf"

    cat > "$hook" <<'HOOK'
#!/bin/bash
set -euo pipefail
CONF="/etc/letsencrypt/renewal-hooks/deploy/neodesk-reload.conf"
[ -f "$CONF" ] && . "$CONF"
RUSTDESK_PATH="${RUSTDESK_PATH:-/opt/neodesk}"
CONSOLE_PATH="${CONSOLE_PATH:-/opt/neodesk}"
ENV_FILE="$CONSOLE_PATH/.env"
SSL_DIR="$RUSTDESK_PATH/ssl"
SVC_USER="neodesk"

le_live_dir=""
if [ -f "$ENV_FILE" ]; then
    le_live_dir=$(grep -m1 '^LE_CERT_LIVE_DIR=' "$ENV_FILE" 2>/dev/null | cut -d= -f2- || true)
fi
if [ -z "$le_live_dir" ] || [ ! -d "$le_live_dir" ]; then
    echo "neodesk-reload: LE_CERT_LIVE_DIR missing or invalid — skipping cert copy" >&2
    systemctl restart neodesk-server 2>/dev/null || true
    exit 0
fi

mkdir -p "$SSL_DIR"
for pair in "fullchain.pem:neodesk.crt" "privkey.pem:neodesk.key"; do
    src_name="${pair%%:*}"
    dest_name="${pair##*:}"
    src="$le_live_dir/$src_name"
    dest="$SSL_DIR/$dest_name"
    src_real=$(readlink -f "$src" 2>/dev/null || echo "$src")
    if [ -e "$dest" ]; then
        dest_real=$(readlink -f "$dest" 2>/dev/null || echo "$dest")
        [ "$src_real" = "$dest_real" ] && rm -f "$dest"
    fi
    tmp="${dest}.neodesk.$$.tmp"
    cp -L "$src" "$tmp"
    mv -f "$tmp" "$dest"
done
if id "$SVC_USER" &>/dev/null; then
    chown root:"$SVC_USER" "$SSL_DIR/neodesk.crt" "$SSL_DIR/neodesk.key"
fi
chmod 640 "$SSL_DIR/neodesk.crt" "$SSL_DIR/neodesk.key"
systemctl restart neodesk-server 2>/dev/null || true
HOOK
    chmod +x "$hook"
}

# Repair installs that symlinked LE certs into ssl/ (console user cannot read privkey).
maybe_repair_le_ssl_symlinks() {
    local ssl_dir="$RUSTDESK_PATH/ssl"
    local crt="$ssl_dir/neodesk.crt"
    local key="$ssl_dir/neodesk.key"
    local env_file="${CONSOLE_PATH}/.env"
    local needs_redeploy="no"
    local ssl_key_env ssl_cert_env
    local console_user="neodesk"

    for f in "$crt" "$key"; do
        if [ -L "$f" ]; then
            local target
            target=$(readlink -f "$f" 2>/dev/null || readlink "$f" 2>/dev/null || echo "")
            if [[ "$target" == *"/etc/letsencrypt/"* ]]; then
                needs_redeploy="yes"
            fi
        fi
    done

    ssl_key_env=$(grep -m1 '^SSL_KEY_PATH=' "$env_file" 2>/dev/null | cut -d= -f2- || true)
    ssl_cert_env=$(grep -m1 '^SSL_CERT_PATH=' "$env_file" 2>/dev/null | cut -d= -f2- || true)
    if [[ "$ssl_key_env" == *"/etc/letsencrypt/"* ]] || [[ "$ssl_cert_env" == *"/etc/letsencrypt/"* ]]; then
        needs_redeploy="yes"
    fi
    if id "$console_user" &>/dev/null && [ -e "$key" ] \
        && ! runuser -u "$console_user" -- test -r "$key" 2>/dev/null; then
        needs_redeploy="yes"
    fi

    if [ "$needs_redeploy" != "yes" ]; then
        return 2
    fi

    local le_live_dir
    le_live_dir=$(resolve_le_cert_live_dir "$env_file" "$crt")

    if [ -z "$le_live_dir" ] || [ ! -f "$le_live_dir/fullchain.pem" ] || [ ! -f "$le_live_dir/privkey.pem" ]; then
        print_warning "LE certificate symlinks detected but live dir not found — manual repair may be needed"
        return 1
    fi

    print_info "Repairing LE certificate symlinks → copied files for console user"
    if ! deploy_ssl_material_to_rustdesk_dir "$le_live_dir/fullchain.pem" "$le_live_dir/privkey.pem" "$le_live_dir"; then
        print_error "LE redeploy failed for $le_live_dir — remove symlinks under $ssl_dir and retry"
        return 1
    fi
    _sync_deployed_ssl_paths_to_env
    return 0
}

# When HTTPS uses standard port 443, align HTTP redirect listener to :80.
_ensure_standard_https_redirect_ports() {
    local env_file="${CONSOLE_PATH}/.env"
    local https_port http_port https_enabled changed=0

    https_enabled=$(read_effective_console_setting HTTPS_ENABLED false)
    if [ "$(echo "$https_enabled" | tr '[:upper:]' '[:lower:]')" != "true" ]; then
        return 1
    fi

    https_port=$(read_effective_console_setting HTTPS_PORT 5443)
    [ "$https_port" = "443" ] || return 1

    http_port=$(resolve_panel_http_port)
    if [ "$http_port" != "80" ]; then
        set_panel_http_port 80
        _upsert_env_line "$env_file" HTTP_REDIRECT_HTTPS true
        changed=1
    fi
    # Ports below 1024 need CAP_NET_BIND_SERVICE in the unit
    if [ "$changed" -eq 1 ] && is_go_only_install; then
        maybe_update_services >/dev/null
    fi
    if [ "$changed" -eq 1 ]; then
        ensure_service_user >/dev/null
        print_info "Standard HTTPS ports synced: HTTPS :443, HTTP redirect :80"
        return 0
    fi
    return 1
}

# Repair HTTPS stuck state: Go signal port isolation + LE material redeploy.
repair_https_stuck_state() {
    local quiet="${1:-}"
    local changed=0

    if ensure_go_server_signal_ports; then
        changed=1
    fi

    local https_enabled
    https_enabled=$(read_effective_console_setting HTTPS_ENABLED false)
    if [ "$(echo "$https_enabled" | tr '[:upper:]' '[:lower:]')" = "true" ]; then
        local le_rc=2
        maybe_repair_le_ssl_symlinks || le_rc=$?
        if [ "$le_rc" -eq 0 ]; then
            changed=1
        elif [ "$le_rc" -ne 2 ] && ensure_console_tls_material_readable; then
            changed=1
        fi
        _sync_deployed_ssl_paths_to_env 2>/dev/null || true
        if _ensure_standard_https_redirect_ports; then
            changed=1
        fi
    fi

    if [ "$changed" -eq 1 ] && [ "$quiet" != "yes" ]; then
        print_info "HTTPS/TLS configuration repaired"
    fi
    return 0
}

# Ensure copied TLS files under $RUSTDESK_PATH/ssl/ are referenced in .env.
_sync_deployed_ssl_paths_to_env() {
    local ssl_dir="$RUSTDESK_PATH/ssl"
    local env_file="${CONSOLE_PATH}/.env"

    _upsert_env_line "$env_file" SSL_CERT_PATH "$ssl_dir/neodesk.crt"
    _upsert_env_line "$env_file" SSL_KEY_PATH "$ssl_dir/neodesk.key"
}

# When HTTPS is enabled, ensure the console user can read the TLS private key.
# Re-copies from LE_CERT_LIVE_DIR when symlinks, unreadable keys, or /etc/letsencrypt paths remain.
ensure_console_tls_material_readable() {
    local https_enabled console_user="neodesk"
    local env_file="${CONSOLE_PATH}/.env"
    local ssl_dir="$RUSTDESK_PATH/ssl"
    local ssl_key_path ssl_cert_path

    https_enabled=$(read_effective_console_setting HTTPS_ENABLED false)
    if [ "$(echo "$https_enabled" | tr '[:upper:]' '[:lower:]')" != "true" ]; then
        return 0
    fi

    maybe_repair_le_ssl_symlinks 2>/dev/null || true

    ssl_key_path=$(read_effective_console_setting SSL_KEY_PATH "")
    ssl_cert_path=$(read_effective_console_setting SSL_CERT_PATH "")
    if [ -z "$ssl_key_path" ]; then
        ssl_key_path="$ssl_dir/neodesk.key"
    fi

    if id "$console_user" &>/dev/null && [ -e "$ssl_key_path" ]; then
        if runuser -u "$console_user" -- test -r "$ssl_key_path" 2>/dev/null; then
            return 0
        fi
    fi

    local le_live_dir
    le_live_dir=$(resolve_le_cert_live_dir "$env_file" "$ssl_key_path")
    if [ -z "$le_live_dir" ] && [ -n "$ssl_cert_path" ]; then
        le_live_dir=$(resolve_le_cert_live_dir "$env_file" "$ssl_cert_path")
    fi

    if [ -n "$le_live_dir" ] && [ -f "$le_live_dir/fullchain.pem" ] && [ -f "$le_live_dir/privkey.pem" ]; then
        print_info "Re-deploying Let's Encrypt certificate for console user"
        if deploy_ssl_material_to_rustdesk_dir "$le_live_dir/fullchain.pem" "$le_live_dir/privkey.pem" "$le_live_dir"; then
            _sync_deployed_ssl_paths_to_env
            if id "$console_user" &>/dev/null && runuser -u "$console_user" -- test -r "$ssl_dir/neodesk.key" 2>/dev/null; then
                return 0
            fi
        fi
    fi

    print_warning "HTTPS is enabled but console user cannot read TLS key (${ssl_key_path:-$ssl_dir/neodesk.key})"
    print_info "  Check: runuser -u neodesk -- test -r ${ssl_key_path:-$ssl_dir/neodesk.key}"
    print_info "  Logs:  journalctl -u neodesk-server -n 30 --no-pager"
    return 1
}

# Wait for an HTTP(S) endpoint to return a usable status code (post-restart boot delay).
_wait_for_http_code() {
    local url="$1"
    local max_wait="${2:-15}"
    local use_insecure="${3:-}"
    local elapsed=0
    local code="000"
    local curl_args=(-s -o /dev/null -w '%{http_code}' --max-time 4)

    if [ "$use_insecure" = "yes" ]; then
        curl_args=(-k "${curl_args[@]}")
    fi

    while [ "$elapsed" -lt "$max_wait" ]; do
        code=$(curl "${curl_args[@]}" "$url" 2>/dev/null || echo "000")
        if [[ "$code" =~ ^(200|301|302|304|401|403|405)$ ]]; then
            echo "$code"
            return 0
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done
    echo "$code"
    return 1
}

# Sync .env for HTTP or HTTPS panel mode.
apply_console_protocol_mode() {
    local mode="$1"
    local cert_crt="${2:-}"
    local cert_key="${3:-}"
    local api_tls="${4:-false}"
    local allow_self_signed="${5:-true}"
    local env_file="${CONSOLE_PATH}/.env"
    local go_port="${GO_API_PORT:-21114}"

    if [ "$mode" = "http" ]; then
        _upsert_env_line "$env_file" HTTPS_ENABLED false
        _upsert_env_line "$env_file" RUSTDESK_API_TLS false
        _upsert_env_line "$env_file" ALLOW_SELF_SIGNED_CERTS false
        _upsert_env_line "$env_file" HTTP_REDIRECT_HTTPS false
        _upsert_env_line "$env_file" TRUST_PROXY false
        _upsert_env_line "$env_file" HBBS_API_URL "http://localhost:${go_port}/api"
        _upsert_env_line "$env_file" NEODESK_API_URL "http://localhost:${go_port}/api"
        _remove_env_line "$env_file" NODE_EXTRA_CA_CERTS
        _remove_env_line "$env_file" ENTERPRISE_TLS
        sync_go_server_trust_proxy no
    elif [ "$mode" = "https" ]; then
        _upsert_env_line "$env_file" HTTPS_ENABLED true
        _upsert_env_line "$env_file" SSL_CERT_PATH "$cert_crt"
        _upsert_env_line "$env_file" SSL_KEY_PATH "$cert_key"
        _upsert_env_line "$env_file" TRUST_PROXY false
        if ! grep -q '^HTTPS_PORT=' "$env_file" 2>/dev/null; then
            _upsert_env_line "$env_file" HTTPS_PORT 5443
        fi
        _upsert_env_line "$env_file" HTTP_REDIRECT_HTTPS true
        _upsert_env_line "$env_file" RUSTDESK_API_TLS "$api_tls"
        _upsert_env_line "$env_file" ALLOW_SELF_SIGNED_CERTS "$allow_self_signed"
        _upsert_env_line "$env_file" HBBS_API_URL "http://localhost:${go_port}/api"
        _upsert_env_line "$env_file" NEODESK_API_URL "http://localhost:${go_port}/api"
        # Only the Node.js console read NODE_EXTRA_CA_CERTS
        _remove_env_line "$env_file" NODE_EXTRA_CA_CERTS
        sync_go_server_trust_proxy no
    else
        print_error "apply_console_protocol_mode: unknown mode '$mode'"
        return 1
    fi

    systemctl daemon-reload 2>/dev/null || true
}

# Enable signal/relay TLS on neodesk-server using deployed panel cert.
sync_go_server_signal_relay_tls() {
    local ssl_dir="${1:-$RUSTDESK_PATH/ssl}"
    local go_svc_file="$SERVER_UNIT"

    [ -f "$go_svc_file" ] || return 0
    sed -i 's/ -tls-cert [^ ]*//g' "$go_svc_file"
    sed -i 's/ -tls-key [^ ]*//g' "$go_svc_file"
    sed -i 's/ -tls-signal//g' "$go_svc_file"
    sed -i 's/ -tls-relay//g' "$go_svc_file"
    sed -i 's/ -tls-api//g' "$go_svc_file"
    sed -i 's/ -force-https//g' "$go_svc_file"
    sed -i "s|\(ExecStart=.*neodesk-server[^$]*\)|\1 -tls-cert $ssl_dir/neodesk.crt -tls-key $ssl_dir/neodesk.key -tls-signal -tls-relay|" "$go_svc_file"
    systemctl daemon-reload 2>/dev/null || true
}

# Remove signal/relay TLS from neodesk-server.
clear_go_server_signal_relay_tls() {
    local go_svc_file="$SERVER_UNIT"

    [ -f "$go_svc_file" ] || return 0
    sed -i 's/ -tls-cert [^ ]*//g' "$go_svc_file"
    sed -i 's/ -tls-key [^ ]*//g' "$go_svc_file"
    sed -i 's/ -tls-signal//g' "$go_svc_file"
    sed -i 's/ -tls-relay//g' "$go_svc_file"
    sed -i 's/ -tls-api//g' "$go_svc_file"
    sed -i 's/ -force-https//g' "$go_svc_file"
    systemctl daemon-reload 2>/dev/null || true
}

# Enable or disable Go server reverse-proxy trust.
# Optional 2nd arg: TRUSTED_PROXIES CIDR list. Omitted → loopback default.
# Empty string → enable TRUST_PROXY but do not write TRUSTED_PROXIES (remote proxy).
sync_go_server_trust_proxy() {
    local enable="${1:-yes}"
    local trusted_cidrs
    if [ "$#" -ge 2 ]; then
        trusted_cidrs="$2"
    else
        trusted_cidrs="127.0.0.1/32,::1/128"
    fi
    local go_svc_file="$SERVER_UNIT"

    [ -f "$go_svc_file" ] || return 0
    if [ "$enable" = "yes" ]; then
        _upsert_systemd_env "$go_svc_file" TRUST_PROXY Y
        if [ -n "$trusted_cidrs" ]; then
            _upsert_systemd_env "$go_svc_file" TRUSTED_PROXIES "$trusted_cidrs"
        fi
        if ! grep -q '\-trust-proxy' "$go_svc_file" 2>/dev/null; then
            sed -i 's|\(ExecStart=.*neodesk-server[^$]*\)|\1 -trust-proxy|' "$go_svc_file"
        fi
    else
        _remove_systemd_env "$go_svc_file" TRUST_PROXY
        _remove_systemd_env "$go_svc_file" TRUSTED_PROXIES
        sed -i 's/ -trust-proxy//g' "$go_svc_file"
    fi
    systemctl daemon-reload 2>/dev/null || true
}

# Console + Go settings for TLS termination at an external reverse proxy.
apply_console_reverse_proxy_mode() {
    local panel_host="${1:-}"
    local server_id="${2:-}"
    local ws_origins="${3:-}"
    local panel_bind="${4:-127.0.0.1}"
    local env_file="${CONSOLE_PATH}/.env"
    local go_port="${GO_API_PORT:-21114}"

    apply_console_protocol_mode http
    clear_go_server_signal_relay_tls

    _upsert_env_line "$env_file" HOST "$panel_bind"
    _upsert_env_line "$env_file" TRUST_PROXY Y
    # Same-host proxy: loopback. Remote proxy (HOST=0.0.0.0): operator must set the proxy CIDR.
    local trusted_cidrs="127.0.0.1/32,::1/128"
    if [ "$panel_bind" = "0.0.0.0" ]; then
        trusted_cidrs=""
    fi
    if [ -n "$trusted_cidrs" ]; then
        _upsert_env_line "$env_file" TRUSTED_PROXIES "$trusted_cidrs"
    fi
    _upsert_env_line "$env_file" HTTP_REDIRECT_HTTPS false
    _upsert_env_line "$env_file" HBBS_API_URL "http://localhost:${go_port}/api"
    _upsert_env_line "$env_file" NEODESK_API_URL "http://localhost:${go_port}/api"

    if [ -n "$panel_host" ]; then
        _upsert_env_line "$env_file" PANEL_PUBLIC_HOST "$panel_host"
        _upsert_env_line "$env_file" PANEL_PUBLIC_URL "https://${panel_host}"
        # The console's port carries the client API under /client-api, so
        # clients reach it through the same host name. An address set
        # before stays.
        if ! grep -q '^PUBLIC_API_URL=.' "$env_file" 2>/dev/null; then
            _upsert_env_line "$env_file" PUBLIC_API_URL "https://${panel_host}/client-api"
        fi
    fi
    if [ -n "$server_id" ]; then
        _upsert_env_line "$env_file" PUBLIC_SERVER_ID "$server_id"
    elif [ -n "$panel_host" ]; then
        _upsert_env_line "$env_file" PUBLIC_SERVER_ID "$panel_host"
    fi
    if [ -n "$ws_origins" ]; then
        _upsert_env_line "$env_file" WS_ALLOWED_ORIGINS "$ws_origins"
    elif [ -n "$panel_host" ]; then
        _upsert_env_line "$env_file" WS_ALLOWED_ORIGINS "https://${panel_host}"
    fi

    sync_go_server_trust_proxy yes "$trusted_cidrs"
    systemctl daemon-reload 2>/dev/null || true
}

# Write Caddy/Nginx snippets and verify script under $RUSTDESK_PATH/reverse-proxy/.
generate_reverse_proxy_config() {
    local panel_host="${1:-}"
    local proxy_type="${2:-caddy}"
    local route_wss="${3:-yes}"
    local server_id="${4:-}"
    local panel_bind="${5:-}"
    local upstream_addr="${6:-}"

    if [ -z "$panel_host" ]; then
        read -p "Public panel hostname (e.g., console.example.com): " panel_host
        if [ -z "$panel_host" ]; then
            print_error "Hostname is required for reverse-proxy snippets"
            return 1
        fi
    fi

    if [ -z "$panel_bind" ]; then
        if confirm "Is the reverse proxy on THIS server (same host as NeoDesk)?"; then
            panel_bind="127.0.0.1"
            upstream_addr="127.0.0.1"
        else
            panel_bind="0.0.0.0"
            upstream_addr=$(ip route get 1 2>/dev/null | awk '{print $7; exit}')
            [ -z "$upstream_addr" ] && upstream_addr=$(hostname -I 2>/dev/null | awk '{print $1}')
            echo ""
            read -p "NeoDesk LAN IP for proxy upstream [${upstream_addr}]: " _custom_up
            [ -n "$_custom_up" ] && upstream_addr="$_custom_up"
            if [ -z "$upstream_addr" ]; then
                print_error "LAN IP required when the proxy runs on another host"
                return 1
            fi
            print_warning "Panel will listen on 0.0.0.0:$(resolve_panel_http_port) — restrict firewall to your proxy host"
        fi
    fi
    [ -z "$upstream_addr" ] && upstream_addr="$panel_bind"
    if [ "$panel_bind" = "0.0.0.0" ] && [ "$upstream_addr" = "0.0.0.0" ]; then
        upstream_addr=$(ip route get 1 2>/dev/null | awk '{print $7; exit}')
    fi

    if [ -z "$proxy_type" ] || [ "$proxy_type" = "prompt" ]; then
        echo ""
        echo "  1) Caddy"
        echo "  2) Nginx"
        read -p "Proxy type [1]: " _proxy_pick
        case "${_proxy_pick:-1}" in
            2) proxy_type="nginx" ;;
            *) proxy_type="caddy" ;;
        esac
    fi

    if [ -z "$route_wss" ] || [ "$route_wss" = "prompt" ]; then
        if confirm "Route RustDesk WSS paths (/ws/id, /ws/relay) on the same hostname?"; then
            route_wss="yes"
        else
            route_wss="no"
        fi
    fi

    if [ -z "$server_id" ]; then
        if confirm "Use a different hostname for RustDesk ID/relay clients than the panel?"; then
            read -p "RustDesk ID server hostname (e.g., desk.example.com): " server_id
        fi
    fi
    [ -z "$server_id" ] && server_id="$panel_host"

    local out_dir="$RUSTDESK_PATH/reverse-proxy"
    mkdir -p "$out_dir"

    local ws_origins="https://${panel_host}"
    [ "$panel_host" != "$server_id" ] && ws_origins="${ws_origins},https://${server_id}"

    cat > "$out_dir/neodesk.env.snippet" << EOF
# NeoDesk reverse-proxy mode — merge into $CONSOLE_PATH/.env
HOST=${panel_bind}
HTTPS_ENABLED=false
HTTP_REDIRECT_HTTPS=false
TRUST_PROXY=Y
TRUSTED_PROXIES=127.0.0.1/32,::1/128
CONSOLE_PORT=$(resolve_panel_http_port)
PORT=$(resolve_panel_http_port)
PANEL_PUBLIC_HOST=${panel_host}
PANEL_PUBLIC_URL=https://${panel_host}
PUBLIC_SERVER_ID=${server_id}
PUBLIC_API_URL=https://${panel_host}/client-api
WS_ALLOWED_ORIGINS=${ws_origins}
EOF

    if [ "$proxy_type" = "nginx" ]; then
        cat > "$out_dir/nginx.neodesk.conf.snippet" << EOF
# NeoDesk reverse-proxy snippet — merge into your nginx site config.
# TLS certificates: use certbot --nginx or your existing cert setup.

map \$http_upgrade \$connection_upgrade {
    default upgrade;
    ''      close;
}

server {
    listen 80;
    server_name ${panel_host};

    client_max_body_size 100M;
EOF
        if [ "$route_wss" = "yes" ]; then
            cat >> "$out_dir/nginx.neodesk.conf.snippet" << EOF

    location = /ws/id {
        proxy_pass http://${upstream_addr}:21118;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "Upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_buffering off;
        proxy_read_timeout 120s;
        proxy_send_timeout 120s;
    }

    location = /ws/relay {
        proxy_pass http://${upstream_addr}:21119;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "Upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_buffering off;
        proxy_read_timeout 120s;
        proxy_send_timeout 120s;
    }
EOF
        fi
        cat >> "$out_dir/nginx.neodesk.conf.snippet" << EOF

    location ~ ^/ws/ {
        proxy_pass http://${upstream_addr}:$(resolve_panel_http_port);
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_buffering off;
        proxy_cache off;
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
        proxy_socket_keepalive on;
    }

    location / {
        proxy_pass http://${upstream_addr}:$(resolve_panel_http_port);
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_read_timeout 86400s;
    }
}
EOF
        print_success "Nginx snippet: $out_dir/nginx.neodesk.conf.snippet"
    else
        cat > "$out_dir/caddy.Caddyfile.snippet" << EOF
# NeoDesk reverse-proxy snippet — merge into /etc/caddy/Caddyfile
# Caddy obtains TLS automatically when this block is active.

${panel_host} {
EOF
        if [ "$route_wss" = "yes" ]; then
            cat >> "$out_dir/caddy.Caddyfile.snippet" << EOF
    handle /ws/id {
        reverse_proxy ${upstream_addr}:21118
    }
    handle /ws/relay {
        reverse_proxy ${upstream_addr}:21119
    }
EOF
        fi
        cat >> "$out_dir/caddy.Caddyfile.snippet" << EOF
    reverse_proxy ${upstream_addr}:$(resolve_panel_http_port)

    encode gzip zstd
    header {
        X-Content-Type-Options nosniff
        X-Frame-Options DENY
        Referrer-Policy strict-origin-when-cross-origin
    }
}
EOF
        if [ "$panel_host" != "$server_id" ]; then
            cat >> "$out_dir/caddy.Caddyfile.snippet" << EOF

# Optional second site when ID/relay clients use a different hostname:
# ${server_id} {
#     handle /ws/id { reverse_proxy ${upstream_addr}:21118 }
#     handle /ws/relay { reverse_proxy ${upstream_addr}:21119 }
# }
EOF
        fi
        print_success "Caddy snippet: $out_dir/caddy.Caddyfile.snippet"
    fi

    cat > "$out_dir/firewall-notes.txt" << EOF
NeoDesk firewall notes — every port is described at https://neode.sk/docs/operations/ports

WAN (clients reach these directly — cannot be HTTP-proxied):
  - 21116/tcp + 21116/udp  Signal (registration, hole punching)
  - 21117/tcp              Relay data

Client API (needed for branding, enrollment, short-code pairing):
  - Through the proxy: https://${panel_host}/client-api (the console's port carries it)
  - 21121/tcp              Client API port, for clients set up with http://<host>:21121

Through your reverse proxy (HTTPS :443):
  - Panel, console WebSockets and the client API under /client-api -> http://${upstream_addr}:$(resolve_panel_http_port)
$( [ "$route_wss" = "yes" ] && echo "  - RustDesk WSS /ws/id -> ${upstream_addr}:21118, /ws/relay -> ${upstream_addr}:21119" )
$( [ "$panel_bind" = "0.0.0.0" ] && echo "  - Panel bind: 0.0.0.0:$(resolve_panel_http_port) (remote proxy) — restrict :$(resolve_panel_http_port) to proxy IP in firewall" )

Localhost only (never expose):
  - $(resolve_panel_http_port)/tcp               Console panel
  - 5443/tcp               Console panel (native HTTPS mode)

Example (ufw), recommended profile with a reverse proxy:
  sudo ufw allow 443/tcp
  sudo ufw allow 21116/tcp
  sudo ufw allow 21116/udp
  sudo ufw allow 21117/tcp
  # Keep 21114 off WAN when the proxy reaches it on loopback:
  sudo ufw deny 21114/tcp

Verify the running profile:
  sudo bash scripts/check-connection-ports.sh b
EOF

    cat > "$out_dir/verify.sh" << 'VERIFYEOF'
#!/usr/bin/env bash
# NeoDesk reverse-proxy verification
set -euo pipefail
PANEL_HOST="${1:-}"
if [ -z "$PANEL_HOST" ]; then
    echo "Usage: $0 <public-hostname>"
    exit 1
fi
echo "=== Local panel (HTTP) ==="
curl -sI "http://127.0.0.1:$(resolve_panel_http_port)/" | head -5 || true
echo ""
echo "=== Public panel (HTTPS via proxy) ==="
curl -sI "https://${PANEL_HOST}/" | head -5 || true
echo ""
echo "=== Console WebSocket upgrade ==="
curl -i -N --max-time 8 \
  -H "Connection: Upgrade" -H "Upgrade: websocket" \
  -H "Sec-WebSocket-Version: 13" \
  -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" \
  "https://${PANEL_HOST}/ws/nd-signal" 2>/dev/null | head -8 || true
VERIFYEOF
    chmod +x "$out_dir/verify.sh"
    # Inject hostname into verify script usage (already passed as arg)

    echo ""
    print_info "Reverse-proxy files written to: $out_dir"
    print_info "  neodesk.env.snippet"
    [ "$proxy_type" = "nginx" ] && print_info "  nginx.neodesk.conf.snippet" || print_info "  caddy.Caddyfile.snippet"
    print_info "  verify.sh $panel_host"
    print_info "  firewall-notes.txt"
    print_info "Documentation: https://neode.sk/docs/operations/reverse-proxy-tls"
    echo ""
    print_warning "Configure your proxy, then open https://${panel_host}/ (not :5443)"
    if [ "$panel_host" != "$server_id" ]; then
        print_info "RustDesk clients: ID server ${server_id} (set PUBLIC_SERVER_ID in .env)"
    fi

    REVERSE_PROXY_GENERATED_HOST="$panel_host"
    REVERSE_PROXY_GENERATED_SERVER_ID="$server_id"
    REVERSE_PROXY_GENERATED_WS_ORIGINS="$ws_origins"
    REVERSE_PROXY_PANEL_BIND="$panel_bind"
    REVERSE_PROXY_UPSTREAM_ADDR="$upstream_addr"
}

# Interactive reverse-proxy wizard: apply NeoDesk settings + emit proxy snippets.
do_configure_reverse_proxy() {
    local panel_host server_id ws_origins panel_bind

    echo ""
    print_step "Configuring NeoDesk for external reverse proxy (TLS at Caddy/Nginx)..."
    print_info "Your proxy terminates TLS on :443; NeoDesk panel stays plain HTTP"
    echo ""

    read -p "Public panel hostname (e.g., console.example.com): " panel_host
    if [ -z "$panel_host" ]; then
        print_error "Hostname is required"
        return 1
    fi

    if ! generate_reverse_proxy_config "$panel_host" "prompt" "prompt" ""; then
        return 1
    fi

    server_id="${REVERSE_PROXY_GENERATED_SERVER_ID:-$panel_host}"
    ws_origins="${REVERSE_PROXY_GENERATED_WS_ORIGINS:-https://${panel_host}}"
    panel_bind="${REVERSE_PROXY_PANEL_BIND:-127.0.0.1}"

    apply_console_reverse_proxy_mode "$panel_host" "$server_id" "$ws_origins" "$panel_bind"
    # A proxy on another machine still needs the console's port
    [ "$panel_bind" = "0.0.0.0" ] || close_console_firewall_ports

    print_success "NeoDesk configured for external reverse proxy"
    echo ""
    if [ "$panel_bind" = "0.0.0.0" ]; then
        print_info "  Panel (bind):   http://0.0.0.0:$(resolve_panel_http_port) (remote proxy host)"
        print_info "  Proxy upstream: http://${REVERSE_PROXY_UPSTREAM_ADDR:-<lan-ip>}:$(resolve_panel_http_port)"
    else
        print_info "  Panel (local):  http://127.0.0.1:$(resolve_panel_http_port)"
    fi
    print_info "  Panel (public): https://${panel_host}/"
    print_info "  TRUST_PROXY:    Y (console + Go server)"
    if [ "$panel_bind" = "0.0.0.0" ]; then
        print_info "  TRUSTED_PROXIES: set to your reverse-proxy IP/CIDR in .env (required for Go WSS)"
    else
        print_info "  TRUSTED_PROXIES: 127.0.0.1/32,::1/128 (same-host)"
    fi
    print_info "  Signal/Relay:   TCP :21116 / :21117 (direct — not HTTP-proxied)"
    echo ""
    print_info "Copy proxy snippet from $RUSTDESK_PATH/reverse-proxy/ into Caddy/Nginx, then reload the proxy."
}

# The console's HTTP port (the redirect when HTTPS is on): CONSOLE_PORT for
# the server with its console, PORT for the Node.js console; default
# CONSOLE_DEFAULT_PORT (3375 since 3.6.0-rc.5, 5000 before).
resolve_panel_http_port() {
    local port=""
    is_go_only_install && port=$(read_effective_console_setting CONSOLE_PORT "")
    [ -n "$port" ] || port=$(read_effective_console_setting PORT "$CONSOLE_DEFAULT_PORT")
    echo "$port"
}

# HTTPS panel listen port (HTTPS_PORT, default 5443 — never conflated with PORT).
resolve_panel_https_port() {
    read_effective_console_setting HTTPS_PORT 5443
}

# Offer native HTTPS on standard port 443 after enabling TLS.
maybe_offer_standard_https_port() {
    local env_file="${CONSOLE_PATH}/.env"
    local current_https_port

    current_https_port=$(read_effective_console_setting HTTPS_PORT 5443)
    [ "$current_https_port" = "443" ] && return 0

    echo ""
    print_info "Panel HTTPS defaults to port 5443 (avoids conflicts with nginx/certbot on :443)."
    if confirm "Use standard HTTPS port 443 (https://your-domain without :5443)?"; then
        _upsert_env_line "$env_file" HTTPS_PORT 443
        set_panel_http_port 80
        _upsert_env_line "$env_file" HTTP_REDIRECT_HTTPS true
        # Ports below 1024 need CAP_NET_BIND_SERVICE in the unit
        if is_go_only_install; then
            maybe_update_services >/dev/null
        fi
        ensure_service_user >/dev/null
        print_success "Standard ports configured: HTTPS :443, HTTP redirect :80"
        print_info "Ensure nothing else listens on :443/:80; open firewall: ufw allow 443/tcp (and 80/tcp if redirecting)"
    fi
}

# True when Client API (:21121) should be probed over HTTPS (RUSTDESK_API_TLS + cert present).
client_api_should_use_tls() {
    local mode cert_path key_path
    mode=$(read_effective_console_setting RUSTDESK_API_TLS auto)
    mode=$(echo "$mode" | tr '[:upper:]' '[:lower:]')
    if [ "$mode" = "false" ] || [ "$mode" = "0" ] || [ "$mode" = "off" ] || [ "$mode" = "http" ]; then
        return 1
    fi
    cert_path=$(read_effective_console_setting SSL_CERT_PATH "")
    key_path=$(read_effective_console_setting SSL_KEY_PATH "")
    if [ -z "$cert_path" ] || [ ! -f "$cert_path" ] || [ -z "$key_path" ] || [ ! -f "$key_path" ]; then
        return 1
    fi
    if [ "$mode" = "true" ] || [ "$mode" = "1" ] || [ "$mode" = "on" ] || [ "$mode" = "https" ]; then
        return 0
    fi
    # auto — certs present
    return 0
}

# Before a start: the server's files belong to the service account and the
# TLS files it needs are readable.
prepare_console_after_update() {
    is_go_only_install || return 0
    systemctl reset-failed "$SERVER_SERVICE" 2>/dev/null || true
    repair_https_stuck_state yes || true
    set_server_folder_permissions
    ensure_console_tls_material_readable 2>/dev/null || true
    return 0
}

# Start neodesk-server and check that it answers.
start_services_with_verification() {
    print_step "Starting neodesk-server with health verification..."

    local has_errors=false
    if ! systemctl is-active --quiet "$SERVER_SERVICE" 2>/dev/null; then
        if ! check_port_available "21116" "signal"; then
            print_error "Port 21116 (ID server) is not available"
            has_errors=true
        fi
        if ! check_port_available "21117" "relay"; then
            print_error "Port 21117 (relay) is not available"
            has_errors=true
        fi
    fi
    if [ "$has_errors" = true ]; then
        print_error "Cannot start neodesk-server - ports are in use"
        print_info "Try: sudo lsof -i :21116 and sudo lsof -i :21117 to find conflicts"
        return 1
    fi

    prepare_console_after_update || print_warning "Preparing the start reported issues (continuing)"
    systemctl enable "$SERVER_SERVICE" 2>/dev/null || true
    if systemctl is-active --quiet "$SERVER_SERVICE" 2>/dev/null; then
        systemctl restart "$SERVER_SERVICE" || true
    else
        systemctl start "$SERVER_SERVICE" || true
    fi

    if ! verify_go_install 90; then
        print_error "neodesk-server did not come up"
        print_info "Run: journalctl -u neodesk-server -n 50 --no-pager"
        return 1
    fi
    print_success "neodesk-server started and verified"
    return 0
}

#===============================================================================
# Detection Functions
#===============================================================================

detect_installation() {
    INSTALL_STATUS="none"
    HBBS_RUNNING=false
    HBBR_RUNNING=false
    CONSOLE_RUNNING=false
    BINARIES_OK=false
    DATABASE_OK=false
    CONSOLE_TYPE="none"
    
    # Check paths
    if [ -d "$RUSTDESK_PATH" ]; then
        INSTALL_STATUS="partial"
        
        # Check Go server binary (primary) or legacy Rust binaries
        if [ -f "$RUSTDESK_PATH/neodesk-server" ]; then
            BINARIES_OK=true
            SERVER_TYPE="go"
        elif [ -f "$RUSTDESK_PATH/hbbs" ] || [ -f "$RUSTDESK_PATH/hbbs-v8-api" ]; then
            BINARIES_OK=true
            SERVER_TYPE="rust"
            print_warning "Legacy Rust binaries detected. Consider upgrading to Go server."
        fi
        
        # Check database (SQLite file or PostgreSQL connection)
        if [ "$(env_database_type "$CONSOLE_PATH/.env")" = "postgres" ]; then
            local pg_uri
            pg_uri=$(env_database_url "$CONSOLE_PATH/.env")
            if [ -n "$pg_uri" ]; then
                if PGCONNECT_TIMEOUT=3 psql "$pg_uri" -c "SELECT 1" &>/dev/null 2>&1; then
                    DATABASE_OK=true
                fi
            fi
        else
            # SQLite: check file exists
            if [ -f "$DB_PATH" ]; then
                DATABASE_OK=true
            fi
        fi
    fi
    
    # Detect console type: the console inside the server, or the old Node.js one
    if [ -d "$CONSOLE_PATH" ]; then
        if is_go_only_install && [ -f "$CONSOLE_PATH/.env" ]; then
            CONSOLE_TYPE="go"
        elif [ -f "$CONSOLE_PATH/server.js" ] || [ -f "$CONSOLE_PATH/package.json" ]; then
            CONSOLE_TYPE="nodejs"
        fi

        if [ "$CONSOLE_TYPE" != "none" ] && [ "$BINARIES_OK" = true ] && [ "$DATABASE_OK" = true ]; then
            INSTALL_STATUS="complete"
        fi
    fi
    
    # Check services (Go server or legacy Rust)
    if systemctl is-active --quiet neodesk-server 2>/dev/null; then
        HBBS_RUNNING=true
        HBBR_RUNNING=true  # Go server handles both
    elif systemctl is-active --quiet rustdesksignal 2>/dev/null || \
         systemctl is-active --quiet hbbs 2>/dev/null; then
        HBBS_RUNNING=true
    fi
    
    if ! [ "$HBBR_RUNNING" = true ]; then
        if systemctl is-active --quiet rustdeskrelay 2>/dev/null || \
           systemctl is-active --quiet hbbr 2>/dev/null; then
            HBBR_RUNNING=true
        fi
    fi
    
    if [ "$CONSOLE_TYPE" = "go" ]; then
        if [ "$HBBS_RUNNING" = true ] && [ "$(read_effective_console_setting CONSOLE_PORT "$CONSOLE_DEFAULT_PORT")" != "0" ]; then
            CONSOLE_RUNNING=true
        fi
    elif systemctl is-active --quiet "$LEGACY_CONSOLE_SERVICE" 2>/dev/null; then
        CONSOLE_RUNNING=true
    fi
}

# Preserve database configuration from existing .env file
# This MUST be called before the .env is written during UPDATE/REPAIR
# to prevent switching from PostgreSQL to SQLite
preserve_database_config() {
    if [ -f "$CONSOLE_PATH/.env" ]; then
        if [ "$(env_database_type "$CONSOLE_PATH/.env")" = "postgres" ]; then
            USE_POSTGRESQL="true"
            POSTGRESQL_URI=$(env_database_url "$CONSOLE_PATH/.env")
            print_info "Preserving PostgreSQL configuration from existing .env"
        else
            USE_POSTGRESQL="false"
            POSTGRESQL_URI=""
            print_info "Preserving SQLite configuration from existing .env"
        fi
    fi
}

# Write or merge the console's .env from the template built into the server,
# then let upgrade-env add what the server needs (CONSOLE_PORT,
# NEODESK_ENV_FILE, the pinned ports) and comment out what it does not.
# Usage: merge_console_env true   — fresh install (full template)
#        merge_console_env false  — update (append missing keys only)
merge_console_env() {
    local fresh_install="${1:-false}"
    local ssl_dir="$RUSTDESK_PATH/ssl"
    local env_file="$CONSOLE_PATH/.env"
    local db_type="sqlite"
    local database_url=""
    local admin_password="${ADMIN_PASSWORD:-}"
    local session_secret=""
    local remote_target_vault_key=""
    local go_port="${GO_API_PORT:-21114}"
    local client_port="${CLIENT_API_PORT:-21121}"
    local bin
    bin=$(server_binary_path)

    if ! binary_has_subcommands "$bin"; then
        print_error "$bin is missing or too old to write .env"
        return 1
    fi

    if [ "$USE_POSTGRESQL" = "true" ] && [ -n "$POSTGRESQL_URI" ]; then
        db_type="postgres"
        database_url="$POSTGRESQL_URI"
    else
        database_url="$RUSTDESK_PATH/db_v2.sqlite3"
    fi

    if [ "$fresh_install" = "true" ]; then
        if [ -z "$admin_password" ]; then
            admin_password=$(openssl rand -hex 16)
        fi
        session_secret=$(openssl rand -hex 32)
    else
        session_secret=$(env_file_value "$env_file" SESSION_SECRET)
        if [ -z "$admin_password" ]; then
            admin_password=$(env_file_value "$env_file" DEFAULT_ADMIN_PASSWORD)
        fi
        if [ -z "$session_secret" ]; then
            session_secret=$(openssl rand -hex 32)
        fi
    fi
    remote_target_vault_key=$(env_file_value "$env_file" REMOTE_TARGET_VAULT_KEY)
    if [ -z "$remote_target_vault_key" ]; then
        remote_target_vault_key=$(openssl rand -hex 32)
    fi

    local -a merge_args=(env merge --target "$env_file" --subst-env)
    [ "$fresh_install" = "true" ] && merge_args+=(--fresh)

    local merge_output=""
    if ! merge_output=$(NEODESK_ENV_FILE='' \
        ND_SUBST_RUSTDESK_DIR="$RUSTDESK_PATH" \
        ND_SUBST_PUB_KEY_PATH="$RUSTDESK_PATH/id_ed25519.pub" \
        ND_SUBST_API_KEY_PATH="$RUSTDESK_PATH/.api_key" \
        ND_SUBST_DB_TYPE="$db_type" \
        ND_SUBST_DB_PATH="$RUSTDESK_PATH/db_v2.sqlite3" \
        ND_SUBST_DATABASE_URL="$database_url" \
        ND_SUBST_DATA_DIR="$CONSOLE_PATH/data" \
        ND_SUBST_GO_API_PORT="$go_port" \
        ND_SUBST_HBBS_API_URL="http://localhost:${go_port}/api" \
        ND_SUBST_NEODESK_API_URL="http://localhost:${go_port}/api" \
        ND_SUBST_API_PORT="$client_port" \
        ND_SUBST_DEFAULT_ADMIN_PASSWORD="$admin_password" \
        ND_SUBST_SESSION_SECRET="$session_secret" \
        ND_SUBST_REMOTE_TARGET_VAULT_KEY="$remote_target_vault_key" \
        ND_SUBST_GUACD_ADDRESS="127.0.0.1:4822" \
        ND_SUBST_SSL_CERT_PATH="$ssl_dir/neodesk.crt" \
        ND_SUBST_SSL_KEY_PATH="$ssl_dir/neodesk.key" \
        "$bin" "${merge_args[@]}" 2>&1) || ! printf '%s' "$merge_output" | grep -q '"success":true'; then
        print_error "Failed to write .env (neodesk-server env merge)"
        [ -n "$merge_output" ] && print_info "$merge_output"
        return 1
    fi

    # The server's database is DATABASE_URL (the template's, filled above).
    # A file that names none gets it; an older binary reads DB_URL instead
    # (its template still writes DB_TYPE), which the old units passed as -db
    if ! binary_reads_database_url "$bin"; then
        grep -q '^DB_URL=' "$env_file" || printf 'DB_URL=%s\n' "$database_url" >> "$env_file"
    elif [ -z "$(env_database_url "$env_file")" ]; then
        use_database_in_env "$db_type" "$database_url"
    fi
    # The server makes the first admin before the console starts, and the
    # console keeps an admin it did not make: both take the same password
    if [ "$fresh_install" = "true" ] && ! grep -q '^INIT_ADMIN_PASS=' "$env_file"; then
        printf 'INIT_ADMIN_PASS=%s\n' "$admin_password" >> "$env_file"
    fi
    # A new install starts in Managed: new clients wait for approval. This
    # is only the first default; a mode saved in the console wins.
    if [ "$fresh_install" = "true" ] && ! grep -q '^ENROLLMENT_MODE=' "$env_file"; then
        printf 'ENROLLMENT_MODE=managed\n' >> "$env_file"
    fi
    # The update channel the installer was given, over the template's main
    save_given_update_channel

    if ! NEODESK_ENV_FILE='' "$bin" upgrade-env --from "$env_file" --write --supervisor systemd >/dev/null; then
        print_error "neodesk-server upgrade-env could not finish .env"
        return 1
    fi
    # A fresh file has no older version to keep
    [ "$fresh_install" = "true" ] && rm -f "$env_file.pre-go"

    chmod 600 "$env_file" 2>/dev/null || true
    if [ "$fresh_install" = "true" ]; then
        print_info "Created .env configuration file (fresh install)"
    else
        print_info "Merged new .env keys (existing settings preserved)"
    fi
    return 0
}

detect_architecture() {
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64) ARCH_NAME="x86_64" ;;
        aarch64|arm64) ARCH_NAME="aarch64" ;;
        armv7l) ARCH_NAME="armv7" ;;
        *) ARCH_NAME="unknown" ;;
    esac
}

detect_os() {
    if [ -f /etc/os-release ]; then
        OS_NAME=$(grep -m1 '^NAME=' /etc/os-release | cut -d= -f2- | sed 's/^"//; s/"$//' || echo "Unknown")
        OS_VERSION=$(grep -m1 '^VERSION_ID=' /etc/os-release | cut -d= -f2- | sed 's/^"//; s/"$//' || echo "")
    else
        OS_NAME="Unknown"
        OS_VERSION=""
    fi
}

# Auto-detect RustDesk installation path
auto_detect_paths() {
    local found=false
    
    # If RUSTDESK_PATH is already set (via env var), validate it
    if [ -n "$RUSTDESK_PATH" ]; then
        if [ -d "$RUSTDESK_PATH" ] && { [ -f "$RUSTDESK_PATH/neodesk-server" ] || [ -f "$RUSTDESK_PATH/hbbs" ] || [ -f "$RUSTDESK_PATH/hbbs-v8-api" ]; }; then
            print_info "Using the configured server folder: $RUSTDESK_PATH"
        else
            print_warning "Configured RUSTDESK_PATH ($RUSTDESK_PATH) is invalid"
            RUSTDESK_PATH=""
        fi
    fi
    
    # Auto-detect if not found
    if [ -z "$RUSTDESK_PATH" ]; then
        for path in "${COMMON_RUSTDESK_PATHS[@]}"; do
            if [ -d "$path" ] && { [ -f "$path/neodesk-server" ] || [ -f "$path/hbbs" ] || [ -f "$path/hbbs-v8-api" ]; }; then
                RUSTDESK_PATH="$path"
                print_success "Detected the server folder: $RUSTDESK_PATH"
                break
            fi
        done
    fi
    
    # If still not found, use default for new installations
    if [ -z "$RUSTDESK_PATH" ]; then
        RUSTDESK_PATH="/opt/neodesk"
        print_info "No installation detected. Default path: $RUSTDESK_PATH"
    fi
    
    # Auto-detect the console's folder (its .env and data) and type
    CONSOLE_TYPE="none"

    if [ -n "$CONSOLE_PATH" ]; then
        if [ -d "$CONSOLE_PATH" ] && { [ -f "$CONSOLE_PATH/.env" ] || [ -f "$CONSOLE_PATH/server.js" ]; }; then
            print_info "Using configured console path: $CONSOLE_PATH"
        else
            print_warning "Configured CONSOLE_PATH ($CONSOLE_PATH) is invalid"
            CONSOLE_PATH=""
        fi
    fi

    # The server's unit names the console's env file
    if [ -z "$CONSOLE_PATH" ] && is_go_only_install; then
        local env_from_unit
        env_from_unit=$(unit_env_value "$SERVER_UNIT" NEODESK_ENV_FILE)
        if [ -n "$env_from_unit" ] && [ -f "$env_from_unit" ]; then
            CONSOLE_PATH=$(dirname "$env_from_unit")
            print_success "Detected the console folder: $CONSOLE_PATH"
        fi
    fi

    if [ -z "$CONSOLE_PATH" ]; then
        for path in "${COMMON_CONSOLE_PATHS[@]}"; do
            if [ -d "$path" ] && { [ -f "$path/.env" ] || [ -f "$path/server.js" ]; }; then
                CONSOLE_PATH="$path"
                print_success "Detected the console folder: $CONSOLE_PATH"
                break
            fi
        done
    fi
    if is_go_only_install; then
        CONSOLE_TYPE="go"
    elif [ -n "$CONSOLE_PATH" ] && [ -f "$CONSOLE_PATH/server.js" ]; then
        CONSOLE_TYPE="nodejs"
    fi
    
    # Default Console path if not found
    if [ -z "$CONSOLE_PATH" ]; then
        CONSOLE_PATH="/opt/NeoDeskConsole"
    fi
    
    # Update DB_PATH based on detected RUSTDESK_PATH
    DB_PATH="$RUSTDESK_PATH/db_v2.sqlite3"
    
    return 0
}

# Interactive path configuration
configure_paths() {
    local _menu_items=(
        $'Auto-detect paths\tScan common install locations'
        $'Set server folder\tManually set the server folder (keys, database, binary)'
        $'Set console path\tManually set the web console path'
        $'Reset to defaults\t/opt/neodesk + /opt/NeoDeskConsole'
        $'Back\tReturn to the main menu'
    )
    local _menu_returns=( 1 2 3 4 0 )
    local subtitle="server: ${RUSTDESK_PATH:-unset} | console: ${CONSOLE_PATH:-unset}"
    menu_choose "Path Configuration" "$subtitle"
    local choice="$MENU_CHOICE"

    case $choice in
        1)
            RUSTDESK_PATH=""
            CONSOLE_PATH=""
            auto_detect_paths
            press_enter
            configure_paths
            ;;
        2)
            echo ""
            echo -n "Enter the server folder (e.g., /opt/neodesk): "
            read -r new_path
            if [ -n "$new_path" ]; then
                if [ -d "$new_path" ]; then
                    RUSTDESK_PATH="$new_path"
                    DB_PATH="$RUSTDESK_PATH/db_v2.sqlite3"
                    print_success "Server folder set to: $RUSTDESK_PATH"
                else
                    print_warning "Directory does not exist: $new_path"
                    if confirm "Create this directory?"; then
                        mkdir -p "$new_path"
                        RUSTDESK_PATH="$new_path"
                        DB_PATH="$RUSTDESK_PATH/db_v2.sqlite3"
                        print_success "Created and set the server folder: $RUSTDESK_PATH"
                    fi
                fi
            fi
            press_enter
            configure_paths
            ;;
        3)
            echo ""
            echo -n "Enter Console path (e.g., /opt/NeoDeskConsole): "
            read -r new_path
            if [ -n "$new_path" ]; then
                if [ -d "$new_path" ]; then
                    CONSOLE_PATH="$new_path"
                    print_success "Console path set to: $CONSOLE_PATH"
                else
                    print_warning "Directory does not exist: $new_path"
                    if confirm "Create this directory?"; then
                        mkdir -p "$new_path"
                        CONSOLE_PATH="$new_path"
                        print_success "Created and set Console path: $CONSOLE_PATH"
                    fi
                fi
            fi
            press_enter
            configure_paths
            ;;
        4)
            RUSTDESK_PATH="/opt/neodesk"
            CONSOLE_PATH="/opt/NeoDeskConsole"
            DB_PATH="$RUSTDESK_PATH/db_v2.sqlite3"
            print_success "Paths reset to defaults"
            press_enter
            configure_paths
            ;;
        0|"")
            return
            ;;
        *)
            print_error "Invalid option"
            press_enter
            configure_paths
            ;;
    esac
}

print_status() {
    detect_installation
    detect_architecture
    detect_os
    
    echo ""
    echo -e "${WHITE}${BOLD}═══ System Status ═══${NC}"
    echo ""
    echo -e "  System:       ${CYAN}$OS_NAME $OS_VERSION${NC}"
    echo -e "  Architecture: ${CYAN}$ARCH_NAME${NC}"
    echo ""
    
    echo -e "${WHITE}${BOLD}═══ Configured Paths ═══${NC}"
    echo ""
    echo -e "  Server:       ${CYAN}$RUSTDESK_PATH${NC}"
    echo -e "  Console:      ${CYAN}$CONSOLE_PATH${NC}"
    
    # Show database type and path/URI
    if [ "$(env_database_type "$CONSOLE_PATH/.env")" = "postgres" ]; then
        local diag_pg_uri
        diag_pg_uri=$(env_database_url "$CONSOLE_PATH/.env")
        # Mask password in URI for display
        local diag_pg_display
        diag_pg_display=$(echo "$diag_pg_uri" | sed 's|://[^:]*:[^@]*@|://***:***@|')
        echo -e "  Database:     ${CYAN}PostgreSQL${NC} ($diag_pg_display)"
    else
        echo -e "  Database:     ${CYAN}SQLite${NC} ($DB_PATH)"
    fi
    echo ""
    
    echo -e "${WHITE}${BOLD}═══ Installation Status ═══${NC}"
    echo ""
    
    # Installation status
    case "$INSTALL_STATUS" in
        "complete")
            echo -e "  Status:       ${GREEN}✓ Installed${NC}"
            ;;
        "partial")
            echo -e "  Status:       ${YELLOW}! Partial installation${NC}"
            ;;
        "none")
            echo -e "  Status:       ${RED}✗ Not installed${NC}"
            ;;
    esac
    
    # Components
    if [ "$BINARIES_OK" = true ]; then
        echo -e "  Binaries:      ${GREEN}✓ OK${NC}"
    else
        echo -e "  Binaries:      ${RED}✗ Not found${NC}"
    fi
    
    if [ "$DATABASE_OK" = true ]; then
        echo -e "  Database:  ${GREEN}✓ OK${NC}"
    else
        echo -e "  Database:  ${RED}✗ Not found${NC}"
    fi
    
    if [ -d "$CONSOLE_PATH" ]; then
        case "$CONSOLE_TYPE" in
            go) echo -e "  Web Console:  ${GREEN}✓ OK${NC} (inside neodesk-server)" ;;
            nodejs) echo -e "  Web Console:  ${YELLOW}! Node.js${NC} (this installer does not upgrade it)" ;;
            *) echo -e "  Web Console:  ${GREEN}✓ OK${NC}" ;;
        esac
    else
        echo -e "  Web Console:  ${RED}✗ Not found${NC}"
    fi
    
    echo ""
    echo -e "${WHITE}${BOLD}═══ Services Status ═══${NC}"
    echo ""
    
    # Check if using Go server (single binary) or legacy Rust (two binaries)
    if [ "${SERVER_TYPE:-}" = "go" ] || systemctl is-active --quiet neodesk-server 2>/dev/null; then
        local go_state
        go_state=$(systemctl show neodesk-server --property=ActiveState --value 2>/dev/null || echo "unknown")
        case "$go_state" in
            active)
                echo -e "  NeoDesk Server: ${GREEN}● Active${NC} (Signal + Relay + API$([ "$CONSOLE_TYPE" = go ] && [ "$CONSOLE_RUNNING" = true ] && echo " + web console"))"
                ;;
            failed)
                echo -e "  NeoDesk Server: ${RED}✗ Failed${NC} (check: journalctl -u neodesk-server -n 30)"
                ;;
            activating)
                echo -e "  NeoDesk Server: ${YELLOW}◌ Starting...${NC}"
                ;;
            *)
                echo -e "  NeoDesk Server: ${RED}○ Inactive${NC} ($go_state)"
                ;;
        esac
    else
        # Legacy Rust servers
        if [ "$HBBS_RUNNING" = true ]; then
            echo -e "  ID server:     ${GREEN}● Active${NC} ${YELLOW}(legacy Rust server)${NC}"
        else
            echo -e "  ID server:     ${RED}○ Inactive${NC}"
        fi
        
        if [ "$HBBR_RUNNING" = true ]; then
            echo -e "  Relay:         ${GREEN}● Active${NC} ${YELLOW}(legacy Rust server)${NC}"
        else
            echo -e "  Relay:         ${RED}○ Inactive${NC}"
        fi
    fi
    
    # The old Node.js console, while an install still has it
    if [ "$CONSOLE_TYPE" = "nodejs" ]; then
        local console_state
        console_state=$(systemctl show "$LEGACY_CONSOLE_SERVICE" --property=ActiveState --value 2>/dev/null || echo "unknown")
        case "$console_state" in
            active) echo -e "  Web Console (Node.js): ${GREEN}● Active${NC}" ;;
            failed) echo -e "  Web Console (Node.js): ${RED}✗ Failed${NC} (check: journalctl -u neodesk-server -n 30)" ;;
            *) echo -e "  Web Console (Node.js): ${RED}○ Inactive${NC} ($console_state)" ;;
        esac
    fi
    
    echo ""
}

#===============================================================================
# Go Installation and Compilation
#===============================================================================

# Extract numeric semver component (handles "1.25+", "26rc1", etc.).
_go_version_part() {
    local ver="$1" field="${2:-1}"
    local part
    part=$(echo "$ver" | cut -d'.' -f"$field" | grep -oE '^[0-9]+' | head -1)
    echo "${part:-0}"
}

check_go_installed() {
    if command -v go &> /dev/null; then
        local go_version
        go_version=$(go version | awk '{print $3}' | sed 's/go//')
        local go_major=$(_go_version_part "$go_version" 1)
        local go_minor=$(_go_version_part "$go_version" 2)
        local go_patch=$(_go_version_part "$go_version" 3)
        local min_major=$(_go_version_part "$GO_MIN_VERSION" 1)
        local min_minor=$(_go_version_part "$GO_MIN_VERSION" 2)
        local min_patch=$(_go_version_part "$GO_MIN_VERSION" 3)

        # Security hardening: reject vulnerable Go 1.26.0 stdlib.
        if [ "$go_major" -eq 1 ] && [ "$go_minor" -eq 26 ] && [ "$go_patch" -eq 0 ]; then
            print_warning "Detected vulnerable Go version $go_version (known stdlib CVEs)."
            return 1
        fi
        
        if [ "$go_major" -gt "$min_major" ] ||
           ([ "$go_major" -eq "$min_major" ] && [ "$go_minor" -gt "$min_minor" ]) ||
           ([ "$go_major" -eq "$min_major" ] && [ "$go_minor" -eq "$min_minor" ] && [ "$go_patch" -ge "$min_patch" ]); then
            return 0
        fi
    fi
    return 1
}

install_golang() {
    print_step "Installing Go $GO_MIN_VERSION+..."
    
    # Ensure architecture is detected
    if [ -z "$ARCH_NAME" ]; then
        detect_architecture
    fi
    
    if check_go_installed; then
        local go_version=$(go version | awk '{print $3}' | sed 's/go//')
        print_info "Go $go_version is already installed"
        return 0
    fi
    
    local go_version="$GO_DOWNLOAD_VERSION"
    local go_arch=""
    
    case "$ARCH_NAME" in
        x86_64) go_arch="amd64" ;;
        aarch64) go_arch="arm64" ;;
        armv7*) go_arch="armv6l" ;;
        *) print_error "Unsupported architecture: $ARCH_NAME"; return 1 ;;
    esac
    
    local go_tarball="go${go_version}.linux-${go_arch}.tar.gz"
    local go_url="https://go.dev/dl/$go_tarball"
    
    print_info "Downloading Go $go_version for $go_arch..."
    
    cd /tmp
    if command -v wget &> /dev/null; then
        wget -q --show-progress "$go_url" -O "$go_tarball" || wget "$go_url" -O "$go_tarball"
    elif command -v curl &> /dev/null; then
        curl -fSL --progress-bar "$go_url" -o "$go_tarball"
    else
        print_error "Neither wget nor curl available"
        return 1
    fi
    
    print_info "Installing Go to /usr/local/go..."
    rm -rf /usr/local/go
    tar -C /usr/local -xzf "$go_tarball"
    rm "$go_tarball"
    
    # Add to PATH for current session
    export PATH=$PATH:/usr/local/go/bin
    
    # Add to system-wide PATH
    if [ ! -f /etc/profile.d/go.sh ]; then
        echo 'export PATH=$PATH:/usr/local/go/bin' > /etc/profile.d/go.sh
        chmod +x /etc/profile.d/go.sh
    fi
    
    if check_go_installed; then
        print_success "Go $go_version installed successfully"
        return 0
    else
        print_error "Go installation failed"
        return 1
    fi
}

# Probe a fixed HTTPS host without executing response body (connectivity only).
# Optional 3rd arg: curl IP family flag ("-4" or "-6"); empty = dual-stack default.
_go_probe_https() {
    local url="$1"
    local limit="${2:-$GO_MODULE_PREFLIGHT_TIMEOUT}"
    local ip_flag="${3:-}"

    if command -v curl &> /dev/null; then
        # No -f: any HTTP response means the TCP/TLS path works (404 is fine).
        # shellcheck disable=SC2086
        curl -sS -o /dev/null --connect-timeout "$limit" --max-time "$limit" $ip_flag "$url"
        return $?
    fi
    if command -v wget &> /dev/null; then
        # wget has no reliable -4/-6 on all distros; dual-stack only.
        wget -q --spider --timeout="$limit" --tries=1 "$url"
        return $?
    fi
    return 2
}

# Read a sysctl value or echo "unknown".
_go_sysctl_get() {
    local key="$1"
    if command -v sysctl &> /dev/null; then
        sysctl -n "$key" 2>/dev/null || echo "unknown"
    else
        echo "unknown"
    fi
}

# Temporarily disable IPv6 for Go dual-stack dials on broken-IPv6 VMs (save/restore).
_go_ipv4_force_begin() {
    GO_IPV4_SAVED_ALL=""
    GO_IPV4_SAVED_DEFAULT=""
    GO_IPV4_APPLIED=0

    if [ "${GO_FORCE_IPV4:-0}" != "1" ]; then
        return 0
    fi
    if ! command -v sysctl &> /dev/null; then
        print_warning "Broken IPv6 detected but sysctl unavailable; cannot force IPv4 for Go"
        return 0
    fi

    GO_IPV4_SAVED_ALL=$(_go_sysctl_get net.ipv6.conf.all.disable_ipv6)
    GO_IPV4_SAVED_DEFAULT=$(_go_sysctl_get net.ipv6.conf.default.disable_ipv6)

    if sysctl -w net.ipv6.conf.all.disable_ipv6=1 >/dev/null 2>&1 \
        && sysctl -w net.ipv6.conf.default.disable_ipv6=1 >/dev/null 2>&1; then
        GO_IPV4_APPLIED=1
        print_info "Temporarily disabled IPv6 for Go module download (broken IPv6 path detected)"
    else
        print_warning "Could not disable IPv6 via sysctl; Go may still hang on AAAA dials"
    fi
}

_go_ipv4_force_end() {
    if [ "${GO_IPV4_APPLIED:-0}" != "1" ]; then
        return 0
    fi
    if [ -n "${GO_IPV4_SAVED_ALL}" ] && [ "${GO_IPV4_SAVED_ALL}" != "unknown" ]; then
        sysctl -w "net.ipv6.conf.all.disable_ipv6=${GO_IPV4_SAVED_ALL}" >/dev/null 2>&1 || true
    fi
    if [ -n "${GO_IPV4_SAVED_DEFAULT}" ] && [ "${GO_IPV4_SAVED_DEFAULT}" != "unknown" ]; then
        sysctl -w "net.ipv6.conf.default.disable_ipv6=${GO_IPV4_SAVED_DEFAULT}" >/dev/null 2>&1 || true
    fi
    GO_IPV4_APPLIED=0
    print_info "Restored previous IPv6 sysctl settings"
}

# Drop leftover partial/lock files from a previous Ctrl+C during go mod download.
_go_clear_stale_module_partials() {
    local modcache
    modcache=$(go env GOMODCACHE 2>/dev/null || true)
    if [ -z "$modcache" ] || [ ! -d "$modcache" ]; then
        return 0
    fi
    local cleared=0
    cleared=$(find "$modcache" \( -name '*.partial' -o -name '*.lock' \) 2>/dev/null | wc -l | tr -d ' ')
    if [ "${cleared:-0}" -gt 0 ] 2>/dev/null; then
        print_warning "Removing ${cleared} stale Go module cache lock/partial file(s) from a prior interrupted download"
        find "$modcache" \( -name '*.partial' -o -name '*.lock' \) -delete 2>/dev/null || true
    fi
}

# Fail fast when proxy.golang.org / sum.golang.org are unreachable.
# Prefer IPv4 probes; set GO_FORCE_IPV4=1 when IPv6 is broken but IPv4 works.
_go_module_network_preflight() {
    local limit="${GO_MODULE_PREFLIGHT_TIMEOUT}"
    local probe_status=0
    local ipv4_ok=0
    local ipv6_ok=0

    GO_FORCE_IPV4=0
    print_info "Checking HTTPS reachability of Go module endpoints (${limit}s)..."

    if ! command -v curl &> /dev/null && ! command -v wget &> /dev/null; then
        print_warning "Neither curl nor wget available; skipping Go module network preflight"
        return 0
    fi

    if command -v curl &> /dev/null; then
        if _go_probe_https "https://proxy.golang.org/" "$limit" "-4"; then
            ipv4_ok=1
            print_success "Reachable via IPv4: proxy.golang.org"
        else
            print_error "Cannot reach https://proxy.golang.org/ via IPv4 within ${limit}s"
        fi

        # Short IPv6 probe — failure here is common on GCP and is not fatal if IPv4 works.
        if _go_probe_https "https://proxy.golang.org/" 5 "-6"; then
            ipv6_ok=1
            print_success "Reachable via IPv6: proxy.golang.org"
        else
            print_warning "IPv6 path to proxy.golang.org failed (will prefer IPv4 for Go if IPv4 works)"
        fi

        if [ "$ipv4_ok" -eq 1 ] && [ "$ipv6_ok" -eq 0 ]; then
            GO_FORCE_IPV4=1
            print_info "Broken IPv6 detected — Go module download will temporarily disable IPv6"
        fi

        if [ "$ipv4_ok" -ne 1 ]; then
            # Last resort: dual-stack (some hosts lack curl -4).
            if _go_probe_https "https://proxy.golang.org/" "$limit"; then
                print_success "Reachable (dual-stack): proxy.golang.org"
            else
                probe_status=1
            fi
        fi

        if ! _go_probe_https "https://sum.golang.org/" "$limit" "-4" \
            && ! _go_probe_https "https://sum.golang.org/" "$limit"; then
            print_error "Cannot reach https://sum.golang.org/ within ${limit}s"
            probe_status=1
        else
            print_success "Reachable: sum.golang.org"
        fi

        # GET a tiny known proxy path so HEAD-only reachability cannot hide a hung download path.
        if [ "$probe_status" -eq 0 ]; then
            print_info "Probing Go module proxy GET (sample @v/list)..."
            if ! curl -4 -sS -o /dev/null --connect-timeout "$limit" --max-time 30 \
                "https://proxy.golang.org/github.com/google/uuid/@v/list"; then
                print_error "Go module proxy GET probe failed within 30s"
                print_error "HEAD may work while module downloads hang — check firewall/DPI/IPv6"
                probe_status=1
            else
                print_success "Go module proxy GET probe OK"
            fi
        fi
    else
        if ! _go_probe_https "https://proxy.golang.org/" "$limit"; then
            print_error "Cannot reach https://proxy.golang.org/ within ${limit}s"
            probe_status=1
        else
            print_success "Reachable: proxy.golang.org"
        fi
        if ! _go_probe_https "https://sum.golang.org/" "$limit"; then
            print_error "Cannot reach https://sum.golang.org/ within ${limit}s"
            probe_status=1
        else
            print_success "Reachable: sum.golang.org"
        fi
    fi

    if [ "$probe_status" -ne 0 ]; then
        print_error "Outbound HTTPS to the Go module proxy/checksum DB is blocked or timing out"
        print_error "On cloud VMs check DNS, firewall/egress, IPv6 blackholes, and GOPROXY — then retry"
        print_error "Override example: GOPROXY=https://proxy.golang.org,direct"
        return 1
    fi
    return 0
}

# Kill a process group (negative PGID) with TERM then KILL.
_go_kill_process_group() {
    local pgid="$1"
    local label="${2:-process group}"

    if [ -z "$pgid" ] || [ "$pgid" -le 1 ] 2>/dev/null; then
        return 0
    fi
    print_error "Stopping ${label} (PGID ${pgid}) with SIGTERM..."
    kill -TERM -- "-${pgid}" 2>/dev/null || kill -TERM "$pgid" 2>/dev/null || true
    sleep 2
    if kill -0 "$pgid" 2>/dev/null; then
        print_error "Still alive — sending SIGKILL to PGID ${pgid}"
        kill -KILL -- "-${pgid}" 2>/dev/null || kill -KILL "$pgid" 2>/dev/null || true
    fi
}

# Run a Go command with a hard deadline and visible progress.
_run_go_command_bounded() {
    local label="$1"
    local deadline="$2"
    shift 2
    local command_pid=""
    local command_pgid=""
    local heartbeat_pid=""
    local elapsed=0
    local status=0
    local heartbeat_interval="${GO_COMMAND_HEARTBEAT_INTERVAL}"
    local kill_after="${GO_COMMAND_KILL_AFTER}"

    case "$heartbeat_interval" in
        ''|*[!0-9]*) heartbeat_interval=15 ;;
    esac
    case "$kill_after" in
        ''|*[!0-9]*) kill_after=15 ;;
    esac

    if command -v setsid &> /dev/null; then
        setsid "$@" &
    else
        "$@" &
    fi
    command_pid=$!

    if command -v ps &> /dev/null; then
        command_pgid=$(ps -o pgid= -p "$command_pid" 2>/dev/null | tr -d ' ' || true)
        case "$command_pgid" in
            ''|*[!0-9]*) command_pgid="" ;;
        esac
    fi

    print_info "${label} started (PID ${command_pid}, deadline ${deadline}s)"

    (
        heartbeat_elapsed=0
        while kill -0 "$command_pid" 2>/dev/null; do
            sleep "$heartbeat_interval"
            if ! kill -0 "$command_pid" 2>/dev/null; then
                break
            fi
            heartbeat_elapsed=$((heartbeat_elapsed + heartbeat_interval))
            printf 'i  still %s... %ss elapsed (watchdog active)\n' \
                "$label" "$heartbeat_elapsed" >&2
        done
    ) &
    heartbeat_pid=$!

    while kill -0 "$command_pid" 2>/dev/null; do
        if [ "$elapsed" -ge "$deadline" ]; then
            print_error "${label} exceeded ${deadline}s"
            if [ -n "$command_pgid" ] && [ "$command_pgid" -gt 1 ] 2>/dev/null; then
                _go_kill_process_group "$command_pgid" "$label"
            else
                kill -TERM "$command_pid" 2>/dev/null || true
                sleep "$kill_after"
                if kill -0 "$command_pid" 2>/dev/null; then
                    kill -KILL "$command_pid" 2>/dev/null || true
                fi
            fi
            status=124
            break
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done

    if [ "$status" -ne 124 ]; then
        if wait "$command_pid"; then
            status=0
        else
            status=$?
        fi
    else
        wait "$command_pid" 2>/dev/null || true
    fi

    if [ -n "$heartbeat_pid" ]; then
        kill "$heartbeat_pid" 2>/dev/null || true
        wait "$heartbeat_pid" 2>/dev/null || true
    fi

    return "$status"
}

# Run go mod download with a hard bash deadline (primary guard).
# GNU timeout alone was insufficient on some cloud VMs.
_run_go_mod_download_bounded() {
    local deadline="${GO_MODULE_DOWNLOAD_TIMEOUT}"
    local kill_after=15
    local status=0
    local download_pid=""
    local elapsed=0
    local heartbeat_pid=""

    _go_ipv4_force_begin
    _go_clear_stale_module_partials

    # Prefer IPv4 for Go's resolver when the host has broken AAAA routes.
    export GODEBUG="${GODEBUG:+$GODEBUG,}netdns=go"

    # Heartbeat — no `local` inside non-function subshell (set -e).
    (
        elapsed=0
        while true; do
            sleep 15
            elapsed=$((elapsed + 15))
            printf 'i  still downloading Go modules... %ss elapsed (watchdog active)\n' "$elapsed" >&2
        done
    ) &
    heartbeat_pid=$!

    # Run go as a direct background child of this shell (same user/session).
    # Prior setsid/pidfile races could exit the waiter early, restore IPv6, and
    # report success while go was still hung or already dead.
    (
        echo "go mod download child starting" >&2
        exec go mod download -x
    ) &
    download_pid=$!

    print_info "go mod download started (PID ${download_pid}, deadline ${deadline}s)"

    elapsed=0
    while kill -0 "$download_pid" 2>/dev/null; do
        if [ "$elapsed" -ge "$deadline" ]; then
            print_error "Go module download exceeded ${deadline}s"
            kill -TERM "$download_pid" 2>/dev/null || true
            sleep "$kill_after"
            if kill -0 "$download_pid" 2>/dev/null; then
                kill -KILL "$download_pid" 2>/dev/null || true
            fi
            status=124
            break
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done

    if [ "$status" -ne 124 ]; then
        if wait "$download_pid"; then
            status=0
        else
            status=$?
        fi
    else
        wait "$download_pid" 2>/dev/null || true
    fi

    if [ -n "$heartbeat_pid" ]; then
        kill "$heartbeat_pid" 2>/dev/null || true
        wait "$heartbeat_pid" 2>/dev/null || true
    fi

    _go_ipv4_force_end
    return "$status"
}

# embed_web_ui_build GO: copies the web app build (web-ui/build) into the
# server module, where the binary embeds it from. Without a build it makes
# one when Node.js and npm are installed; a build from source needs them.
embed_web_ui_build() {
    local go_bin="$1" web_ui="$REPO_DIR/web-ui"
    if [ ! -f "$web_ui/build/index.html" ]; then
        if ! command -v npm &>/dev/null || [ ! -f "$web_ui/package-lock.json" ]; then
            print_error "A build from source needs the web app: $web_ui/build, or Node.js 22 and npm to build it"
            return 1
        fi
        print_step "Building the web app (npm, a few minutes)..."
        if ! (cd "$web_ui" && npx -y npm@11.6.2 ci --no-audit --no-fund && npm run build) > /tmp/neodesk-web-ui-build.log 2>&1; then
            print_error "The web app build failed (log: /tmp/neodesk-web-ui-build.log)"
            return 1
        fi
    fi
    if ! _run_go_command_bounded "embedding the web app" "$GO_MODULE_GRAPH_TIMEOUT" \
        "$go_bin" run ./cmd/embed-webui -from "$web_ui/build"; then
        print_error "Could not copy the web app build into the server module"
        return 1
    fi
    print_success "Web app build embedded"
}

compile_go_server() {
    print_step "Compiling NeoDesk Go server..."
    
    if [ ! -d "$GO_SERVER_SOURCE" ]; then
        print_error "Go server source not found: $GO_SERVER_SOURCE"
        return 1
    fi
    
    # Ensure Go is available
    export PATH=$PATH:/usr/local/go/bin
    
    if ! check_go_installed; then
        if ! install_golang; then
            print_error "Go is required for compilation"
            return 1
        fi
    fi
    
    cd "$GO_SERVER_SOURCE"
    
    # Clean previous builds
    rm -f neodesk-server neodesk-server-linux-*
    
    # Build
    print_info "Building NeoDesk server for $ARCH_NAME..."
    local output_name="neodesk-server"
    local go_bin
    go_bin=$(command -v go)

    # Force local toolchain for native compile so host GOTOOLCHAIN=auto cannot
    # silently download another toolchain mid-install (hang risk on cloud VMs).
    # Override with NEODESK_GOTOOLCHAIN if needed. GOPROXY/GOSUMDB still honour env.
    export GOTOOLCHAIN="${NEODESK_GOTOOLCHAIN:-local}"
    export GOPROXY="${GOPROXY:-https://proxy.golang.org,direct}"
    export GOSUMDB="${GOSUMDB:-sum.golang.org}"

    print_info "Using $($go_bin version 2>/dev/null || echo 'unknown go')"
    print_info "GOPROXY=${GOPROXY} GOSUMDB=${GOSUMDB} GOTOOLCHAIN=${GOTOOLCHAIN}"

    if ! _go_module_network_preflight; then
        return 1
    fi

    # Download dependencies. Keep this visible and hard-bounded (bash watchdog).
    print_info "Downloading Go modules (timeout: ${GO_MODULE_DOWNLOAD_TIMEOUT}s, kill-after: 15s, process watchdog)..."
    local module_download_status=0
    # Keep the command in the if condition so `set -e` does not abort before
    # we can capture the actual watchdog/download exit status. Do not use `!`
    # here: inside its branch `$?` would be the status of the negation (0).
    if _run_go_mod_download_bounded; then
        module_download_status=0
    else
        module_download_status=$?
    fi

    if [ "$module_download_status" -ne 0 ]; then
        if [ "$module_download_status" -eq 124 ] || [ "$module_download_status" -eq 137 ]; then
            print_error "Go module download timed out after ${GO_MODULE_DOWNLOAD_TIMEOUT}s"
        else
            print_error "Go module download failed (exit code ${module_download_status})"
        fi
        print_error "Check DNS, outbound HTTPS to proxy.golang.org / sum.golang.org / go.dev, firewall and GOPROXY, then retry"
        print_error "On GCP/cloud VMs with broken IPv6, confirm IPv4 works: curl -4 -I https://proxy.golang.org/"
        return 1
    fi

    print_info "Go module download completed; validating module graph (timeout: ${GO_MODULE_GRAPH_TIMEOUT}s)..."
    local module_graph_status=0
    if _run_go_command_bounded "validating Go module graph" "$GO_MODULE_GRAPH_TIMEOUT" go list -m all; then
        module_graph_status=0
    else
        module_graph_status=$?
    fi
    if [ "$module_graph_status" -ne 0 ]; then
        if [ "$module_graph_status" -eq 124 ] || [ "$module_graph_status" -eq 137 ]; then
            print_error "Go module graph validation timed out after ${GO_MODULE_GRAPH_TIMEOUT}s"
        else
            print_error "Go module graph validation failed (exit code ${module_graph_status})"
        fi
        print_error "The module cache may be incomplete; retry the native installation after checking GOPROXY and disk space"
        return 1
    fi
    print_success "Go module graph validated"

    # The binary carries the web app: its build goes into the module first
    if ! embed_web_ui_build "$go_bin"; then
        return 1
    fi

    # Build with optimizations
    print_info "Building NeoDesk server (timeout: ${GO_BUILD_TIMEOUT}s)..."
    local build_status=0 commit
    commit=$(git -C "$REPO_DIR" rev-parse HEAD 2>/dev/null || true)
    if _run_go_command_bounded "building Go server" "$GO_BUILD_TIMEOUT" \
        env CGO_ENABLED=0 "$go_bin" build -trimpath \
        -ldflags="-s -w -X main.Version=${VERSION} -X main.Commit=${commit}" -o "$output_name" .; then
        build_status=0
    else
        build_status=$?
    fi
    if [ "$build_status" -ne 0 ]; then
        if [ "$build_status" -eq 124 ] || [ "$build_status" -eq 137 ]; then
            print_error "Go server build timed out after ${GO_BUILD_TIMEOUT}s"
        else
            print_error "Go server build failed (exit code ${build_status})"
        fi
        return 1
    fi
    
    if [ -f "$output_name" ]; then
        chmod +x "$output_name"
        local size=$(du -h "$output_name" | cut -f1)
        print_success "Compiled: $output_name ($size)"
        return 0
    else
        print_error "Compilation failed"
        return 1
    fi
}

#===============================================================================
# Installation Functions
#===============================================================================

# apt_quiet ARGS...: apt-get without questions, its output in the log.
# needrestart only lists the services it would restart (they keep
# running), and nothing that is installed already is upgraded when ARGS
# install packages.
apt_quiet() {
    local -a args=("$@")
    [ "${1:-}" = install ] && args=(install --no-upgrade "${@:2}")
    DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l NEEDRESTART_SUSPEND=1 \
        apt-get "${args[@]}" >>"$LOG_FILE" 2>&1
}

# apt_update: the package lists. A source that fails (a third-party
# repository, a mirror in sync) stops nothing: the packages come from the
# lists that are there, and apt-get install says when one is missing.
apt_update() {
    apt_quiet update -qq || print_warning "apt-get update failed for a package source (see $LOG_FILE); installing from the package lists there are"
}

install_dependencies() {
    print_step "Installing dependencies..."
    
    # The server is one static binary; the installer needs only these
    if command -v apt-get &> /dev/null; then
        apt_update
        apt_quiet install -y -qq sqlite3 curl wget openssl ca-certificates iproute2 lsof \
            || print_warning "apt-get could not install every package (see $LOG_FILE)"
    elif command -v dnf &> /dev/null; then
        dnf install -y -q sqlite curl wget openssl ca-certificates iproute lsof
    elif command -v yum &> /dev/null; then
        yum install -y -q sqlite curl wget openssl ca-certificates iproute lsof
    elif command -v pacman &> /dev/null; then
        pacman -Sy --noconfirm sqlite curl wget openssl ca-certificates iproute2 lsof
    else
        print_warning "Unknown package manager. Make sure curl, openssl and SQLite are installed."
    fi
    
    print_success "Dependencies installed"
}

#===============================================================================
# PostgreSQL Installation Functions
#===============================================================================

install_postgresql() {
    print_step "Installing PostgreSQL..."
    
    if command -v psql &> /dev/null; then
        local pg_version=$(psql --version | grep -oP '\d+' | head -1)
        print_success "PostgreSQL $pg_version already installed"
        return 0
    fi
    
    if command -v apt-get &> /dev/null; then
        apt_update
        apt_quiet install -y -qq postgresql postgresql-contrib \
            || print_warning "apt-get could not install PostgreSQL (see $LOG_FILE)"
    elif command -v dnf &> /dev/null; then
        dnf install -y -q postgresql-server postgresql
        postgresql-setup --initdb 2>/dev/null || true
    elif command -v yum &> /dev/null; then
        yum install -y -q postgresql-server postgresql
        postgresql-setup initdb 2>/dev/null || true
    elif command -v pacman &> /dev/null; then
        pacman -Sy --noconfirm postgresql
        su - postgres -c "initdb -D /var/lib/postgres/data" 2>/dev/null || true
    else
        print_error "Cannot install PostgreSQL automatically."
        print_info "Please install PostgreSQL manually and run the script again."
        return 1
    fi
    
    # Start PostgreSQL service
    systemctl start postgresql 2>/dev/null || service postgresql start 2>/dev/null || true
    systemctl enable postgresql 2>/dev/null || true
    
    # Verify installation
    if command -v psql &> /dev/null; then
        print_success "PostgreSQL installed and started"
        return 0
    else
        print_error "PostgreSQL installation failed!"
        return 1
    fi
}

setup_postgresql_database() {
    print_step "Setting up PostgreSQL database for NeoDesk..."

    if ! is_valid_pg_identifier "$POSTGRESQL_USER"; then
        print_error "Invalid PostgreSQL username: $POSTGRESQL_USER"
        print_info "Allowed pattern: ^[A-Za-z_][A-Za-z0-9_]{0,62}$"
        return 1
    fi
    if ! is_valid_pg_identifier "$POSTGRESQL_DB"; then
        print_error "Invalid PostgreSQL database name: $POSTGRESQL_DB"
        print_info "Allowed pattern: ^[A-Za-z_][A-Za-z0-9_]{0,62}$"
        return 1
    fi
    
    # Generate password if not set
    if [ -z "$POSTGRESQL_PASS" ]; then
        # SECURITY (audit fix M-05, 2026-04-10): use hex (4 bits/char, no
        # alphabet shrinking) instead of base64+tr+truncate which lost a few
        # entropy bits per character.
        POSTGRESQL_PASS=$(openssl rand -hex 16)
        print_info "Generated PostgreSQL password"
    fi
    
    # Check if PostgreSQL is running
    if ! systemctl is-active --quiet postgresql 2>/dev/null; then
        systemctl start postgresql 2>/dev/null || service postgresql start 2>/dev/null
        sleep 2
    fi
    
    # Create user and database
    local pg_pass_sql
    pg_pass_sql=$(sql_escape_literal "$POSTGRESQL_PASS")

    print_step "Creating PostgreSQL user '$POSTGRESQL_USER'..."
    sudo -u postgres psql -v ON_ERROR_STOP=1 -c "CREATE USER \"$POSTGRESQL_USER\" WITH PASSWORD '$pg_pass_sql' CREATEDB;" 2>/dev/null || {
        print_warning "User might already exist, trying to update password..."
        sudo -u postgres psql -v ON_ERROR_STOP=1 -c "ALTER USER \"$POSTGRESQL_USER\" WITH PASSWORD '$pg_pass_sql';" 2>/dev/null || true
    }
    
    print_step "Creating PostgreSQL database '$POSTGRESQL_DB'..."
    POSTGRESQL_DB_CREATED=false
    if sudo -u postgres psql -v ON_ERROR_STOP=1 -c "CREATE DATABASE \"$POSTGRESQL_DB\" OWNER \"$POSTGRESQL_USER\";" 2>/dev/null; then
        POSTGRESQL_DB_CREATED=true
    else
        print_warning "Database might already exist"
    fi
    
    if ! ensure_postgresql_local_hba_rules; then
        print_error "PostgreSQL authentication setup failed"
        return 1
    fi

    # Build connection URI
    POSTGRESQL_URI="postgres://$POSTGRESQL_USER:$POSTGRESQL_PASS@$POSTGRESQL_HOST:$POSTGRESQL_PORT/$POSTGRESQL_DB?sslmode=disable"
    
    # Test connection
    print_step "Testing PostgreSQL connection..."
    if PGPASSWORD="$POSTGRESQL_PASS" psql -U "$POSTGRESQL_USER" -h "$POSTGRESQL_HOST" -p "$POSTGRESQL_PORT" -d "$POSTGRESQL_DB" -c "SELECT 1;" &>/dev/null; then
        print_success "PostgreSQL connection successful!"
        print_info "Connection URI: postgres://$POSTGRESQL_USER:****@$POSTGRESQL_HOST:$POSTGRESQL_PORT/$POSTGRESQL_DB"
    else
        print_error "PostgreSQL connection failed!"
        print_info "Check PostgreSQL pg_hba.conf for local connections"
        return 1
    fi
    
    return 0
}

# prepare_postgresql: a database given with --pg-uri (or POSTGRESQL_URI) is
# used as it is; without one, PostgreSQL is installed on this machine with
# a user and a database for NeoDesk.
prepare_postgresql() {
    if [ -n "$POSTGRESQL_URI" ]; then
        print_info "PostgreSQL: the database given with --pg-uri; nothing is set up on this machine"
        return 0
    fi
    # The database is made on this machine, so a host elsewhere could not
    # have it
    if ! is_local_postgresql_host; then
        print_error "PostgreSQL on $POSTGRESQL_HOST: give a database on another machine with --pg-uri (POSTGRESQL_URI)"
        return 1
    fi
    install_postgresql || { print_error "PostgreSQL installation failed"; return 1; }
    setup_postgresql_database || { print_error "PostgreSQL setup failed"; return 1; }
}

choose_database_type() {
    # A database given with --pg-uri needs no question
    if [ "$USE_POSTGRESQL" = "true" ] && [ -n "$POSTGRESQL_URI" ]; then
        print_info "Using the PostgreSQL database given with --pg-uri"
        return 0
    fi
    if [ "$AUTO_MODE" = true ]; then
        # In auto mode, use environment variable or default to SQLite
        if [ "$USE_POSTGRESQL" = "true" ]; then
            print_info "Auto mode: Using PostgreSQL"
            return 0
        else
            print_info "Auto mode: Using SQLite (default)"
            USE_POSTGRESQL="false"
            return 0
        fi
    fi
    
    echo ""
    local _menu_items=(
        $'SQLite (default)\tSingle-file DB, zero setup, good for <=100 devices'
        $'PostgreSQL (production)\tPooled SQL DB, multi-server / >100 devices / HA'
    )
    local _menu_returns=( 1 2 )
    menu_choose "Select Database Type" "SQLite is recommended for most installs"
    local db_choice="${MENU_CHOICE:-1}"
    
    case $db_choice in
        2)
            USE_POSTGRESQL="true"
            print_info "Selected: PostgreSQL"
            echo ""
            local _menu_items=(
                $'On this machine\tInstalls PostgreSQL here and creates the database and its user'
                $'An existing database\tOn this or another machine, given as a connection URI'
            )
            local _menu_returns=( 1 2 )
            menu_choose "PostgreSQL" "Where the database is"
            if [ "${MENU_CHOICE:-1}" = 2 ]; then
                local pg_uri=""
                while [ -z "$pg_uri" ]; do
                    read -rp "Connection URI (postgres://user:password@host:5432/database): " pg_uri || return 1
                    if ! is_postgres_url "$pg_uri"; then
                        print_warning "The URI starts with postgres:// or postgresql://"
                        pg_uri=""
                    fi
                done
                POSTGRESQL_URI="$pg_uri"
                return 0
            fi

            # The database on this machine: its name, user and password
            read -rp "Database name [$POSTGRESQL_DB]: " pg_db
            POSTGRESQL_DB="${pg_db:-$POSTGRESQL_DB}"

            read -rp "Database user [$POSTGRESQL_USER]: " pg_user
            POSTGRESQL_USER="${pg_user:-$POSTGRESQL_USER}"

            read -rsp "Password of that user (leave empty to generate): " pg_pass
            echo ""
            POSTGRESQL_PASS="${pg_pass:-}"
            ;;
        *)
            USE_POSTGRESQL="false"
            print_info "Selected: SQLite"
            ;;
    esac
}

migrate_sqlite_to_postgresql() {
    print_step "Migrating existing SQLite data to PostgreSQL..."
    
    local sqlite_db="$RUSTDESK_PATH/db_v2.sqlite3"
    
    if [ ! -f "$sqlite_db" ]; then
        print_info "No existing SQLite database found, skipping migration"
        return 0
    fi
    
    # The installed binary's migrate command
    local migrate_bin=server_migrate
    if ! binary_migrates; then
        print_warning "$(server_binary_path) has no migrate command: the server keeps using $sqlite_db"
        print_info "Move it later with: M -> 3 (SQLite → PostgreSQL)"
        keep_sqlite_install "$sqlite_db"
        return 0
    fi
    
    if [ "$AUTO_MODE" != true ] && ! confirm "Move the existing SQLite install (every server and console table) to PostgreSQL?"; then
        print_info "The install stays on SQLite ($sqlite_db); move it later with the menu's Database migration"
        keep_sqlite_install "$sqlite_db"
        return 0
    fi

    # -overwrite only for a database this run created itself, or after the
    # user agreed: otherwise the tool refuses a database with rows in it
    local overwrite=""
    if [ "$POSTGRESQL_DB_CREATED" = true ]; then
        overwrite="-overwrite"
    elif [ "$AUTO_MODE" != true ] && confirm "If the PostgreSQL database already holds data, replace all of it?"; then
        overwrite="-overwrite"
    fi

    print_step "Creating backup before migration..."
    "$migrate_bin" -mode backup -src "$sqlite_db" 2>&1 || true

    print_step "Moving the SQLite install to PostgreSQL..."
    if "$migrate_bin" -mode sqlite2pg -src "$sqlite_db" -dst "$POSTGRESQL_URI" ${overwrite:+"$overwrite"} 2>&1; then
        use_database_in_env postgres "$POSTGRESQL_URI"
        print_success "The install now runs on PostgreSQL"
    else
        print_warning "The move to PostgreSQL failed (output above): the server keeps using $sqlite_db"
        keep_sqlite_install "$sqlite_db"
    fi
}

# use_database_in_env postgres URI | sqlite PATH: points the console's .env
# at the database the server is to use: DATABASE_URL alone, its type from
# the scheme; the DB_TYPE, DB_URL and DB_PATH of an older install go. For
# an installed binary that reads only DB_URL and DB_TYPE, those are written
# as it reads them.
use_database_in_env() {
    local env_file="$CONSOLE_PATH/.env" key url="" current=true
    [ -f "$env_file" ] || return 0
    [ "$1" = postgres ] && url="$2"
    binary_reads_database_url || current=false
    # The lines are written anew instead of edited with sed, so an address
    # with & or | in it stays as it is
    for key in DB_TYPE DATABASE_URL DB_URL; do
        _remove_env_line "$env_file" "$key"
    done
    [ "$current" = true ] && _remove_env_line "$env_file" DB_PATH
    [ -z "$(tail -c1 "$env_file")" ] || echo >> "$env_file"
    if [ "$current" = true ]; then
        printf 'DATABASE_URL=%s\n' "$2" >> "$env_file"
    else
        printf 'DB_TYPE=%s\nDATABASE_URL=%s\nDB_URL=%s\n' "$1" "$url" "$2" >> "$env_file"
    fi
}

# keep_sqlite_install PATH: the install stays on its SQLite file after the
# move to PostgreSQL did not happen.
keep_sqlite_install() {
    USE_POSTGRESQL="false"
    POSTGRESQL_URI=""
    use_database_in_env sqlite "$1"
}

#===============================================================================
# The server binary and the console's folder
#===============================================================================

# The release file of this machine's binary.
release_asset_name() {
    case "$(uname -m)" in
        x86_64|amd64) echo "neodesk-server-linux-amd64" ;;
        aarch64|arm64) echo "neodesk-server-linux-arm64" ;;
        armv7l|armv7|armhf) echo "neodesk-server-linux-armv7" ;;
        *) return 1 ;;
    esac
}

# Where the release files are: RELEASE_BASE_URL, else the newest release
# (stable channel, UPDATE_GITHUB_BRANCH main) or the "dev" pre-release
# (development channel, dev) of UPDATE_GITHUB_OWNER/UPDATE_GITHUB_REPO.
release_base_url() {
    if [ -n "${RELEASE_BASE_URL:-}" ]; then
        printf '%s\n' "${RELEASE_BASE_URL%/}"
        return
    fi
    local releases="https://github.com/${UPDATE_GITHUB_OWNER}/${UPDATE_GITHUB_REPO}/releases"
    if [ "$UPDATE_GITHUB_BRANCH" = "dev" ]; then
        printf '%s\n' "$releases/download/dev"
    else
        printf '%s\n' "$releases/latest/download"
    fi
}

# fetch_release_file BASE NAME DEST: downloads BASE/NAME to DEST and prints
# the HTTP status (000 when the server was not reached).
fetch_release_file() {
    local code progress=(-sS)
    [ "$2" != SHA256SUMS ] && [ "${2#manifest}" = "$2" ] && [ -t 1 ] && progress=(--progress-bar)
    code=$(curl -L --retry 3 --connect-timeout 20 "${progress[@]}" -o "$3" -w '%{http_code}' "$1/$2" 2>/dev/null) || true
    printf '%s\n' "${code:-000}"
}

# newest_prerelease_tag: the tag of the newest published pre-release of
# UPDATE_GITHUB_OWNER/UPDATE_GITHUB_REPO other than the rolling "dev" one;
# empty when there is none or the API does not answer. GitHub lists the
# releases newest first, each with tag_name, then draft, then prerelease.
newest_prerelease_tag() {
    curl -fsSL --retry 2 --connect-timeout 20 -H 'Accept: application/vnd.github+json' \
        "https://api.github.com/repos/${UPDATE_GITHUB_OWNER}/${UPDATE_GITHUB_REPO}/releases?per_page=50" 2>/dev/null \
        | tr -d '\r\n' \
        | grep -oE '"(tag_name|draft|prerelease)"[[:space:]]*:[[:space:]]*("[^"]*"|true|false)' \
        | sed -E 's/^"([a-z_]+)"[[:space:]]*:[[:space:]]*"?([^"]*)"?$/\1 \2/' \
        | awk '$1 == "tag_name" { tag = $2; draft = "" }
               $1 == "draft" { draft = $2 }
               $1 == "prerelease" && $2 == "true" && draft == "false" && tag != "dev" && tag ~ /^[A-Za-z0-9][A-Za-z0-9._-]*$/ { print tag; exit }' \
        || true
}

# download_release_binary DIR: the release binary for this machine into
# DIR/neodesk-server, checked against the release's SHA256SUMS and the
# signature of its manifest (verify_release_files). While the repository
# has no stable release, the stable channel takes the newest pre-release,
# and the development build when there is none and no channel was given or
# saved.
download_release_binary() {
    local dir="$1" asset base expected actual code
    asset=$(release_asset_name) || {
        print_error "There is no release binary for $(uname -m); use --from-source"
        return 1
    }
    read_update_github_branch_from_env
    # The repository given to the installer, else the one .env names
    [ -n "${UPDATE_GITHUB_OWNER_GIVEN:-}" ] || UPDATE_GITHUB_OWNER=$(env_file_value "${CONSOLE_PATH:-}/.env" UPDATE_GITHUB_OWNER | grep . || printf '%s\n' "$UPDATE_GITHUB_OWNER")
    [ -n "${UPDATE_GITHUB_REPO_GIVEN:-}" ] || UPDATE_GITHUB_REPO=$(env_file_value "${CONSOLE_PATH:-}/.env" UPDATE_GITHUB_REPO | grep . || printf '%s\n' "$UPDATE_GITHUB_REPO")
    base=$(release_base_url)
    print_info "Downloading $asset ($UPDATE_GITHUB_BRANCH channel) from $base"
    code=$(fetch_release_file "$base" SHA256SUMS "$dir/SHA256SUMS")
    # No stable release yet: the newest pre-release (a release candidate of
    # the stable channel), else, with no channel given or saved, the
    # development build and its channel for later updates (DECISIONS A183)
    local prerelease=""
    if [ "$code" = 404 ] && [ -z "${RELEASE_BASE_URL:-}" ] && [ "$UPDATE_GITHUB_BRANCH" != dev ]; then
        prerelease=$(newest_prerelease_tag)
    fi
    if [ -n "$prerelease" ]; then
        print_warning "${UPDATE_GITHUB_OWNER}/${UPDATE_GITHUB_REPO} has no stable release yet: installing the newest pre-release $prerelease"
        base="https://github.com/${UPDATE_GITHUB_OWNER}/${UPDATE_GITHUB_REPO}/releases/download/$prerelease"
        print_info "Downloading $asset ($prerelease) from $base"
        code=$(fetch_release_file "$base" SHA256SUMS "$dir/SHA256SUMS")
    elif [ "$code" = 404 ] && [ -z "${RELEASE_BASE_URL:-}" ] && [ "$UPDATE_GITHUB_BRANCH" != dev ] \
        && [ -z "${UPDATE_GITHUB_BRANCH_GIVEN:-}" ] && [ -z "$(env_file_value "${CONSOLE_PATH:-}/.env" UPDATE_GITHUB_BRANCH)" ]; then
        print_warning "${UPDATE_GITHUB_OWNER}/${UPDATE_GITHUB_REPO} has no stable release or pre-release yet: installing the development build (--channel dev) instead"
        print_info "Updates follow the development channel; once a stable release is out: sudo $(basename "$MANAGER_COMMAND") --update --channel stable"
        UPDATE_GITHUB_BRANCH=dev
        UPDATE_GITHUB_BRANCH_GIVEN=dev
        export UPDATE_GITHUB_BRANCH
        base=$(release_base_url)
        print_info "Downloading $asset (dev channel) from $base"
        code=$(fetch_release_file "$base" SHA256SUMS "$dir/SHA256SUMS")
    fi
    case "$code" in
        200) ;;
        000)
            print_error "Could not reach $base"
            print_info "Check this server's internet access and DNS (a proxy goes in HTTPS_PROXY),"
            print_info "or install offline: download the binary elsewhere and run with --binary FILE"
            return 1
            ;;
        404)
            if [ -z "${RELEASE_BASE_URL:-}" ] && [ "$UPDATE_GITHUB_BRANCH" != dev ]; then
                print_error "${UPDATE_GITHUB_OWNER}/${UPDATE_GITHUB_REPO} has no stable release yet"
                print_info "Install the development build with --channel dev, or a binary you have with --binary FILE"
            else
                print_error "There is no release at $base"
                print_info "Install a binary you have with --binary FILE"
            fi
            return 1
            ;;
        *)
            print_error "Downloading $base/SHA256SUMS failed (HTTP $code); try again later, or use --binary FILE"
            return 1
            ;;
    esac
    code=$(fetch_release_file "$base" "$asset" "$dir/$asset")
    if [ "$code" != 200 ]; then
        print_error "Could not download $base/$asset (HTTP $code)"
        return 1
    fi
    expected=$(awk -v name="$asset" '$2 == name || $2 == "*" name { print tolower($1); exit }' "$dir/SHA256SUMS")
    actual=$(sha256sum "$dir/$asset" | awk '{ print $1 }')
    if [ "$SKIP_VERIFY" = true ]; then
        print_warning "SHA-256 and signature checks skipped (--skip-verify)"
    elif [ -z "$expected" ]; then
        print_error "SHA256SUMS of the release does not list $asset"
        return 1
    elif [ "$actual" != "$expected" ]; then
        print_error "SHA-256 of $asset does not match the release's SHA256SUMS"
        return 1
    else
        print_success "SHA-256 of $asset matches the release"
        local name rc=0
        for name in manifest.json manifest.sig; do
            code=$(fetch_release_file "$base" "$name" "$dir/$name")
            if [ "$code" != 200 ]; then
                rm -f -- "${dir:?}/${name:?}"
                if [ "$code" != 404 ]; then
                    print_error "Could not download $base/$name (HTTP $code); try again later"
                    return 1
                fi
            fi
        done
        verify_release_files "$dir" "$asset" "$UPDATE_GITHUB_BRANCH" || rc=$?
        case "$rc" in
            0) ;;
            2)
                print_warning "The release signature cannot be checked on this machine: $RELEASE_CHECK_PROBLEM."
                print_warning "The binary is checked by its SHA-256 over HTTPS only. From the next update on,"
                print_warning "the installed neodesk-server checks the signature itself."
                ;;
            *)
                print_info "Nothing was installed. A release signed with another key (a fork's) installs with --skip-verify"
                return 1
                ;;
        esac
    fi
    mv -f "$dir/$asset" "$dir/neodesk-server"
    # neodesk-setup comes from the same release (install_manager_command)
    RELEASE_FOLDER_USED="$base"
}

# binary_verifies_releases [BIN]: true when the binary checks a release's
# signature itself, with the release key it carries (verify-release).
binary_verifies_releases() {
    local bin="${1:-$(server_binary_path)}"
    [ -x "$bin" ] && grep -a -q -F 'verify-release --manifest FILE' "$bin" 2>/dev/null
}

# manifest_field MANIFEST KEY CHARS: the value of the field KEY of
# manifest.json, when the file has it once and the value is made of CHARS
# (an extended regular expression); fails otherwise.
manifest_field() {
    local values
    values=$(tr -d '\r\n' < "$1" | grep -oE "\"$2\"[[:space:]]*:[[:space:]]*\"$3\"" \
        | sed -E 's/^.*:[[:space:]]*"//; s/"$//') || return 1
    [ -n "$values" ] && [ "$(printf '%s\n' "$values" | wc -l)" -eq 1 ] || return 1
    printf '%s\n' "$values"
}

# release_payload MANIFEST: the text the release signature covers, made
# from manifest.json as the server makes it (updater.CanonicalPayload): the
# owner, repository, branch and commit, and each binary's SHA-256 and name,
# sorted by name. Fails when manifest.json has a field it cannot read.
release_payload() {
    local manifest="$1" owner repo branch sha files count paths
    owner=$(manifest_field "$manifest" owner '[A-Za-z0-9_.-]+') || return 1
    repo=$(manifest_field "$manifest" repo '[A-Za-z0-9_.-]+') || return 1
    branch=$(manifest_field "$manifest" branch '[A-Za-z0-9_./-]+') || return 1
    sha=$(manifest_field "$manifest" sha '[0-9a-f]{40}') || return 1
    files=$(tr -d '\r\n' < "$manifest" \
        | grep -oE '"path"[[:space:]]*:[[:space:]]*"[a-z0-9.-]+"[[:space:]]*,[[:space:]]*"sha256"[[:space:]]*:[[:space:]]*"[0-9a-f]{64}"' \
        | sed -E 's/^"path"[[:space:]]*:[[:space:]]*"([^"]*)".*"([0-9a-f]{64})"$/\2  \1/' \
        | LC_ALL=C sort -s -k2,2) || return 1
    count=$(printf '%s\n' "$files" | grep -c .) || true
    paths=$(tr -d '\r\n' < "$manifest" | grep -oE '"path"[[:space:]]*:' | wc -l)
    [ "$count" -gt 0 ] && [ "$count" -eq "$paths" ] || return 1
    printf 'neodesk-update-manifest-v1\nowner=%s\nrepo=%s\nbranch=%s\nsha=%s\nfiles=%s\n%s\n' \
        "$owner" "$repo" "$branch" "$sha" "$count" "$files"
}

# ensure_openssl: openssl, installed with the package manager when missing.
ensure_openssl() {
    command -v openssl >/dev/null 2>&1 && return 0
    print_info "Installing openssl to check the release signature..."
    if command -v apt-get >/dev/null 2>&1; then
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq openssl >/dev/null 2>&1 \
            || { apt-get update -qq >/dev/null 2>&1 && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq openssl >/dev/null 2>&1; }
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y -q openssl >/dev/null 2>&1
    elif command -v yum >/dev/null 2>&1; then
        yum install -y -q openssl >/dev/null 2>&1
    elif command -v pacman >/dev/null 2>&1; then
        pacman -Sy --noconfirm openssl >/dev/null 2>&1
    fi
    command -v openssl >/dev/null 2>&1
}

# verify_release_files DIR ASSET BRANCH: DIR/ASSET is a binary the signed
# manifest of the release (DIR/manifest.json and DIR/manifest.sig) names,
# and the release is of the channel's BRANCH. The installed binary checks
# it when it can (verify-release, with the release key it carries), else
# openssl with RELEASE_PUBLIC_KEY_PEM. Returns 0 when checked, 1 when
# refused, 2 when this machine cannot check an ed25519 signature
# (RELEASE_CHECK_PROBLEM says why).
verify_release_files() {
    local dir="$1" asset="$2" branch="$3" installed out rc=0 work sum
    RELEASE_CHECK_PROBLEM=""
    installed=$(server_binary_path)
    if [ ! -s "$dir/manifest.json" ] || [ ! -s "$dir/manifest.sig" ]; then
        print_error "The release has no signed manifest (manifest.json and manifest.sig), so $asset is not installed"
        return 1
    fi
    if binary_verifies_releases "$installed"; then
        out=$("$installed" verify-release --manifest "$dir/manifest.json" --signature "$dir/manifest.sig" \
            --name "$asset" "$dir/$asset" 2>&1) || rc=$?
        case "$rc" in
            0)
                if [ "$(manifest_field "$dir/manifest.json" branch '[A-Za-z0-9_./-]+' || true)" != "$branch" ]; then
                    print_error "The release is not one of the $branch channel, so $asset is not installed"
                    return 1
                fi
                print_success "Release signature checked by the installed neodesk-server (${out#verified: })"
                return 0
                ;;
            1)
                print_error "The installed neodesk-server refused the release: ${out#neodesk-server verify-release: }"
                return 1
                ;;
        esac
    fi
    if ! ensure_openssl; then
        RELEASE_CHECK_PROBLEM="openssl is missing and could not be installed"
        return 2
    fi
    if ! openssl pkeyutl -help 2>&1 | grep -q -- '-rawin'; then
        RELEASE_CHECK_PROBLEM="$(openssl version 2>/dev/null | cut -d' ' -f1-2) checks no ed25519 signatures (OpenSSL 3 does)"
        return 2
    fi
    work=$(mktemp -d) || return 1
    printf '%s\n' "$RELEASE_PUBLIC_KEY_PEM" > "$work/key.pem"
    rc=0
    if ! release_payload "$dir/manifest.json" > "$work/payload"; then
        print_error "manifest.json of the release has fields this installer cannot read, so $asset is not installed"
        rc=1
    elif ! tr -d '[:space:]' < "$dir/manifest.sig" | base64 -d > "$work/sig" 2>/dev/null \
        || ! openssl pkeyutl -verify -pubin -inkey "$work/key.pem" -rawin -in "$work/payload" -sigfile "$work/sig" >/dev/null 2>&1; then
        print_error "The release signature does not verify against the release key, so $asset is not installed"
        rc=1
    elif ! grep -qx "branch=$branch" "$work/payload"; then
        print_error "The release is not one of the $branch channel, so $asset is not installed"
        rc=1
    else
        sum=$(sha256sum "$dir/$asset" | awk '{ print $1 }')
        if ! grep -qxF "$sum  $asset" "$work/payload"; then
            print_error "$asset is not the binary the release's signed manifest names, so it is not installed"
            rc=1
        fi
    fi
    rm -rf -- "${work:?}"
    [ "$rc" -eq 0 ] && print_success "Release signature checked against the release key (openssl)"
    return "$rc"
}

# build_server_from_source DEST: builds neodesk-server from this checkout,
# with the web app built in, into DEST.
build_server_from_source() {
    local dest="$1"
    detect_architecture
    if ! compile_go_server; then
        print_error "Failed to build neodesk-server from $GO_SERVER_SOURCE"
        return 1
    fi
    cp "$GO_SERVER_SOURCE/neodesk-server" "$dest"
}

# obtain_server_binary: a checked binary for this machine, from --binary,
# --from-source or the release, at STAGED_SERVER_BINARY in a temporary
# folder STAGED_SERVER_DIR that the caller removes.
obtain_server_binary() {
    STAGED_SERVER_DIR=$(mktemp -d /tmp/neodesk-server.XXXXXX)
    STAGED_SERVER_BINARY="$STAGED_SERVER_DIR/neodesk-server"
    if [ -n "$SERVER_BINARY_FILE" ]; then
        print_info "Using the binary $SERVER_BINARY_FILE"
        cp "$SERVER_BINARY_FILE" "$STAGED_SERVER_BINARY" || return 1
    elif [ "$FROM_SOURCE" = true ]; then
        build_server_from_source "$STAGED_SERVER_BINARY" || return 1
    else
        download_release_binary "$STAGED_SERVER_DIR" || return 1
    fi
    chmod 0755 "$STAGED_SERVER_BINARY"
    local line
    if ! line=$(timeout 10 "$STAGED_SERVER_BINARY" -version 2>/dev/null); then
        print_error "The new binary does not run on this machine"
        return 1
    fi
    if ! binary_has_subcommands "$STAGED_SERVER_BINARY"; then
        print_error "The new binary is not a release with the web console inside ($line)"
        return 1
    fi
    STAGED_SERVER_VERSION="$line"
    print_success "New binary: $line"
}

# install_staged_binary [SUFFIX]: puts STAGED_SERVER_BINARY in place of the
# installed binary and keeps the old one as neodesk-server<SUFFIX>
# (.prev unless given). The service must be stopped.
install_staged_binary() {
    local suffix="${1:-.prev}" bin
    bin=$(server_binary_path)
    mkdir -p "$RUSTDESK_PATH"
    if [ -f "$bin" ]; then
        cp -p "$bin" "$bin$suffix"
    fi
    if ! install -m 0755 "$STAGED_SERVER_BINARY" "$bin.new.$$" || ! mv -f "$bin.new.$$" "$bin"; then
        rm -f "$bin.new.$$"
        print_error "Could not install $bin"
        return 1
    fi
    print_success "Installed $bin"
}

install_binaries() {
    print_step "Installing neodesk-server..."
    obtain_server_binary || { rm -rf "${STAGED_SERVER_DIR:-}"; return 1; }
    if systemctl is-active --quiet "$SERVER_SERVICE" 2>/dev/null; then
        graceful_stop_services
    fi
    install_staged_binary || { rm -rf "$STAGED_SERVER_DIR"; return 1; }
    rm -rf "$STAGED_SERVER_DIR"
}

# The account the server runs as.
ensure_service_user() {
    if ! id "$SERVICE_USER" &>/dev/null; then
        useradd -r -s /usr/sbin/nologin -d /var/lib/neodesk -c "NeoDesk server" "$SERVICE_USER" || {
            print_error "Could not create the system user $SERVICE_USER"
            return 1
        }
    fi
    mkdir -p /var/lib/neodesk
    chown "$SERVICE_USER:$SERVICE_USER" /var/lib/neodesk 2>/dev/null || true
}

# own_by_service_user PATH...: hands files and folders below PATH to the
# service account, touching only those another account owns.
own_by_service_user() {
    find "$@" \( ! -user "$SERVICE_USER" -o ! -group "$SERVICE_USER" \) \
        -exec chown -h "$SERVICE_USER:$SERVICE_USER" {} + 2>/dev/null || true
}

# The server folder belongs to root with the service's group, which may
# write it, and nobody else may list or read it (2770): the server makes
# its database, keys and the binary's .prev there. Its files belong to the service account, except the copies
# kept for a rollback, the admin credentials and a source checkout.
set_server_folder_permissions() {
    mkdir -p "$RUSTDESK_PATH/ssl"
    chown root:"$SERVICE_USER" "$RUSTDESK_PATH" 2>/dev/null || true
    chmod 2770 "$RUSTDESK_PATH" 2>/dev/null || true
    local -a entries
    mapfile -t entries < <(find "$RUSTDESK_PATH" -mindepth 1 -maxdepth 1 ! -name '.admin_credentials' \
        ! -name '*.pre-go' ! -name 'source')
    [ "${#entries[@]}" -gt 0 ] && own_by_service_user "${entries[@]}"
    chmod 750 "$RUSTDESK_PATH/ssl" 2>/dev/null || true
    local f
    for f in .api_key id_ed25519 ssl/neodesk.key; do
        [ -f "$RUSTDESK_PATH/$f" ] && chmod 600 "$RUSTDESK_PATH/$f"
    done
    return 0
}

# setup_console_home: the console's folder with its .env and data folder.
setup_console_home() {
    print_step "Setting up the web console's folder $CONSOLE_PATH..."
    ensure_service_user || return 1
    mkdir -p "$CONSOLE_PATH/data"

    local is_fresh=false
    if [ ! -f "$CONSOLE_PATH/.env" ]; then
        is_fresh=true
    fi
    FRESH_CONSOLE_ENV="$is_fresh"
    if [ "$is_fresh" = true ]; then
        if [ -z "$ADMIN_PASSWORD" ]; then
            ADMIN_PASSWORD=$(openssl rand -hex 16)
        else
            print_info "Using custom admin password from ADMIN_PASSWORD env var"
        fi
        touch "$CONSOLE_PATH/data/.force_password_update"
    else
        print_info "Keeping the existing .env and accounts"
        ADMIN_PASSWORD="${ADMIN_PASSWORD:-}"
    fi

    merge_console_env "$is_fresh" || return 1
    if [ "$MINIMAL_MODE" = true ]; then
        _upsert_env_line "$CONSOLE_PATH/.env" CONSOLE_PORT 0
        print_info "Minimal installation: the web console stays off (CONSOLE_PORT=0)"
    fi

    if [ -d "$REPO_DIR/remote-gateway" ]; then
        mkdir -p "$CONSOLE_PATH/remote-gateway"
        cp -a "$REPO_DIR/remote-gateway/." "$CONSOLE_PATH/remote-gateway/"
    fi
    if [ -f "$REPO_DIR/VERSION" ]; then
        cp -a "$REPO_DIR/VERSION" "$CONSOLE_PATH/VERSION" 2>/dev/null || true
    fi

    if [ "$STORE_ADMIN_CREDENTIALS" = "true" ] && [ "$is_fresh" = true ] && [ -n "$ADMIN_PASSWORD" ]; then
        (umask 077 && cat > "$CONSOLE_PATH/data/.admin_credentials") << CREDEOF
Admin Username: admin
Admin Password: $ADMIN_PASSWORD
Generated by: NeoDesk installer
Timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)
CREDEOF
    fi

    own_by_service_user "$CONSOLE_PATH"
    chmod 750 "$CONSOLE_PATH"
    chmod 700 "$CONSOLE_PATH/data"
    chmod 600 "$CONSOLE_PATH/.env"
    if [ -f "$CONSOLE_PATH/data/.admin_credentials" ]; then
        chown root:root "$CONSOLE_PATH/data/.admin_credentials"
        chmod 600 "$CONSOLE_PATH/data/.admin_credentials"
    fi
    CONSOLE_TYPE="go"
    print_success "Web console folder ready"
}

# address_host ADDRESS: the host of an address clients get (host,
# host:port, [v6]:port, a list of them): its first host without the port.
address_host() {
    local host="${1%%,*}"
    case "$host" in
        \[*) host="${host#[}"; host="${host%%]*}" ;;
        *:*:*) ;;
        *:*) host="${host%%:*}" ;;
    esac
    printf '%s\n' "$host"
}

# san_entry HOST: HOST as a subjectAltName entry, IP: for an address and
# DNS: for a name.
san_entry() {
    if [[ "$1" =~ ^[0-9.]+$ ]] || [[ "$1" == *:* ]]; then
        printf 'IP:%s\n' "$1"
    else
        printf 'DNS:%s\n' "$1"
    fi
}

generate_ssl_certificates() {
    print_step "Generating self-signed TLS certificates..."
    
    local ssl_dir="$RUSTDESK_PATH/ssl"
    
    # Skip if certificates already exist
    if [ -f "$ssl_dir/neodesk.crt" ] && [ -f "$ssl_dir/neodesk.key" ]; then
        print_info "TLS certificates already exist at $ssl_dir"
        print_info "Skipping certificate generation (use SSL config menu to regenerate)"
        return 0
    fi
    
    mkdir -p "$ssl_dir"
    
    # Detect server IPs for SAN (Subject Alternative Name)
    local server_ip
    server_ip=$(get_public_ip)
    
    # Detect LAN IP (first non-loopback IPv4)
    local lan_ip
    lan_ip=$(ip -4 addr show scope global | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1 2>/dev/null || \
             hostname -I 2>/dev/null | awk '{print $1}' || echo "")
    
    # Build SAN list
    local san_list="IP:$server_ip,IP:127.0.0.1,DNS:localhost"
    
    # Add LAN IP if different from public IP
    if [ -n "$lan_ip" ] && [ "$lan_ip" != "$server_ip" ] && [ "$lan_ip" != "127.0.0.1" ]; then
        san_list="$san_list,IP:$lan_ip"
    fi
    
    # The address clients get when it was given (--relay-servers, the
    # custom address of the relay question): the console's redirects lead
    # there (PANEL_PUBLIC_HOST), so the certificate is for it too
    local relay_host
    relay_host=$(address_host "${RELAY_SERVERS:-}")
    if [ -n "$relay_host" ] && [ "$relay_host" != "$server_ip" ] && [ "$relay_host" != "$lan_ip" ] \
        && [ "$relay_host" != "${SSL_DOMAIN:-}" ]; then
        san_list="$(san_entry "$relay_host"),$san_list"
        print_info "Adding the relay address to the certificate: $relay_host"
    else
        relay_host=""
    fi

    # Add custom domain if provided via environment variable
    if [ -n "${SSL_DOMAIN:-}" ]; then
        san_list="DNS:$SSL_DOMAIN,$san_list"
        print_info "Adding domain to certificate: $SSL_DOMAIN"
    fi
    
    # The common name: the domain, else the relay address given, else the
    # public IP
    local cn="${SSL_DOMAIN:-${relay_host:-$server_ip}}"
    
    # The binary makes the pair (no OpenSSL needed); an older binary
    # without the cert command leaves it to openssl
    local bin
    bin=$(server_binary_path)
    if [ -x "$bin" ] && grep -q 'cert --out DIR' "$bin" 2>/dev/null; then
        local -a cert_args=(cert --out "$ssl_dir" --force)
        [ -n "${SSL_DOMAIN:-}" ] && cert_args+=(--host "$SSL_DOMAIN")
        [ -n "$relay_host" ] && cert_args+=(--host "$relay_host")
        cert_args+=(--host "$server_ip")
        [ -n "$lan_ip" ] && [ "$lan_ip" != "$server_ip" ] && cert_args+=(--host "$lan_ip")
        if ! "$bin" "${cert_args[@]}" >/dev/null; then
            print_error "Failed to generate self-signed certificate"
            return 1
        fi
    else
        if ! command -v openssl &>/dev/null; then
            print_warning "openssl not found - skipping TLS certificate generation"
            print_info "Install openssl and use SSL config menu (option C) to generate later"
            return 1
        fi
        # Generate certificate with SAN extension (valid for 10 years for self-signed)
        openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
            -keyout "$ssl_dir/neodesk.key" \
            -out "$ssl_dir/neodesk.crt" \
            -subj "/CN=$cn/O=NeoDesk/C=PL" \
            -addext "subjectAltName=$san_list" \
            >/dev/null 2>&1 || {
            print_warning "Certificate generation failed (openssl too old for -addext?)"
            # Fallback without SAN for older openssl
            openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
                -keyout "$ssl_dir/neodesk.key" \
                -out "$ssl_dir/neodesk.crt" \
                -subj "/CN=$cn/O=NeoDesk/C=PL" \
                2>&1 || {
                print_error "Failed to generate self-signed certificate"
                return 1
            }
        }
    fi

    # Deploy with console-user-readable permissions
    if ! deploy_ssl_material_to_rustdesk_dir "$ssl_dir/neodesk.crt" "$ssl_dir/neodesk.key"; then
        print_error "Failed to set permissions on self-signed certificate"
        return 1
    fi
    
    if [ -d "$CONSOLE_PATH" ]; then
        # HTTPS for the web console (5443, a redirect on its HTTP port) and
        # the client API port
        local env_file="$CONSOLE_PATH/.env"
        if [ -f "$env_file" ]; then
            sed -i "s|^HTTPS_ENABLED=.*|HTTPS_ENABLED=true|" "$env_file"
            sed -i "s|^SSL_CERT_PATH=.*|SSL_CERT_PATH=$ssl_dir/neodesk.crt|" "$env_file"
            sed -i "s|^SSL_KEY_PATH=.*|SSL_KEY_PATH=$ssl_dir/neodesk.key|" "$env_file"
            # RustDesk clients refuse a self-signed certificate: the client
            # API port stays on HTTP until a trusted certificate is set up
            _upsert_env_line "$env_file" RUSTDESK_API_TLS false
            # The internal API URLs stay http://: API TLS breaks RustDesk clients.

            # Enterprise TLS compatibility: Go API must remain HTTP because
            # RustDesk desktop clients use plain HTTP on signal_port-2.
            if [ "${ENTERPRISE_TLS:-false}" = "true" ]; then
                if grep -q '^ALLOW_SELF_SIGNED_CERTS=' "$env_file" 2>/dev/null; then
                    sed -i "s|^ALLOW_SELF_SIGNED_CERTS=.*|ALLOW_SELF_SIGNED_CERTS=true|" "$env_file"
                else
                    echo "ALLOW_SELF_SIGNED_CERTS=true" >> "$env_file"
                fi
                sed -i "s|^HBBS_API_URL=https://localhost|HBBS_API_URL=http://localhost|" "$env_file"
                sed -i "s|^NEODESK_API_URL=https://localhost|NEODESK_API_URL=http://localhost|" "$env_file"
                print_info "Enterprise TLS: Go API stays HTTP for RustDesk client compatibility"
            fi
        fi
    fi
    
    print_success "Self-signed TLS certificate generated (valid 10 years)"
    print_info "Certificate: $ssl_dir/neodesk.crt"
    print_info "Private key: $ssl_dir/neodesk.key"
    print_info "SANs: $san_list"
    [ -n "$lan_ip" ] && [ "$lan_ip" != "$server_ip" ] && print_info "LAN IP included: $lan_ip"
    return 0
}

#===============================================================================
# The service: neodesk-server with the web console inside
#===============================================================================

# env_file_value FILE KEY: the value the first line setting KEY has, trimmed.
env_file_value() {
    [ -f "$1" ] || return 0
    { grep -m1 "^$2=" "$1" 2>/dev/null || true; } | cut -d= -f2- | tr -d '\r' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

# is_postgres_url ADDRESS: true for a postgres:// or postgresql:// address.
is_postgres_url() {
    case "${1,,}" in
        postgres://*|postgresql://*) return 0 ;;
    esac
    return 1
}

# env_database_url FILE: the database the server opens with this env file,
# read as the server reads it: DATABASE_URL, a postgres:// address or the
# SQLite file (sqlite:// before it allowed), else DB_URL of an older
# install. DB_TYPE=sqlite of an older install keeps it on SQLite where
# DATABASE_URL still names PostgreSQL. Empty when the file names none: the
# server then opens db_v2.sqlite3 in its folder.
env_database_url() {
    local url legacy type
    url=$(env_file_value "$1" DATABASE_URL)
    legacy=$(env_file_value "$1" DB_URL)
    type=$(env_file_value "$1" DB_TYPE)
    if [ -n "$url" ] && is_postgres_url "$url" && [ "${type,,}" = sqlite ]; then
        url=""
        is_postgres_url "$legacy" && legacy=""
    fi
    url="${url:-$legacy}"
    if ! is_postgres_url "$url"; then
        case "${url,,}" in
            sqlite://*) url="${url:9}" ;;
            sqlite:*) url="${url:7}" ;;
        esac
    fi
    printf '%s\n' "$url"
}

# env_database_type FILE: postgres when the server opens PostgreSQL with
# this env file, else sqlite.
env_database_type() {
    if is_postgres_url "$(env_database_url "$1")"; then
        echo postgres
    else
        echo sqlite
    fi
}

# binary_migrates [BIN]: true when the binary carries the migrate command
# (sqlite2pg, pg2sqlite, rust2go and backup of a SQLite file).
binary_migrates() {
    local bin="${1:-$(server_binary_path)}"
    [ -x "$bin" ] && grep -a -q -F 'migrate -mode sqlite2pg' "$bin" 2>/dev/null
}

# binary_backs_up [BIN]: true when the binary carries the backup command
# (the console's full backup, also of PostgreSQL, while the server runs).
binary_backs_up() {
    local bin="${1:-$(server_binary_path)}"
    [ -x "$bin" ] && grep -a -q -F 'backup [--out DIR]' "$bin" 2>/dev/null
}

# server_migrate ARGS...: the installed binary's migrate command.
server_migrate() {
    "$(server_binary_path)" migrate "$@"
}

# binary_reads_database_url [BIN]: true when the binary takes its database
# from DATABASE_URL; older ones read DB_URL and DB_TYPE only.
binary_reads_database_url() {
    local bin="${1:-$(server_binary_path)}"
    [ -f "$bin" ] && grep -a -q -F 'Remove DB_TYPE to use DATABASE_URL' "$bin" 2>/dev/null
}

# unit_environment UNIT: the KEY=VALUE pairs of a unit's Environment= lines,
# one per line, with systemd's quotes and its $$ and %% escapes undone.
unit_environment() {
    local line rest
    local -a words
    [ -f "$1" ] || return 0
    while IFS= read -r line; do
        rest="${line#Environment=}"
        if [[ "$rest" == \"*\" ]]; then
            rest="${rest#\"}"
            printf '%s\n' "${rest%\"}"
        else
            read -r -a words <<< "$rest"
            [ "${#words[@]}" -gt 0 ] && printf '%s\n' "${words[@]}"
        fi
    done < <(grep -E '^Environment=' "$1") | sed 's/\$\$/$/g; s/%%/%/g'
}

# unit_env_value UNIT KEY: the value a unit's Environment= lines give KEY.
unit_env_value() {
    unit_environment "$1" | awk -v key="$2" 'index($0, key "=") == 1 { value = substr($0, length(key) + 2) } END { if (value != "") print value }'
}

# unit_exec_flag_value UNIT FLAG: the value of a flag on a unit's ExecStart
# line, quoted or not, with systemd's escapes undone.
unit_exec_flag_value() {
    grep -m1 '^ExecStart=' "$1" 2>/dev/null \
        | sed -nE "s/.*[[:space:]]$2[[:space:]]+\"([^\"]*)\".*/\\1/p; t; s/.*[[:space:]]$2[[:space:]]+([^[:space:]]+).*/\\1/p" \
        | head -1 | sed 's/\$\$/$/g; s/%%/%/g'
}

# unit_exec_args UNIT: the arguments of a unit's ExecStart after the
# program, without -db and -init-admin-pass (the env file carries them as
# DB_URL and INIT_ADMIN_PASS), without the API TLS flags RustDesk clients
# cannot use, and with the old client API port as -api-port moved to
# GO_API_PORT (the web console serves 21121).
unit_exec_args() {
    grep -m1 '^ExecStart=' "$1" 2>/dev/null \
        | sed -E 's/^ExecStart=[-@+!:]*[^[:space:]]+//' \
        | sed -E 's/[[:space:]]-db[[:space:]]+"[^"]*"//; s/[[:space:]]-db[[:space:]]+[^[:space:]]+//' \
        | sed -E 's/[[:space:]]-init-admin-pass[[:space:]]+[^[:space:]]+//' \
        | sed -E 's/[[:space:]]-tls-api-port(=[^[:space:]]*)?//g; s/[[:space:]]-tls-api(=[^[:space:]]*)?//g' \
        | sed -E "s/-api-port[[:space:]]+${CLIENT_API_PORT:-21121}([[:space:]]|\$)/-api-port ${GO_API_PORT:-21114}\\1/" \
        | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//; s/[[:space:]]+/ /g'
}

# The settings write_server_unit writes itself, and the ports that live in
# .env (carry_unit_ports moves them there).
SERVER_UNIT_OWN_KEYS=" NEODESK_ENV_FILE NEODESK_SUPERVISOR SIGNAL_PORT RELAY_PORT GO_API_PORT MESH_ENABLED CONSOLE_PORT "

# server_unit_extra_environment: the Environment= lines of the installed
# unit besides the ones write_server_unit writes (connection mode, proxy
# trust), so a rewritten unit keeps them.
server_unit_extra_environment() {
    local pair key
    is_go_only_install || return 0
    while IFS= read -r pair; do
        key="${pair%%=*}"
        case "$SERVER_UNIT_OWN_KEYS" in *" $key "*) continue ;; esac
        printf 'Environment=%s\n' "$(printf '%s' "$pair" | sed 's/\$/$$/g; s/%/%%/g')"
    done < <(unit_environment "$SERVER_UNIT")
}

# True when the web console listens on a port below 1024.
console_uses_privileged_port() {
    local key port
    for key in CONSOLE_PORT HTTPS_PORT API_PORT; do
        port=$(env_file_value "$CONSOLE_PATH/.env" "$key")
        if [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -gt 0 ] && [ "$port" -lt 1024 ]; then
            return 0
        fi
    done
    return 1
}

# write_server_unit ARGS EXTRA_ENV: neodesk-server.service, the one
# process that serves signal, relay, API and the web console, as the
# service account. ARGS are the server's arguments; EXTRA_ENV are more
# Environment= lines. The server reads the console's .env itself
# (NEODESK_ENV_FILE) and fills only what the unit leaves unset. Exit
# status 3 is the server's request to be started again (a restart, an
# update or a restore from the panel). The description names no version:
# the console's updater replaces the binary without writing the unit.
write_server_unit() {
    local args="$1" extra_env="${2:-}" bind_cap=""
    if console_uses_privileged_port; then
        bind_cap="AmbientCapabilities=CAP_NET_BIND_SERVICE"
    fi
    # Lines of the template that stay empty are left out
    cat << EOF | grep -v '^__EMPTY__$' > "$SERVER_UNIT"
[Unit]
Description=NeoDesk server and web console
Documentation=https://github.com/neodeskapp/neodesk
After=network-online.target postgresql.service
Wants=network-online.target

[Service]
Type=simple
User=$SERVICE_USER
Group=$SERVICE_USER
WorkingDirectory=$RUSTDESK_PATH
Environment=NEODESK_ENV_FILE=$CONSOLE_PATH/.env
Environment=NEODESK_SUPERVISOR=systemd
Environment=GO_API_PORT=${GO_API_PORT:-21114}
Environment=MESH_ENABLED=Y
${extra_env:-__EMPTY__}
ExecStart=$(server_binary_path) $args
Restart=always
RestartSec=2
SuccessExitStatus=3
LimitNOFILE=1000000
NoNewPrivileges=yes
PrivateTmp=yes
${bind_cap:-__EMPTY__}

[Install]
WantedBy=multi-user.target
EOF
    chmod 0644 "$SERVER_UNIT"
}

# Removes the units of retired NeoDesk services (Rust signal and relay,
# Flask console, manual installs).
remove_retired_units() {
    local svc
    for svc in rustdesksignal rustdeskrelay neodesk-api neodesk-go neodesk; do
        if [ -f "/etc/systemd/system/$svc.service" ]; then
            systemctl stop "$svc" 2>/dev/null || true
            systemctl disable "$svc" 2>/dev/null || true
            rm -f "/etc/systemd/system/$svc.service"
            print_info "Removed retired $svc.service"
        fi
    done
}

# ask_relay_address: in an interactive run without RELAY_SERVERS or a
# --relay-mode, asks once for the address clients get: the public IP, the
# LAN IP or one typed in.
ask_relay_address() {
    [ "$AUTO_MODE" = false ] && [ -z "${RELAY_SERVERS:-}" ] && [ "${RELAY_MODE:-auto}" = "auto" ] \
        && [ "${RELAY_ASKED:-false}" != true ] || return 0
    local _local_ip _relay_choice
    _local_ip=$(get_local_ip)
    echo ""
    print_info "Relay server address controls how clients connect for remote sessions."
    echo -e "  ${CYAN}1)${NC} Internet / public  ${DIM}(auto-detect public IP — default)${NC}"
    echo -e "  ${CYAN}2)${NC} LAN only           ${DIM}(use this server's local IP: $_local_ip)${NC}"
    echo -e "  ${CYAN}3)${NC} Custom address     ${DIM}(enter a specific IP or host)${NC}"
    echo -ne "  ${CYAN}Select relay mode [1]:${NC} "
    read -r _relay_choice
    case "$_relay_choice" in
        2) RELAY_MODE="local" ;;
        3)
            echo -ne "  ${CYAN}Enter relay address (IP or host[:port]):${NC} "
            read -r RELAY_SERVERS
            ;;
        *) RELAY_MODE="auto" ;;
    esac
    RELAY_ASKED=true
    echo ""
}

setup_services() {
    print_step "Configuring the systemd service..."

    # The database settings from an existing .env, so a reinstall keeps
    # PostgreSQL
    if [ "$USE_POSTGRESQL" != "true" ] && [ "$(env_database_type "$CONSOLE_PATH/.env")" = "postgres" ]; then
        POSTGRESQL_URI=$(env_database_url "$CONSOLE_PATH/.env")
        USE_POSTGRESQL="true"
        print_info "Recovered PostgreSQL config from existing .env"
    fi

    # Relay address: RELAY_SERVERS, else the mode (auto = public IP, local =
    # LAN IP), asked for in an interactive run
    ask_relay_address

    local server_ip relay_mode="$RELAY_MODE"
    server_ip=$(resolve_relay_ip)
    resolve_connection_mode_env
    [ -n "${RELAY_SERVERS:-}" ] && relay_mode=fixed
    print_info "Relay server IP: $server_ip (mode: $relay_mode)"
    set_panel_public_host "${SSL_DOMAIN:-$server_ip}"

    local signal_rate_limit="${SIGNAL_RATE_LIMIT_PER_IP:-20}"
    if ! [[ "$signal_rate_limit" =~ ^[0-9]+$ ]]; then
        print_warning "Invalid SIGNAL_RATE_LIMIT_PER_IP='$signal_rate_limit'; using 20"
        signal_rate_limit="20"
    fi

    # TLS for signal and relay when certificates exist. The API port stays
    # HTTP: RustDesk desktop clients call it without TLS.
    local tls_arg=""
    local ssl_dir="$RUSTDESK_PATH/ssl"
    if [ -f "$ssl_dir/neodesk.crt" ] && [ -f "$ssl_dir/neodesk.key" ]; then
        tls_arg=" -tls-cert $ssl_dir/neodesk.crt -tls-key $ssl_dir/neodesk.key -tls-signal -tls-relay"
        print_info "TLS: on for signal and relay (API stays HTTP)"
    fi

    if [ ! -s "$RUSTDESK_PATH/.api_key" ]; then
        (umask 077 && openssl rand -hex 32 > "$RUSTDESK_PATH/.api_key")
        chmod 600 "$RUSTDESK_PATH/.api_key"
    fi

    write_server_unit "-mode all -relay-servers $server_ip -key-file $RUSTDESK_PATH/id_ed25519 -api-port ${GO_API_PORT:-21114} -signal-rate-limit-per-ip $signal_rate_limit$tls_arg" \
        "$CONNECTION_MODE_ENV_BLOCK"
    remove_retired_units
    systemctl daemon-reload
    print_success "Created neodesk-server.service (server and web console, user $SERVICE_USER)"
}

# set_panel_public_host ADDRESS: the host of the address clients get becomes
# PANEL_PUBLIC_HOST when .env has none, so the console's HTTP port redirects
# to HTTPS on that host. A value set before stays.
set_panel_public_host() {
    local env_file="$CONSOLE_PATH/.env" host="${1%%,*}"
    [ -f "$env_file" ] || return 0
    [ -n "$(env_file_value "$env_file" PANEL_PUBLIC_HOST)" ] && return 0
    case "$host" in
        \[*) host="${host%%]*}]" ;;
        *:*:*) ;;
        *:*) host="${host%%:*}" ;;
    esac
    [ -n "$host" ] && _upsert_env_line "$env_file" PANEL_PUBLIC_HOST "$host"
    return 0
}

# carry_unit_ports: the signal and relay ports an older unit set (they won
# over .env) go into .env, where the admin changes them, so a unit written
# without them keeps the ports the server listens on.
carry_unit_ports() {
    local key value
    for key in SIGNAL_PORT RELAY_PORT; do
        value=$(unit_env_value "$SERVER_UNIT" "$key")
        [ -n "$value" ] && _upsert_env_line "$CONSOLE_PATH/.env" "$key" "$value"
    done
    return 0
}

# During UPDATE and REPAIR: write the unit again from the template with the
# installed unit's arguments and extra settings; make it when missing.
maybe_update_services() {
    if ! is_go_only_install; then
        setup_services
        return
    fi
    local args extra
    args=$(unit_exec_args "$SERVER_UNIT")
    extra=$(server_unit_extra_environment)
    carry_unit_ports
    set_panel_public_host "$(unit_exec_flag_value "$SERVER_UNIT" -relay-servers)"
    write_server_unit "$args" "$extra"
    systemctl daemon-reload
    print_info "neodesk-server.service written again with its arguments and settings"
}

# The port the web console answers /health on: HTTPS_PORT when HTTPS is on
# and its certificate is there, else CONSOLE_PORT. Empty when the console
# is off.
console_health_url() {
    local env_file="$CONSOLE_PATH/.env" port https cert key
    port=$(read_effective_console_setting CONSOLE_PORT "")
    [ -n "$port" ] || port=$(read_effective_console_setting PORT "$CONSOLE_DEFAULT_PORT")
    [ "$port" = "0" ] && return 0
    https=$(read_effective_console_setting HTTPS_ENABLED false | tr '[:upper:]' '[:lower:]')
    cert=$(env_file_value "$env_file" SSL_CERT_PATH)
    key=$(env_file_value "$env_file" SSL_KEY_PATH)
    if [ "$https" = "true" ] && [ -f "$cert" ] && [ -f "$key" ]; then
        printf 'https://127.0.0.1:%s/health\n' "$(read_effective_console_setting HTTPS_PORT 5443)"
    else
        printf 'http://127.0.0.1:%s/health\n' "$port"
    fi
}

# The signal and relay ports the server listens on.
signal_port() { read_effective_console_setting SIGNAL_PORT 21116; }
relay_port() { read_effective_console_setting RELAY_PORT 21117; }

# verify_go_install [SECONDS]: the service runs, the API and the web console
# answer /health, signal and relay listen, and the client API port listens
# when it is on.
verify_go_install() {
    local timeout="${1:-60}" waited=0 api_ok=false console_url console_ok=false signal relay
    console_url=$(console_health_url)
    signal=$(signal_port)
    relay=$(relay_port)
    [ -z "$console_url" ] && console_ok=true
    while [ "$waited" -lt "$timeout" ]; do
        if systemctl is-active --quiet "$SERVER_SERVICE"; then
            [ "$api_ok" = true ] || { curl -fsS -o /dev/null --max-time 3 "http://127.0.0.1:${GO_API_PORT:-21114}/api/health" 2>/dev/null && api_ok=true; }
            [ "$console_ok" = true ] || { curl -ksf -o /dev/null --max-time 3 "$console_url" 2>/dev/null && console_ok=true; }
            if [ "$api_ok" = true ] && [ "$console_ok" = true ] && _tcp_port_is_listening "$signal" && _tcp_port_is_listening "$relay"; then
                break
            fi
        fi
        sleep 2
        waited=$((waited + 2))
    done
    if ! systemctl is-active --quiet "$SERVER_SERVICE"; then
        print_error "$SERVER_SERVICE is not running"
        show_service_logs "$SERVER_SERVICE" 30
        return 1
    fi
    [ "$api_ok" = true ] || { print_error "The API does not answer on :${GO_API_PORT:-21114}"; show_service_logs "$SERVER_SERVICE" 30; return 1; }
    [ "$console_ok" = true ] || { print_error "The web console does not answer $console_url"; show_service_logs "$SERVER_SERVICE" 30; return 1; }
    _tcp_port_is_listening "$signal" || { print_error "Signal port $signal is not listening"; return 1; }
    _tcp_port_is_listening "$relay" || { print_error "Relay port $relay is not listening"; return 1; }
    if [ "$(read_effective_console_setting API_ENABLED true | tr '[:upper:]' '[:lower:]')" = "true" ] \
        && [ "$(read_effective_console_setting CONSOLE_PORT "$CONSOLE_DEFAULT_PORT")" != "0" ]; then
        local client_port
        client_port=$(read_effective_console_setting API_PORT "${CLIENT_API_PORT:-21121}")
        _tcp_port_is_listening "$client_port" || print_warning "The client API port $client_port is not listening"
    fi
    print_success "neodesk-server answers: API :${GO_API_PORT:-21114}${console_url:+, web console $console_url}, signal :$signal, relay :$relay"
}

#===============================================================================
# The install of the server with its console, and older ones
#===============================================================================

# True when the installed unit runs the server with the web console
# inside: this installer writes NEODESK_SUPERVISOR into it.
is_go_only_install() {
    [ -f "$SERVER_UNIT" ] && grep -q '^Environment=NEODESK_SUPERVISOR=' "$SERVER_UNIT" 2>/dev/null
}

# True when the install still runs the Node.js console.
is_node_era_install() {
    ! is_go_only_install && { [ -f "$LEGACY_CONSOLE_UNIT" ] || [ -f "$CONSOLE_PATH/server.js" ]; }
}

# refuse_node_era_install: an install that still runs the Node.js console
# is neither upgraded nor installed over; NeoDesk has no way from it.
refuse_node_era_install() {
    print_error "This server runs the old Node.js web console, which this installer does not upgrade."
    print_info "Back up its data and install NeoDesk on a clean server."
}

# update_go_install: the newest release of the update channel (or --binary,
# --from-source, RELEASE_BASE_URL), the unit written again, a restart and a
# check. A new binary that does not come up is replaced by the previous one.
# console_port_named: the install's settings name the console's port
# (CONSOLE_PORT or PORT in the unit or .env). One that names none follows
# the server's default, CONSOLE_DEFAULT_PORT.
console_port_named() {
    local key
    for key in CONSOLE_PORT PORT; do
        [ -n "$(unit_env_value "$SERVER_UNIT" "$key" 2>/dev/null)" ] && return 0
        [ -n "$(env_file_value "${CONSOLE_PATH:-}/.env" "$key" 2>/dev/null)" ] && return 0
    done
    return 1
}

# note_console_port_move NAMED: after an update of an install that named
# no port (NAMED false), which ran on the old default: says that the
# console moved to the new default and how to keep the old port, and
# opens the new one in the firewall this installer manages.
note_console_port_move() {
    [ "$1" = false ] || return 0
    [ "$(resolve_panel_http_port)" = "$CONSOLE_DEFAULT_PORT" ] || return 0
    configure_firewall_rules || true
    print_warning "The console now answers on port $CONSOLE_DEFAULT_PORT; it was $CONSOLE_OLD_DEFAULT_PORT. To keep $CONSOLE_OLD_DEFAULT_PORT set CONSOLE_PORT=$CONSOLE_OLD_DEFAULT_PORT in $CONSOLE_PATH/.env, then: sudo systemctl restart $SERVER_SERVICE"
}

# file_sum FILE: the SHA-256 of FILE, empty when there is none.
file_sum() {
    sha256sum "$1" 2>/dev/null | awk '{ print $1 }'
}

# server_update_args: what update_go_install passes to neodesk-server
# update: --yes, and --no-restart-hint when the installed binary has it
# (the installer restarts the service and puts the previous binary back
# itself).
server_update_args() {
    printf '%s\n' --yes
    grep -a -q -F -- '--no-restart-hint' "$(server_binary_path)" 2>/dev/null && printf '%s\n' --no-restart-hint
    return 0
}

# The backup comes only before a new binary: an update that finds the
# release installed already makes none, and when the unit and .env stay as
# they were too, the running server is not restarted.
update_go_install() {
    local bin before after port_named=true env_before unit_before
    bin=$(server_binary_path)
    before=$(file_sum "$bin")
    # Before .env is merged: an install that names no port moves to the
    # new default port (note_console_port_move)
    console_port_named || port_named=false
    # The server's updater reads the channel from .env
    save_given_update_channel

    # An installed binary without verify-release is older than the release
    # key, and its updater would take a release without checking the
    # signature: this installer downloads and checks the release itself
    if [ -n "$SERVER_BINARY_FILE" ] || [ "$FROM_SOURCE" = true ] || [ -n "${RELEASE_BASE_URL:-}" ] \
        || ! binary_verifies_releases "$bin"; then
        obtain_server_binary || { rm -rf "${STAGED_SERVER_DIR:-}"; return 1; }
        if [ "$(file_sum "$STAGED_SERVER_BINARY")" != "$before" ]; then
            print_info "Creating backup before update..."
            do_backup_silent
            systemctl stop "$SERVER_SERVICE" 2>/dev/null || true
            wait_for_service_stop "$SERVER_SERVICE" 15 || true
            install_staged_binary .prev || { rm -rf "$STAGED_SERVER_DIR"; systemctl start "$SERVER_SERVICE" || true; return 1; }
        fi
        rm -rf "$STAGED_SERVER_DIR"
    else
        # The server's own updater: the release of the channel, its manifest
        # signature (with the release key the installed binary carries) and
        # SHA-256 checked, the old binary kept as .prev
        print_step "Checking the newest release with neodesk-server update (it checks the release signature)..."
        # The repository goes to the updater: an installed binary may have
        # an older default
        local owner repo check_out="" check_rc=0
        owner="${UPDATE_GITHUB_OWNER_GIVEN:-$(env_file_value "$CONSOLE_PATH/.env" UPDATE_GITHUB_OWNER)}"
        repo="${UPDATE_GITHUB_REPO_GIVEN:-$(env_file_value "$CONSOLE_PATH/.env" UPDATE_GITHUB_REPO)}"
        owner="${owner:-$UPDATE_GITHUB_OWNER}"
        repo="${repo:-$UPDATE_GITHUB_REPO}"
        check_out=$(UPDATE_GITHUB_OWNER="$owner" UPDATE_GITHUB_REPO="$repo" server_cmd --as-service update --check 2>&1) || check_rc=$?
        log "neodesk-server update --check: $check_out"
        if [ "$check_rc" -ne 0 ]; then
            [ -n "$check_out" ] && printf '%s\n' "$check_out"
            print_error "neodesk-server update failed"
            return 1
        fi
        case "$check_out" in
            *"Already up to date"*) ;;
            *)
                print_info "Creating backup before update..."
                do_backup_silent
                local -a update_args
                mapfile -t update_args < <(server_update_args)
                if ! UPDATE_GITHUB_OWNER="$owner" UPDATE_GITHUB_REPO="$repo" \
                    server_cmd --as-service update "${update_args[@]}"; then
                    print_error "neodesk-server update failed"
                    return 1
                fi
                ;;
        esac
    fi
    after=$(file_sum "$bin")

    env_before=$(file_sum "$CONSOLE_PATH/.env")
    unit_before=$(file_sum "$SERVER_UNIT")
    merge_console_env false || print_warning ".env merge reported a problem"
    maybe_update_services
    set_server_folder_permissions
    if [ "$before" = "$after" ] && [ "$env_before" = "$(file_sum "$CONSOLE_PATH/.env")" ] \
        && [ "$unit_before" = "$(file_sum "$SERVER_UNIT")" ] && systemctl is-active --quiet "$SERVER_SERVICE" 2>/dev/null; then
        forget_first_admin_password
        print_success "neodesk-server is up to date: $(timeout 10 "$bin" -version 2>/dev/null); nothing changed, so it keeps running"
        install_manager_command
        note_console_port_move "$port_named"
        return 0
    fi
    systemctl reset-failed "$SERVER_SERVICE" 2>/dev/null || true
    systemctl restart "$SERVER_SERVICE" || true
    if verify_go_install 90; then
        forget_first_admin_password
    else
        if [ "$before" != "$after" ] && [ -f "$bin.prev" ]; then
            print_error "The new binary did not come up; putting the previous one back"
            systemctl stop "$SERVER_SERVICE" 2>/dev/null || true
            cp -a "$bin.prev" "$bin"
            # systemd stops restarting a unit that failed too often in a
            # row (StartLimitBurst), as the new binary may have
            systemctl reset-failed "$SERVER_SERVICE" 2>/dev/null || true
            systemctl start "$SERVER_SERVICE" || true
            verify_go_install 60 || true
        fi
        return 1
    fi

    if [ "$before" = "$after" ]; then
        print_success "neodesk-server is up to date: $(timeout 10 "$bin" -version 2>/dev/null)"
    else
        print_success "Updated to $(timeout 10 "$bin" -version 2>/dev/null)"
    fi
    install_manager_command
    note_console_port_move "$port_named"
}

# credentials_box TITLE PASSWORD: the admin's sign-in in a box, with the
# command that gives a new password. The right border stays in line for a
# password of up to 42 characters.
credentials_box() {
    local width=56 line
    local -a rows=("  Login:    admin" "  Password: $2" "" "  Lost it? sudo $(basename "$MANAGER_COMMAND") --reset-password")
    local bar
    bar=$(printf '═%.0s' $(seq 1 "$width"))
    echo -e "${GREEN}╔${bar}╗${NC}"
    printf "${GREEN}║${NC}${BOLD}%-${width}s${NC}${GREEN}║${NC}\n" "  $1"
    echo -e "${GREEN}╠${bar}╣${NC}"
    for line in "${rows[@]}"; do
        printf "${GREEN}║${NC}%-${width}s${GREEN}║${NC}\n" "$line"
    done
    echo -e "${GREEN}╚${bar}╝${NC}"
}

# Shows the admin's first password, once: only when this run made the
# console's .env. The server makes the admin at its first start from
# DEFAULT_ADMIN_PASSWORD.
create_admin_user() {
    if [ "${FRESH_CONSOLE_ENV:-false}" != true ]; then
        return 0
    fi
    local admin_password="${ADMIN_PASSWORD:-}"
    if [ -z "$admin_password" ]; then
        admin_password=$(env_file_value "$CONSOLE_PATH/.env" DEFAULT_ADMIN_PASSWORD)
    fi

    if [ -n "$admin_password" ]; then
        echo ""
        credentials_box "Web console sign-in (shown only now)" "$admin_password"
        echo ""

        if [ "$STORE_ADMIN_CREDENTIALS" = "true" ]; then
            (umask 077 && cat > "$RUSTDESK_PATH/.admin_credentials") << CREDEOF
Admin Username: admin
Admin Password: $admin_password
Generated by: NeoDesk installer
Timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)
CREDEOF
            chown root:root "$RUSTDESK_PATH/.admin_credentials" 2>/dev/null || true
            chmod 600 "$RUSTDESK_PATH/.admin_credentials"
            print_info "Credentials saved in: $RUSTDESK_PATH/.admin_credentials (root-only, 0600)"
        fi
    else
        print_warning "No admin password to show; set one with: sudo $(basename "$MANAGER_COMMAND") --reset-password"
    fi
}

start_services() {
    start_services_with_verification
}

# print_install_summary: what the admin needs after an install, and no
# password: the console's address, the first sign-in, what RustDesk
# clients are given, the log, the settings file and the commands for
# later.
print_install_summary() {
    local env_file="$CONSOLE_PATH/.env" cmd host key console http_port https_port
    local id_server relay_server signal relay
    cmd=$(basename "$MANAGER_COMMAND")
    host=$(env_file_value "$env_file" PANEL_PUBLIC_HOST)
    [ -n "$host" ] || host=$(get_public_ip)
    key=$(cat "$RUSTDESK_PATH/id_ed25519.pub" 2>/dev/null || true)
    http_port=$(resolve_panel_http_port)
    https_port=$(resolve_panel_https_port)
    if [ "$MINIMAL_MODE" = true ] || [ "$http_port" = 0 ]; then
        console="off (set CONSOLE_PORT in $env_file to turn it on)"
    elif [ "$(read_effective_console_setting HTTPS_ENABLED false | tr '[:upper:]' '[:lower:]')" = "true" ]; then
        console="https://$host:$https_port  (http://$host:$http_port leads there)"
    else
        console="http://$host:$http_port"
    fi
    signal=$(signal_port)
    relay=$(relay_port)
    id_server="$host"
    [ "$signal" = 21116 ] || id_server="$host:$signal"
    # The relay with its port, as the console's Client setup shows it
    relay_server="$host:$relay"

    echo ""
    echo -e "${GREEN}${BOLD}NeoDesk is installed${NC}"
    echo ""
    echo -e "  Web console:   ${WHITE}$console${NC}"
    local subject="" issuer=""
    if [ -f "$RUSTDESK_PATH/ssl/neodesk.crt" ]; then
        subject=$(openssl x509 -in "$RUSTDESK_PATH/ssl/neodesk.crt" -noout -subject 2>/dev/null | sed 's/^subject=//')
        issuer=$(openssl x509 -in "$RUSTDESK_PATH/ssl/neodesk.crt" -noout -issuer 2>/dev/null | sed 's/^issuer=//')
    fi
    if [ -n "$subject" ] && [ "$subject" = "$issuer" ]; then
        echo "                 The certificate is self-signed, so the browser warns once."
    fi
    if [ "${FRESH_CONSOLE_ENV:-false}" = true ]; then
        echo "  First sign-in: user admin, with the password shown above (it is not shown again;"
        echo "                 lost it? sudo $cmd --reset-password)"
    else
        echo "  Sign in:       user admin; forgot the password? sudo $cmd --reset-password"
        echo "                 (add --reset-two-factor when the authenticator is lost too)"
    fi
    echo "  RustDesk clients (Settings > Network > ID/Relay server):"
    echo -e "    ID server:     ${WHITE}$id_server${NC}"
    echo -e "    Relay server:  ${WHITE}$relay_server${NC}"
    local api_scheme=http
    client_api_should_use_tls && api_scheme=https
    echo -e "    API server:    ${WHITE}$api_scheme://$host:$(read_effective_console_setting API_PORT "${CLIENT_API_PORT:-21121}")${NC}"
    echo -e "    Key:           ${WHITE}$key${NC}"
    echo "  Log:           sudo journalctl -u neodesk-server -f"
    echo "  Settings:      $env_file (then: sudo systemctl restart neodesk-server)"
    echo "  Update:        sudo $cmd --update"
    echo "  Uninstall:     sudo $cmd --uninstall"
    if binary_hands_over "$(server_binary_path)"; then
        echo "  Command line:  sudo neodesk --help"
    fi
    echo "  Help:          $NEODESK_HELP_URL"
    echo ""
}

# forget_first_admin_password: once the server has started and made the
# admin, .env and its kept copies hold no admin password any more (the
# server reads DEFAULT_ADMIN_PASSWORD and INIT_ADMIN_PASS only to make the
# first account).
forget_first_admin_password() {
    local f
    for f in "$CONSOLE_PATH/.env" "$CONSOLE_PATH"/.env.pre-go*; do
        [ -f "$f" ] || continue
        if grep -q '^DEFAULT_ADMIN_PASSWORD=.' "$f" || grep -q '^INIT_ADMIN_PASS=' "$f"; then
            sed -i -e 's/^DEFAULT_ADMIN_PASSWORD=.*/DEFAULT_ADMIN_PASSWORD=/' -e '/^INIT_ADMIN_PASS=/d' "$f"
        fi
    done
    return 0
}

#===============================================================================
# Installation
#===============================================================================

# ask_install_questions: the questions of an interactive install that are
# left after the database: the address clients get, the connection
# strategy, and whether HTTPS ends at a reverse proxy or gets another
# certificate than the self-signed one (INSTALL_TLS_STEP proxy or
# certificate, done after the install).
ask_install_questions() {
    INSTALL_TLS_STEP=""
    [ "$AUTO_MODE" = false ] || return 0
    ask_relay_address
    ask_connection_mode
    [ "$MINIMAL_MODE" != true ] || return 0
    echo ""
    print_info "The console gets HTTPS with a self-signed certificate on port 5443."
    if confirm "Will a reverse proxy (Caddy, nginx) handle HTTPS for the console instead?"; then
        INSTALL_TLS_STEP=proxy
    elif confirm "Replace the self-signed certificate with Let's Encrypt or your own after the install?"; then
        INSTALL_TLS_STEP=certificate
    fi
    echo ""
}

# Minimal installation: the same server with its web console off
# (CONSOLE_PORT=0 in .env); setting a port there turns it on.
do_install_minimal() {
    MINIMAL_MODE=true
    do_install
}

do_install() {
    print_header
    if [ "$MINIMAL_MODE" = true ]; then
        echo -e "${WHITE}${BOLD}══════════ MINIMAL INSTALLATION (web console off) ══════════${NC}"
    else
        echo -e "${WHITE}${BOLD}══════════ FRESH INSTALLATION ══════════${NC}"
    fi
    echo ""

    detect_installation

    if is_node_era_install; then
        refuse_node_era_install
        [ "$AUTO_MODE" = true ] || press_enter
        return 1
    fi

    if [ "$INSTALL_STATUS" = "complete" ]; then
        print_warning "NeoDesk is already installed!"
        if [ "$AUTO_MODE" = false ]; then
            if ! confirm "Do you want to reinstall?"; then
                return
            fi
        fi
        do_backup_silent
    fi

    echo ""
    print_info "Starting NeoDesk v$VERSION installation..."
    echo ""

    # Every question comes before the install: the database, the address
    # clients get, the connection strategy and the HTTPS set-up
    choose_database_type || return 1
    ask_install_questions

    # Stop services if running (prevents "Text file busy" error)
    graceful_stop_services
    if [ -n "${FOREIGN_PORT_HOLDERS:-}" ]; then
        print_error "Installation stopped: the ports above are in use"
        return 1
    fi

    install_dependencies

    # Install and configure PostgreSQL if selected
    if [ "$USE_POSTGRESQL" = "true" ]; then
        prepare_postgresql || return 1
    fi

    detect_architecture
    install_binaries || { print_error "Binary installation failed"; return 1; }
    setup_console_home || { print_error "Setting up the console folder failed"; return 1; }

    # Generate self-signed TLS certificates (default for fresh installs)
    generate_ssl_certificates

    # Migrate existing SQLite data to PostgreSQL if applicable
    if [ "$USE_POSTGRESQL" = "true" ]; then
        migrate_sqlite_to_postgresql
    fi

    setup_services

    # Configure firewall rules
    print_step "Configuring firewall rules..."
    configure_firewall_rules

    local install_ok=true
    if ! start_services; then
        install_ok=false
    fi
    [ "$install_ok" = true ] && forget_first_admin_password

    # The HTTPS set-up chosen at the start, before the summary, which it
    # changes (a reverse proxy closes the console's ports)
    if [ "$install_ok" = true ]; then
        case "${INSTALL_TLS_STEP:-}" in
            proxy) do_configure_reverse_proxy || true ;;
            certificate) do_configure_ssl || true ;;
        esac
    fi
    [ "$install_ok" = true ] && install_manager_command

    echo ""
    if [ "$install_ok" = true ]; then
        print_success "Installation completed successfully!"
    else
        print_warning "Installation finished but neodesk-server does not answer."
        print_info "Look into it with: sudo $(basename "$MANAGER_COMMAND"), then Diagnostics"
    fi

    # The password and the summary come last, so nothing pushes them off
    # the screen
    create_admin_user
    print_install_summary

    if [ "$AUTO_MODE" = false ]; then
        press_enter
    fi
    [ "$install_ok" = true ]
}

#===============================================================================
# Update Functions
#===============================================================================

# GitHub repository configuration for online updates
# A repository given to the installer wins over .env, and .env over these
UPDATE_GITHUB_OWNER_GIVEN="${UPDATE_GITHUB_OWNER:-}"
UPDATE_GITHUB_REPO_GIVEN="${UPDATE_GITHUB_REPO:-}"
UPDATE_GITHUB_OWNER="${UPDATE_GITHUB_OWNER:-neodeskapp}"
UPDATE_GITHUB_REPO="${UPDATE_GITHUB_REPO:-neodesk}"
# A channel given to the installer (--channel, or install.sh's --channel)
# wins over .env and is written into it. UPDATE_GITHUB_BRANCH holds the
# channel's id, main for stable and dev for development, not a git branch.
UPDATE_GITHUB_BRANCH_GIVEN="${UPDATE_GITHUB_BRANCH:-}"
UPDATE_GITHUB_BRANCH="${UPDATE_GITHUB_BRANCH:-main}"

# save_given_update_channel: the channel the installer was given goes into
# .env, where the server's updater reads it
save_given_update_channel() {
    if [ -n "${UPDATE_GITHUB_BRANCH_GIVEN:-}" ] && [ -f "${CONSOLE_PATH:-}/.env" ]; then
        _upsert_env_line "$CONSOLE_PATH/.env" UPDATE_GITHUB_BRANCH "$UPDATE_GITHUB_BRANCH_GIVEN"
    fi
    return 0
}

read_update_github_branch_from_env() {
    local env_file="${CONSOLE_PATH:-}/.env"
    [ -n "${UPDATE_GITHUB_BRANCH_GIVEN:-}" ] && return 0
    if [ -n "$CONSOLE_PATH" ] && [ -f "$env_file" ]; then
        local val
        val=$(grep -E '^UPDATE_GITHUB_BRANCH=' "$env_file" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '\r"')
        if [ -n "$val" ]; then
            UPDATE_GITHUB_BRANCH="$val"
            export UPDATE_GITHUB_BRANCH
        fi
    fi
}

write_update_github_branch_to_env() {
    local branch="$1"
    local env_file="${CONSOLE_PATH:-}/.env"
    if [ -z "$CONSOLE_PATH" ]; then
        print_error "Console path unknown — cannot save update channel"
        return 1
    fi
    if [ ! -f "$env_file" ]; then
        touch "$env_file"
    fi
    if grep -qE '^UPDATE_GITHUB_BRANCH=' "$env_file" 2>/dev/null; then
        sed -i "s/^UPDATE_GITHUB_BRANCH=.*/UPDATE_GITHUB_BRANCH=${branch}/" "$env_file"
    else
        printf '\nUPDATE_GITHUB_BRANCH=%s\n' "$branch" >> "$env_file"
    fi
    UPDATE_GITHUB_BRANCH="$branch"
    UPDATE_GITHUB_BRANCH_GIVEN="${UPDATE_GITHUB_BRANCH_GIVEN:+$branch}"
    export UPDATE_GITHUB_BRANCH
    print_success "Update channel saved: $branch"
    return 0
}

switch_update_channel() {
    print_header
    echo -e "${WHITE}${BOLD}══════════ UPDATE CHANNEL ══════════${NC}"
    echo ""
    detect_installation
    if [ "$INSTALL_STATUS" = "none" ]; then
        print_error "NeoDesk is not installed!"
        press_enter
        return
    fi
    read_update_github_branch_from_env
    print_info "Current update channel: $UPDATE_GITHUB_BRANCH"
    echo ""
    local _menu_items=(
        $'Stable (main)\tReleases from version tags'
        $'Development (dev)\tThe newest build of the main branch'
        $'Back\tReturn without changes'
    )
    local _menu_returns=( main dev 0 )
    menu_choose "Update Channel" "Stable is recommended for production servers"
    case "${MENU_CHOICE:-main}" in
        0) return ;;
        main)
            write_update_github_branch_to_env "main"
            ;;
        dev)
            print_warning "Development channel may include unstable changes."
            write_update_github_branch_to_env "dev"
            ;;
        *)
            write_update_github_branch_to_env "main"
            ;;
    esac
    print_info "The next update (Settings > Updates in the panel, or Update here) installs the channel's release."
    press_enter
}

# If Update already wrote a newer neodesk.sh, re-exec before Repair/Toggle.
maybe_reexec_if_installer_on_disk_is_newer() {
    if [ "${AUTO_MODE:-false}" = "true" ]; then
        return 0
    fi
    if [ "${NEODESK_REEXECED:-}" = "1" ]; then
        return 0
    fi
    local self="${SCRIPT_DIR}/neodesk.sh"
    [ -f "$self" ] || return 0
    local disk_rev
    disk_rev=$(grep -m1 '^NEODESK_SH_REVISION=' "$self" 2>/dev/null | cut -d= -f2- | tr -d "\"'[:space:]")
    if [ -z "$disk_rev" ] || [ "$disk_rev" = "${NEODESK_SH_REVISION:-}" ]; then
        return 0
    fi
    print_info "Installer on disk is newer (revision $disk_rev) — reloading before this action"
    exec env NEODESK_REEXECED=1 bash "$self" "${NEODESK_ORIG_ARGV[@]}"
}

do_update() {
    print_header
    echo -e "${WHITE}${BOLD}══════════ UPDATE ══════════${NC}"
    echo ""

    detect_installation

    if is_node_era_install; then
        refuse_node_era_install
        [ "$AUTO_MODE" = true ] || [ "$UPDATE_MODE" = true ] || press_enter
        return 1
    fi
    if [ "$INSTALL_STATUS" = "none" ]; then
        print_error "NeoDesk is not installed!"
        print_info "Use 'FRESH INSTALLATION' option"
        [ "$AUTO_MODE" = true ] || press_enter
        return 1
    fi

    # Detect Rust → Go upgrade (major architecture change)
    if [ "${SERVER_TYPE:-}" = "rust" ]; then
        print_warning "Legacy Rust server (hbbs/hbbr) detected!"
        print_warning "Upgrading from Rust to Go server requires a FRESH INSTALLATION."
        print_info "The Go server is a single binary replacing both hbbs and hbbr."
        print_info "Your data (keys, database) will be preserved during migration."
        echo ""
        if [ "${AUTO_MODE:-false}" = "true" ]; then
            print_info "Auto mode: Redirecting to fresh installation for Rust → Go migration"
            do_install
            return
        else
            read -rp "Proceed with fresh installation (recommended)? [Y/n] " answer
            if [ "${answer,,}" != "n" ]; then
                do_install
                return
            fi
            return 0
        fi
    fi

    # CRITICAL: Preserve database configuration before the .env is merged
    # This prevents PostgreSQL → SQLite switch during updates
    preserve_database_config
    read_update_github_branch_from_env


    print_info "Update channel: $UPDATE_GITHUB_BRANCH ($( [ "$UPDATE_GITHUB_BRANCH" = dev ] && echo development || echo stable))"
    if [ "${AUTO_MODE:-false}" != "true" ] && [ "$UPDATE_MODE" != true ]; then
        local _menu_items=(
            $'Update now\tInstall the newest release of the update channel'
            $'Switch update channel\tChoose stable (main) or development (dev)'
            $'Back\tReturn to the main menu'
        )
        local _menu_returns=( 1 2 0 )
        menu_choose "Update" "Releases are checked by SHA-256 and their signature before they replace the binary"
        case "${MENU_CHOICE:-1}" in
            0) return 0 ;;
            2) switch_update_channel; return 0 ;;
        esac
    fi

    local rc=0
    update_go_install || rc=$?
    if [ "$rc" -ne 0 ]; then
        print_error "Update failed"
    fi
    [ "$AUTO_MODE" = true ] || [ "$UPDATE_MODE" = true ] || press_enter
    return "$rc"
}

#===============================================================================
# Repair Functions
#===============================================================================

do_repair() {
    maybe_reexec_if_installer_on_disk_is_newer
    print_header
    echo -e "${WHITE}${BOLD}══════════ REPAIR INSTALLATION ══════════${NC}"
    echo ""
    
    detect_installation
    check_management_capabilities || print_warning "Repair will report permission blockers before changing protected files"
    
    # CRITICAL: Preserve database configuration before any repair operation
    # This prevents PostgreSQL → SQLite switch when regenerating service files
    preserve_database_config
    
    print_status
    
    local _menu_items=(
        $'Repair binaries\tReplace the server binary with NeoDesk Go'
        $'Repair database\tAdd missing columns / run migrations'
        $'Repair services\tRegenerate systemd service units'
        $'Repair permissions\tFix file ownership and permissions'
        $'Repair HTTPS / TLS\tFix LE certs, a signal port that takes the console\'s'
        $'Full repair\tRun all repair steps above'
        $'Back\tReturn to the main menu'
    )
    local _menu_returns=( 1 2 3 4 5 6 0 )
    menu_choose "Repair Installation" "Choose what to repair"
    local repair_choice="$MENU_CHOICE"
    
    case $repair_choice in
        1) repair_binaries ;;
        2) repair_database ;;
        3) repair_services ;;
        4) repair_permissions ;;
        5) repair_https_tls ;;
        6) 
            repair_binaries
            repair_database
            repair_services
            repair_permissions
            repair_https_tls
            print_success "Full repair completed!"
            ;;
        0) return ;;
    esac
    
    press_enter
}

repair_binaries() {
    print_step "Repairing neodesk-server..."
    if is_node_era_install; then
        refuse_node_era_install
        return 1
    fi
    if ! obtain_server_binary; then
        rm -rf "${STAGED_SERVER_DIR:-}"
        print_error "Could not get a server binary"
        return 1
    fi
    graceful_stop_services
    install_staged_binary .prev || { rm -rf "$STAGED_SERVER_DIR"; return 1; }
    rm -rf "$STAGED_SERVER_DIR"
    if ! start_services_with_verification; then
        print_error "neodesk-server failed to start after the binary repair"
        return 1
    fi
    print_success "Server binary repaired and verified!"
}

# The server migrates its schema at every start; this checks the SQLite
# file's integrity.
repair_database() {
    print_step "Checking the database..."
    if [ "$(env_database_type "$CONSOLE_PATH/.env")" = "postgres" ]; then
        print_info "PostgreSQL: neodesk-server migrates its tables at start"
        return 0
    fi
    if [ ! -f "$DB_PATH" ]; then
        print_warning "No database at $DB_PATH; neodesk-server creates it at start"
        return 0
    fi
    if ! command -v sqlite3 &>/dev/null; then
        print_warning "sqlite3 is not installed; skipping the check"
        return 0
    fi
    local result
    result=$(sqlite3 "$DB_PATH" "PRAGMA integrity_check;" 2>&1 | head -5)
    if [ "$result" = "ok" ]; then
        print_success "Database integrity: ok (neodesk-server migrates its tables at start)"
    else
        print_error "Database integrity check: $result"
        return 1
    fi
}

repair_services() {
    print_step "Repairing the systemd service..."

    if is_node_era_install; then
        refuse_node_era_install
        return 1
    fi
    if [ ! -f "$(server_binary_path)" ]; then
        print_error "neodesk-server binary not found at $(server_binary_path)"
        print_info "Run 'Repair binaries' first"
        return 1
    fi

    graceful_stop_services
    local backup_file=""
    if [ -f "$SERVER_UNIT" ]; then
        backup_file="$SERVER_UNIT.backup.$(date +%Y%m%d%H%M%S)"
        cp "$SERVER_UNIT" "$backup_file"
    fi

    maybe_update_services

    if ! start_services_with_verification; then
        print_error "neodesk-server failed to start after the repair"
        if [ -n "$backup_file" ]; then
            print_info "Restoring the previous unit..."
            cp "$backup_file" "$SERVER_UNIT"
            systemctl daemon-reload
            systemctl start "$SERVER_SERVICE" 2>/dev/null || true
        fi
        return 1
    fi

    print_success "Service repaired and verified!"
}

repair_permissions() {
    print_step "Repairing permissions..."
    ensure_service_user || return 1
    if [ -d "$CONSOLE_PATH" ]; then
        own_by_service_user "$CONSOLE_PATH"
        chmod 700 "$CONSOLE_PATH/data" 2>/dev/null || true
        chmod 600 "$CONSOLE_PATH/.env" 2>/dev/null || true
    fi
    set_server_folder_permissions
    repair_https_stuck_state yes
    ensure_console_tls_material_readable 2>/dev/null || true

    if systemctl is-enabled --quiet "$SERVER_SERVICE" 2>/dev/null; then
        systemctl restart "$SERVER_SERVICE" 2>/dev/null || true
        if verify_go_install 60; then
            print_success "Permissions repaired — neodesk-server is running"
        else
            print_warning "Permissions synced but neodesk-server does not answer — check: journalctl -u neodesk-server -n 40 --no-pager"
        fi
    else
        print_success "Permissions repaired"
    fi
}

repair_https_tls() {
    print_step "Repairing HTTPS / TLS configuration..."

    repair_https_stuck_state

    if confirm "Restart NeoDesk services now?"; then
        systemctl restart "$SERVER_SERVICE" 2>/dev/null || true
        verify_go_install 60 >/dev/null 2>&1 || true
        print_success "neodesk-server restarted"
        run_protocol_tests
    else
        print_info "Repair saved. Restart later: systemctl restart neodesk-server"
    fi
}

#===============================================================================
# Validation Functions
#===============================================================================

do_validate() {
    print_header
    echo -e "${WHITE}${BOLD}══════════ INSTALLATION VALIDATION ══════════${NC}"
    echo ""
    
    local errors=0
    local warnings=0
    
    detect_installation
    detect_architecture
    
    echo -e "${WHITE}Checking components...${NC}"
    echo ""
    
    # Check directories
    echo -n "  Server folder ($RUSTDESK_PATH): "
    if [ -d "$RUSTDESK_PATH" ]; then
        echo -e "${GREEN}✓${NC}"
    else
        echo -e "${RED}✗ Not found${NC}"
        errors=$((errors + 1))
    fi
    
    echo -n "  Console directory ($CONSOLE_PATH): "
    if [ -d "$CONSOLE_PATH" ]; then
        echo -e "${GREEN}✓${NC}"
    else
        echo -e "${RED}✗ Not found${NC}"
        errors=$((errors + 1))
    fi
    
    # Check Go server binary
    echo -n "  NeoDesk Server (Go): "
    if [ -x "$RUSTDESK_PATH/neodesk-server" ]; then
        echo -e "${GREEN}✓ Single binary (signal + relay + API)${NC}"
    elif [ -x "$RUSTDESK_PATH/hbbs" ] && [ -x "$RUSTDESK_PATH/hbbr" ]; then
        echo -e "${YELLOW}! Legacy Rust binaries (consider upgrading to Go)${NC}"
        warnings=$((warnings + 1))
    else
        echo -e "${RED}✗ Not found or missing permissions${NC}"
        errors=$((errors + 1))
    fi
    
    # Check database
    echo -n "  Database: "
    if [ "$(env_database_type "$CONSOLE_PATH/.env")" = "postgres" ]; then
        local pg_uri
        pg_uri=$(env_database_url "$CONSOLE_PATH/.env")
        if [ -n "$pg_uri" ] && PGCONNECT_TIMEOUT=3 psql "$pg_uri" -c "SELECT 1" &>/dev/null 2>&1; then
            echo -e "${GREEN}✓ PostgreSQL${NC}"
            # Check tables in PostgreSQL
            echo -n "    - Table peers: "
            if PGCONNECT_TIMEOUT=3 psql "$pg_uri" -c "SELECT 1 FROM peers LIMIT 1" &>/dev/null 2>&1; then
                echo -e "${GREEN}✓${NC}"
            else
                echo -e "${YELLOW}! Empty or not found (will be created on first start)${NC}"
                warnings=$((warnings + 1))
            fi
            echo -n "    - Table users: "
            if PGCONNECT_TIMEOUT=3 psql "$pg_uri" -c "SELECT 1 FROM users LIMIT 1" &>/dev/null 2>&1; then
                echo -e "${GREEN}✓${NC}"
            else
                echo -e "${YELLOW}! Empty or not found (will be created on first start)${NC}"
                warnings=$((warnings + 1))
            fi
        else
            echo -e "${RED}✗ PostgreSQL connection failed${NC}"
            errors=$((errors + 1))
        fi
    elif [ -f "$DB_PATH" ]; then
        echo -e "${GREEN}✓ SQLite${NC}"
        
        # Check tables (Go uses 'peers', legacy uses 'peer')
        echo -n "    - Table peers: "
        if sqlite3 "$DB_PATH" "SELECT 1 FROM peers LIMIT 1" 2>/dev/null; then
            echo -e "${GREEN}✓${NC}"
        elif sqlite3 "$DB_PATH" "SELECT 1 FROM peer LIMIT 1" 2>/dev/null; then
            echo -e "${YELLOW}! Legacy schema (peer)${NC}"
            warnings=$((warnings + 1))
        else
            echo -e "${YELLOW}! Empty or not found (will be created on first start)${NC}"
            warnings=$((warnings + 1))
        fi
        
        echo -n "    - Table users: "
        if sqlite3 "$DB_PATH" "SELECT 1 FROM users LIMIT 1" 2>/dev/null; then
            echo -e "${GREEN}✓${NC}"
        else
            echo -e "${YELLOW}! Empty or not found (will be created on first start)${NC}"
            warnings=$((warnings + 1))
        fi
    else
        # Check if Go server is running — it creates the DB on start
        if systemctl is-active --quiet neodesk-server 2>/dev/null; then
            echo -e "${YELLOW}! SQLite file not yet created (server running, will create on first connection)${NC}"
            warnings=$((warnings + 1))
        else
            echo -e "${RED}✗ Not found (will be created when server starts)${NC}"
            errors=$((errors + 1))
        fi
    fi
    
    # Check keys
    echo -n "  Ed25519 key: "
    if [ -f "$RUSTDESK_PATH/id_ed25519.pub" ] || [ -f "$RUSTDESK_PATH/id_ed25519" ]; then
        echo -e "${GREEN}✓${NC}"
    else
        echo -e "${YELLOW}! Will be generated on first start${NC}"
        warnings=$((warnings + 1))
    fi
    
    # Check services
    echo ""
    echo -e "${WHITE}Checking services...${NC}"
    echo ""
    
    # Check Go server service first
    echo -n "  neodesk-server (Go): "
    if systemctl is-active --quiet neodesk-server 2>/dev/null; then
        echo -e "${GREEN}● Active (signal + relay + API)${NC}"
    elif systemctl is-enabled --quiet neodesk-server 2>/dev/null; then
        echo -e "${YELLOW}○ Enabled but inactive${NC}"
        warnings=$((warnings + 1))
    elif systemctl list-unit-files neodesk-server.service &>/dev/null 2>&1; then
        echo -e "${RED}○ Disabled${NC}"
        errors=$((errors + 1))
    else
        # Check legacy Rust services
        echo -e "${CYAN}Not installed${NC}"
        
        for service in rustdesksignal rustdeskrelay; do
            echo -n "  $service (Legacy Rust): "
            if systemctl is-active --quiet "$service" 2>/dev/null; then
                echo -e "${GREEN}● Active${NC}"
            elif systemctl is-enabled --quiet "$service" 2>/dev/null; then
                echo -e "${YELLOW}○ Enabled but inactive${NC}"
                warnings=$((warnings + 1))
            else
                echo -e "${RED}○ Disabled${NC}"
                errors=$((errors + 1))
            fi
        done
    fi
    
    if is_go_only_install; then
        echo -n "  Web console (in neodesk-server): "
        local console_url
        console_url=$(console_health_url)
        if [ -z "$console_url" ]; then
            echo -e "${CYAN}off (CONSOLE_PORT=0)${NC}"
        elif curl -ksf -o /dev/null --max-time 5 "$console_url" 2>/dev/null; then
            echo -e "${GREEN}● Answers${NC} ($console_url)"
        else
            echo -e "${RED}✗ No answer${NC} ($console_url)"
            errors=$((errors + 1))
        fi
        if [ -f "$LEGACY_CONSOLE_UNIT" ]; then
            echo -e "  neodesk-console (Node.js): ${CYAN}disabled${NC} (a leftover; sudo systemctl disable neodesk-console and remove its unit)"
        fi
    else
        echo -n "  neodesk-console (Node.js): "
        if systemctl is-active --quiet "$LEGACY_CONSOLE_SERVICE" 2>/dev/null; then
            echo -e "${GREEN}● Active${NC} (the old console, which this installer does not upgrade)"
        elif systemctl is-enabled --quiet "$LEGACY_CONSOLE_SERVICE" 2>/dev/null; then
            echo -e "${YELLOW}○ Enabled but inactive${NC}"
            warnings=$((warnings + 1))
        else
            echo -e "${RED}○ Disabled${NC}"
            errors=$((errors + 1))
        fi
    fi

    # Check ports
    echo ""
    echo -e "${WHITE}Checking ports...${NC}"
    echo ""

    for port in "${GO_API_PORT:-21114}" "${CLIENT_API_PORT:-21121}" 21115 21116 21117 "$(resolve_panel_http_port)"; do
        echo -n "  Port $port: "
        if ss -tlnp 2>/dev/null | grep -q ":$port " || netstat -tlnp 2>/dev/null | grep -q ":$port "; then
            local pname=$(ss -tlnp 2>/dev/null | grep ":$port " | grep -oP 'users:\(\("\K[^"]+' 2>/dev/null | head -1)
            echo -e "${GREEN}● Listening${NC}${pname:+ ($pname)}"
        else
            echo -e "${YELLOW}○ Free${NC}"
            warnings=$((warnings + 1))
        fi
    done
    
    # Summary
    echo ""
    echo -e "${WHITE}═══════════════════════════════════════${NC}"
    
    if [ $errors -eq 0 ] && [ $warnings -eq 0 ]; then
        echo -e "${GREEN}✓ Installation correct - no problems found${NC}"
    elif [ $errors -eq 0 ]; then
        echo -e "${YELLOW}! Found $warnings warnings${NC}"
    else
        echo -e "${RED}✗ Found $errors errors and $warnings warnings${NC}"
        echo ""
        echo -e "${CYAN}Use 'REPAIR INSTALLATION' option to fix problems${NC}"
    fi
    
    press_enter
}

#===============================================================================
# Backup Functions
#===============================================================================

# move_backup_folder: the backups of an install of 3.6.0-rc.4 or older (in
# /opt/rustdesk-backups) go to BACKUP_DIR, and nothing is left at the old
# place; a link to BACKUP_DIR that an earlier build left there goes too. A
# backup whose name BACKUP_DIR has already stays where it is, and so does
# the folder. A BACKUP_DIR given to the installer is left alone.
move_backup_folder() {
    local old="$OLD_BACKUP_DIR" item left=0
    [ -z "${BACKUP_DIR_GIVEN:-}" ] || return 0
    if [ -L "$old" ]; then
        [ "$(readlink "$old")" != "$BACKUP_DIR" ] || rm -f "$old" || return 1
        return 0
    fi
    [ -d "$old" ] || return 0
    if [ ! -e "$BACKUP_DIR" ] && [ ! -L "$BACKUP_DIR" ]; then
        { mkdir -p "$(dirname "$BACKUP_DIR")" && mv "$old" "$BACKUP_DIR"; } || return 1
    else
        for item in "$old"/* "$old"/.[!.]*; do
            { [ -e "$item" ] || [ -L "$item" ]; } || continue
            if [ -e "$BACKUP_DIR/${item##*/}" ] || [ -L "$BACKUP_DIR/${item##*/}" ] || ! mv "$item" "$BACKUP_DIR/"; then
                left=$((left + 1))
            fi
        done
        if [ "$left" -gt 0 ]; then
            print_warning "$left backup(s) stay in $old: $BACKUP_DIR has some of the same name"
            return 0
        fi
        rmdir "$old" || return 1
    fi
    print_info "The backups moved from $old to $BACKUP_DIR"
}

do_backup() {
    print_header
    echo -e "${WHITE}${BOLD}══════════ BACKUP ══════════${NC}"
    echo ""
    
    do_backup_silent
    
    print_success "Backup completed!"
    press_enter
}

# secure_backup_folder: the installer's backups hold the server's private
# key, the API key and every secret of .env, so only root may read them:
# each backup is 0600 (a folder in it 0700), and so is the backup folder,
# unless it is a BACKUP_DIR given to the installer, whose mode stays.
secure_backup_folder() {
    [ -d "$BACKUP_DIR" ] || return 0
    [ -n "${BACKUP_DIR_GIVEN:-}" ] || chmod 700 "$BACKUP_DIR" 2>/dev/null || true
    find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 \( -name 'neodesk_backup_*' -o -name 'pre-go-*' \) \
        -exec chmod -R go-rwx {} + 2>/dev/null || true
    return 0
}

# installer_backups: the backups this installer made in BACKUP_DIR, one
# path per line.
installer_backups() {
    [ -d "$BACKUP_DIR" ] || return 0
    find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 \( -name 'neodesk_backup_*' -o -name 'pre-go-*' \) 2>/dev/null | sort
}

# postgresql_left_behind URL: what the uninstall leaves of the PostgreSQL
# database at URL, with the commands that remove it when it is on this
# machine.
postgresql_left_behind() {
    local rest authority userinfo="" hostport host db user
    rest="${1#*://}"
    authority="${rest%%/*}"
    db=""
    [ "$authority" != "$rest" ] && db="${rest#*/}"
    db="${db%%\?*}"
    case "$authority" in *@*) userinfo="${authority%@*}" ;; esac
    hostport="${authority##*@}"
    user="${userinfo%%:*}"
    case "$hostport" in
        \[*) host="${hostport%%]*}"; host="${host#[}" ;;
        *) host="${hostport%%:*}" ;;
    esac
    case "${host,,}" in
        ""|localhost|127.0.0.1|::1)
            if [ -n "$db" ] && [ -n "$user" ]; then
                printf 'the PostgreSQL database %s and its user %s (sudo -u postgres dropdb %s && sudo -u postgres dropuser %s), and PostgreSQL itself\n' "$db" "$user" "$db" "$user"
            else
                printf 'the PostgreSQL database %s, and PostgreSQL itself (remove it: sudo -u postgres dropdb %s)\n' "${db:-neodesk}" "${db:-neodesk}"
            fi
            ;;
        *) printf 'the PostgreSQL database %s on %s\n' "${db:-neodesk}" "$host" ;;
    esac
}

# prune_backups: the newest BACKUP_KEEP (5) of the installer's backups stay,
# older ones are removed; BACKUP_KEEP=0 keeps them all. The names carry the
# time, so they sort by age.
prune_backups() {
    local keep="${BACKUP_KEEP:-5}" old
    [[ "$keep" =~ ^[0-9]+$ ]] && [ "$keep" -gt 0 ] && [ -d "$BACKUP_DIR" ] || return 0
    while IFS= read -r old; do
        [ -n "$old" ] || continue
        rm -f -- "$old" && print_info "Removed the old backup $(basename "$old")"
    done < <(find "$BACKUP_DIR" -maxdepth 1 -type f -name 'neodesk_backup_*.tar.gz' | sort | head -n -"$keep")
}

do_backup_silent() {
    local backup_name="neodesk_backup_$(date +%Y%m%d_%H%M%S)"
    local backup_path="$BACKUP_DIR/$backup_name"
    local old_umask
    old_umask=$(umask)

    # What this makes is for root only (secure_backup_folder)
    umask 077
    mkdir -p "$backup_path"
    secure_backup_folder

    print_step "Creating backup: $backup_name"

    # The server's own backup: a consistent copy of the database (SQLite or
    # PostgreSQL), the env file, the console's data and its certificates,
    # also while the server runs. An older binary has none: the SQLite file
    # is copied as it is
    local archive=""
    if binary_backs_up && archive=$(server_cmd backup --out "$backup_path" 2>>"$LOG_FILE"); then
        print_info "  - Database, settings and the console's data ($(basename "$archive"))"
    else
        if binary_backs_up; then
            print_warning "neodesk-server backup failed (its message is in $LOG_FILE); the backup holds a copy of the database file instead"
        fi
        if [ -f "$DB_PATH" ]; then
            cp "$DB_PATH" "$backup_path/"
            print_info "  - Database"
        fi
    fi
    
    # Backup keys
    if [ -f "$RUSTDESK_PATH/id_ed25519" ]; then
        cp "$RUSTDESK_PATH/id_ed25519"* "$backup_path/"
        print_info "  - Keys"
    fi
    
    # Backup API key
    if [ -f "$RUSTDESK_PATH/.api_key" ]; then
        cp "$RUSTDESK_PATH/.api_key" "$backup_path/"
        print_info "  - API key"
    fi
    
    # Backup credentials
    if [ -f "$RUSTDESK_PATH/.admin_credentials" ]; then
        cp "$RUSTDESK_PATH/.admin_credentials" "$backup_path/"
        print_info "  - Login credentials"
    fi
    
    # Create archive
    tar -C "$BACKUP_DIR" -czf "$BACKUP_DIR/$backup_name.tar.gz" "$backup_name"
    chmod 600 "$BACKUP_DIR/$backup_name.tar.gz" 2>/dev/null || true
    rm -rf "$backup_path"
    umask "$old_umask"

    print_success "Backup saved: $BACKUP_DIR/$backup_name.tar.gz (readable by root only)"
    prune_backups
}

#===============================================================================
# Password Reset Functions
#===============================================================================

do_reset_password() {
    print_header
    echo -e "${WHITE}${BOLD}══════════ ADMIN PASSWORD RESET ══════════${NC}"
    echo ""

    # Refresh detection
    auto_detect_paths

    if [ "$CONSOLE_TYPE" = "none" ]; then
        print_error "No console installation detected!"
        press_enter
        return 1
    fi
    if [ "$CONSOLE_TYPE" = "nodejs" ]; then
        refuse_node_era_install
        press_enter
        return 1
    fi

    local pw_choice new_password
    if [ "$AUTO_MODE" = true ]; then
        # --reset-password: ADMIN_PASSWORD, else a random one
        pw_choice=1
        [ -n "${ADMIN_PASSWORD:-}" ] && pw_choice=env
    else
        local _menu_items=(
            $'Generate random password\tCreate a strong random admin password'
            $'Set custom password\tType a new password (min. 8 characters)'
            $'Back\tReturn to the main menu'
        )
        local _menu_returns=( 1 2 0 )
        menu_choose "Admin Password Reset" "The account admin of the web console"
        pw_choice="$MENU_CHOICE"
    fi

    case $pw_choice in
        1)
            # M-05: full hex entropy
            new_password=$(openssl rand -hex 16)
            ;;
        env)
            new_password="$ADMIN_PASSWORD"
            if [ ${#new_password} -lt 8 ]; then
                print_error "ADMIN_PASSWORD must be at least 8 characters"
                return 1
            fi
            ;;
        2)
            echo ""
            read -sp "Enter new password (min. 8 characters): " new_password
            echo ""
            if [ ${#new_password} -lt 8 ]; then
                print_error "Password must be at least 8 characters!"
                press_enter
                return
            fi
            ;;
        *)
            return
            ;;
    esac

    # The server sets it on the console's database (SQLite or PostgreSQL);
    # the password goes in on standard input, never in the arguments
    local -a reset_args=(reset-password)
    if [ "$RESET_TWO_FACTOR" = true ]; then
        if ! grep -a -q -F -- '--reset-two-factor' "$(server_binary_path)" 2>/dev/null; then
            print_error "This neodesk-server can't turn off two-factor sign-in; update it first: sudo $(basename "$MANAGER_COMMAND") --update"
            press_enter
            return 1
        fi
        reset_args+=(--reset-two-factor)
    fi
    reset_args+=(admin)

    local success=false reset_out
    if reset_out=$(printf '%s\n' "$new_password" | server_cmd --as-service "${reset_args[@]}" 2>&1); then
        success=true
        log "neodesk-server reset-password: $reset_out"
    else
        printf '%s\n' "$reset_out"
    fi

    echo ""
    if [ "$success" = "true" ]; then
        # .env keeps no password: an old one there would come back at a
        # start with a forced password update
        forget_first_admin_password

        credentials_box "New web console sign-in (shown only now)" "$new_password"
        if [ "$RESET_TWO_FACTOR" = true ]; then
            print_info "Two-factor sign-in is off for admin; where it is required, the console sets it up again at the next sign-in."
        else
            print_info "Two-factor sign-in stays as it was. Lost the authenticator and the recovery codes too? sudo $(basename "$MANAGER_COMMAND") --reset-password --reset-two-factor"
        fi

        # Persist credentials only when explicitly requested.
        if [ "$STORE_ADMIN_CREDENTIALS" = "true" ]; then
            (umask 077 && cat > "$RUSTDESK_PATH/.admin_credentials") << CREDEOF
Admin Username: admin
Admin Password: $new_password
Generated by: NeoDesk password reset
Timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)
CREDEOF
            chmod 600 "$RUSTDESK_PATH/.admin_credentials"
        fi
    else
        print_error "Failed to reset password!"
        print_info "Check the database settings in $CONSOLE_PATH/.env"
    fi

    press_enter
    [ "$success" = true ]
}

#===============================================================================
# Build Functions
#===============================================================================

# Legacy Support Agent source staging — Generator now downloads NeoDesk-Client
# templates into data/modules/neodesk-support-generator/. Kept as a no-op so
# older install/update call sites do not fail.
stage_support_agent_source() {
    print_info "Support Generator uses Client templates (module install); skipping Go support-agent staging"
    return 0
}

# Optional developer toolchain for local embedded NeoDesk-Client builds.
# Production installs should Import latest release in Generator instead —
# signed agents come from GitHub (NeoDesk-Client), not from this host.
do_install_build_toolchain() {
    print_header
    echo -e "${WHITE}${BOLD}══════════ AGENT BUILD TOOLCHAIN (OPTIONAL / DEV) ══════════${NC}"
    echo ""
    echo "  Production: use Generator → Import latest release"
    echo "  (signed incoming-only agents from NeoDesk-Client)."
    echo "  This host does NOT need Flutter/Cargo for that path."
    echo ""
    echo "  This menu is for maintainers who set"
    echo "  NEODESK_CLIENT_GENERATOR_MODE=embedded and compile"
    echo "  Support agents locally (large download; not required)."
    echo ""
    echo "  Disk:  ~3 GB download, ~5 GB after install,"
    echo "         plus cargo build cache (/var/cache/neodesk-build)."
    echo ""

    local toolchain_script="$REPO_DIR/scripts/install-build-toolchain.sh"

    if [ ! -f "$toolchain_script" ]; then
        print_error "Toolchain installer not found: $toolchain_script"
        print_info "Pull the latest repository and try again."
        press_enter
        return 1
    fi

    if [ "$AUTO_MODE" != true ]; then
        read -p "Proceed with toolchain install? [y/N]: " confirm
        confirm="${confirm:-N}"
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            print_info "Cancelled."
            press_enter
            return 0
        fi
    fi

    local extra_args=()
    [ "$AUTO_MODE" = true ] && extra_args+=(--unattended)

    BUILD_USER="${SUDO_USER:-${BUILD_USER:-neodesk}}" \
        bash "$toolchain_script" "${extra_args[@]}"

    local rc=$?
    if [ $rc -eq 0 ]; then
        stage_support_agent_source "$script_dir" || true
        print_success "Build toolchain installed."
        print_info "Restart the server to pick up the new PATH:"
        print_info "  sudo systemctl restart neodesk-server"
    else
        print_error "Toolchain installer exited with code $rc"
    fi
    press_enter
    return $rc
}

do_build() {
    local _menu_items=(
        $'Rebuild & deploy server\tCompile, stop, replace and restart the Go server'
        $'Compile server only\tBuild the Go binary without deploying it'
        $'Build legacy Rust binaries\tArchived hbbs/hbbr (advanced)'
        $'Back\tReturn to the main menu'
    )
    local _menu_returns=( 1 2 3 0 )
    menu_choose "Build & Deploy" "Rebuild and deploy the NeoDesk Go server"
    local build_choice="${MENU_CHOICE:-1}"

    case $build_choice in
        1) do_rebuild_go_server ;;
        2) do_compile_go_only ;;
        3) do_build_legacy_rust ;;
        0) return ;;
        *) print_warning "Invalid option"; sleep 1 ;;
    esac
}

# Rebuild & deploy Go server: compile → backup → stop → replace → start → verify
do_rebuild_go_server() {
    print_header
    echo -e "${WHITE}${BOLD}══════════ REBUILD & DEPLOY GO SERVER ══════════${NC}"
    echo ""

    detect_installation

    if [ "$INSTALL_STATUS" = "none" ]; then
        print_warning "NeoDesk is not installed. Binary will be compiled but not deployed."
        if ! confirm "Continue with compilation only?"; then
            press_enter
            return
        fi
        do_compile_go_only
        return
    fi

    # Step 1: Compile
    print_step "[1/5] Compiling Go server from source..."
    detect_architecture

    if ! compile_go_server; then
        print_error "Compilation failed — aborting. Current installation is untouched."
        press_enter
        return
    fi

    local new_binary="$GO_SERVER_SOURCE/neodesk-server"
    if [ ! -f "$new_binary" ]; then
        print_error "Compiled binary not found at $new_binary"
        press_enter
        return
    fi

    # Step 2: Backup current binary
    print_step "[2/5] Backing up current binary..."
    local installed_binary="$RUSTDESK_PATH/neodesk-server"
    local ts
    ts=$(date +%Y%m%d_%H%M%S)
    if [ -f "$installed_binary" ]; then
        cp "$installed_binary" "${installed_binary}.backup.${ts}"
        print_info "Backup: ${installed_binary}.backup.${ts}"
    else
        print_info "No existing binary to backup"
    fi

    # Step 3: Stop services
    print_step "[3/5] Stopping services..."
    graceful_stop_services

    # Step 4: Replace binary
    print_step "[4/5] Deploying new binary..."
    mkdir -p "$RUSTDESK_PATH"
    cp "$new_binary" "$installed_binary"
    chmod +x "$installed_binary"
    local size
    size=$(du -h "$installed_binary" | cut -f1)
    print_success "Deployed: $installed_binary ($size)"

    # Step 5: Start services and verify
    print_step "[5/5] Starting services..."
    start_services_with_verification

    if systemctl is-active --quiet neodesk-server 2>/dev/null; then
        echo ""
        print_success "Go server rebuilt and deployed successfully!"
        echo ""
        echo -e "${WHITE}Recent logs:${NC}"
        journalctl -u neodesk-server -n 5 --no-pager 2>/dev/null || true
    else
        print_error "Service failed to start after rebuild!"
        echo ""
        echo -e "${YELLOW}Rolling back to previous binary...${NC}"
        if [ -f "${installed_binary}.backup.${ts}" ]; then
            cp "${installed_binary}.backup.${ts}" "$installed_binary"
            chmod +x "$installed_binary"
            systemctl start neodesk-server 2>/dev/null || true
            sleep 2
            if systemctl is-active --quiet neodesk-server 2>/dev/null; then
                print_success "Rollback successful — previous binary restored"
            else
                print_error "Rollback also failed. Check: journalctl -u neodesk-server -n 50"
            fi
        else
            print_error "No backup to rollback to. Check: journalctl -u neodesk-server -n 50"
        fi
    fi

    press_enter
}

# Compile Go server only (no deployment)
do_compile_go_only() {
    print_header
    echo -e "${WHITE}${BOLD}══════════ COMPILE GO SERVER ══════════${NC}"
    echo ""

    detect_architecture

    if ! compile_go_server; then
        print_error "Compilation failed"
        press_enter
        return
    fi

    local new_binary="$GO_SERVER_SOURCE/neodesk-server"
    local size
    size=$(du -h "$new_binary" | cut -f1)
    print_success "Binary compiled: $new_binary ($size)"
    print_info "Use option 7 → 1 to deploy it, or copy manually."

    press_enter
}

# Legacy Rust build (archived — hbbs/hbbr)
do_build_legacy_rust() {
    print_header
    echo -e "${WHITE}${BOLD}══════════ BUILD LEGACY RUST BINARIES ══════════${NC}"
    echo ""
    print_warning "Legacy Rust binaries (hbbs/hbbr) are archived."
    print_info "The Go server is the current architecture."
    echo ""
    if ! confirm "Continue with legacy Rust build anyway?"; then
        return
    fi

    # Check Rust
    if ! command -v cargo &> /dev/null; then
        print_warning "Rust is not installed!"
        echo ""
        if confirm "Do you want to install Rust?"; then
            curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
            source "$HOME/.cargo/env"
        else
            press_enter
            return
        fi
    fi

    print_info "Rust: $(cargo --version)"
    echo ""

    local build_dir="/tmp/neodesk_build_$$"
    mkdir -p "$build_dir"
    cd "$build_dir"

    print_step "Downloading RustDesk Server sources..."
    git clone --depth 1 --branch 1.1.14 https://github.com/rustdesk/rustdesk-server.git
    cd rustdesk-server
    git submodule update --init --recursive

    print_step "Applying NeoDesk modifications..."

    # Copy modified sources
    if [ -d "$REPO_DIR/hbbs-patch-v2/src" ]; then
        cp "$REPO_DIR/hbbs-patch-v2/src/main.rs" src/ 2>/dev/null || true
        cp "$REPO_DIR/hbbs-patch-v2/src/http_api.rs" src/ 2>/dev/null || true
        cp "$REPO_DIR/hbbs-patch-v2/src/database.rs" src/ 2>/dev/null || true
        cp "$REPO_DIR/hbbs-patch-v2/src/peer.rs" src/ 2>/dev/null || true
        cp "$REPO_DIR/hbbs-patch-v2/src/rendezvous_server.rs" src/ 2>/dev/null || true
    else
        print_error "Modified sources not found in hbbs-patch-v2/src/"
        press_enter
        return
    fi

    print_step "Compiling (may take several minutes)..."
    cargo build --release

    # Copy results
    print_step "Copying binaries..."
    detect_architecture
    mkdir -p "$REPO_DIR/hbbs-patch-v2"

    cp target/release/hbbs "$REPO_DIR/hbbs-patch-v2/hbbs-linux-$ARCH_NAME"
    cp target/release/hbbr "$REPO_DIR/hbbs-patch-v2/hbbr-linux-$ARCH_NAME"

    # Cleanup
    cd /
    rm -rf "$build_dir"

    print_success "Legacy Rust compilation completed!"
    print_info "Binaries saved in: $REPO_DIR/hbbs-patch-v2/"

    press_enter
}

#===============================================================================
# Firewall Configuration
#===============================================================================

# firewall_ports: the ports the installers open, one PORT/PROTO a line:
# the API port a stock RustDesk client without an API server setting calls
# (the signal port minus 2, 21114: callers from other hosts get only the
# client API there), RustDesk's (NAT test, signal TCP and UDP, relay), the
# client API port,
# the CDAP gateway (21122) while CDAP is on, and the console's ports
# unless TLS ends at a reverse proxy (TRUST_PROXY).
firewall_ports() {
    local signal relay value port
    signal=$(signal_port)
    relay=$(relay_port)
    printf '%s\n' "$((signal - 2))/tcp" "$((signal - 1))/tcp" "$signal/tcp" "$signal/udp" "$relay/tcp"
    echo "$(read_effective_console_setting API_PORT "${CLIENT_API_PORT:-21121}")/tcp"
    value=$(read_effective_console_setting CDAP_ENABLED Y | tr '[:upper:]' '[:lower:]')
    case "$value" in n|no|0|false|off) ;; *) echo "21122/tcp" ;; esac
    # relay nodes of sites connect to NODE_CONTROL_PORT; 0 turns it off
    port=$(read_effective_console_setting NODE_CONTROL_PORT 21123)
    [ "$port" = 0 ] || echo "$port/tcp"
    value=$(read_effective_console_setting TRUST_PROXY false | tr '[:upper:]' '[:lower:]')
    case "$value" in y|yes|1|true|on) return 0 ;; esac
    port=$(resolve_panel_http_port)
    [ "$port" != 0 ] && echo "$port/tcp"
    if [ "$(read_effective_console_setting HTTPS_ENABLED false | tr '[:upper:]' '[:lower:]')" = "true" ]; then
        echo "$(resolve_panel_https_port)/tcp"
    fi
    return 0
}

# ufw_active: ufw is installed and on. "ufw status" prints "Status:
# active" or "Status: inactive" (in English with LC_ALL=C); rules added to
# an inactive ufw go live with the next "ufw enable".
ufw_active() {
    command -v ufw &>/dev/null && LC_ALL=C ufw status 2>/dev/null | grep -q '^Status: active'
}

# iptables_is_the_firewall: neither ufw nor firewalld is installed, so
# iptables rules are how this machine filters. A ufw or firewalld that is
# installed but switched off was switched off by its admin: no rules then,
# not even iptables ones.
iptables_is_the_firewall() {
    ! command -v ufw &>/dev/null && ! command -v firewall-cmd &>/dev/null && command -v iptables &>/dev/null
}

# configure_firewall_rules: opens firewall_ports in ufw or firewalld when
# one of them is active, with iptables when neither is installed
# (iptables_is_the_firewall), and names the ports a firewall outside this
# machine needs.
configure_firewall_rules() {
    local entries entry created=0
    mapfile -t entries < <(firewall_ports)
    if ufw_active; then
        print_info "Opening the NeoDesk ports in ufw..."
        for entry in "${entries[@]}"; do
            ufw allow "$entry" comment "NeoDesk" >/dev/null 2>&1 && created=$((created + 1))
        done
    elif command -v firewall-cmd &>/dev/null && systemctl is-active --quiet firewalld 2>/dev/null; then
        print_info "Opening the NeoDesk ports in firewalld..."
        for entry in "${entries[@]}"; do
            firewall-cmd --permanent --add-port="$entry" >/dev/null 2>&1 && created=$((created + 1))
        done
        firewall-cmd --reload >/dev/null 2>&1 || true
    elif iptables_is_the_firewall; then
        print_info "Opening the NeoDesk ports with iptables..."
        for entry in "${entries[@]}"; do
            iptables -C INPUT -p "${entry#*/}" --dport "${entry%/*}" -j ACCEPT 2>/dev/null \
                || iptables -A INPUT -p "${entry#*/}" --dport "${entry%/*}" -j ACCEPT 2>/dev/null
            created=$((created + 1))
        done
        if command -v iptables-save &>/dev/null; then
            iptables-save > /etc/iptables/rules.v4 2>/dev/null || \
            iptables-save > /etc/sysconfig/iptables 2>/dev/null || true
        fi
    else
        print_info "No firewall is active on this machine"
    fi
    [ "$created" -gt 0 ] && print_success "Open: ${entries[*]}"
    print_info "A firewall outside this machine (your cloud provider's) needs the same ports: ${entries[*]}"
    return 0
}

# close_console_firewall_ports: TLS ends at a reverse proxy on this
# machine, which reaches the console on loopback, so the console's ports
# that configure_firewall_rules opened are closed again.
close_console_firewall_ports() {
    local entries=() entry port
    port=$(resolve_panel_http_port)
    [ "$port" != 0 ] && entries+=("$port/tcp")
    entries+=("$(resolve_panel_https_port)/tcp")
    if ufw_active; then
        for entry in "${entries[@]}"; do
            ufw delete allow "$entry" >/dev/null 2>&1 || true
        done
    elif command -v firewall-cmd &>/dev/null && systemctl is-active --quiet firewalld 2>/dev/null; then
        for entry in "${entries[@]}"; do
            firewall-cmd --permanent --remove-port="$entry" >/dev/null 2>&1 || true
        done
        firewall-cmd --reload >/dev/null 2>&1 || true
    elif iptables_is_the_firewall; then
        for entry in "${entries[@]}"; do
            while iptables -D INPUT -p "${entry#*/}" --dport "${entry%/*}" -j ACCEPT 2>/dev/null; do :; done
        done
    else
        return 0
    fi
    print_info "Closed the console's ports ${entries[*]}: the reverse proxy reaches the console on this machine"
}

#===============================================================================
# Diagnostics Functions
#===============================================================================

do_diagnostics() {
    print_header
    echo -e "${WHITE}${BOLD}══════════ DIAGNOSTICS ══════════${NC}"
    echo ""
    
    print_status
    
    echo ""
    echo -e "${WHITE}${BOLD}═══ Service logs (last 10 lines) ═══${NC}"
    echo ""
    
    # Check for Go server first, then legacy Rust services
    if systemctl list-unit-files neodesk-server.service &>/dev/null 2>&1; then
        echo -e "${CYAN}--- neodesk-server (Go) ---${NC}"
        journalctl -u neodesk-server -n 10 --no-pager 2>/dev/null || echo "No logs found"
    else
        echo -e "${CYAN}--- rustdesksignal (Legacy Rust) ---${NC}"
        journalctl -u rustdesksignal -n 10 --no-pager 2>/dev/null || echo "No logs found"
        
        echo ""
        echo -e "${CYAN}--- rustdeskrelay (Legacy Rust) ---${NC}"
        journalctl -u rustdeskrelay -n 10 --no-pager 2>/dev/null || echo "No logs found"
    fi
    
    echo ""
    
    echo ""
    echo -e "${WHITE}${BOLD}═══ Database statistics ═══${NC}"
    echo ""
    
    # The database the server opens with the console's .env (DATABASE_URL,
    # or DB_URL and DB_TYPE of an older install), and only then a SQLite
    # file: a stale db_v2.sqlite3 of an earlier install does not hide
    # PostgreSQL.
    local diag_db_type diag_pg_uri=""
    diag_db_type=$(env_database_type "$CONSOLE_PATH/.env")
    if [ "$diag_db_type" = postgres ]; then
        diag_pg_uri=$(env_database_url "$CONSOLE_PATH/.env")
    fi
    # The Go server may also carry the DSN in its systemd unit (-db postgres://...)
    if [ "$diag_db_type" != "postgres" ] && [ -f /etc/systemd/system/neodesk-server.service ]; then
        local svc_db
        svc_db=$(grep -oP '\-db\s+"?\K(postgres|postgresql)://[^" ]+' /etc/systemd/system/neodesk-server.service 2>/dev/null | head -1)
        if [ -n "$svc_db" ]; then
            diag_db_type="postgres"
            diag_pg_uri="${diag_pg_uri:-$svc_db}"
        fi
    fi
    
    if [ "$diag_db_type" = "postgres" ] && [ -n "$diag_pg_uri" ]; then
        # Mask password for display
        local diag_pg_display
        diag_pg_display=$(echo "$diag_pg_uri" | sed 's|://[^:]*:[^@]*@|://***:***@|')
        echo -e "  Database type:     ${CYAN}PostgreSQL${NC}"
        echo -e "  Connection:        ${DIM}$diag_pg_display${NC}"
        if command -v psql &>/dev/null; then
            if PGCONNECT_TIMEOUT=3 psql "$diag_pg_uri" -tAc "SELECT 1" &>/dev/null; then
                local device_count online_count user_count
                device_count=$(PGCONNECT_TIMEOUT=3 psql "$diag_pg_uri" -tAc "SELECT COUNT(*) FROM peers WHERE soft_deleted = FALSE" 2>/dev/null || echo "0")
                online_count=$(PGCONNECT_TIMEOUT=3 psql "$diag_pg_uri" -tAc "SELECT COUNT(*) FROM peers WHERE soft_deleted = FALSE AND status = 'ONLINE'" 2>/dev/null || echo "0")
                user_count=$(PGCONNECT_TIMEOUT=3 psql "$diag_pg_uri" -tAc "SELECT COUNT(*) FROM users" 2>/dev/null || echo "0")
                echo -e "  Status:            ${GREEN}Connected${NC}"
                echo "  Devices:           ${device_count:-0}"
                echo "  Online:            ${online_count:-0}"
                echo "  Users:             ${user_count:-0}"
            else
                echo -e "  Status:            ${RED}Connection failed${NC}"
                echo -e "  ${YELLOW}Tip: verify the PostgreSQL service and DATABASE_URL credentials${NC}"
            fi
        else
            echo -e "  ${YELLOW}Install the 'psql' client to see live database statistics${NC}"
        fi
    elif [ -f "$DB_PATH" ]; then
        local device_count online_count user_count
        device_count=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM peers WHERE soft_deleted = 0" 2>/dev/null || \
                            sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM peers WHERE is_deleted = 0" 2>/dev/null || \
                            sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM peer WHERE is_deleted = 0" 2>/dev/null || echo "0")
        online_count=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM peers WHERE soft_deleted = 0 AND status = 'ONLINE'" 2>/dev/null || \
                            sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM peers WHERE status = 1 AND is_deleted = 0" 2>/dev/null || \
                            sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM peer WHERE status = 1 AND is_deleted = 0" 2>/dev/null || echo "0")
        user_count=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM users" 2>/dev/null || echo "0")
        
        echo -e "  Database type:     ${CYAN}SQLite${NC}"
        echo -e "  File:              ${DIM}$DB_PATH${NC}"
        echo "  Devices:           $device_count"
        echo "  Online:            $online_count"
        echo "  Users:             $user_count"
    else
        echo -e "  Database type:     ${CYAN}SQLite${NC} (configured)"
        echo -e "  ${YELLOW}SQLite database file not found: $DB_PATH${NC}"
        echo -e "  ${DIM}This is normal before the first device registers.${NC}"
    fi
    
    # --- Port diagnostics ---
    echo ""
    echo -e "${WHITE}${BOLD}═══ Port diagnostics ═══${NC}"
    echo ""
    
    local port_issues=0
    local port_defs=(
        "${GO_API_PORT:-21114}:TCP:neodesk-serv|neodesk-server|hbbs:Go HTTP API (handlers)"
        "${CLIENT_API_PORT:-21121}:TCP:node|MainThread:Client API compat proxy → Go"
        "21115:TCP:neodesk-serv|neodesk-server|hbbs:NAT Test"
        "21116:TCP:neodesk-serv|neodesk-server|hbbs:ID Server (TCP)"
        "21116:UDP:neodesk-serv|neodesk-server|hbbs:ID Server (UDP)"
        "21117:TCP:neodesk-serv|neodesk-server|hbbr:Relay Server"
        "$(resolve_panel_http_port):TCP:neodesk-serv|neodesk-server|node|MainThread:Web Console"
    )
    
    for entry in "${port_defs[@]}"; do
        IFS=':' read -r port proto expected desc <<< "$entry"
        
        local listening=false
        local proc_info=""
        
        if [ "$proto" = "TCP" ]; then
            proc_info=$(ss -tlnp 2>/dev/null | grep ":${port} " | head -1)
            [ -z "$proc_info" ] && proc_info=$(netstat -tlnp 2>/dev/null | grep ":${port} " | head -1)
        else
            proc_info=$(ss -ulnp 2>/dev/null | grep ":${port} " | head -1)
            [ -z "$proc_info" ] && proc_info=$(netstat -ulnp 2>/dev/null | grep ":${port} " | head -1)
        fi
        
        if [ -n "$proc_info" ]; then
            listening=true
            local process_name=$(echo "$proc_info" | grep -oP 'users:\(\("\K[^"]+' 2>/dev/null || \
                                echo "$proc_info" | awk '{print $NF}')
        fi
        
        printf "  Port %s/%s (%-18s): " "$port" "$proto" "$desc"
        
        if $listening; then
            if [ -n "$process_name" ] && echo "$process_name" | grep -qiE "$expected"; then
                echo -e "${GREEN}OK - $process_name${NC}"
            elif [ -n "$process_name" ]; then
                echo -e "${RED}CONFLICT - used by $process_name${NC}"
                port_issues=$((port_issues + 1))
            else
                echo -e "${GREEN}LISTENING${NC}"
            fi
        else
            echo -e "${YELLOW}NOT LISTENING${NC}"
        fi
    done
    
    if [ $port_issues -gt 0 ]; then
        echo ""
        print_warning "$port_issues port conflict(s) detected!"
        echo -e "  ${YELLOW}Tip: Stop conflicting processes or change ports in configuration${NC}"
    fi
    
    # --- Firewall diagnostics ---
    echo ""
    echo -e "${WHITE}${BOLD}═══ Firewall status ═══${NC}"
    echo ""
    
    local fw_type="none"
    local missing_rules=0
    local required_ports="${GO_API_PORT:-21114} ${CLIENT_API_PORT:-21121} 21115 21116 21117 $(resolve_panel_http_port)"
    
    if ufw_active; then
        fw_type="ufw"
        echo -e "  Firewall: ${YELLOW}UFW (active)${NC}"
        echo ""
        
        for port in $required_ports; do
            local status_line=$(ufw status 2>/dev/null | grep -E "^${port}[/ ]")
            printf "  Port %-5s: " "$port"
            if [ -n "$status_line" ]; then
                echo -e "${GREEN}ALLOWED${NC}"
            else
                echo -e "${RED}NO RULE${NC}"
                missing_rules=$((missing_rules + 1))
            fi
        done
        
    elif command -v firewall-cmd &>/dev/null && systemctl is-active --quiet firewalld 2>/dev/null; then
        fw_type="firewalld"
        echo -e "  Firewall: ${YELLOW}firewalld (active)${NC}"
        echo ""
        
        local open_ports=$(firewall-cmd --list-ports 2>/dev/null)
        for port in $required_ports; do
            printf "  Port %-5s: " "$port"
            if echo "$open_ports" | grep -qE "${port}/tcp|${port}/udp"; then
                echo -e "${GREEN}ALLOWED${NC}"
            else
                echo -e "${RED}NO RULE${NC}"
                missing_rules=$((missing_rules + 1))
            fi
        done
        
    elif iptables -L INPUT -n 2>/dev/null | grep -q "ACCEPT"; then
        fw_type="iptables"
        echo -e "  Firewall: ${YELLOW}iptables${NC}"
        echo ""
        
        for port in $required_ports; do
            printf "  Port %-5s: " "$port"
            if iptables -L INPUT -n 2>/dev/null | grep -qE "dpt:${port}\b"; then
                echo -e "${GREEN}ALLOWED${NC}"
            else
                echo -e "${RED}NO RULE / CHECK MANUALLY${NC}"
                missing_rules=$((missing_rules + 1))
            fi
        done
    else
        echo -e "  Firewall: ${GREEN}No active firewall detected (all ports open)${NC}"
    fi
    
    if [ $missing_rules -gt 0 ]; then
        echo ""
        print_warning "$missing_rules firewall rule(s) missing!"
        echo -e "  ${YELLOW}Use option 'F' below to auto-configure firewall${NC}"
    fi
    
    # --- API connectivity test ---
    echo ""
    echo -e "${WHITE}${BOLD}═══ API connectivity ═══${NC}"
    echo ""
    
    local api_port="${GO_API_PORT:-21114}"
    
    # Detect if Go server API uses TLS (only if explicit --tls-api in service args)
    local api_use_tls=false
    local api_scheme="http"
    if systemctl cat neodesk-server.service 2>/dev/null | grep -qE '\-tls-api'; then
        api_use_tls=true
        api_scheme="https"
    fi
    
    printf "  Go Server API (%s %s):  " "$api_scheme" "$api_port"
    if [ "$api_use_tls" = true ]; then
        if curl -skfo /dev/null --connect-timeout 3 "https://127.0.0.1:${api_port}/api/health" 2>/dev/null; then
            echo -e "${GREEN}OK (HTTPS)${NC}"
        else
            # Fallback: try HTTP in case TLS is only on signal/relay
            if curl -sfo /dev/null --connect-timeout 3 "http://127.0.0.1:${api_port}/api/health" 2>/dev/null; then
                echo -e "${GREEN}OK (HTTP)${NC}"
                echo -e "  ${YELLOW}⚠ Note: Go server has TLS cert but API responds on HTTP${NC}"
            else
                echo -e "${RED}UNREACHABLE${NC}"
                echo -e "  ${YELLOW}Tip: Check neodesk-server logs: journalctl -u neodesk-server -n 20${NC}"
            fi
        fi
    else
        if curl -sfo /dev/null --connect-timeout 3 "http://127.0.0.1:${api_port}/api/health" 2>/dev/null; then
            echo -e "${GREEN}OK${NC}"
        else
            echo -e "${RED}UNREACHABLE${NC}"
        fi
    fi
    
    printf "  Web Console (%s):    " "$(resolve_panel_http_port)"
    if curl -sfo /dev/null --connect-timeout 3 "http://127.0.0.1:$(resolve_panel_http_port)/health" 2>/dev/null; then
        echo -e "${GREEN}OK${NC}"
    else
        echo -e "${RED}UNREACHABLE${NC}"
    fi
    
    # --- TLS mismatch detection ---
    if [ "$api_use_tls" = true ]; then
        local console_api_url=""
        # Check what URL the console is configured to use
        if [ -f "$CONSOLE_PATH/.env" ]; then
            console_api_url=$(grep -m1 '^NEODESK_API_URL=' "$CONSOLE_PATH/.env" 2>/dev/null | cut -d= -f2-)
        fi
        
        if [ -n "$console_api_url" ] && echo "$console_api_url" | grep -q '^http://'; then
            echo ""
            print_warning "TLS MISMATCH DETECTED!"
            echo -e "  ${YELLOW}Go server has TLS enabled but console is configured with HTTP:${NC}"
            echo -e "  ${YELLOW}  Console URL: $console_api_url${NC}"
            echo -e "  ${YELLOW}  Expected:    https://localhost:$api_port/api${NC}"
            echo -e "  ${YELLOW}  Fix: Re-run installation (option 1) or update .env and systemd service${NC}"
        fi
    fi
    
    # --- Diagnostics sub-menu ---
    echo ""
    local _menu_items=(
        $'Configure firewall rules\tAuto-create any missing firewall rules'
        $'Test external ports\tCheck port connectivity from outside'
        $'Back\tReturn to the main menu'
    )
    local _menu_returns=( F P 0 )
    menu_choose "Diagnostics Actions" "Optional follow-up checks"
    local sub_choice="$MENU_CHOICE"
    
    case "$sub_choice" in
        [Ff])
            echo ""
            configure_firewall_rules
            press_enter
            ;;
        [Pp])
            echo ""
            echo -e "${WHITE}${BOLD}═══ External port test ═══${NC}"
            echo ""
            local server_ip=$(get_public_ip)
            print_info "Public IP: $server_ip"
            print_info "Testing external port accessibility..."
            echo ""
            
            for port in 21115 21116 21117; do
                printf "  Port %s: " "$port"
                if timeout 3 bash -c "echo >/dev/tcp/$server_ip/$port" 2>/dev/null; then
                    echo -e "${GREEN}REACHABLE${NC}"
                else
                    echo -e "${RED}BLOCKED/UNREACHABLE${NC}"
                fi
            done
            press_enter
            ;;
        *)
            return
            ;;
    esac
}

#===============================================================================
# Uninstall Functions
#===============================================================================

do_uninstall() {
    print_header
    echo -e "${RED}${BOLD}══════════ UNINSTALL ══════════${NC}"
    echo ""
    
    print_warning "This operation will remove NeoDesk Console!"
    echo ""
    
    if [ "$AUTO_MODE" != true ] && [ "$UNINSTALL_MODE" != true ]; then
        if ! confirm "Are you sure you want to continue?"; then
            return
        fi
    fi
    
    # The installer's backups: removed only when asked, on a terminal
    local remove_backups=false
    if [ -d "$BACKUP_DIR" ] && [ -n "$(installer_backups)" ] \
        && { [ "$AUTO_MODE" != true ] || { [ "$PURGE_MODE" = true ] && has_terminal; }; } \
        && confirm "Remove the backups in $BACKUP_DIR too? They hold the server's keys and settings."; then
        remove_backups=true
    fi

    if [ "$remove_backups" != true ] && { [ "$AUTO_MODE" = true ] || confirm "Create backup before uninstall?"; }; then
        do_backup_silent
    fi
    # The database, read before the settings that name it go
    local database_url
    database_url=$(env_database_url "$CONSOLE_PATH/.env")

    print_step "Stopping services..."
    # Stop Go server (primary)
    systemctl stop neodesk-server neodesk-console 2>/dev/null || true
    systemctl disable neodesk-server neodesk-console 2>/dev/null || true
    # Stop legacy Rust services if they exist
    systemctl stop rustdesksignal rustdeskrelay neodesk neodesk-api neodesk-go 2>/dev/null || true
    systemctl disable rustdesksignal rustdeskrelay neodesk neodesk-api neodesk-go 2>/dev/null || true
    
    print_step "Removing service files..."
    # Remove Go services
    rm -f /etc/systemd/system/neodesk-server.service
    rm -f /etc/systemd/system/neodesk-console.service
    # Remove legacy services
    rm -f /etc/systemd/system/rustdesksignal.service
    rm -f /etc/systemd/system/rustdeskrelay.service
    rm -f /etc/systemd/system/neodesk.service
    rm -f /etc/systemd/system/neodesk-api.service
    rm -f /etc/systemd/system/neodesk-go.service
    systemctl daemon-reload
    
    if [ "$PURGE_MODE" = true ] || { [ "$AUTO_MODE" != true ] && confirm "Remove installation files ($RUSTDESK_PATH)?"; }; then
        rm -rf "$RUSTDESK_PATH"
        print_info "Removed: $RUSTDESK_PATH"
    else
        print_info "Preserved server data: $RUSTDESK_PATH"
    fi
    
    if [ "$PURGE_MODE" = true ] || { [ "$AUTO_MODE" != true ] && confirm "Remove Web Console ($CONSOLE_PATH)?"; }; then
        rm -rf "$CONSOLE_PATH"
        print_info "Removed: $CONSOLE_PATH"
    else
        print_info "Preserved console data: $CONSOLE_PATH"
    fi
    
    # The commands: neodesk-setup, neodesk when it is the command line
    # this installer placed, and the manager at its old place
    if [ "$PURGE_MODE" = true ]; then
        rm -f "$MANAGER_COMMAND"
        if is_our_cli "$CLI_COMMAND"; then rm -f "$CLI_COMMAND"; fi
        if is_old_manager "$OLD_MANAGER_COMMAND"; then rm -f "$OLD_MANAGER_COMMAND"; fi
    fi

    if [ "$remove_backups" = true ]; then
        local backup
        while IFS= read -r backup; do
            rm -rf -- "$backup"
        done < <(installer_backups)
        rmdir "$BACKUP_DIR" 2>/dev/null || true
        print_info "Removed the backups in $BACKUP_DIR"
    fi

    print_success "NeoDesk has been uninstalled"
    local left=()
    [ -d "$RUSTDESK_PATH" ] && left+=("$RUSTDESK_PATH: the database, the server's keys and certificates")
    [ -d "$CONSOLE_PATH" ] && left+=("$CONSOLE_PATH: the settings (.env) and the console's data")
    if [ -n "$(installer_backups)" ]; then
        left+=("$BACKUP_DIR: the backups, readable by root only (they hold the keys and settings; sudo rm -rf $BACKUP_DIR removes them)")
    fi
    id "$SERVICE_USER" &>/dev/null && left+=("the system user $SERVICE_USER (sudo userdel $SERVICE_USER)")
    if is_postgres_url "$database_url"; then
        left+=("$(postgresql_left_behind "$database_url")")
    fi
    left+=("the firewall rules for the NeoDesk ports")
    [ -x "$MANAGER_COMMAND" ] && left+=("the command $MANAGER_COMMAND, to install again")
    is_our_cli "$CLI_COMMAND" && left+=("the command line $CLI_COMMAND")
    is_old_manager "$OLD_MANAGER_COMMAND" && left+=("the installer's older copy $OLD_MANAGER_COMMAND")
    echo ""
    echo "Left on this machine:"
    printf '  %s\n' "${left[@]}"
    if [ "$PURGE_MODE" != true ] && { [ -d "$RUSTDESK_PATH" ] || [ -d "$CONSOLE_PATH" ]; }; then
        echo "Remove the data too with: sudo $(basename "$MANAGER_COMMAND") --uninstall --purge"
    fi
    press_enter
}

#===============================================================================
# SSL Certificate Configuration
#===============================================================================

do_configure_ssl() {
    maybe_reexec_if_installer_on_disk_is_newer
    print_header
    echo -e "${WHITE}${BOLD}══════════ SSL CERTIFICATE CONFIGURATION ══════════${NC}"
    echo ""

    if [ ! -f "$CONSOLE_PATH/.env" ]; then
        print_error "Console .env not found at $CONSOLE_PATH/.env"
        print_info "Please install NeoDesk first (option 1)"
        press_enter
        return
    fi

    local ssl_dir="$RUSTDESK_PATH/ssl"
    local env_file="$CONSOLE_PATH/.env"
    local ssl_tls_active="no"

    local _menu_items=(
        $'Let\'s Encrypt\tAutomatic cert (needs domain name + port 80)'
        $'Custom certificate\tProvide your own cert + key files'
        $'Self-signed certificate\tLAN / testing only'
        $'Disable SSL\tRevert the console to plain HTTP'
        $'Enterprise TLS\tPanel + signal + relay TLS (API stays HTTP)'
        $'External reverse proxy\tTLS at Caddy/Nginx — panel HTTP on localhost'
    )
    local _menu_returns=( 1 2 3 4 5 6 )
    menu_choose "SSL Certificate Configuration" "HTTPS for the panel, or TLS at an external reverse proxy"
    local ssl_choice="$MENU_CHOICE"

    case "${ssl_choice:-1}" in
        1)
            echo ""
            read -p "Enter your domain name (e.g., neodesk.example.com): " domain
            if [ -z "$domain" ]; then
                print_error "Domain name required for Let's Encrypt"
                press_enter
                return
            fi

            if ! command -v certbot &> /dev/null; then
                print_step "Installing certbot..."
                if command -v apt-get &> /dev/null; then apt_quiet install -y certbot
                elif command -v dnf &> /dev/null; then dnf install -y certbot
                elif command -v yum &> /dev/null; then yum install -y certbot
                elif command -v pacman &> /dev/null; then pacman -Sy --noconfirm certbot
                else
                    print_error "Could not install certbot. Please install it manually."
                    press_enter
                    return
                fi
            fi

            print_step "Requesting certificate for $domain..."
            print_info "Port 80 must be accessible from the internet"

            certbot certonly --standalone --preferred-challenges http \
                -d "$domain" --non-interactive --agree-tos \
                --email "admin@$domain" 2>&1 || {
                    print_error "Certificate request failed. Make sure port 80 is open and the domain points to this server."
                    press_enter
                    return
                }

            local le_live_dir="/etc/letsencrypt/live/$domain"
            if ! deploy_ssl_material_to_rustdesk_dir \
                "$le_live_dir/fullchain.pem" "$le_live_dir/privkey.pem" "$le_live_dir"; then
                print_error "Failed to deploy Let's Encrypt certificate for console user"
                press_enter
                return
            fi

            apply_console_protocol_mode https "$ssl_dir/neodesk.crt" "$ssl_dir/neodesk.key" true false
            ssl_tls_active="yes"

            if ! crontab -l 2>/dev/null | grep -q "certbot renew"; then
                (crontab -l 2>/dev/null; echo "0 3 * * * certbot renew --quiet") | crontab -
                print_info "Auto-renewal cron job added (daily at 3:00 AM)"
            fi

            print_success "Let's Encrypt certificate configured for $domain"
            print_info "Open the panel at https://${domain}:$(resolve_panel_https_port) (IP access will show certificate errors)"
            ;;
        2)
            echo ""
            read -p "Path to certificate file (PEM): " cert_path
            read -p "Path to private key file (PEM): " key_path
            read -p "Path to CA bundle (optional, press Enter to skip): " ca_path

            if [ ! -f "$cert_path" ] || [ ! -f "$key_path" ]; then
                print_error "Certificate or key file not found."
                press_enter
                return
            fi
            if ! openssl x509 -in "$cert_path" -noout 2>/dev/null; then
                print_error "The provided certificate is not a valid X.509 file."
                press_enter
                return
            fi

            local deploy_crt="$cert_path" merged_crt=""
            if [ -n "$ca_path" ] && [ -f "$ca_path" ]; then
                merged_crt=$(mktemp)
                cat "$cert_path" "$ca_path" > "$merged_crt"
                deploy_crt="$merged_crt"
            fi
            if ! deploy_ssl_material_to_rustdesk_dir "$deploy_crt" "$key_path"; then
                [ -n "$merged_crt" ] && rm -f "$merged_crt"
                print_error "Failed to deploy custom certificate for console user"
                press_enter
                return
            fi
            [ -n "$merged_crt" ] && rm -f "$merged_crt"

            infer_tls_mode_from_cert "$ssl_dir/neodesk.crt"
            apply_console_protocol_mode https "$ssl_dir/neodesk.crt" "$ssl_dir/neodesk.key" \
                "$INFERRED_RUSTDESK_API_TLS" "$INFERRED_ALLOW_SELF_SIGNED"
            if [ -n "$ca_path" ] && [ -f "$ca_path" ]; then
                _upsert_env_line "$env_file" SSL_CA_PATH "$ca_path"
            fi
            ssl_tls_active="yes"
            print_success "Custom SSL certificate configured"
            ;;
        3)
            mkdir -p "$ssl_dir"
            echo ""
            read -p "Enter domain name (optional, press Enter to skip): " cert_domain

            local server_ip lan_ip san_list cn
            server_ip=$(get_public_ip)
            lan_ip=$(ip -4 addr show scope global | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1 2>/dev/null || \
                     hostname -I 2>/dev/null | awk '{print $1}' || echo "")
            san_list="IP:$server_ip,IP:127.0.0.1,DNS:localhost"
            [ -n "$lan_ip" ] && [ "$lan_ip" != "$server_ip" ] && san_list="$san_list,IP:$lan_ip"
            [ -n "$cert_domain" ] && san_list="DNS:$cert_domain,$san_list"
            cn="${cert_domain:-$server_ip}"

            print_step "Generating self-signed certificate..."
            print_info "SANs: $san_list"
            openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
                -keyout "$ssl_dir/neodesk.key" \
                -out "$ssl_dir/neodesk.crt" \
                -subj "/CN=$cn/O=NeoDesk/C=PL" \
                -addext "subjectAltName=$san_list" 2>/dev/null || \
            openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
                -keyout "$ssl_dir/neodesk.key" \
                -out "$ssl_dir/neodesk.crt" \
                -subj "/CN=$cn/O=NeoDesk/C=PL" 2>/dev/null

            if ! deploy_ssl_material_to_rustdesk_dir "$ssl_dir/neodesk.crt" "$ssl_dir/neodesk.key"; then
                print_error "Failed to set permissions on self-signed certificate"
                press_enter
                return
            fi

            apply_console_protocol_mode https "$ssl_dir/neodesk.crt" "$ssl_dir/neodesk.key" false true
            ssl_tls_active="yes"
            print_success "Self-signed certificate generated (valid 10 years)"
            print_info "Certificate: $ssl_dir/neodesk.crt"
            [ -n "$lan_ip" ] && [ "$lan_ip" != "$server_ip" ] && print_info "LAN IP included: $lan_ip"
            print_warning "Browsers will show security warning. Use Let's Encrypt for public servers."
            ;;
        4)
            apply_console_protocol_mode http
            clear_go_server_signal_relay_tls
            print_success "SSL disabled. Running in HTTP mode."
            print_info "If your browser still redirects to HTTPS, clear site cache or HSTS (chrome://net-internals/#hsts)"
            ;;
        5)
            print_header "Enterprise TLS Configuration"
            echo ""
            print_warning "IMPORTANT: Go API port ${GO_API_PORT:-21114} stays HTTP for RustDesk client compatibility."
            echo ""

            mkdir -p "$ssl_dir"
            read -p "Enter domain name (optional, press Enter to skip): " cert_domain

            local server_ip lan_ip san_list cn
            server_ip=$(get_public_ip)
            lan_ip=$(ip -4 addr show scope global | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1 2>/dev/null || \
                     hostname -I 2>/dev/null | awk '{print $1}' || echo "")
            san_list="IP:$server_ip,IP:127.0.0.1,DNS:localhost"
            [ -n "$lan_ip" ] && [ "$lan_ip" != "$server_ip" ] && san_list="$san_list,IP:$lan_ip"
            [ -n "$cert_domain" ] && san_list="DNS:$cert_domain,$san_list"
            cn="${cert_domain:-$server_ip}"

            print_step "Generating Enterprise certificate..."
            print_info "SANs: $san_list"
            openssl req -x509 -nodes -days 3650 -newkey rsa:4096 \
                -keyout "$ssl_dir/neodesk.key" \
                -out "$ssl_dir/neodesk.crt" \
                -subj "/CN=$cn/O=NeoDesk Enterprise/C=PL" \
                -addext "subjectAltName=$san_list" 2>/dev/null || \
            openssl req -x509 -nodes -days 3650 -newkey rsa:4096 \
                -keyout "$ssl_dir/neodesk.key" \
                -out "$ssl_dir/neodesk.crt" \
                -subj "/CN=$cn/O=NeoDesk Enterprise/C=PL" 2>/dev/null

            if ! deploy_ssl_material_to_rustdesk_dir "$ssl_dir/neodesk.crt" "$ssl_dir/neodesk.key"; then
                print_error "Failed to set permissions on Enterprise certificate"
                press_enter
                return
            fi

            apply_console_protocol_mode https "$ssl_dir/neodesk.crt" "$ssl_dir/neodesk.key" true true
            _upsert_env_line "$env_file" ENTERPRISE_TLS true
            ssl_tls_active="yes"

            print_success "Enterprise TLS configured successfully!"
            echo ""
            print_info "Certificate: $ssl_dir/neodesk.crt"
            print_info "Private key: $ssl_dir/neodesk.key"
            [ -n "$lan_ip" ] && [ "$lan_ip" != "$server_ip" ] && print_info "LAN IP: $lan_ip"
            echo ""
            print_info "  Panel HTTPS: :$(resolve_panel_https_port)"
            print_info "  Signal TLS:  :21116"
            print_info "  Relay TLS:   :21117"
            print_info "  Go API HTTP: :${GO_API_PORT:-21114} (RustDesk client compatibility)"
            ;;
        6)
            do_configure_reverse_proxy || true
            ;;
        *)
            print_warning "Invalid option"
            press_enter
            return
            ;;
    esac

    if [ "$ssl_tls_active" = "yes" ]; then
        sync_go_server_signal_relay_tls "$ssl_dir"
        ensure_service_user >/dev/null
        print_info "Signal/relay TLS enabled; Go API stays HTTP (RustDesk client compatibility)"
        maybe_offer_standard_https_port
    fi

    echo ""
    if confirm "Restart NeoDesk to apply changes?"; then
        repair_https_stuck_state yes
        ensure_console_tls_material_readable 2>/dev/null || true
        systemctl restart neodesk-server 2>/dev/null || true
        print_success "NeoDesk services restarted"
        verify_service_health "neodesk-server" "21116" 15 >/dev/null 2>&1 || true
        verify_go_install 60 >/dev/null 2>&1 || true
        run_protocol_tests
    fi

    press_enter
}

#===============================================================================
# Protocol verification test-suite
#===============================================================================
# Runs a series of non-destructive connectivity / certificate checks after an
# HTTP <-> HTTPS switch so the operator gets immediate, trustworthy feedback.
# Honours the project invariant: the Go API (:21121) must remain HTTP for RustDesk clients.
run_protocol_tests() {
    local go_svc_file="$SERVER_UNIT"
    local ssl_dir="$RUSTDESK_PATH/ssl"
    local pass=0 fail=0 warn=0

    echo ""
    echo -e "${WHITE}${BOLD}═══ Post-configuration tests ═══${NC}"
    echo ""

    _test_ok()   { echo -e "  ${GREEN}✓${NC} $1"; pass=$((pass+1)); }
    _test_fail() { echo -e "  ${RED}✗${NC} $1"; fail=$((fail+1)); }
    _test_warn() { echo -e "  ${YELLOW}!${NC} $1"; warn=$((warn+1)); }

    # ── 1. Services running ──
    if systemctl is-active --quiet neodesk-server 2>/dev/null; then
        _test_ok "Go server service is active"
    else
        _test_fail "Go server service is NOT active (journalctl -u neodesk-server)"
        if journalctl -u neodesk-server --no-pager -n 40 2>/dev/null | grep -q "listen tcp :$(resolve_panel_http_port)"; then
            echo -e "      ${DIM}Hint: Go tried signal on :$(resolve_panel_http_port) — panel PORT in .env leaked; run Repair → Repair HTTPS/TLS${NC}"
        fi
    fi
    if systemctl is-active --quiet "$(console_service_name)" 2>/dev/null; then
        _test_ok "Web console service is active"
    else
        _test_fail "Web console service is NOT active (journalctl -u neodesk-server)"
    fi

    # ── 1b. Wait for Go signal port (post-restart boot delay) ──
    if systemctl is-active --quiet neodesk-server 2>/dev/null; then
        if verify_service_health "neodesk-server" "21116" 15 >/dev/null 2>&1; then
            _test_ok "Go server listening on signal port :21116"
        elif journalctl -u neodesk-server --no-pager -n 40 2>/dev/null | grep -q "listen tcp :$(resolve_panel_http_port)"; then
            _test_fail "Go server tried signal on :$(resolve_panel_http_port) (conflicts with panel redirect) — Repair → Repair HTTPS/TLS"
        else
            _test_fail "Go server not listening on :21116 yet (journalctl -u neodesk-server)"
        fi
    fi

    # ── 2. Effective runtime configuration (systemd overrides .env) ──
    local https_enabled http_port https_port http_redirect api_tls_mode
    https_enabled=$(read_effective_console_setting HTTPS_ENABLED false)
    http_port=$(resolve_panel_http_port)
    https_port=$(resolve_panel_https_port)
    http_redirect=$(read_effective_console_setting HTTP_REDIRECT_HTTPS true)
    api_tls_mode=$(read_effective_console_setting RUSTDESK_API_TLS auto)

    local panel_scheme="http" panel_port
    if [ "$(echo "$https_enabled" | tr '[:upper:]' '[:lower:]')" = "true" ]; then
        panel_scheme="https"
        panel_port="$https_port"
    else
        panel_port="$http_port"
    fi

    # ── 2c. External reverse-proxy mode (TRUST_PROXY + plain HTTP panel) ──
    local trust_proxy_val host_bind
    trust_proxy_val=$(read_effective_console_setting TRUST_PROXY false)
    host_bind=$(read_effective_console_setting HOST "127.0.0.1")
    local _trust_on="no"
    case "$(echo "$trust_proxy_val" | tr '[:upper:]' '[:lower:]')" in
        y|yes|1|true|on) _trust_on="yes" ;;
    esac
    if [ "$(echo "$https_enabled" | tr '[:upper:]' '[:lower:]')" != "true" ] && [ "$_trust_on" = "yes" ]; then
        if [ "$host_bind" = "127.0.0.1" ] || [ "$host_bind" = "localhost" ]; then
            _test_ok "Reverse-proxy mode: panel bound to localhost ($host_bind)"
        elif [ "$host_bind" = "0.0.0.0" ]; then
            _test_ok "Reverse-proxy mode: panel bound to all interfaces (remote proxy host)"
        else
            _test_warn "TRUST_PROXY enabled with HOST=$host_bind (use 127.0.0.1 same-host or 0.0.0.0 remote proxy)"
        fi
        if [ -f "$go_svc_file" ] && grep -qE 'Environment=TRUST_PROXY=Y|-trust-proxy' "$go_svc_file" 2>/dev/null; then
            _test_ok "Go server trusts reverse-proxy headers (TRUST_PROXY / -trust-proxy)"
            if grep -qE 'Environment=TRUSTED_PROXIES=.+' "$go_svc_file" 2>/dev/null || \
               grep -qE '^TRUSTED_PROXIES=.+' "${CONSOLE_PATH}/.env" 2>/dev/null; then
                _test_ok "TRUSTED_PROXIES allowlist configured"
            else
                _test_warn "TRUSTED_PROXIES empty — Go ignores X-Forwarded-* until set (e.g. 127.0.0.1/32)"
            fi
        else
            _test_fail "Go server TRUST_PROXY not enabled — API rate limits may use proxy IP only"
        fi
        local rp_dir="$RUSTDESK_PATH/reverse-proxy"
        if [ -d "$rp_dir" ] && { [ -f "$rp_dir/caddy.Caddyfile.snippet" ] || [ -f "$rp_dir/nginx.neodesk.conf.snippet" ]; }; then
            _test_ok "Reverse-proxy snippets in $rp_dir/"
        else
            _test_warn "No snippets in $rp_dir/ — re-run SSL menu → External reverse proxy"
        fi
    fi

    # ── 2b. TLS key readable by console user (HTTPS only) ──
    if [ "$(echo "$https_enabled" | tr '[:upper:]' '[:lower:]')" = "true" ]; then
        local ssl_key_path console_user="neodesk"
        ssl_key_path=$(read_effective_console_setting SSL_KEY_PATH "")
        if id "$console_user" &>/dev/null && [ -n "$ssl_key_path" ] && [ -e "$ssl_key_path" ]; then
            if runuser -u "$console_user" -- test -r "$ssl_key_path" 2>/dev/null; then
                _test_ok "TLS private key readable by console user ($console_user)"
            else
                _test_fail "Console user $console_user cannot read TLS key ($ssl_key_path) — HTTPS panel will fall back to HTTP (journalctl -u neodesk-server)"
            fi
        fi
    fi

    # ── 3. Panel reachability on the correct scheme/port ──
    if systemctl is-active --quiet "$(console_service_name)" 2>/dev/null; then
        verify_service_health "$(console_service_name)" "$panel_port" 15 >/dev/null 2>&1 || true
    fi
    local panel_code panel_insecure="no"
    [ "$panel_scheme" = "https" ] && panel_insecure="yes"
    panel_code=$(_wait_for_http_code "${panel_scheme}://127.0.0.1:${panel_port}/" 15 "$panel_insecure" || true)
    if [[ "$panel_code" =~ ^(200|301|302|304|401|403)$ ]]; then
        _test_ok "Web panel reachable: ${panel_scheme}://<server>:${panel_port} (HTTP $panel_code)"
    else
        local alt_panel_port=""
        if [ "$panel_scheme" = "https" ] && [ "$panel_port" = "443" ] && _tcp_port_is_listening 5443; then
            alt_panel_port="5443"
            panel_code=$(_wait_for_http_code "https://127.0.0.1:5443/" 5 "$panel_insecure" || true)
            if [[ "$panel_code" =~ ^(200|301|302|304|401|403)$ ]]; then
                _test_fail "Web panel NOT reachable on https://127.0.0.1:443 (panel bound :5443 instead — run Repair → Repair permissions for CAP_NET_BIND_SERVICE)"
            else
                _test_fail "Web panel NOT reachable on ${panel_scheme}://127.0.0.1:${panel_port} (got $panel_code)"
            fi
        else
            _test_fail "Web panel NOT reachable on ${panel_scheme}://127.0.0.1:${panel_port} (got $panel_code)"
        fi
        if systemctl is-active --quiet "$(console_service_name)" 2>/dev/null && [ "$panel_scheme" = "https" ]; then
            if journalctl -u neodesk-server --no-pager -n 80 2>/dev/null | grep -qi 'Falling back to HTTP'; then
                echo -e "      ${DIM}Hint: console logged HTTPS fallback — check TLS key permissions (runuser -u neodesk test -r key)${NC}"
            elif [ -n "$alt_panel_port" ]; then
                echo -e "      ${DIM}Hint: configured HTTPS_PORT=443 but Node bound :5443 — Repair → Repair permissions, then restart${NC}"
            fi
        fi
    fi

    # ── 3b. HTTP→HTTPS redirect (only when HTTPS + redirect enabled) ──
    if [ "$(echo "$https_enabled" | tr '[:upper:]' '[:lower:]')" = "true" ] \
        && [ "$(echo "$http_redirect" | tr '[:upper:]' '[:lower:]')" = "true" ]; then
        local redirect_hdr _r_elapsed=0 redirect_probe_port="$http_port"
        # Standard HTTPS on :443 always redirects from :80 — never probe the default port.
        if [ "$https_port" = "443" ]; then
            redirect_probe_port="80"
        fi
        redirect_hdr=""
        while [ "$_r_elapsed" -lt 10 ]; do
            redirect_hdr=$(curl -sI --max-time 4 "http://127.0.0.1:${redirect_probe_port}/" 2>/dev/null | grep -i '^location:' | head -1)
            if [ "$https_port" = "443" ]; then
                if echo "$redirect_hdr" | grep -qi 'https://' \
                    && { ! echo "$redirect_hdr" | grep -qiE ':[0-9]+' || echo "$redirect_hdr" | grep -qi ':443'; }; then
                    break
                fi
            elif echo "$redirect_hdr" | grep -qi ":${https_port}"; then
                break
            fi
            sleep 1
            _r_elapsed=$((_r_elapsed + 1))
        done
        if [ "$https_port" = "443" ]; then
            if echo "$redirect_hdr" | grep -qi 'https://' \
                && { ! echo "$redirect_hdr" | grep -qiE ':[0-9]+' || echo "$redirect_hdr" | grep -qi ':443'; }; then
                _test_ok "HTTP redirect active: :${redirect_probe_port} → HTTPS :${https_port}"
            else
                _test_fail "HTTP redirect missing or wrong target on :${redirect_probe_port} (got: ${redirect_hdr:-none})"
                if [ "$redirect_probe_port" = "80" ]; then
                    echo -e "      ${DIM}Hint: set PORT=80 in .env, run Repair → Repair HTTPS/TLS, ensure CAP_NET_BIND_SERVICE${NC}"
                fi
            fi
        elif echo "$redirect_hdr" | grep -qi ":${https_port}"; then
            _test_ok "HTTP redirect active: :${http_port} → HTTPS :${https_port}"
        else
            _test_fail "HTTP redirect missing or wrong target on :${http_port} (got: ${redirect_hdr:-none})"
        fi
    fi

    # ── 4. Go API (RustDesk client + REST) on GO_API_PORT (default 21114) ──
    local go_api_port="${GO_API_PORT:-21114}"
    local client_api_port="${CLIENT_API_PORT:-21121}"
    local api_code _api_elapsed=0
    while [ "$_api_elapsed" -lt 15 ]; do
        api_code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 4 \
            "http://127.0.0.1:${go_api_port}/api/server/stats" 2>/dev/null || echo "000")
        if [[ "$api_code" =~ ^(200|401|403|404)$ ]]; then
            break
        fi
        sleep 1
        _api_elapsed=$((_api_elapsed + 1))
    done
    if [[ "$api_code" =~ ^(200|401|403|404)$ ]]; then
        _test_ok "Go API responding over HTTP on :${go_api_port} (HTTP $api_code)"
    else
        _test_fail "Go API not responding over HTTP on :${go_api_port} (got $api_code)"
        if ! ss -tlnH 2>/dev/null | grep -q ":${go_api_port} "; then
            if ss -tlnpH 2>/dev/null | grep ":${client_api_port} " | grep -qiE 'neodesk-server|neodesk-serv'; then
                echo -e "      ${DIM}Hint: Go API bound to :${client_api_port} — API_PORT from .env leaked; run Repair → Repair HTTPS/TLS or update${NC}"
            fi
        fi
    fi

    # ── 4b. Client API compat proxy (:21121) — scheme matches RUSTDESK_API_TLS ──
    local client_api_scheme="http" client_api_code client_insecure="no"
    if client_api_should_use_tls; then
        client_api_scheme="https"
        client_insecure="yes"
    fi
    client_api_code=$(_wait_for_http_code \
        "${client_api_scheme}://127.0.0.1:${CLIENT_API_PORT:-21121}/api/login-options" 15 "$client_insecure" || true)
    if [[ "$client_api_code" =~ ^(200|401|403|404|405)$ ]]; then
        _test_ok "Client API compat proxy on :${CLIENT_API_PORT:-21121} (${client_api_scheme^^} $client_api_code)"
    else
        _test_fail "Client API proxy not responding on :${CLIENT_API_PORT:-21121} (${client_api_scheme}, got $client_api_code) — check API_ENABLED / RUSTDESK_API_TLS"
    fi

    # Critical invariant: Go API must never be HTTPS-only
    if [ -f "$go_svc_file" ] && grep -Eq '\-tls-api|\-force-https' "$go_svc_file" 2>/dev/null; then
        _test_warn "Go service carries -tls-api/-force-https — RustDesk clients require plain HTTP on :${GO_API_PORT:-21114}"
    fi

    # ── 5. Signal / Relay listeners ──
    local p
    for p in 21116 21117; do
        if ss -tlnH 2>/dev/null | grep -q ":${p} "; then
            _test_ok "Listener present on TCP :${p}"
        else
            _test_warn "No TCP listener detected on :${p} (UDP-only signal is normal for :21116)"
        fi
    done

    # ── 6. Certificate validation (HTTPS / TLS modes) ──
    local tls_active="no"
    [ -f "$go_svc_file" ] && grep -q '\-tls-signal' "$go_svc_file" 2>/dev/null && tls_active="yes"
    if [ "$(echo "$https_enabled" | tr '[:upper:]' '[:lower:]')" = "true" ] || [ "$tls_active" = "yes" ]; then
        if [ -f "$ssl_dir/neodesk.crt" ]; then
            if openssl x509 -in "$ssl_dir/neodesk.crt" -noout 2>/dev/null; then
                local not_after days_left
                not_after=$(openssl x509 -in "$ssl_dir/neodesk.crt" -noout -enddate 2>/dev/null | cut -d= -f2)
                if [ -n "$not_after" ]; then
                    local exp_epoch now_epoch
                    exp_epoch=$(date -d "$not_after" +%s 2>/dev/null || echo 0)
                    now_epoch=$(date +%s)
                    if [ "$exp_epoch" -gt "$now_epoch" ]; then
                        days_left=$(( (exp_epoch - now_epoch) / 86400 ))
                        if [ "$days_left" -lt 14 ]; then
                            _test_warn "Certificate valid but expires in ${days_left} days ($not_after)"
                        else
                            _test_ok "Certificate valid for ${days_left} more days (until $not_after)"
                        fi
                    else
                        _test_fail "Certificate has EXPIRED ($not_after)"
                    fi
                fi
                local san
                san=$(openssl x509 -in "$ssl_dir/neodesk.crt" -noout -ext subjectAltName 2>/dev/null | tail -n +2 | tr -d ' ')
                [ -n "$san" ] && echo -e "      ${DIM}SAN: ${san}${NC}"
            else
                _test_fail "Certificate file is not a valid X.509 certificate"
            fi
        else
            _test_fail "HTTPS/TLS enabled but no certificate found at $ssl_dir/neodesk.crt"
        fi

        if [ "$tls_active" = "yes" ]; then
            if echo | timeout 5 openssl s_client -connect "127.0.0.1:21116" 2>/dev/null | grep -q 'BEGIN CERTIFICATE'; then
                _test_ok "TLS handshake succeeded on signal :21116"
            else
                _test_warn "Could not complete TLS handshake on :21116 (dual-mode listener may still accept plain TCP)"
            fi
        fi
    fi

    echo ""
    local go_signal_port relay_port
    go_signal_port=$(grep -m1 '^Environment=SIGNAL_PORT=' "$go_svc_file" 2>/dev/null | cut -d= -f2- || echo "21116")
    relay_port=$(grep -m1 '^Environment=RELAY_PORT=' "$go_svc_file" 2>/dev/null | cut -d= -f2- || echo "21117")
    echo -e "  ${DIM}Effective config: HTTPS_ENABLED=${https_enabled} panel=${panel_scheme}:${panel_port} redirect=${http_redirect} client_api_tls=${api_tls_mode} go_signal=${go_signal_port} go_relay=${relay_port}${NC}"
    echo ""
    echo -e "  ${GREEN}${pass} passed${NC}   ${YELLOW}${warn} warnings${NC}   ${RED}${fail} failed${NC}"
    if [ "$fail" -gt 0 ]; then
        echo -e "  ${YELLOW}Some checks failed — review the messages above and the service logs.${NC}"
    else
        echo -e "  ${GREEN}Configuration verified successfully.${NC}"
        if [ "$(echo "$https_enabled" | tr '[:upper:]' '[:lower:]')" = "true" ] && [ "$https_port" = "5443" ]; then
            echo ""
            echo -e "  ${DIM}Tip: for https://your-domain without :5443, set HTTPS_PORT=443 in .env and run Repair → Repair permissions, or re-run Protocol Toggle / SSL config and choose standard port 443. See https://neode.sk/docs/operations/reverse-proxy-tls#https-without-a-proxy${NC}"
        elif [ "$(echo "$https_enabled" | tr '[:upper:]' '[:lower:]')" != "true" ] && [ "$_trust_on" = "yes" ]; then
            echo ""
            echo -e "  ${DIM}Tip: configure Caddy/Nginx using $RUSTDESK_PATH/reverse-proxy/ snippets, then open https://your-domain/ (not :5443). See https://neode.sk/docs/operations/reverse-proxy-tls${NC}"
        fi
    fi
    echo ""

    unset -f _test_ok _test_fail _test_warn 2>/dev/null || true
}

#===============================================================================
# HTTP/HTTPS Protocol Toggle
#===============================================================================

do_toggle_protocol() {
    maybe_reexec_if_installer_on_disk_is_newer
    print_header
    echo -e "${WHITE}${BOLD}══════════ PROTOCOL TOGGLE (HTTP / HTTPS) ══════════${NC}"
    echo ""

    local env_file="$CONSOLE_PATH/.env"
    local go_svc_file="$SERVER_UNIT"
    local ssl_dir="$RUSTDESK_PATH/ssl"

    # Detect current mode (effective runtime: systemd overrides .env)
    local current_mode="HTTP"
    if [ "$(read_effective_console_setting HTTPS_ENABLED false | tr '[:upper:]' '[:lower:]')" = "true" ]; then
        current_mode="HTTPS"
    fi

    local tls_signal="no"
    local tls_relay="no"
    if [ -f "$go_svc_file" ]; then
        grep -q '\-tls-signal' "$go_svc_file" 2>/dev/null && tls_signal="yes"
        grep -q '\-tls-relay' "$go_svc_file" 2>/dev/null && tls_relay="yes"
    fi

    local _menu_items=(
        $'Switch to HTTP\tEverything plain — LAN / testing'
        $'Switch to HTTPS\tPanel HTTPS + signal/relay TLS'
        $'External reverse proxy\tTLS at Caddy/Nginx — panel HTTP on localhost'
        $'Back\tReturn to the main menu'
    )
    local _menu_returns=( 1 2 3 0 )
    menu_choose "Protocol Toggle (HTTP / HTTPS / reverse proxy)" "Current: ${current_mode} | signal TLS: ${tls_signal} | relay TLS: ${tls_relay}"
    local proto_choice="$MENU_CHOICE"

    case "${proto_choice:-0}" in
        1)
            # ── Switch to HTTP ──
            echo ""
            print_step "Switching to HTTP mode..."

            apply_console_protocol_mode http
            clear_go_server_signal_relay_tls

            print_success "Switched to HTTP mode"
            echo ""
            print_info "  Panel:         HTTP :$(resolve_panel_http_port)"
            print_info "  Signal:        TCP  :21116"
            print_info "  Relay:         TCP  :21117"
            print_info "  Go API:        HTTP :${GO_API_PORT:-21114}"
            print_info "  Client API:    HTTP :${CLIENT_API_PORT:-21121}"
            echo ""
            print_warning "SSL certificates were NOT deleted (use option C > 4 to remove)"
            print_info "If your browser still redirects to HTTPS, clear site cache or HSTS (chrome://net-internals/#hsts)"
            ;;
        2)
            # ── Switch to HTTPS ──
            echo ""
            local have_cert="no"
            [ -f "$ssl_dir/neodesk.crt" ] && [ -f "$ssl_dir/neodesk.key" ] && have_cert="yes"
            local _keep_desc="No existing certificate found"
            [ "$have_cert" = "yes" ] && _keep_desc="Reuse $ssl_dir/neodesk.crt"
            local _menu_items=(
                $'Keep existing certificate\t'"$_keep_desc"
                $'Self-signed certificate\tGenerate one for LAN / testing'
                $'Let\'s Encrypt certificate\tPublic domain, port 80 must be free'
                $'Custom certificate\tPaste your own cert + key file paths'
                $'Cancel\tDo not change the protocol'
            )
            local _menu_returns=( 1 2 3 4 0 )
            menu_choose "HTTPS Certificate Source" "Choose the certificate to use for TLS"
            local cert_choice="$MENU_CHOICE"

            case "${cert_choice:-2}" in
                1)
                    if [ "$have_cert" != "yes" ]; then
                        print_error "No existing certificate found — choose another option."
                        press_enter
                        return
                    fi
                    maybe_repair_le_ssl_symlinks 2>/dev/null || true
                    print_info "Using existing certificate at $ssl_dir/neodesk.crt"
                    ;;
                2)
                    mkdir -p "$ssl_dir"
                    local server_ip lan_ip san_list
                    server_ip=$(get_public_ip 2>/dev/null || echo "127.0.0.1")
                    lan_ip=$(ip route get 1 2>/dev/null | awk '{print $7; exit}')
                    san_list="IP:$server_ip,IP:127.0.0.1,DNS:localhost"
                    [ -n "$lan_ip" ] && [ "$lan_ip" != "$server_ip" ] && san_list="$san_list,IP:$lan_ip"
                    read -p "Optional DNS domain for the certificate (blank to skip): " ss_domain
                    [ -n "$ss_domain" ] && san_list="$san_list,DNS:$ss_domain"
                    print_step "Generating self-signed certificate..."
                    openssl req -x509 -nodes -days 3650 -newkey rsa:4096 \
                        -keyout "$ssl_dir/neodesk.key" \
                        -out "$ssl_dir/neodesk.crt" \
                        -subj "/CN=${ss_domain:-$server_ip}/O=NeoDesk/C=PL" \
                        -addext "subjectAltName=$san_list" 2>/dev/null || \
                    openssl req -x509 -nodes -days 3650 -newkey rsa:4096 \
                        -keyout "$ssl_dir/neodesk.key" \
                        -out "$ssl_dir/neodesk.crt" \
                        -subj "/CN=${ss_domain:-$server_ip}/O=NeoDesk/C=PL" 2>/dev/null
                    if ! deploy_ssl_material_to_rustdesk_dir "$ssl_dir/neodesk.crt" "$ssl_dir/neodesk.key"; then
                        print_error "Failed to set permissions on self-signed certificate"
                        press_enter
                        return
                    fi
                    print_success "Self-signed certificate generated"
                    ;;
                3)
                    if ! command -v certbot &>/dev/null; then
                        print_step "Installing certbot..."
                        if command -v dnf &>/dev/null; then dnf install -y certbot &>/dev/null
                        elif command -v apt-get &>/dev/null; then apt_quiet install -y certbot
                        elif command -v yum &>/dev/null; then yum install -y certbot &>/dev/null; fi
                    fi
                    if ! command -v certbot &>/dev/null; then
                        print_error "certbot could not be installed automatically."
                        press_enter
                        return
                    fi
                    read -p "Public domain (e.g. desk.example.com): " le_domain
                    read -p "Admin email (for renewal notices): " le_email
                    if [ -z "$le_domain" ]; then
                        print_error "A domain is required for Let's Encrypt."
                        press_enter
                        return
                    fi
                    print_step "Requesting certificate for $le_domain (standalone, needs port 80)..."
                    if certbot certonly --standalone --non-interactive --agree-tos \
                        ${le_email:+--email "$le_email"} ${le_email:+} \
                        $([ -z "$le_email" ] && echo "--register-unsafely-without-email") \
                        -d "$le_domain"; then
                        local le_live_dir="/etc/letsencrypt/live/$le_domain"
                        if ! deploy_ssl_material_to_rustdesk_dir \
                            "$le_live_dir/fullchain.pem" "$le_live_dir/privkey.pem" "$le_live_dir"; then
                            print_error "Failed to deploy Let's Encrypt certificate for console user"
                            press_enter
                            return
                        fi
                        print_success "Let's Encrypt certificate installed for $le_domain"
                        print_info "Open the panel at https://${le_domain}:$(resolve_panel_https_port) (IP access will show certificate errors)"
                    else
                        print_error "certbot failed — check that DNS points here and port 80 is free."
                        press_enter
                        return
                    fi
                    ;;
                4)
                    read -p "Path to certificate (.crt/.pem, fullchain): " custom_crt
                    read -p "Path to private key (.key): " custom_key
                    read -p "Path to CA chain (optional, blank to skip): " custom_ca
                    if [ ! -f "$custom_crt" ] || [ ! -f "$custom_key" ]; then
                        print_error "Certificate or key file not found."
                        press_enter
                        return
                    fi
                    if ! openssl x509 -in "$custom_crt" -noout 2>/dev/null; then
                        print_error "The provided certificate is not a valid X.509 file."
                        press_enter
                        return
                    fi
                    local deploy_crt="$custom_crt" merged_crt=""
                    if [ -n "$custom_ca" ] && [ -f "$custom_ca" ]; then
                        merged_crt=$(mktemp)
                        cat "$custom_crt" "$custom_ca" > "$merged_crt"
                        deploy_crt="$merged_crt"
                    fi
                    if ! deploy_ssl_material_to_rustdesk_dir "$deploy_crt" "$custom_key"; then
                        [ -n "$merged_crt" ] && rm -f "$merged_crt"
                        print_error "Failed to deploy custom certificate for console user"
                        press_enter
                        return
                    fi
                    [ -n "$merged_crt" ] && rm -f "$merged_crt"
                    print_success "Custom certificate installed"
                    ;;
                0|*)
                    print_info "Cancelled — no changes made."
                    press_enter
                    return
                    ;;
            esac

            local api_tls="false" allow_self_signed="true"
            case "${cert_choice:-2}" in
                1)
                    infer_tls_mode_from_cert "$ssl_dir/neodesk.crt"
                    api_tls="$INFERRED_RUSTDESK_API_TLS"
                    allow_self_signed="$INFERRED_ALLOW_SELF_SIGNED"
                    ;;
                2)
                    api_tls="false"
                    allow_self_signed="true"
                    ;;
                3)
                    api_tls="true"
                    allow_self_signed="false"
                    ;;
                4)
                    infer_tls_mode_from_cert "$ssl_dir/neodesk.crt"
                    api_tls="$INFERRED_RUSTDESK_API_TLS"
                    allow_self_signed="$INFERRED_ALLOW_SELF_SIGNED"
                    ;;
            esac

            print_step "Switching to HTTPS mode..."

            apply_console_protocol_mode https "$ssl_dir/neodesk.crt" "$ssl_dir/neodesk.key" "$api_tls" "$allow_self_signed"

            sync_go_server_signal_relay_tls "$ssl_dir"
            ensure_service_user >/dev/null

            print_success "Switched to HTTPS mode"
            echo ""
            print_info "  Panel:         HTTPS :$(resolve_panel_https_port)"
            print_info "  Redirect:      HTTP :$(resolve_panel_http_port) → HTTPS :$(resolve_panel_https_port)"
            print_info "  Signal:        TLS   :21116"
            print_info "  Relay:         TLS   :21117"
            print_info "  Go API:        HTTP  :${GO_API_PORT:-21114} (RustDesk client + REST)"
            if [ "$api_tls" = "true" ]; then
                print_info "  Client API:    HTTPS :${CLIENT_API_PORT:-21121}"
            else
                print_info "  Client API:    HTTP  :${CLIENT_API_PORT:-21121}"
            fi
            maybe_offer_standard_https_port
            ;;
        3)
            do_configure_reverse_proxy || true
            ;;
        0|4|*)
            return
            ;;
    esac

    echo ""
    if confirm "Restart NeoDesk services now?"; then
        repair_https_stuck_state yes
        ensure_console_tls_material_readable 2>/dev/null || true
        systemctl restart neodesk-server 2>/dev/null || true
        verify_service_health "neodesk-server" "21116" 15 >/dev/null 2>&1 || true
        verify_go_install 60 >/dev/null 2>&1 || true
        print_success "NeoDesk services restarted"
        run_protocol_tests
    else
        print_info "Changes saved. Restart later with: systemctl restart neodesk-server"
    fi

    press_enter
}

#===============================================================================
# Database Migration Functions
#===============================================================================

# migrate_dst_overwrite DST: whether the migration tool may replace the
# SQLite file at DST. Sets MIGRATE_OVERWRITE to -overwrite when the file
# (or a -wal, -shm or -journal of one) exists and the user agreed, to
# nothing when there is nothing to replace; returns 1 when the user
# declined. A postgres:// destination needs nothing.
migrate_dst_overwrite() {
    local dst="$1"
    MIGRATE_OVERWRITE=""
    case "${dst,,}" in
        postgres://*|postgresql://*) return 0 ;;
    esac
    if [ -e "$dst" ] || [ -e "$dst-wal" ] || [ -e "$dst-shm" ] || [ -e "$dst-journal" ]; then
        print_warning "Destination file exists: $dst"
        confirm "Overwrite (backup will be created first)?" || return 1
        MIGRATE_OVERWRITE="-overwrite"
    fi
}

# migrate_sqlite_dst_done DST: hands a SQLite file the migration tool wrote
# to the service account, as the install does with the server's files.
migrate_sqlite_dst_done() {
    case "${1,,}" in
        postgres://*|postgresql://*) return 0 ;;
    esac
    own_by_service_user "$1"
}

do_migrate_database() {
    print_header
    echo -e "${WHITE}${BOLD}══════════ DATABASE MIGRATION ══════════${NC}"
    echo ""

    # The installed binary's migrate command
    local migrate_bin=""
    binary_migrates && migrate_bin=server_migrate
    if [ -z "$migrate_bin" ]; then
        print_error "No migration tool: $(server_binary_path) has no migrate command"
        print_info "Update first (sudo $(basename "$MANAGER_COMMAND") --update): the server's own migrate command moves the database"
        press_enter
        return
    fi
    print_info "Migration tool: $(server_binary_path) migrate"
    echo ""
    local _menu_items=(
        $'Rust -> Go\tMigrate legacy Rust hbbs database to the Go server'
        $'SQLite -> PostgreSQL\tMove the whole install (every server and console table) to PostgreSQL'
        $'PostgreSQL -> SQLite\tMove the whole install from PostgreSQL to a SQLite file'
        $'Backup\tCreate a timestamped SQLite database backup'
        $'Back\tReturn to the main menu'
    )
    local _menu_returns=( 1 2 3 4 0 )
    menu_choose "Database Migration" "Migrate databases between NeoDesk components"
    local mig_choice="$MENU_CHOICE"

    case $mig_choice in
        1)
            # Rust → Go
            echo ""
            local default_src="$RUSTDESK_PATH/db_v2.sqlite3"
            read -p "Source Rust database [$default_src]: " src_db
            src_db="${src_db:-$default_src}"

            if [ ! -f "$src_db" ]; then
                print_error "Source database not found: $src_db"
                press_enter
                return
            fi

            read -p "Destination (SQLite path or postgres:// URI) [new file next to source]: " dst_db
            dst_db="${dst_db:-$(dirname "$src_db")/neodesk.sqlite3}"
            if ! migrate_dst_overwrite "$dst_db"; then
                press_enter
                return
            fi

            print_step "Creating backup before migration..."
            "$migrate_bin" -mode backup -src "$src_db" 2>&1 || true
            if [ -n "$MIGRATE_OVERWRITE" ] && [ -f "$dst_db" ]; then
                "$migrate_bin" -mode backup -src "$dst_db" 2>&1 || true
            fi

            print_step "Running Rust → Go migration..."
            if "$migrate_bin" -mode rust2go -src "$src_db" -dst "$dst_db" ${MIGRATE_OVERWRITE:+"$MIGRATE_OVERWRITE"} 2>&1; then
                migrate_sqlite_dst_done "$dst_db"
                print_success "Rust → Go migration completed successfully!"
            else
                print_error "Migration failed. Check the output above for details."
            fi
            ;;
        2)
            # SQLite → PostgreSQL
            echo ""
            local default_src="$RUSTDESK_PATH/db_v2.sqlite3"
            read -p "Source SQLite database [$default_src]: " src_db
            src_db="${src_db:-$default_src}"

            if [ ! -f "$src_db" ]; then
                print_error "Source database not found: $src_db"
                press_enter
                return
            fi

            read -p "PostgreSQL connection URI (postgres://user:pass@host:5432/dbname): " pg_uri
            if [ -z "$pg_uri" ]; then
                print_error "PostgreSQL URI is required"
                press_enter
                return
            fi

            print_info "Every table of the server and the console moves: devices, users, settings, tickets, groups, audit log and the rest."
            local pg_overwrite=""
            if confirm "If the PostgreSQL database already holds data, replace all of it?"; then
                pg_overwrite="-overwrite"
            fi

            print_step "Creating backup before migration..."
            "$migrate_bin" -mode backup -src "$src_db" 2>&1 || true

            # The install's own database: the server stops for the copy and
            # starts again on the new database
            local own_db=false
            [ "$src_db" = "$RUSTDESK_PATH/db_v2.sqlite3" ] && [ -f "$CONSOLE_PATH/.env" ] && own_db=true
            [ "$own_db" = true ] && systemctl stop "$SERVER_SERVICE" 2>/dev/null

            print_step "Running SQLite → PostgreSQL migration..."
            if "$migrate_bin" -mode sqlite2pg -src "$src_db" -dst "$pg_uri" ${pg_overwrite:+"$pg_overwrite"} 2>&1; then
                print_success "SQLite → PostgreSQL migration completed successfully!"
                if [ "$own_db" = true ]; then
                    use_database_in_env postgres "$pg_uri"
                    print_success "The install now runs on PostgreSQL"
                fi
            else
                print_error "Migration failed. Check the output above for details."
                [ "$own_db" = true ] && print_info "The install stays on $src_db"
            fi
            [ "$own_db" = true ] && systemctl restart "$SERVER_SERVICE" 2>/dev/null
            ;;
        3)
            # PostgreSQL → SQLite
            echo ""
            read -p "PostgreSQL connection URI (postgres://user:pass@host:5432/dbname): " pg_uri
            if [ -z "$pg_uri" ]; then
                print_error "PostgreSQL URI is required"
                press_enter
                return
            fi

            local default_dst="$RUSTDESK_PATH/db_v2.sqlite3"
            read -p "Destination SQLite file [$default_dst]: " dst_db
            dst_db="${dst_db:-$default_dst}"

            print_info "Every table of the server and the console moves: devices, users, settings, tickets, groups, audit log and the rest."
            if ! migrate_dst_overwrite "$dst_db"; then
                press_enter
                return
            fi
            if [ -n "$MIGRATE_OVERWRITE" ] && [ -f "$dst_db" ]; then
                "$migrate_bin" -mode backup -src "$dst_db" 2>&1 || true
            fi

            # The install's own database: the server stops for the copy and
            # starts again on the new database
            local own_pg=false
            [ -f "$CONSOLE_PATH/.env" ] && [ "$(env_database_url "$CONSOLE_PATH/.env")" = "$pg_uri" ] \
                && [ "$dst_db" = "$RUSTDESK_PATH/db_v2.sqlite3" ] && own_pg=true
            [ "$own_pg" = true ] && systemctl stop "$SERVER_SERVICE" 2>/dev/null

            print_step "Running PostgreSQL → SQLite migration..."
            if "$migrate_bin" -mode pg2sqlite -src "$pg_uri" -dst "$dst_db" ${MIGRATE_OVERWRITE:+"$MIGRATE_OVERWRITE"} 2>&1; then
                migrate_sqlite_dst_done "$dst_db"
                print_success "PostgreSQL → SQLite migration completed successfully!"
                if [ "$own_pg" = true ]; then
                    use_database_in_env sqlite "$dst_db"
                    print_success "The install now runs on SQLite ($dst_db)"
                fi
            else
                print_error "Migration failed. Check the output above for details."
            fi
            [ "$own_pg" = true ] && systemctl restart "$SERVER_SERVICE" 2>/dev/null
            ;;
        4)
            # Backup
            echo ""
            local default_src="$RUSTDESK_PATH/db_v2.sqlite3"
            read -p "SQLite database to backup [$default_src]: " src_db
            src_db="${src_db:-$default_src}"

            if [ ! -f "$src_db" ]; then
                print_error "Database not found: $src_db"
                press_enter
                return
            fi

            print_step "Creating backup..."
            "$migrate_bin" -mode backup -src "$src_db" 2>&1

            if [ $? -eq 0 ]; then
                print_success "Backup created successfully!"
            else
                print_error "Backup failed."
            fi
            ;;
        0)
            return
            ;;
        *)
            print_warning "Invalid option"
            ;;
    esac

    press_enter
}

#===============================================================================
# Relay node (--node)
#===============================================================================
# A relay node is the server binary in node mode at a site: the site's
# devices relay through it. It has no database and no web console. The
# central server sends it the sessions it may relay over one outbound TLS
# connection, to the address in the join string. A server install on the
# same machine stays as it is: the node has its own folder, account, env
# file and unit.

NODE_SERVICE="neodesk-relay-node"
NODE_UNIT="/etc/systemd/system/${NODE_SERVICE}.service"
NODE_USER="neodesk-relay-node"
# The binary, root's own: a run of the installer updates it
NODE_INSTALL_DIR="/opt/neodesk-relay-node"
# node.key and node.json, the node's identity and enrollment: the unit's
# StateDirectory, 0700 and the node account's own
NODE_STATE_DIR="/var/lib/${NODE_SERVICE}"
# The join string and the addresses, root's own (0600)
NODE_ENV_DIR="/etc/${NODE_SERVICE}"
NODE_ENV_FILE="$NODE_ENV_DIR/node.env"

# node_address ADDRESS: ADDRESS as host:port, with the relay port 21117
# when it names none. Fails for anything but a host name, an IPv4 address
# or an IPv6 address in brackets.
node_address() {
    local addr="$1"
    if [[ "$addr" =~ ^\[[0-9A-Fa-f:.]+\]$ ]] || [[ "$addr" =~ ^[A-Za-z0-9.-]+$ ]]; then
        addr="$addr:21117"
    fi
    [[ "$addr" =~ ^(\[[0-9A-Fa-f:.]+\]|[A-Za-z0-9.-]+):[0-9]{1,5}$ ]] || return 1
    printf '%s\n' "$addr"
}

# The account the node runs as, a system account like the server's
ensure_node_user() {
    id "$NODE_USER" &>/dev/null && return 0
    useradd -r -s /usr/sbin/nologin -d "$NODE_STATE_DIR" -M -c "NeoDesk relay node" "$NODE_USER" || {
        print_error "Could not create the system user $NODE_USER"
        return 1
    }
}

# write_node_unit: neodesk-relay-node.service. The node needs no rights
# beyond its state folder and the network, so the unit closes the rest.
# Exit status 3 is a request to be started again, as for the server.
write_node_unit() {
    cat > "$NODE_UNIT" << EOF
[Unit]
Description=NeoDesk relay node
Documentation=https://github.com/neodeskapp/neodesk
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$NODE_USER
Group=$NODE_USER
EnvironmentFile=$NODE_ENV_FILE
Environment=NEODESK_SUPERVISOR=systemd
StateDirectory=$NODE_SERVICE
StateDirectoryMode=0700
WorkingDirectory=$NODE_STATE_DIR
ExecStart=$NODE_INSTALL_DIR/neodesk-server node
Restart=always
RestartSec=2
SuccessExitStatus=3
LimitNOFILE=1000000
UMask=0077
NoNewPrivileges=yes
PrivateTmp=yes
PrivateDevices=yes
ProtectSystem=strict
ProtectHome=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectKernelLogs=yes
ProtectControlGroups=yes
ProtectClock=yes
ProtectHostname=yes
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX AF_NETLINK
RestrictNamespaces=yes
RestrictRealtime=yes
RestrictSUIDSGID=yes
LockPersonality=yes
MemoryDenyWriteExecute=yes
SystemCallArchitectures=native
SystemCallFilter=@system-service
CapabilityBoundingSet=

[Install]
WantedBy=multi-user.target
EOF
    chmod 0644 "$NODE_UNIT"
}

# do_node_install: installs or updates the relay node. The first install
# needs --join; the addresses default to what the env file has, else the
# LAN address with port 21117 and no public address.
do_node_install() {
    print_header
    print_step "Installing the NeoDesk relay node..."
    if ! command -v systemctl &>/dev/null; then
        print_error "The relay node runs as a systemd service; without systemd use Docker (docker-compose.relay-node.yml)"
        return 1
    fi
    local enrolled=false
    [ -s "$NODE_STATE_DIR/node.json" ] && enrolled=true
    if [ -n "$NODE_JOIN" ]; then
        if [[ ! "$NODE_JOIN" =~ ^nd1\.[A-Za-z0-9_=-]+$ ]]; then
            print_error "--join takes the join string the console shows under Sites (nd1. and the rest of it)"
            return 1
        fi
        if [ "$enrolled" = true ]; then
            print_error "This machine is a relay node already ($NODE_STATE_DIR/node.json)"
            print_info "Run without --join to update it. To join another site, first: --node --uninstall --purge"
            return 1
        fi
    elif [ "$enrolled" != true ] && [ -z "$(env_file_value "$NODE_ENV_FILE" NODE_JOIN)" ]; then
        print_error "--join is needed: the join string the console shows under Sites"
        return 1
    fi

    local lan public
    lan="${NODE_LAN_ADDR:-$(env_file_value "$NODE_ENV_FILE" NODE_LAN_ADDR)}"
    public="${NODE_PUBLIC_ADDR:-$(env_file_value "$NODE_ENV_FILE" NODE_PUBLIC_ADDR)}"
    [ -n "$lan" ] || lan=$(get_local_ip)
    if ! lan=$(node_address "$lan"); then
        print_error "--lan-addr takes host:port (an IPv6 address in brackets: [2001:db8::5]:21117)"
        return 1
    fi
    if [ -n "$public" ] && ! public=$(node_address "$public"); then
        print_error "--public-addr takes host:port (an IPv6 address in brackets: [2001:db8::5]:21117)"
        return 1
    fi
    case "$lan" in
        127.*) print_warning "No LAN address found: the node says $lan; give the right one with --lan-addr" ;;
    esac

    ensure_node_user || return 1
    # The binary is checked against the node's own folder (its installed
    # binary verifies the release), never against a server install here
    RUSTDESK_PATH="$NODE_INSTALL_DIR"
    CONSOLE_PATH=""
    obtain_server_binary || { rm -rf "${STAGED_SERVER_DIR:-}"; return 1; }
    if ! grep -a -q -F 'NODE_JOIN' "$STAGED_SERVER_BINARY"; then
        print_error "This neodesk-server has no relay node mode yet ($STAGED_SERVER_VERSION)"
        rm -rf "$STAGED_SERVER_DIR"
        return 1
    fi
    systemctl stop "$NODE_SERVICE" 2>/dev/null || true
    install -d -m 0755 -o root -g root "$NODE_INSTALL_DIR"
    install_staged_binary || { rm -rf "$STAGED_SERVER_DIR"; return 1; }
    rm -rf "$STAGED_SERVER_DIR"

    install -d -m 0700 -o root -g root "$NODE_ENV_DIR"
    if [ ! -f "$NODE_ENV_FILE" ]; then
        (umask 077 && printf '# NeoDesk relay node: read by %s.service\n' "$NODE_SERVICE" > "$NODE_ENV_FILE")
    fi
    chown root:root "$NODE_ENV_FILE"
    chmod 0600 "$NODE_ENV_FILE"
    _upsert_env_line "$NODE_ENV_FILE" MODE node
    _upsert_env_line "$NODE_ENV_FILE" NODE_DATA_DIR "$NODE_STATE_DIR"
    _upsert_env_line "$NODE_ENV_FILE" NODE_LAN_ADDR "$lan"
    _upsert_env_line "$NODE_ENV_FILE" NODE_PUBLIC_ADDR "$public"
    [ -z "$NODE_JOIN" ] || _upsert_env_line "$NODE_ENV_FILE" NODE_JOIN "$NODE_JOIN"
    print_success "Settings in $NODE_ENV_FILE (LAN $lan, public ${public:-none})"

    write_node_unit
    systemctl daemon-reload
    systemctl enable "$NODE_SERVICE" >/dev/null 2>&1 || true
    if ! systemctl restart "$NODE_SERVICE"; then
        print_error "$NODE_SERVICE did not start"
        journalctl -u "$NODE_SERVICE" -n 30 --no-pager 2>/dev/null || true
        return 1
    fi
    print_success "Started $NODE_SERVICE.service (user $NODE_USER)"

    # The join string is good for one enrollment: once the node has its
    # node.json it goes from the env file
    if [ -n "$(env_file_value "$NODE_ENV_FILE" NODE_JOIN)" ]; then
        local i
        for i in $(seq 1 30); do
            [ -s "$NODE_STATE_DIR/node.json" ] && break
            systemctl is-active --quiet "$NODE_SERVICE" || break
            sleep 1
        done
        if [ -s "$NODE_STATE_DIR/node.json" ]; then
            _remove_env_line "$NODE_ENV_FILE" NODE_JOIN
            print_success "The node joined its site"
        elif ! systemctl is-active --quiet "$NODE_SERVICE"; then
            print_error "$NODE_SERVICE stopped before it joined its site"
            journalctl -u "$NODE_SERVICE" -n 30 --no-pager 2>/dev/null || true
            return 1
        else
            print_warning "The node has not joined its site yet; see: journalctl -u $NODE_SERVICE -f"
        fi
    fi
    print_info "Devices reach the relay on TCP 21117 and 21119 (WebSocket): open both towards them,"
    print_info "and forward them from the public address when there is one"
    print_info "Update: run this again without --join. Remove: --node --uninstall (--purge also its key)"
    return 0
}

# do_node_uninstall: removes the relay node; its key and enrollment stay
# unless --purge is given
do_node_uninstall() {
    print_header
    print_step "Removing the NeoDesk relay node..."
    if [ ! -f "$NODE_UNIT" ] && [ ! -d "$NODE_INSTALL_DIR" ] && [ ! -d "$NODE_STATE_DIR" ]; then
        print_info "There is no relay node on this machine"
        return 0
    fi
    systemctl disable --now "$NODE_SERVICE" 2>/dev/null || true
    rm -f "$NODE_UNIT"
    systemctl daemon-reload 2>/dev/null || true
    rm -rf -- "${NODE_INSTALL_DIR:?}" "${NODE_ENV_DIR:?}"
    if [ "$PURGE_MODE" = true ]; then
        rm -rf -- "${NODE_STATE_DIR:?}"
        userdel "$NODE_USER" 2>/dev/null || true
        print_success "Relay node removed with its key; remove it in the console too (Sites)"
    else
        print_success "Relay node removed; its key stays in $NODE_STATE_DIR (--purge removes it)"
    fi
    return 0
}

#===============================================================================
# Main Menu
#===============================================================================

show_menu() {
    print_header
    print_status
    
    echo -e "${WHITE}${BOLD}══════════ MAIN MENU ══════════${NC}"
    echo ""
    echo "  1. 🚀 FRESH INSTALLATION"
    echo "  2. ⬆️  UPDATE"
    echo "  3. 🔧 REPAIR INSTALLATION"
    echo "  4. ✅ INSTALLATION VALIDATION"
    echo "  5. 💾 Backup"
    echo "  6. 🔐 Reset admin password"
    echo "  7. 🔨 Build & deploy server"
    echo "  8. 📊 DIAGNOSTICS"
    echo "  9. 🗑️  UNINSTALL"
    echo ""
    echo "  L. 📦 MINIMAL INSTALLATION (server only)"
    echo "  C. 🔒 Configure SSL certificates"
    echo "  T. 🔄 Toggle HTTP/HTTPS mode"
    echo "  M. 🔄 Database migration"
    echo "  B. 🧰 Build toolchain (optional/dev; not needed for production)"
    echo "  S. ⚙️  Settings (paths)"
    echo "  P. 🛡️  Management capabilities and server settings"
    echo "  0. ❌ Exit"
    echo ""
    echo -e "  ${DIM}Tip: this menu also supports arrow-key navigation (set NEODESK_CLASSIC_MENU=1 to force this list).${NC}"
    echo ""
}

main() {
    # Check root
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}This script requires root privileges!${NC}"
        # neodesk hands the installer's options over and says so
        if [ "${NEODESK_SETUP_CALLED_AS:-}" = neodesk ]; then
            echo "Run: sudo neodesk ${NEODESK_ORIG_ARGV[*]}"
        else
            case "$0" in
                bash|-bash|*/bash) echo "Run: curl -fsSL https://neode.sk/neodesk.sh | sudo bash" ;;
                *) echo "Run: sudo $0" ;;
            esac
        fi
        exit 1
    fi
    # A relay node leaves a server install here alone: nothing below runs
    if [ "$NODE_MODE" = true ]; then
        if [ "$UNINSTALL_MODE" = true ]; then
            do_node_uninstall
        else
            do_node_install
        fi
        exit $?
    fi
    move_backup_folder || print_warning "The backups in $OLD_BACKUP_DIR could not move to $BACKUP_DIR"
    # Backups an older installer left readable for every account
    secure_backup_folder

    # Auto-detect paths on startup
    echo -e "${CYAN}Detecting installation...${NC}"
    auto_detect_paths
    echo ""
    sleep 1

    default_to_auto_without_terminal

    if [ "$CHECK_CAPABILITIES" = true ] || [ "$REPAIR_PERMISSIONS" = true ] \
        || [ "${#MANAGED_CONFIG_CHANGES[@]}" -gt 0 ]; then
        local management_rc=0
        [ "$REPAIR_PERMISSIONS" = true ] && repair_management_permissions
        # --set-config alone gets no capability report: config set checks
        # what it writes itself
        if [ "$CHECK_CAPABILITIES" = true ] || [ "$REPAIR_PERMISSIONS" = true ]; then
            check_management_capabilities || management_rc=$?
        fi
        if [ "${#MANAGED_CONFIG_CHANGES[@]}" -gt 0 ]; then
            apply_managed_config || management_rc=$?
        fi
        exit "$management_rc"
    fi

    # An update runs without questions
    if [ "$UPDATE_MODE" = true ]; then
        AUTO_MODE=true
        do_update
        exit $?
    fi

    # --uninstall asks nothing: it makes a backup and keeps the data unless
    # --purge is given
    [ "$UNINSTALL_MODE" = true ] && AUTO_MODE=true

    if [ "$RESET_PASSWORD_MODE" = true ]; then
        AUTO_MODE=true
        do_reset_password
        exit $?
    fi

    # Without questions: install, or update an install that is there (run
    # again, the installer updates)
    if [ "$AUTO_MODE" = true ]; then
        case "$(auto_action)" in
            uninstall) do_uninstall ;;
            update)
                print_info "NeoDesk is installed here: updating it"
                do_update
                ;;
            minimal) do_install_minimal ;;
            *) do_install ;;
        esac
        exit $?
    fi

    # Action tokens map 1:1 to the classic case dispatch below, so both the
    # arrow-key TUI and the numeric fallback share the exact same handlers.
    local menu_labels=(
        $'Fresh installation\tFull install from scratch'
        $'Update\tNewest release of the update channel'
        $'Repair installation\tFix common problems'
        $'Validate installation\tCheck correctness'
        $'Backup\tCreate a backup'
        $'Reset admin password\tReset the console admin'
        $'Build & deploy server\tCompile and deploy the Go server'
        $'Diagnostics\tDetailed problem analysis'
        $'Uninstall\tRemove NeoDesk'
        $'Minimal installation\tServer with its web console off'
        $'Configure SSL certificates\tLet'"'"'s Encrypt / custom / self-signed'
        $'Toggle HTTP/HTTPS\tSwitch protocol + run tests'
        $'Database migration\tMigrate between backends'
        $'Build toolchain (optional/dev)\tBuild support agents on this machine; not needed for production'
        $'Settings (paths)\tConfigure install paths'
        $'Management capabilities\tCheck permissions and change allowlisted server settings'
        $'Exit\tQuit the manager'
    )
    local menu_actions=( 1 2 3 4 5 6 7 8 9 L C T M B S P 0 )

    while true; do
        local choice=""
        if tui_available; then
            detect_installation 2>/dev/null
            local status_line="Install: ${INSTALL_STATUS:-unknown}"
            [ "$HBBS_RUNNING" = true ] && status_line="$status_line  |  server: running" || status_line="$status_line  |  server: stopped"
            [ "$CONSOLE_RUNNING" = true ] && status_line="$status_line  |  console: running" || status_line="$status_line  |  console: stopped"
            if tui_select "NeoDesk Console Manager v${VERSION}" "$status_line" "${menu_labels[@]}"; then
                choice="${menu_actions[$TUI_RESULT]}"
            else
                choice="0"
            fi
        else
            show_menu
            read -p "Select option: " choice
        fi

        case $choice in
            1) do_install ;;
            2) do_update ;;
            3) do_repair ;;
            4) do_validate ;;
            5) do_backup ;;
            6) do_reset_password ;;
            7) do_build ;;
            8) do_diagnostics ;;
            9) do_uninstall ;;
            [Ll]) do_install_minimal ;;
            [Cc]) do_configure_ssl ;;
            [Tt]) do_toggle_protocol ;;
            [Mm]) do_migrate_database ;;
            [Bb]) do_install_build_toolchain ;;
            [Ss]) configure_paths ;;
            [Pp]) configure_management ;;
            0) 
                echo ""
                print_info "Goodbye!"
                exit 0
                ;;
            *)
                print_warning "Invalid option"
                sleep 1
                ;;
        esac
    done
}

# auto_action: what a run without questions does here: install, update (an
# install of the server with its console is there), minimal or uninstall.
# --postgresql on an install that runs on SQLite installs again, which
# moves it to PostgreSQL. An install with the Node.js console gets install,
# which refuses it.
auto_action() {
    if [ "$UNINSTALL_MODE" = true ]; then
        echo uninstall
    elif is_go_only_install && [ -x "$(server_binary_path)" ] && [ -f "$CONSOLE_PATH/.env" ] \
        && { [ "$USE_POSTGRESQL" != true ] || [ "$(env_database_type "$CONSOLE_PATH/.env")" = postgres ]; }; then
        echo update
    elif [ "$MINIMAL_MODE" = true ]; then
        echo minimal
    else
        echo install
    fi
}

# Run only when executed directly or piped into bash (curl ... | sudo bash,
# where BASH_SOURCE is empty); this also lets installer tests source the
# bounded command helpers without starting the interactive manager.
if [[ "${BASH_SOURCE[0]:-$0}" == "$0" ]]; then
    main "$@"
fi
