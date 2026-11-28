#!/usr/bin/env bash
# =============================================================================
# NeoDesk: the one-line installer (Linux)
#
#   curl -fsSL https://neode.sk/install.sh | sudo bash
#   curl -fsSL https://neode.sk/install.sh | sudo bash -s -- --help
#
# Docker (the default) runs neodesk-docker.sh of the release, native
# (--native) its neodesk.sh --auto. usage() below lists every option.
# =============================================================================

set -euo pipefail

NEODESK_REPO="${NEODESK_REPO:-neodeskapp/neodesk}"
# Where the managers this installer runs come from (neodesk.sh for a
# native install, neodesk-docker.sh for Docker), the first that applies:
# RELEASE_BASE_URL, a release folder; a git branch (--branch /
# NEODESK_BRANCH, for development: its install/ folder, and a native
# install clones it); the files next to this installer when it runs from
# a file that has them (a checkout's install/ folder, a downloaded
# release); else the release of this installer's version (the default of
# NEODESK_VERSION), or of --version, checked against the release's
# SHA256SUMS. The branch names no release channel; that is --channel.
NEODESK_BRANCH="${NEODESK_BRANCH:-}"
SKIP_VERIFY=false
# The release channel of a native install: stable or dev; empty leaves it
# to neodesk.sh (stable, or dev while there is no stable release)
RELEASE_CHANNEL=""
# An image tag given (--version, NEODESK_VERSION) pins it; without one
# the install runs latest, the newest release (DECISIONS A163)
NEODESK_VERSION_GIVEN="${NEODESK_VERSION:-}"
NEODESK_VERSION="${NEODESK_VERSION:-3.6.7}"
NEODESK_RAW_BASE="${NEODESK_RAW_BASE:-${NEODESK_BRANCH:+https://raw.githubusercontent.com/${NEODESK_REPO}/${NEODESK_BRANCH}/install}}"
# The folder this installer runs from, when it is a file (not piped)
INSTALLER_FOLDER=""
if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
    INSTALLER_FOLDER="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi
INSTALL_DIR="${INSTALL_DIR:-/opt/neodesk}"
INSTALL_MODE="docker"
MIGRATE_SPLIT=false
RELAY_MODE="${RELAY_MODE:-auto}"
RELAY_SERVERS="${RELAY_SERVERS:-}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-}"
NEODESK_DOMAIN="${NEODESK_DOMAIN:-}"
LETSENCRYPT_EMAIL="${LETSENCRYPT_EMAIL:-}"
LETSENCRYPT_STAGING=false
NO_TRAEFIK=false
NO_IPV6=false
SKIP_DOCKER_INSTALL=false
SKIP_FIREWALL=false
IMPORT_KEYS=""
DO_UNINSTALL=false
DO_PURGE=false
DO_RESCUE=false
RESCUE_ACTION="rescue"
CHECK_CAPABILITIES=false
MANAGED_CONFIG_CHANGES=()
# --node: a relay node of a site (neodesk.sh --node), with the console's
# join string and the addresses devices dial it at
NODE_JOIN=""
NODE_LAN_ADDR=""
NODE_PUBLIC_ADDR=""

# ── Output helpers ────────────────────────────────────────────────────────────

# Colours: 24-bit where the terminal says it has them (COLORTERM), else the
# 16 basic ones; none when the output is not a terminal, NO_COLOR is set or
# TERM is dumb (COLOR_DEPTH 24bit, 16 or empty). In 24-bit, C_RED, C_GREEN,
# C_YELLOW and C_CYAN keep at least 3.8:1 on black, on PowerShell's blue
# and on white.
COLOR_DEPTH=""
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-}" != dumb ]; then
    case "${COLORTERM:-}" in
        truecolor|24bit) COLOR_DEPTH=24bit ;;
        *) COLOR_DEPTH=16 ;;
    esac
fi
case "$COLOR_DEPTH" in
    24bit)
        C_RED='\033[38;2;228;75;69m'
        C_GREEN='\033[38;2;37;149;46m'
        C_YELLOW='\033[38;2;178;116;9m'
        C_CYAN='\033[38;2;26;143;147m'
        ;;
    16)
        C_RED='\033[0;31m'
        C_GREEN='\033[0;32m'
        C_YELLOW='\033[0;33m'
        C_CYAN='\033[0;36m'
        ;;
    *)
        C_RED='' C_GREEN='' C_YELLOW='' C_CYAN=''
        ;;
esac
if [ -n "$COLOR_DEPTH" ]; then
    C_RESET='\033[0m'
    C_BOLD='\033[1m'
else
    C_RESET='' C_BOLD=''
fi

log()  { echo -e "${C_CYAN}[install]${C_RESET} $*"; }
ok()   { echo -e "${C_GREEN}✓${C_RESET} $*"; }
warn() { echo -e "${C_YELLOW}!${C_RESET} $*" >&2; }
die()  { echo -e "${C_RED}✗${C_RESET} $*" >&2; exit 1; }

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

# print_header: the NeoDesk logo with what this script is
# and the release it installs; one plain line without colour (no
# terminal, NO_COLOR). The managers this script runs leave theirs out
# (NEODESK_HEADER_SHOWN).
print_header() {
    local title="Installer ${NEODESK_VERSION}"
    export NEODESK_HEADER_SHOWN=1
    if [ -z "$COLOR_DEPTH" ]; then
        printf 'NeoDesk %s\n' "$title"
        return 0
    fi
    printf '\n'
    draw_logo "$title"
    printf '\n'
}

# usage: the options. A heredoc, since piped into bash (curl ... | sudo
# bash -s -- --help) this script has no file to read them from.
usage() {
    cat <<'EOF'
NeoDesk installer (Linux)

Docker (the default: the published image in one container, neodesk-docker.sh):
  curl -fsSL https://neode.sk/install.sh | sudo bash

Docker, move a two-container (split) install to the one container:
  curl -fsSL https://neode.sk/install.sh | sudo bash -s -- --migrate-split

Native (neodesk.sh --auto of the release): the newest stable release, or the
development build while the repository has none:
  curl -fsSL https://neode.sk/install.sh | sudo bash -s -- --native
Native, the development build: add --channel dev

A relay node of a site (the join string is in the console, under Sites):
  curl -fsSL https://neode.sk/install.sh | sudo bash -s -- --node --join nd1.xxxx

Options (pass them after "bash -s --"):
  --docker | --native            Installation mode (default: docker)
  --node                         A relay node of a site instead of a server:
                                 the service neodesk-relay-node, no database,
                                 no console; a server here stays as it is.
                                 Run again to update it; with --uninstall it
                                 is removed (--purge also its key)
  --join STRING                  Relay node: the console's join string (the
                                 first install only)
  --lan-addr HOST:PORT           Relay node: where LAN devices dial it
                                 (default: the LAN address, port 21117)
  --public-addr HOST:PORT        Relay node: where devices outside the LAN
                                 dial it, through a port forward (default: none)
  --migrate-split                Replace a split install (server and console
                                 containers) with the one container, which takes
                                 its data over
  --install-dir PATH             Install folder (default: /opt/neodesk)
  --version TAG                  Docker image tag to pin (default: latest, the
                                 newest release)
  --branch BRANCH                Take the installer files of a git branch instead
                                 of the release's (development; native installs
                                 clone it)
  --skip-verify                  Native: install a release signed with another
                                 key (a fork's)
  --channel stable|dev           Native: release channel (default: stable)
  --relay-mode auto|local|public How to find the address clients reach this
                                 server at
  --relay-servers ADDRESS        That address, public IP or DNS name (overrides
                                 --relay-mode)
  --admin-password PASS          The admin's first password (Docker: ADMIN_PASSWORD)
  --domain NAME                  Docker: HTTPS for the console at this DNS name
                                 with a Let's Encrypt certificate that Traefik
                                 renews by itself (the name must point at this
                                 server; ports 80 and 443)
  --email ADDRESS                Docker, optional: the contact address of the
                                 Let's Encrypt account (also --letsencrypt-email)
  --letsencrypt-staging          Docker: certificates from Let's Encrypt's
                                 staging server (for tests)
  --no-traefik                   Docker: remove Traefik again; the console
                                 answers on its own port
  --no-ipv6                      Docker: a new install without IPv6 on the
                                 containers' network (on by default with
                                 Docker Engine 27 or newer)
  --import-keys FOLDER           Docker: the key pair of a RustDesk server
                                 (id_ed25519 and id_ed25519.pub in FOLDER), so
                                 its clients keep working
  --skip-docker-install          Do not install Docker when it is missing
  --skip-firewall                Docker: leave ufw and firewalld as they are
  --rescue                       Repair: permissions, restart, health checks
  --diagnose                     Read-only diagnostics of a Docker install
  --repair-permissions           Only repair the Docker volumes' permissions
  --check-permissions            Check update, settings and restart capabilities
  --set-config KEY=VALUE         Apply an allowed server setting
  --uninstall                    Remove the NeoDesk Docker install
  --purge                        With --uninstall: also delete the Docker volumes
  --help                         This text

Environment variables (the same as the options where there is one):
  NEODESK_REPO, NEODESK_BRANCH, NEODESK_VERSION, INSTALL_DIR, RELAY_MODE,
  RELAY_SERVERS, ADMIN_PASSWORD, NEODESK_RAW_BASE, NEODESK_DOMAIN,
  LETSENCRYPT_EMAIL, RELEASE_BASE_URL (a release folder with the files:
  SHA256SUMS, neodesk.sh, neodesk-docker.sh, ...)

Docker installs are managed later with
  sudo bash /opt/neodesk/docker/neodesk-docker.sh --help
EOF
    exit 0
}

# ── Argument parsing ──────────────────────────────────────────────────────────

while [ $# -gt 0 ]; do
    case "$1" in
        --docker) INSTALL_MODE="docker"; shift ;;
        --migrate-split) MIGRATE_SPLIT=true; shift ;;
        --split) die "--split is gone: NeoDesk runs as one container. An existing split install moves with --migrate-split" ;;
        --native) INSTALL_MODE="native"; shift ;;
        --node) INSTALL_MODE="node"; shift ;;
        --join|--lan-addr|--public-addr)
            [ $# -ge 2 ] && [ -n "$2" ] || die "$1 needs a value"
            case "$1" in
                --join) NODE_JOIN="$2" ;;
                --lan-addr) NODE_LAN_ADDR="$2" ;;
                --public-addr) NODE_PUBLIC_ADDR="$2" ;;
            esac
            shift 2 ;;
        --install-dir) INSTALL_DIR="$2"; shift 2 ;;
        --version) NEODESK_VERSION="$2"; NEODESK_VERSION_GIVEN="$2"; shift 2 ;;
        --branch) NEODESK_BRANCH="$2"; NEODESK_RAW_BASE="https://raw.githubusercontent.com/${NEODESK_REPO}/${NEODESK_BRANCH}/install"; shift 2 ;;
        --skip-verify) SKIP_VERIFY=true; shift ;;
        --channel)
            case "${2:-}" in
                stable|main|dev|development) RELEASE_CHANNEL="$2" ;;
                *) die "--channel must be stable or dev" ;;
            esac
            shift 2 ;;
        --relay-mode) RELAY_MODE="$2"; shift 2 ;;
        --relay-servers) RELAY_SERVERS="$2"; shift 2 ;;
        --admin-password) ADMIN_PASSWORD="$2"; shift 2 ;;
        --domain) NEODESK_DOMAIN="$2"; shift 2 ;;
        --email|--letsencrypt-email) [ $# -ge 2 ] || die "$1 needs an e-mail address"; LETSENCRYPT_EMAIL="$2"; shift 2 ;;
        --no-traefik) NO_TRAEFIK=true; shift ;;
        --no-ipv6) NO_IPV6=true; shift ;;
        --letsencrypt-staging) LETSENCRYPT_STAGING=true; shift ;;
        --skip-docker-install) SKIP_DOCKER_INSTALL=true; shift ;;
        --skip-firewall) SKIP_FIREWALL=true; shift ;;
        --import-keys) [ $# -ge 2 ] || die "--import-keys needs a folder"; IMPORT_KEYS="$2"; shift 2 ;;
        --rescue) DO_RESCUE=true; RESCUE_ACTION="rescue"; shift ;;
        --diagnose|--diagnostics) DO_RESCUE=true; RESCUE_ACTION="diagnose"; shift ;;
        --repair-permissions) DO_RESCUE=true; RESCUE_ACTION="repair-permissions"; shift ;;
        --check-permissions|--check-capabilities) CHECK_CAPABILITIES=true; shift ;;
        --set-config)
            [ $# -ge 2 ] && [[ "$2" == *=* ]] || die "--set-config requires KEY=VALUE"
            MANAGED_CONFIG_CHANGES+=("$2")
            shift 2
            ;;
        --purge) DO_PURGE=true; shift ;;
        --uninstall) DO_UNINSTALL=true; shift ;;
        -h|--help) usage ;;
        *) die "Unknown option: $1 (use --help)" ;;
    esac
done

# ── Preflight ─────────────────────────────────────────────────────────────────

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        die "This installer must run as root. Re-run with: sudo bash"
    fi
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

get_public_ip() {
    local ip
    ip=$(curl -4 -fsS --max-time 5 https://checkip.amazonaws.com 2>/dev/null | tr -d '[:space:]') && [ -n "$ip" ] && echo "$ip" && return
    ip=$(curl -4 -fsS --max-time 5 https://api.ipify.org 2>/dev/null | tr -d '[:space:]') && [ -n "$ip" ] && echo "$ip" && return
    ip=$(curl -4 -fsS --max-time 5 https://ifconfig.me/ip 2>/dev/null | tr -d '[:space:]') && [ -n "$ip" ] && echo "$ip" && return
    echo "127.0.0.1"
}

get_local_ip() {
    local ip
    ip=$(ip -4 route get 1.1.1.1 2>/dev/null | grep -oP 'src \K[0-9.]+' | head -1)
    [ -n "$ip" ] && echo "$ip" && return
    ip=$(ip -4 addr show scope global 2>/dev/null | grep -oP 'inet \K[0-9.]+' | head -1)
    [ -n "$ip" ] && echo "$ip" && return
    ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    [ -n "$ip" ] && echo "$ip" && return
    echo "127.0.0.1"
}

is_private_ip() {
    case "$1" in
        127.*|10.*|192.168.*) return 0 ;;
        172.1[6-9].*|172.2[0-9].*|172.3[0-1].*) return 0 ;;
        *) return 1 ;;
    esac
}

resolve_relay_address() {
    if [ -n "$RELAY_SERVERS" ]; then
        warn "Using fixed relay address: $RELAY_SERVERS"
        echo "$RELAY_SERVERS"
        return
    fi

    local ip
    case "${RELAY_MODE}" in
        local|lan)
            ip=$(get_local_ip)
            log "Relay mode 'local': using LAN IP $ip"
            ;;
        public|wan)
            ip=$(get_public_ip)
            log "Relay mode 'public': using public IP $ip"
            ;;
        auto|*)
            ip=$(get_public_ip)
            if is_private_ip "$ip"; then
                warn "Auto-detected private/loopback IP: $ip"
                warn "Internet clients may fail relay connections. Set --relay-servers YOUR.PUBLIC.IP or use --relay-mode local for LAN-only."
            fi
            ;;
    esac

    # Include relay port when only an IP was detected.
    case "$ip" in
        *:*) echo "$ip" ;;
        *) echo "${ip}:21117" ;;
    esac
}

fetch_url_to_file() {
    local url="$1"
    local dest="$2"
    local min_bytes="${3:-512}"
    local max_bytes="${4:-1048576}"

    if ! curl -fsSL --max-time 120 --proto '=https' --tlsv1.2 -o "$dest" "$url"; then
        die "Failed to download: $url"
    fi

    local size
    size=$(stat -c%s "$dest" 2>/dev/null || wc -c <"$dest")
    if [ "${size:-0}" -lt "$min_bytes" ] || [ "${size:-0}" -gt "$max_bytes" ]; then
        die "Downloaded file has unexpected size (${size} bytes): $url"
    fi
}

# ── Docker helpers ────────────────────────────────────────────────────────────

check_docker() {
    command -v docker >/dev/null 2>&1 || return 1
    docker info >/dev/null 2>&1 || return 2
    return 0
}

check_docker_compose() {
    if docker compose version >/dev/null 2>&1; then
        COMPOSE_CMD=(docker compose)
        return 0
    fi
    if command -v docker-compose >/dev/null 2>&1; then
        COMPOSE_CMD=(docker-compose)
        return 0
    fi
    return 1
}

# A two-container (split) install in the compose folder: its .env says so,
# or its compose file runs a console service.
is_split_install() {
    local compose_dir="$1"
    grep -qs '^NEODESK_DOCKER_LAYOUT=split' "${compose_dir}/.env" \
        || grep -Eqs 'ghcr\.io/[a-z0-9._-]+/neodesk-console' "${compose_dir}/docker-compose.yml"
}

# newest_release_tag: the tag of the newest published release, a
# pre-release too, other than the rolling "dev" one; GitHub lists the
# releases newest first, each with tag_name before draft
newest_release_tag() {
    local tag
    tag=$(curl -fsSL --max-time 30 --proto '=https' --tlsv1.2 -H 'Accept: application/vnd.github+json' \
        "https://api.github.com/repos/${NEODESK_REPO}/releases?per_page=20" 2>/dev/null \
        | tr -d '\r\n' \
        | grep -oE '"(tag_name|draft)"[[:space:]]*:[[:space:]]*("[^"]*"|true|false)' \
        | sed -E 's/^"([a-z_]+)"[[:space:]]*:[[:space:]]*"?([^"]*)"?$/\1 \2/' \
        | awk '$1 == "tag_name" { tag = $2 } $1 == "draft" && $2 == "false" && tag != "dev" && tag ~ /^v[0-9][A-Za-z0-9._-]*$/ { print tag; exit }') || true
    [ -n "$tag" ] || return 1
    printf '%s\n' "$tag"
}

# release_base: the folder of the release whose managers this installer
# runs: RELEASE_BASE_URL, else the release of NEODESK_VERSION (this
# installer's own, or --version): the newest for latest, the rolling one
# for dev
release_base() {
    if [ -n "${RELEASE_BASE_URL:-}" ]; then
        printf '%s\n' "${RELEASE_BASE_URL%/}"
        return 0
    fi
    local tag
    case "$NEODESK_VERSION" in
        latest) tag=$(newest_release_tag) || return 1 ;;
        dev) tag=dev ;;
        v[0-9]*) tag="$NEODESK_VERSION" ;;
        [0-9]*.[0-9]*.[0-9]*) tag="v$NEODESK_VERSION" ;;
        *) return 1 ;;
    esac
    printf 'https://github.com/%s/releases/download/%s\n' "$NEODESK_REPO" "$tag"
}

# fetch_manager NAME DEST: the manager NAME (neodesk.sh, neodesk-docker.sh)
# as DEST, from where this installer takes its files (see NEODESK_BRANCH
# above). A release's file is checked against the release's SHA256SUMS;
# while this installer's own release is not out (a checkout ahead of the
# releases), the newest release's is taken.
fetch_manager() {
    local name="$1" dest="$2" base sums expected newest
    mkdir -p "$(dirname "$dest")"
    if [ -z "${RELEASE_BASE_URL:-}" ] && [ -n "$NEODESK_RAW_BASE" ]; then
        fetch_url_to_file "${NEODESK_RAW_BASE}/$name" "$dest.tmp" 4096 1048576
    elif [ -z "${RELEASE_BASE_URL:-}" ] && [ -n "$INSTALLER_FOLDER" ] && [ -f "$INSTALLER_FOLDER/$name" ]; then
        log "Using ${INSTALLER_FOLDER}/$name"
        cp "$INSTALLER_FOLDER/$name" "$dest.tmp"
    else
        base=$(release_base) || die "There is no release for the version ${NEODESK_VERSION}" \
            "Give a release's version with --version, or leave it out for this installer's own"
        sums=$(mktemp)
        if ! curl -fsSL --max-time 60 --proto '=https' --tlsv1.2 -o "$sums" "$base/SHA256SUMS" 2>/dev/null; then
            if [ -n "$NEODESK_VERSION_GIVEN" ] || [ -n "${RELEASE_BASE_URL:-}" ] || ! newest=$(newest_release_tag); then
                rm -f "$sums"
                die "Failed to download: $base/SHA256SUMS" "Releases from 3.6.0-rc.5 on have their installers attached."
            fi
            base="https://github.com/${NEODESK_REPO}/releases/download/${newest}"
            warn "There is no release ${NEODESK_VERSION} yet: taking the files of the newest release, ${newest}"
            curl -fsSL --max-time 60 --proto '=https' --tlsv1.2 -o "$sums" "$base/SHA256SUMS" \
                || { rm -f "$sums"; die "Failed to download: $base/SHA256SUMS"; }
        fi
        expected=$(awk -v n="$name" '$2 == n || $2 == "*" n { print tolower($1); exit }' "$sums")
        rm -f "$sums"
        [ -n "$expected" ] || die "The release at $base has no $name" "Releases from 3.6.0-rc.5 on have their installers attached."
        fetch_url_to_file "$base/$name" "$dest.tmp" 4096 1048576
        if [ "$(sha256sum "$dest.tmp" | cut -d' ' -f1)" != "$expected" ]; then
            rm -f "$dest.tmp"
            die "The release's $name does not match its SHA256SUMS ($base); nothing was changed"
        fi
        log "$name of the release ${base##*/}, checked against its SHA256SUMS"
    fi
    install -m 0755 "$dest.tmp" "$dest"
    rm -f "$dest.tmp"
}

# fetch_docker_manager DEST: neodesk-docker.sh, which installs, updates
# and removes NeoDesk on Docker (fetch_manager).
fetch_docker_manager() {
    local dest="$1"
    fetch_manager neodesk-docker.sh "$dest"
    if ! grep -q 'NEODESK_DOCKER_SOURCED' "$dest"; then
        rm -f "$dest"
        die "The downloaded neodesk-docker.sh is not NeoDesk's Docker manager"
    fi
}

# install_docker_mode: neodesk-docker.sh in the compose folder installs
# the one container there (or updates the install it finds), with the
# options given here; a split install is taken over (--adopt) on its data.
install_docker_mode() {
    local compose_dir="${INSTALL_DIR}/docker"
    local manager="${compose_dir}/neodesk-docker.sh"
    local args=(install --dir "$compose_dir" --yes)

    log "neodesk-docker.sh installs the one container in ${compose_dir}"
    if is_split_install "$compose_dir"; then
        if [ "$MIGRATE_SPLIT" != true ]; then
            warn "This is a split install (server and console containers). NeoDesk now runs as one container."
        fi
        warn "Its data moves into the one container (neodesk-docker.sh --adopt); the old containers are kept, stopped and renamed."
        args+=(--adopt)
    elif [ "$MIGRATE_SPLIT" = true ]; then
        log "No split install in ${compose_dir}; installing the one container"
    fi
    if [ -n "$RELAY_SERVERS" ]; then
        args+=(--relay "$RELAY_SERVERS")
    else
        args+=(--relay-mode "$RELAY_MODE")
    fi
    [ -z "$NEODESK_VERSION_GIVEN" ] || args+=(--tag "$NEODESK_VERSION_GIVEN")
    [ "$SKIP_DOCKER_INSTALL" != true ] || args+=(--no-install-docker)
    [ -z "$NEODESK_DOMAIN" ] || args+=(--domain "$NEODESK_DOMAIN")
    [ -z "$LETSENCRYPT_EMAIL" ] || args+=(--email "$LETSENCRYPT_EMAIL")
    [ "$LETSENCRYPT_STAGING" != true ] || args+=(--letsencrypt-staging)
    [ "$NO_TRAEFIK" != true ] || args+=(--no-traefik)
    [ "$NO_IPV6" != true ] || args+=(--no-ipv6)
    [ -z "$IMPORT_KEYS" ] || args+=(--import-keys "$IMPORT_KEYS")
    # The manager opens the ports in ufw or firewalld, before the container
    # starts (Let's Encrypt's challenge comes in on 80), and closes them at
    # uninstall
    [ "$SKIP_FIREWALL" != true ] || args+=(--skip-firewall)

    fetch_docker_manager "$manager"
    ok "Docker manager: $manager"
    export ADMIN_PASSWORD
    # The manager takes its compose file and its own copy from the same
    # place: a release folder given, or the branch's files
    [ -z "${RELEASE_BASE_URL:-}" ] || export RELEASE_BASE_URL
    [ -z "$NEODESK_RAW_BASE" ] || export NEODESK_RAW_BASE
    "$manager" "${args[@]}"
    log "Later: sudo bash $manager (update), status, logs, backup, uninstall (see --help)"
}

rescue_docker_mode() {
    local rescue_dir="${INSTALL_DIR}/rescue"
    local rescue_script="${rescue_dir}/neodesk-docker.sh"
    local rescue_flag

    case "$RESCUE_ACTION" in
        diagnose) rescue_flag="--diagnose" ;;
        repair-permissions) rescue_flag="--repair-permissions" ;;
        rescue|*) rescue_flag="--rescue" ;;
    esac

    log "Preparing NeoDesk Docker rescue toolkit..."
    require_command curl
    if [ "$RESCUE_ACTION" != "diagnose" ]; then
        check_docker || die "Docker is not available or the daemon is not running"
        check_docker_compose || die "Docker Compose plugin is not available"
    fi

    fetch_docker_manager "$rescue_script"
    ok "Rescue script ready: $rescue_script"

    log "Running Docker rescue action: $RESCUE_ACTION"
    DATA_DIR="${DATA_DIR:-}" COMPOSE_FILE="${COMPOSE_FILE:-}" \
        "$rescue_script" "$rescue_flag" --dir "${INSTALL_DIR}/docker"
}

uninstall_docker_mode() {
    local compose_dir="${INSTALL_DIR}/docker"
    local compose_file="${compose_dir}/docker-compose.yml"
    local manager="${compose_dir}/neodesk-docker.sh"

    require_root
    # The manager of the install removes it and says what it leaves
    if [ -x "$manager" ]; then
        local args=(uninstall --dir "$compose_dir")
        [ "$DO_PURGE" != true ] || args+=(--purge --yes)
        "$manager" "${args[@]}"
        return
    fi
    check_docker_compose || die "Docker Compose not available"

    if [ ! -f "$compose_file" ]; then
        die "No Docker installation found at ${compose_dir}"
    fi

    log "Stopping NeoDesk Docker stack..."
    if [ "$DO_PURGE" = true ]; then
        (cd "$compose_dir" && "${COMPOSE_CMD[@]}" --env-file .env down -v)
        ok "Containers and volumes removed"
    else
        (cd "$compose_dir" && "${COMPOSE_CMD[@]}" --env-file .env down)
        ok "Containers stopped (volumes preserved — re-run with --purge to delete data)"
    fi
}

# ── Native install ────────────────────────────────────────────────────────────

native_backup_source() {
    local source_dir="$1"
    local backup_dir="${source_dir}.backup.$(date +%Y%m%d%H%M%S).$$"

    while [ -e "$backup_dir" ]; do
        backup_dir="${source_dir}.backup.$(date +%Y%m%d%H%M%S).${RANDOM}"
    done
    if ! mv "$source_dir" "$backup_dir"; then
        print_error "Could not preserve existing native source at ${source_dir}"
        return 1
    fi
    printf '%s\n' "$backup_dir"
}

native_clone_source() {
    local repo_dir="$1"
    local backup_dir="${2:-}"
    local staging_parent
    local staging_repo

    mkdir -p "$INSTALL_DIR"
    staging_parent=$(mktemp -d "${INSTALL_DIR}/.source-clone.XXXXXX")
    staging_repo="${staging_parent}/source"

    if ! git clone --depth 1 --branch "$NEODESK_BRANCH" \
        "https://github.com/${NEODESK_REPO}.git" "$staging_repo"; then
        rm -rf "$staging_parent"
        if [ -n "$backup_dir" ] && [ ! -e "$repo_dir" ]; then
            mv "$backup_dir" "$repo_dir" 2>/dev/null || true
        fi
        return 1
    fi

    # The native update path keeps local Go runtime data beside the source.
    # Carry it forward without replacing anything created by the fresh clone.
    if [ -n "$backup_dir" ] \
        && [ -d "$backup_dir/neodesk-server/data" ] \
        && [ ! -e "$staging_repo/neodesk-server/data" ]; then
        if ! cp -a "$backup_dir/neodesk-server/data" "$staging_repo/neodesk-server/"; then
            rm -rf "$staging_parent"
            if [ -n "$backup_dir" ]; then
                mv "$backup_dir" "$repo_dir" 2>/dev/null || true
            fi
            return 1
        fi
    fi

    if ! mv "$staging_repo" "$repo_dir"; then
        rm -rf "$staging_parent"
        if [ -n "$backup_dir" ]; then
            mv "$backup_dir" "$repo_dir" 2>/dev/null || true
        fi
        return 1
    fi
    rm -rf "$staging_parent"
    return 0
}

# native_environment: what neodesk.sh --auto takes from this installer:
# the relay, the admin password, the release channel (--channel: dev
# updates from the dev pre-release, stable from the newest release; else
# neodesk.sh's own choice) and a release folder given
native_environment() {
    export RELAY_MODE RELAY_SERVERS="$1"
    if [ -n "$ADMIN_PASSWORD" ]; then
        export ADMIN_PASSWORD
    fi
    case "$RELEASE_CHANNEL" in
        stable|main) export UPDATE_GITHUB_BRANCH=main ;;
        dev|development) export UPDATE_GITHUB_BRANCH=dev ;;
    esac
    [ -z "${UPDATE_GITHUB_BRANCH:-}" ] || log "Update channel: ${UPDATE_GITHUB_BRANCH}"
    [ -z "${RELEASE_BASE_URL:-}" ] || export RELEASE_BASE_URL
}

# install_native_mode: neodesk.sh of the release (fetch_manager) installs
# NeoDesk with --auto and leaves itself as neodesk-setup. With --branch the
# branch is cloned into INSTALL_DIR/source and its neodesk.sh runs there.
install_native_mode() {
    if [ -n "$NEODESK_BRANCH" ]; then
        install_native_from_branch
        return
    fi
    local relay work
    local args=(--auto)
    relay=$(resolve_relay_address)
    args+=(--relay-servers "$relay")
    [ "$SKIP_VERIFY" != true ] || args+=(--skip-verify)
    work=$(mktemp -d)
    fetch_manager neodesk.sh "$work/neodesk.sh"
    grep -q '^NEODESK_SH_REVISION=' "$work/neodesk.sh" || { rm -rf "$work"; die "The downloaded neodesk.sh is not NeoDesk's installer"; }
    native_environment "$relay"
    log "Running neodesk.sh --auto..."
    local rc=0
    bash "$work/neodesk.sh" "${args[@]}" || rc=$?
    rm -rf "$work"
    [ "$rc" = 0 ] || die "neodesk.sh --auto failed (exit $rc); its output is above"
    ok "Native installation finished. Manage it with: sudo neodesk-setup"
}

install_native_from_branch() {
    local repo_dir="${INSTALL_DIR}/source"
    local relay
    local commit_sha
    local source_backup=""
    local checkout_error=""

    log "Native install branch: ${NEODESK_BRANCH}"

    require_command git
    relay=$(resolve_relay_address)

    if [ -d "$repo_dir/.git" ]; then
        log "Updating existing clone in ${repo_dir} to ${NEODESK_BRANCH}..."
        git -C "$repo_dir" remote set-url origin "https://github.com/${NEODESK_REPO}.git" || true
        git -C "$repo_dir" fetch --depth 1 origin "$NEODESK_BRANCH"
        # Shallow clones previously pinned to another branch need a branch switch.
        checkout_error=$(mktemp)
        if git -C "$repo_dir" checkout -B "$NEODESK_BRANCH" "FETCH_HEAD" 2>"$checkout_error"; then
            rm -f "$checkout_error"
        else
            warn "Could not switch existing clone to ${NEODESK_BRANCH}."
            if [ -n "$(git -C "$repo_dir" status --short 2>/dev/null || true)" ]; then
                warn "The existing clone contains local changes; preserving it before recloning."
                cat "$checkout_error" >&2 || true
            else
                warn "Git checkout failed; preserving the existing clone before recloning."
                cat "$checkout_error" >&2 || true
            fi
            rm -f "$checkout_error"
            if ! source_backup=$(native_backup_source "$repo_dir"); then
                die "Cannot preserve ${repo_dir}; refusing to remove the existing native source"
            fi
            if ! native_clone_source "$repo_dir" "$source_backup"; then
                die "Could not clone ${NEODESK_REPO}@${NEODESK_BRANCH}; original source preserved at ${source_backup}"
            fi
            warn "Previous native source preserved at ${source_backup}"
        fi
    else
        log "Cloning ${NEODESK_REPO} (${NEODESK_BRANCH})..."
        if [ -e "$repo_dir" ]; then
            if ! source_backup=$(native_backup_source "$repo_dir"); then
                die "Cannot preserve ${repo_dir}; refusing to remove the existing native source"
            fi
            warn "Existing non-Git source preserved at ${source_backup}"
        fi
        if ! native_clone_source "$repo_dir" "$source_backup"; then
            die "Could not clone ${NEODESK_REPO}@${NEODESK_BRANCH}; original source preserved at ${source_backup:-none}"
        fi
        if [ -n "$source_backup" ]; then
            warn "Previous native source preserved at ${source_backup}"
        fi
    fi

    commit_sha=$(git -C "$repo_dir" rev-parse --short HEAD 2>/dev/null || echo "unknown")
    log "Using ${NEODESK_REPO}@${NEODESK_BRANCH} (${commit_sha})"

    local native_installer
    native_installer=$(native_installer_in "$repo_dir")
    chmod +x "$native_installer"

    log "Running neodesk.sh --auto..."
    native_environment "$relay"
    local args=(--auto --relay-servers "$relay")
    [ "$SKIP_VERIFY" != true ] || args+=(--skip-verify)
    (cd "$repo_dir" && "$native_installer" "${args[@]}")

    ok "Native installation finished. See ${repo_dir} for logs and credentials."
}

# native_installer_in DIR: neodesk.sh of the checkout DIR, in its install/
# folder since 3.6.0-rc.5, at its root before
native_installer_in() {
    if [ -f "$1/install/neodesk.sh" ]; then
        printf '%s\n' "$1/install/neodesk.sh"
    else
        printf '%s\n' "$1/neodesk.sh"
    fi
}

# native_manager: the manager of the native install: neodesk-setup, the
# old manager /usr/local/sbin/neodesk of 3.6.0-rc.4 and older, else
# neodesk.sh of the checkout an older install.sh cloned
native_manager() {
    if [ -x /usr/local/sbin/neodesk-setup ]; then
        printf '%s\n' /usr/local/sbin/neodesk-setup
    elif [ -x /usr/local/sbin/neodesk ] && grep -q '^NEODESK_SH_REVISION=' /usr/local/sbin/neodesk 2>/dev/null; then
        printf '%s\n' /usr/local/sbin/neodesk
    else
        native_installer_in "${INSTALL_DIR}/source"
    fi
}

uninstall_native_mode() {
    local repo_dir="${INSTALL_DIR}/source"
    local native_installer
    native_installer=$(native_manager)

    require_root
    if [ ! -x "$native_installer" ]; then
        die "Native installer not found at ${native_installer}; nothing was removed"
    fi

    log "Running native uninstall (data is preserved unless --purge is supplied)..."
    local args=(--auto --uninstall)
    if [ "$DO_PURGE" = true ]; then
        args+=(--purge)
    fi
    if [ -d "$repo_dir" ]; then
        (cd "$repo_dir" && "$native_installer" "${args[@]}")
    else
        "$native_installer" "${args[@]}"
    fi
}

rescue_native_mode() {
    local repo_dir="${INSTALL_DIR}/source"
    local native_installer
    native_installer=$(native_manager)

    if [ "$RESCUE_ACTION" = "repair-permissions" ] && [ -x "$native_installer" ]; then
        "$native_installer" --repair-permissions
        return $?
    fi
    warn "Native rescue is handled by neodesk.sh on the installed host."
    if [ -x "$native_installer" ]; then
        echo "Run the interactive native repair toolkit with:"
        echo "  sudo ${native_installer}"
        echo "Then choose: Repair Installation or Diagnostics."
        return 0
    fi

    die "Native checkout not found at ${repo_dir}. Re-run without --rescue to install, or use --docker for Docker rescue."
}

# ── Relay node ────────────────────────────────────────────────────────────────

# node_mode ACTION: neodesk.sh of the release (fetch_manager) installs,
# updates (ACTION install) or removes (uninstall) the relay node. It runs
# once and stays nowhere: a server install here keeps its neodesk-setup.
node_mode() {
    local work rc=0
    local args=(--node)
    if [ "$1" = uninstall ]; then
        args+=(--uninstall)
        [ "$DO_PURGE" != true ] || args+=(--purge)
    else
        [ -z "$NODE_JOIN" ] || args+=(--join "$NODE_JOIN")
        [ -z "$NODE_LAN_ADDR" ] || args+=(--lan-addr "$NODE_LAN_ADDR")
        [ -z "$NODE_PUBLIC_ADDR" ] || args+=(--public-addr "$NODE_PUBLIC_ADDR")
        [ "$SKIP_VERIFY" != true ] || args+=(--skip-verify)
        case "$RELEASE_CHANNEL" in
            stable|main) args+=(--channel stable) ;;
            dev|development) args+=(--channel dev) ;;
        esac
    fi
    work=$(mktemp -d)
    fetch_manager neodesk.sh "$work/neodesk.sh"
    grep -q '^NEODESK_SH_REVISION=' "$work/neodesk.sh" || { rm -rf "$work"; die "The downloaded neodesk.sh is not NeoDesk's installer"; }
    [ -z "${RELEASE_BASE_URL:-}" ] || export RELEASE_BASE_URL
    bash "$work/neodesk.sh" "${args[@]}" || rc=$?
    rm -rf "$work"
    [ "$rc" = 0 ] || die "neodesk.sh --node failed (exit $rc); its output is above"
}

run_native_management_action() {
    local native_installer
    native_installer=$(native_manager)
    [ -x "$native_installer" ] || die "Native NeoDesk manager not found at ${native_installer}"
    local args=()
    [ "$CHECK_CAPABILITIES" = true ] && args+=(--check-permissions)
    [ "${REPAIR_PERMISSIONS:-false}" = true ] && args+=(--repair-permissions)
    local change
    for change in "${MANAGED_CONFIG_CHANGES[@]}"; do
        args+=(--set-config "$change")
    done
    "$native_installer" "${args[@]}"
}

run_docker_management_action() {
    local manager="${INSTALL_DIR}/docker/neodesk-docker.sh"
    [ -x "$manager" ] || die "Docker NeoDesk manager not found at ${manager}"
    local args=(--dir "${INSTALL_DIR}/docker")
    [ "$CHECK_CAPABILITIES" = true ] && args+=(--check-permissions)
    [ "${REPAIR_PERMISSIONS:-false}" = true ] && args+=(--repair-permissions)
    local change
    for change in "${MANAGED_CONFIG_CHANGES[@]}"; do
        args+=(--set-config "$change")
    done
    "$manager" "${args[@]}"
}

# ── Main ──────────────────────────────────────────────────────────────────────

main() {
    print_header

    if [ "$DO_UNINSTALL" = true ]; then
        case "$INSTALL_MODE" in
            docker) uninstall_docker_mode ;;
            native) uninstall_native_mode ;;
            node) require_root; node_mode uninstall ;;
            *) die "Unknown install mode: $INSTALL_MODE" ;;
        esac
        exit 0
    fi

    require_root

    if [ "$INSTALL_MODE" = node ]; then
        if [ "$CHECK_CAPABILITIES" = true ] || [ "${#MANAGED_CONFIG_CHANGES[@]}" -gt 0 ] || [ "$DO_RESCUE" = true ]; then
            die "--node takes --join, --lan-addr, --public-addr, --uninstall and --purge only"
        fi
        node_mode install
        exit 0
    fi

    if [ "$CHECK_CAPABILITIES" = true ] || [ "${#MANAGED_CONFIG_CHANGES[@]}" -gt 0 ]; then
        case "$INSTALL_MODE" in
            docker) run_docker_management_action ;;
            native) run_native_management_action ;;
            *) die "Unknown install mode: $INSTALL_MODE" ;;
        esac
        exit $?
    fi

    if [ "$DO_RESCUE" = true ]; then
        case "$INSTALL_MODE" in
            docker) rescue_docker_mode ;;
            native) rescue_native_mode ;;
            *) die "Unknown install mode: $INSTALL_MODE" ;;
        esac
        exit 0
    fi

    case "$INSTALL_MODE" in
        docker) install_docker_mode ;;
        native) install_native_mode ;;
        *) die "Unknown install mode: $INSTALL_MODE" ;;
    esac
}

# BASH_SOURCE[0] is unset when this script is piped into `bash` (the
# documented `curl ... | sudo bash` path), so default it to $0 under nounset.
if [[ "${BASH_SOURCE[0]:-$0}" == "$0" ]]; then
    main "$@"
fi
