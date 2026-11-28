#!/bin/bash
#===============================================================================
#
#   NeoDesk Console Manager v3.6.7 (Docker)
#
#   Installs, updates and removes NeoDesk on Docker: one container that
#   runs the published image ghcr.io/neodeskapp/neodesk (signal,
#   relay, API and the web console), with docker-compose.yml and .env in
#   one folder (/opt/neodesk/docker).
#
#   sudo bash neodesk-docker.sh            install, or update an install
#   sudo bash neodesk-docker.sh --help     every command and option
#
#===============================================================================

if [ -z "${BASH_VERSION:-}" ]; then
    echo "Run this script with bash: sudo bash $0" >&2
    exit 1
fi

set -Eeuo pipefail

VERSION="3.6.7"
# Where people ask for help: the NeoDesk Discord
NEODESK_HELP_URL="https://discord.gg/nwERSawufr"
# The console's host port when .env names none: 3375 since 3.6.0-rc.5
# (DECISIONS A250), 5000 before
CONSOLE_DEFAULT_PORT=3375
CONSOLE_OLD_DEFAULT_PORT=5000
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || pwd)"

# Settings: flags win over these variables, which win over the defaults
NEODESK_DIR="${NEODESK_DIR:-/opt/neodesk/docker}"
# The image the compose file runs (a mirror goes into docker-compose.override.yml)
NEODESK_IMAGE="ghcr.io/neodeskapp/neodesk"
NEODESK_IMAGE_TAG_SET="${NEODESK_IMAGE_TAG:-}"
# The repository whose releases the compose file and this manager come
# from. RELEASE_BASE_URL names a release folder instead; NEODESK_BRANCH or
# NEODESK_RAW_BASE take a branch's files (for development).
NEODESK_REPO="${NEODESK_REPO:-neodeskapp/neodesk}"
NEODESK_RAW_BASE="${NEODESK_RAW_BASE:-${NEODESK_BRANCH:+https://raw.githubusercontent.com/${NEODESK_REPO}/${NEODESK_BRANCH}/install}}"
RELAY_SERVERS_SET="${RELAY_SERVERS:-}"
RELAY_MODE="${RELAY_MODE:-auto}"
CONSOLE_PORT_SET="${NEODESK_CONSOLE_PORT:-}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-}"
USE_POSTGRES="${NEODESK_POSTGRES:-false}"
# HTTPS with Let's Encrypt: Traefik in front of the console (the compose
# file's profile "traefik"). A domain given turns it on, --no-traefik off.
DOMAIN_SET="${NEODESK_DOMAIN:-}"
LETSENCRYPT_EMAIL_SET="${LETSENCRYPT_EMAIL:-}"
LETSENCRYPT_STAGING="${LETSENCRYPT_STAGING:-false}"
TRAEFIK_ACTION=""
LETSENCRYPT_STAGING_CA="https://acme-staging-v02.api.letsencrypt.org/directory"
CERT_TIMEOUT="${NEODESK_CERT_TIMEOUT:-120}"
# IPv6 on the containers' network of a new install (NEODESK_IPV6): true or
# false given here; without it on when Docker Engine is 27 or newer
IPV6_SET="${NEODESK_IPV6:-}"

# The folder of a RustDesk server's key pair (id_ed25519, id_ed25519.pub)
# to take over
IMPORT_KEYS=""
# ufw or firewalld stay as they are (NEODESK_SKIP_FIREWALL=true)
SKIP_FIREWALL="${NEODESK_SKIP_FIREWALL:-false}"
NEODESK_DEFAULT_DIR=/opt/neodesk/docker

COMMAND=""
ASSUME_YES=false
PURGE=false
NO_PULL=false
BUILD_LOCAL=false
INSTALL_DOCKER=true
ADOPT=false
RESET_USER="admin"
RESET_TWO_FACTOR=false
MOVE_DATA=""
OVERWRITE_POSTGRES=false
MANAGED_CONFIG_CHANGES=()

CONTAINER="neodesk"
PG_CONTAINER="neodesk-postgres"
TRAEFIK_CONTAINER="neodesk-traefik"
DATA_VOLUME="neodesk-data"
CONSOLE_VOLUME="neodesk-console-data"
PG_VOLUME="neodesk-postgres-data"
TRAEFIK_VOLUME="neodesk-traefik-letsencrypt"
OLD_CONTAINERS=(neodesk neodesk-server neodesk-console)
HEALTH_TIMEOUT="${NEODESK_HEALTH_TIMEOUT:-180}"
KEEP_BACKUPS=5
# 21114: the API for RustDesk clients without an API server setting,
# which derive it from the ID server's port (21116 - 2)
DOCKER_PORTS_TCP=(21114 21115 21116 21117 21118 21119 21121 21122 21123)
DOCKER_PORTS_UDP=(21116)

# Colours: 24-bit where the terminal says it has them (COLORTERM), else the
# 16 basic ones; none when the output is not a terminal, NO_COLOR is set or
# TERM is dumb (COLOR_DEPTH 24bit, 16 or empty). In 24-bit, RED, GREEN,
# YELLOW and CYAN keep at least 3.8:1 on black, on PowerShell's blue and on
# white.
COLOR_DEPTH=""
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-}" != dumb ]; then
    case "${COLORTERM:-}" in
        truecolor|24bit) COLOR_DEPTH=24bit ;;
        *) COLOR_DEPTH=16 ;;
    esac
fi
case "$COLOR_DEPTH" in
    24bit)
        RED=$'\033[38;2;228;75;69m' GREEN=$'\033[38;2;37;149;46m' YELLOW=$'\033[38;2;178;116;9m'
        CYAN=$'\033[38;2;26;143;147m' BOLD=$'\033[1m' NC=$'\033[0m'
        ;;
    16)
        RED=$'\033[0;31m' GREEN=$'\033[0;32m' YELLOW=$'\033[0;33m' CYAN=$'\033[0;36m' BOLD=$'\033[1m' NC=$'\033[0m'
        ;;
    *)
        RED="" GREEN="" YELLOW="" CYAN="" BOLD="" NC=""
        ;;
esac

say() { printf '%s\n' "$*"; }
step() { printf '%s==>%s %s\n' "$CYAN" "$NC" "$*"; }
ok() { printf '%sOK%s  %s\n' "$GREEN" "$NC" "$*"; }
warn() { printf '%sWARNING:%s %s\n' "$YELLOW" "$NC" "$*" >&2; }
# die MESSAGE [WHAT TO DO...]: the error and, one line each, what to do
die() {
    printf '%sERROR:%s %s\n' "$RED" "$NC" "$1" >&2
    shift
    local line
    for line in "$@"; do printf '       %s\n' "$line" >&2; done
    exit 1
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

# print_header: the NeoDesk logo with what this script is
# and its version; one plain line without colour (no terminal, NO_COLOR).
# install.sh shows its own before it runs this script
# (NEODESK_HEADER_SHOWN=1), and this one stays out then.
print_header() {
    local title="Docker installer ${VERSION}"
    [ "${NEODESK_HEADER_SHOWN:-}" != 1 ] || return 0
    if [ -z "$COLOR_DEPTH" ]; then
        say "NeoDesk $title"
        return 0
    fi
    say ""
    draw_logo "$title"
    say ""
}

usage() {
    cat <<EOF
NeoDesk on Docker, manager v${VERSION}

Usage: sudo bash neodesk-docker.sh [command] [options]

Commands:
  install          Install NeoDesk, or update the install (the default)
  update           Update the install: back up the data, pull the image,
                   start it, and go back to the old image when the new
                   container does not get healthy
  status           Containers, health, version and the addresses for clients
  logs             Follow the container's log
  backup           Back up the data volumes into <folder>/backups
  reset-password   Give an account a new random password (printed once)
  postgres         Move the install from SQLite to PostgreSQL
  uninstall        Stop and remove the containers; volumes, images and the
                   folder stay unless --purge
  menu             The same commands as a menu

Options:
  --dir PATH             Install folder (NEODESK_DIR, /opt/neodesk/docker)
  --tag TAG              Image tag (NEODESK_IMAGE_TAG); latest, the default,
                         is the newest release, a version such as 3.5.270
                         pins one
  --relay ADDRESS        The address clients reach this server at, public IP
                         or DNS name (RELAY_SERVERS); found by itself when empty
  --relay-mode MODE      How to find it: auto, public or local (RELAY_MODE)
  --console-port PORT    Host port of the web console (NEODESK_CONSOLE_PORT,
                         3375; 5000 up to 3.6.0-rc.4)
  --postgres             A new install on PostgreSQL instead of SQLite
                         (NEODESK_POSTGRES=true)
  --import-keys FOLDER   The key pair of a RustDesk server (id_ed25519 and
                         id_ed25519.pub in FOLDER) instead of a new one, so
                         its clients keep working; the install's own key is
                         kept in the data volume as id_ed25519.before-import-*
  --skip-firewall        Leave ufw and firewalld as they are; without it the
                         client ports (and the console's) are opened there
                         when one of them is on, and closed at uninstall
                         (NEODESK_SKIP_FIREWALL=true)
  --domain NAME          HTTPS for the console at this DNS name (NEODESK_DOMAIN):
                         a Traefik container gets a Let's Encrypt certificate
                         and renews it by itself. The name must point at this
                         server, and ports 80 and 443 must reach it.
  --email ADDRESS        Optional: the contact address of the Let's Encrypt
                         account (LETSENCRYPT_EMAIL). Let's Encrypt sends no
                         expiry mails any more, Traefik renews by itself
  --letsencrypt-staging  Certificates from Let's Encrypt's staging server
                         (not trusted by browsers; for tests). A later run
                         without it gets a trusted certificate
  --no-traefik           Remove Traefik again; the console answers on its
                         own port as before
  --no-ipv6              A new install without IPv6 on the containers'
                         network (NEODESK_IPV6=false). Without it a new
                         install on Docker Engine 27 or newer gets IPv6, so
                         the console sees IPv6 visitors' own addresses, and
                         Docker publishes the ports on IPv6 past ufw and
                         firewalld as it does on IPv4. An install keeps the
                         setting in .env
  --no-move              postgres: do not move the data; the install stays on
                         SQLite and nothing changes
  --overwrite-postgres   postgres: delete the PostgreSQL volume of an earlier
                         try before the move
  --user NAME            reset-password: the account (admin)
  --reset-two-factor     reset-password: also turn off the account's two-factor
                         sign-in (lost phone and recovery codes); where it is
                         required, the account sets it up again at its next
                         sign-in
  --purge                uninstall: also delete the volumes (all data)
  --yes                  Answer yes to every question
  --adopt                Take over a NeoDesk container of another install
                         (an older manager, a split install, another folder):
                         its data is copied into this install's volumes and
                         the old container is kept, stopped and renamed
  --no-pull              Use the image that is on this machine (air-gapped,
                         docker load)
  --build                Build the image from this checkout instead of pulling
  --no-install-docker    Stop with an error when Docker is missing instead of
                         installing it
  --help                 This text

  ADMIN_PASSWORD=...     The admin's password at the first start; without it
                         the container makes a random one, printed once at
                         the end of the install

Repair and checks:
  --rescue               Repair volume permissions, start the container, check
  --diagnose             Read-only diagnostics
  --repair-permissions   Repair the volumes' owner (PUID/PGID, 10001)
  --check-permissions    Check that Docker, Compose and the folder are usable
  --set-config KEY=VALUE An allowed server setting into .env, then restart
                         (repeatable)

Files: <folder>/docker-compose.yml (replaced on update; put your own changes
into docker-compose.override.yml next to it), <folder>/.env (the settings,
every KEY=value reaches the server), <folder>/backups.
The compose file and this script come from the release the image tag names
(the newest for latest), checked against the release's SHA256SUMS; an
update replaces <folder>/neodesk-docker.sh with the release's.
RELEASE_BASE_URL names another release folder.
HTTPS for the console: --domain and --email (Traefik with Let's Encrypt), a
reverse proxy of your own with TLS in front (TRUST_PROXY=1 in .env), or
HTTPS_ENABLED=true with SSL_CERT_PATH and SSL_KEY_PATH naming
files in the data volume (/opt/neodesk/data/...); the console then answers on
port 5443.
Logs: cd <folder> && docker compose logs -f neodesk
EOF
}

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            install|update|status|logs|backup|reset-password|postgres|uninstall|menu)
                [ -z "$COMMAND" ] || die "Two commands given: $COMMAND and $1" "Run one at a time."
                COMMAND="$1" ;;
            --dir) [ $# -ge 2 ] || die "--dir needs a folder"; NEODESK_DIR="$2"; shift ;;
            --dir=*) NEODESK_DIR="${1#*=}" ;;
            --tag) [ $# -ge 2 ] || die "--tag needs a tag"; NEODESK_IMAGE_TAG_SET="$2"; shift ;;
            --tag=*) NEODESK_IMAGE_TAG_SET="${1#*=}" ;;
            --relay) [ $# -ge 2 ] || die "--relay needs an address"; RELAY_SERVERS_SET="$2"; shift ;;
            --relay=*) RELAY_SERVERS_SET="${1#*=}" ;;
            --relay-mode) [ $# -ge 2 ] || die "--relay-mode needs auto, public or local"; RELAY_MODE="$2"; shift ;;
            --relay-mode=*) RELAY_MODE="${1#*=}" ;;
            --console-port) [ $# -ge 2 ] || die "--console-port needs a port"; CONSOLE_PORT_SET="$2"; shift ;;
            --console-port=*) CONSOLE_PORT_SET="${1#*=}" ;;
            --user) [ $# -ge 2 ] || die "--user needs an account name"; RESET_USER="$2"; shift ;;
            --user=*) RESET_USER="${1#*=}" ;;
            --reset-two-factor) RESET_TWO_FACTOR=true ;;
            --postgres) USE_POSTGRES=true ;;
            --import-keys) [ $# -ge 2 ] || die "--import-keys needs a folder"; IMPORT_KEYS="$2"; shift ;;
            --import-keys=*) IMPORT_KEYS="${1#*=}" ;;
            --skip-firewall) SKIP_FIREWALL=true ;;
            --domain) [ $# -ge 2 ] || die "--domain needs a DNS name"; DOMAIN_SET="$2"; shift ;;
            --domain=*) DOMAIN_SET="${1#*=}" ;;
            --email) [ $# -ge 2 ] || die "--email needs an e-mail address"; LETSENCRYPT_EMAIL_SET="$2"; shift ;;
            --email=*) LETSENCRYPT_EMAIL_SET="${1#*=}" ;;
            --letsencrypt-staging) LETSENCRYPT_STAGING=true ;;
            --no-traefik) TRAEFIK_ACTION=off ;;
            --no-ipv6) IPV6_SET=false ;;
            --no-move) MOVE_DATA=no ;;
            --overwrite-postgres) OVERWRITE_POSTGRES=true ;;
            --purge) PURGE=true ;;
            --yes|-y) ASSUME_YES=true ;;
            --adopt) ADOPT=true ;;
            --no-pull) NO_PULL=true ;;
            --build) BUILD_LOCAL=true ;;
            --no-install-docker|--skip-docker-install) INSTALL_DOCKER=false ;;
            --rescue) COMMAND="rescue" ;;
            --diagnose|--diagnostics) COMMAND="diagnose" ;;
            --repair-permissions) COMMAND="repair-permissions" ;;
            --check-permissions|--check-capabilities) COMMAND="check" ;;
            --set-config)
                if [ $# -lt 2 ] || [[ "$2" != *=* ]]; then die "--set-config needs KEY=VALUE"; fi
                MANAGED_CONFIG_CHANGES+=("$2"); COMMAND="${COMMAND:-set-config}"; shift ;;
            -h|--help) usage; exit 0 ;;
            *) die "Unknown option: $1" "See: $(manager_cmd) --help" ;;
        esac
        shift
    done
    COMMAND="${COMMAND:-install}"
    case "$RELAY_MODE" in
        auto|public|wan|local|lan) ;;
        *) die "--relay-mode must be auto, public or local, not $RELAY_MODE" ;;
    esac
    if [ -n "$CONSOLE_PORT_SET" ] && ! [[ "$CONSOLE_PORT_SET" =~ ^[0-9]+$ && "$CONSOLE_PORT_SET" -ge 1 && "$CONSOLE_PORT_SET" -le 65535 ]]; then
        die "--console-port must be a port number, not $CONSOLE_PORT_SET"
    fi
    case "${USE_POSTGRES,,}" in
        1|y|yes|true|on) USE_POSTGRES=true ;;
        *) USE_POSTGRES=false ;;
    esac
    case "${SKIP_FIREWALL,,}" in
        1|y|yes|true|on) SKIP_FIREWALL=true ;;
        *) SKIP_FIREWALL=false ;;
    esac
    [ -z "$IMPORT_KEYS" ] || check_import_keys
    case "${LETSENCRYPT_STAGING,,}" in
        1|y|yes|true|on) LETSENCRYPT_STAGING=true ;;
        *) LETSENCRYPT_STAGING=false ;;
    esac
    case "${IPV6_SET,,}" in
        "") ;;
        1|y|yes|true|on) IPV6_SET=true ;;
        *) IPV6_SET=false ;;
    esac
    DOMAIN_SET="${DOMAIN_SET,,}"
    if [ -n "$DOMAIN_SET" ]; then
        [ "$TRAEFIK_ACTION" != off ] || die "--domain and --no-traefik contradict each other" "Give one of them."
        valid_domain "$DOMAIN_SET" || die "--domain must be a DNS name such as console.example.com, not $DOMAIN_SET" \
            "Let's Encrypt gives no certificate for an IP address or a name without a dot."
        TRAEFIK_ACTION=on
    fi
    if [ -n "$LETSENCRYPT_EMAIL_SET" ] && ! valid_email "$LETSENCRYPT_EMAIL_SET"; then
        die "--email must be an e-mail address, not $LETSENCRYPT_EMAIL_SET"
    fi
    if [ -n "$LETSENCRYPT_EMAIL_SET" ] && ! acme_email_allowed "$LETSENCRYPT_EMAIL_SET"; then
        die "Let's Encrypt refuses addresses at ${LETSENCRYPT_EMAIL_SET#*@}, so no certificate would come." \
            "Give your own address, or leave --email out: it is optional."
    fi
}

# valid_domain NAME: a DNS name with at least one dot, no IP address
valid_domain() {
    [[ "$1" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]([a-z0-9-]{0,61}[a-z0-9])?$ ]] && [ "${#1}" -le 253 ]
}

valid_email() { [[ "$1" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]]; }

# acme_email_allowed ADDRESS: not an address at a domain Let's Encrypt
# refuses as a contact: the example domains and the reserved names
acme_email_allowed() {
    local domain="${1##*@}"
    domain="${domain,,}"
    case ".$domain" in
        *.example.com|*.example.net|*.example.org|*.example|*.invalid|*.test|*.localhost|*.local) return 1 ;;
    esac
    return 0
}

# manager_cmd: how to run this manager from any folder: the install's own
# copy by its full path (with --dir for another folder than the default),
# else this script's own path
manager_cmd() {
    local path="$NEODESK_DIR/neodesk-docker.sh" dir=""
    if [ ! -f "$path" ]; then
        path=$(readlink -f "${BASH_SOURCE[0]:-}" 2>/dev/null || true)
        [ -n "$path" ] && [ -f "$path" ] || path=neodesk-docker.sh
    fi
    [ "$NEODESK_DIR" = "$NEODESK_DEFAULT_DIR" ] || dir=" --dir $NEODESK_DIR"
    printf 'sudo bash %s%s\n' "$path" "$dir"
}

# check_import_keys: IMPORT_KEYS is a folder with a RustDesk key pair
# whose halves belong together (the server does not start otherwise);
# IMPORT_KEYS becomes its full path
check_import_keys() {
    local dir="$IMPORT_KEYS" priv pub
    [ -d "$dir" ] || die "--import-keys: $dir is not a folder" \
        "Name the folder that holds the RustDesk server's id_ed25519 and id_ed25519.pub."
    priv="$dir/id_ed25519"
    pub="$dir/id_ed25519.pub"
    [ -r "$priv" ] && [ -r "$pub" ] || die "--import-keys: $dir has no readable id_ed25519 and id_ed25519.pub" \
        "RustDesk's server keeps them in its data folder (with Docker: the folder mounted at /root)."
    if [ "$(base64 -d < "$priv" 2>/dev/null | wc -c)" != 64 ] || [ "$(base64 -d < "$pub" 2>/dev/null | wc -c)" != 32 ]; then
        die "--import-keys: the files in $dir are no RustDesk key pair (base64, 64 and 32 bytes)."
    fi
    # An Ed25519 private key ends with its public key
    if [ "$(base64 -d < "$priv" | tail -c 32 | od -An -tx1 | tr -d ' \n')" != "$(base64 -d < "$pub" | od -An -tx1 | tr -d ' \n')" ]; then
        die "--import-keys: id_ed25519.pub in $dir does not belong to id_ed25519 there."
    fi
    IMPORT_KEYS=$(cd "$dir" && pwd -P)
}

# confirm QUESTION DEFAULT(y|n): yes or no; --yes says yes, and without a
# terminal the default is taken
confirm() {
    local answer hint="[y/N]"
    [ "$2" = y ] && hint="[Y/n]"
    if [ "$ASSUME_YES" = true ]; then return 0; fi
    if [ ! -t 0 ]; then [ "$2" = y ]; return; fi
    read -r -p "$1 $hint " answer || answer=""
    answer="${answer:-$2}"
    [[ "$answer" =~ ^[YyJj] ]]
}

#===============================================================================
# The install folder: docker-compose.yml and .env
#===============================================================================

compose_file() { printf '%s\n' "$NEODESK_DIR/docker-compose.yml"; }
env_file() { printf '%s\n' "$NEODESK_DIR/.env"; }

# compose ARGS...: docker compose in the install folder (its .env and
# docker-compose.override.yml included)
compose() {
    (cd "$NEODESK_DIR" && docker compose "$@")
}

# compose_quiet ARGS...: docker compose without its progress lines; they
# are shown when it fails
compose_quiet() {
    local out
    if ! out=$(compose "$@" 2>&1); then
        printf '%s\n' "$out" >&2
        return 1
    fi
}

# settings_fingerprint: a hash of what the container is made from: the
# compose files and .env
settings_fingerprint() {
    local f files=()
    for f in "$(compose_file)" "$NEODESK_DIR/docker-compose.override.yml" "$(env_file)"; do
        [ ! -f "$f" ] || files+=("$f")
    done
    cat "${files[@]}" | sha256sum | cut -d' ' -f1
}

# remember_applied: the settings the running container was made from
remember_applied() { settings_fingerprint > "$NEODESK_DIR/.applied.sha256"; }

# env_get KEY: the value of KEY in .env, empty when it has none
env_get() {
    local file
    file=$(env_file)
    [ -f "$file" ] || return 0
    grep -E "^${1}=" "$file" 2>/dev/null | tail -n 1 | cut -d= -f2- | tr -d '\r' || true
}

# env_set KEY VALUE: one line KEY=VALUE in .env, other lines as they are
env_set() {
    local file tmp
    file=$(env_file)
    tmp="${file}.tmp.$$"
    (
        umask 077
        if [ -f "$file" ]; then
            grep -vE "^${1}=" "$file" > "$tmp" || true
        else
            printf '# NeoDesk settings: one KEY=value per line; every key reaches the server.\n' > "$tmp"
        fi
        printf '%s=%s\n' "$1" "$2" >> "$tmp"
    )
    chmod 600 "$tmp"
    mv "$tmp" "$file"
}

env_unset() {
    local file tmp
    file=$(env_file)
    [ -f "$file" ] || return 0
    tmp="${file}.tmp.$$"
    (umask 077; grep -vE "^${1}=" "$file" > "$tmp" || true)
    chmod 600 "$tmp"
    mv "$tmp" "$file"
}

# profile_on NAME, profile_off NAME: an optional service of the compose
# file (postgres, guacd) on or off in COMPOSE_PROFILES, the others kept
profile_on() {
    local list
    list=$(env_get COMPOSE_PROFILES)
    case ",$list," in
        *",$1,"*) return 0 ;;
    esac
    env_set COMPOSE_PROFILES "${list:+$list,}$1"
}

profile_off() {
    local list
    list=$(env_get COMPOSE_PROFILES | tr ',' '\n' | grep -vx "$1" | paste -sd, - || true)
    if [ -n "$list" ]; then env_set COMPOSE_PROFILES "$list"; else env_unset COMPOSE_PROFILES; fi
}

image_tag() {
    local tag
    tag="${NEODESK_IMAGE_TAG_SET:-$(env_get NEODESK_IMAGE_TAG)}"
    printf '%s\n' "${tag:-latest}"
}

image_ref() { printf '%s:%s\n' "$NEODESK_IMAGE" "$(image_tag)"; }

console_port() {
    local port
    port="${CONSOLE_PORT_SET:-$(env_get NEODESK_CONSOLE_PORT)}"
    printf '%s\n' "${port:-$CONSOLE_DEFAULT_PORT}"
}

# The host port of the console's HTTPS, which the compose file publishes
# whether HTTPS is on or not
console_https_port() {
    local port
    port="$(env_get NEODESK_CONSOLE_HTTPS_PORT)"
    printf '%s\n' "${port:-5443}"
}

on_postgres() {
    case "$(env_get DATABASE_URL)" in
        postgres://*|postgresql://*) return 0 ;;
    esac
    return 1
}

# traefik_on: the install runs Traefik in front of the console: it is
# being turned on now, or .env has the profile and it is not being turned off
traefik_on() {
    case "$TRAEFIK_ACTION" in
        on) return 0 ;;
        off) return 1 ;;
    esac
    case ",$(env_get COMPOSE_PROFILES)," in
        *,traefik,*) return 0 ;;
    esac
    return 1
}

# console_domain: the console's DNS name under Traefik, empty without
console_domain() {
    traefik_on || return 0
    printf '%s\n' "${DOMAIN_SET:-$(env_get NEODESK_DOMAIN)}"
}

# console_firewall_ports DOMAIN: the console's TCP ports a firewall in
# front of this machine needs, each followed by ", ", by the rule of the
# installers: Traefik's 80 and 443 with a domain; none while a reverse
# proxy is in front (TRUST_PROXY on, or the console published on loopback
# only); else the console's port, and its HTTPS port with HTTPS_ENABLED on
console_firewall_ports() {
    if [ -n "$1" ]; then
        printf '80, 443, '
        return 0
    fi
    case "$(env_get NEODESK_CONSOLE_BIND)" in
        127.*|::1|"[::1]"|localhost) return 0 ;;
    esac
    case "$(env_get TRUST_PROXY | tr '[:upper:]' '[:lower:]')" in
        ""|n|no|0|false|off) ;;
        *) return 0 ;;
    esac
    printf '%s, ' "$(console_port)"
    case "$(env_get HTTPS_ENABLED | tr '[:upper:]' '[:lower:]')" in
        1|y|yes|true|on) printf '%s, ' "$(console_https_port)" ;;
    esac
}

sha_of() { sha256sum "$1" 2>/dev/null | cut -d' ' -f1; }

# newest_release_tag: the tag of the newest published release, a
# pre-release too, other than the rolling "dev" one; GitHub lists the
# releases newest first, each with tag_name before draft
newest_release_tag() {
    local tag
    tag=$(curl -fsSL --connect-timeout 15 --max-time 30 -H 'Accept: application/vnd.github+json' \
        "https://api.github.com/repos/${NEODESK_REPO}/releases?per_page=20" 2>/dev/null \
        | tr -d '\r\n' \
        | grep -oE '"(tag_name|draft)"[[:space:]]*:[[:space:]]*("[^"]*"|true|false)' \
        | sed -E 's/^"([a-z_]+)"[[:space:]]*:[[:space:]]*"?([^"]*)"?$/\1 \2/' \
        | awk '$1 == "tag_name" { tag = $2 } $1 == "draft" && $2 == "false" && tag != "dev" && tag ~ /^v[0-9][A-Za-z0-9._-]*$/ { print tag; exit }') || true
    [ -n "$tag" ] || return 1
    printf '%s\n' "$tag"
}

# release_tag: the release of the image tag: the newest release for
# latest, the rolling "dev" one for dev, v<version> for a version; fails
# for a tag no release has (local, a tag of one's own)
release_tag() {
    local tag
    tag=$(image_tag)
    case "$tag" in
        latest) newest_release_tag ;;
        dev) printf 'dev\n' ;;
        v[0-9]*) printf '%s\n' "$tag" ;;
        [0-9]*.[0-9]*.[0-9]*) printf 'v%s\n' "$tag" ;;
        *) return 1 ;;
    esac
}

# release_base: the folder of the release whose files this manager takes
# (the compose file, its own copy): RELEASE_BASE_URL, else the release of
# the image tag (release_tag)
release_base() {
    if [ -n "${RELEASE_BASE_URL:-}" ]; then
        printf '%s\n' "${RELEASE_BASE_URL%/}"
        return 0
    fi
    local tag
    tag=$(release_tag) || return 1
    printf 'https://github.com/%s/releases/download/%s\n' "$NEODESK_REPO" "$tag"
}

# tag_has_root_layout TAG: the tag is of 3.6.0-rc.4 or older, whose
# installers and compose files are at the repository's root; later ones
# have them in install/
tag_has_root_layout() {
    case "${1#v}" in
        [0-2].*|3.[0-5].*|3.6.0-rc.[1-4]) return 0 ;;
    esac
    return 1
}

# fetch_from_release NAME DEST: the release's file NAME into DEST, checked
# against the release's SHA256SUMS. Returns 1 when the release has no
# such file or cannot be reached, 2 when the file does not match.
fetch_from_release() {
    local name="$1" dest="$2" base sums expected
    base=$(release_base) || return 1
    sums=$(mktemp) || return 1
    if ! curl -fsSL --connect-timeout 15 --max-time 60 -o "$sums" "$base/SHA256SUMS" 2>/dev/null; then
        rm -f "$sums"
        return 1
    fi
    expected=$(awk -v n="$name" '$2 == n || $2 == "*" n { print tolower($1); exit }' "$sums")
    rm -f "$sums"
    [ -n "$expected" ] || return 1
    curl -fsSL --connect-timeout 15 --max-time 120 -o "$dest" "$base/$name" 2>/dev/null || return 1
    if [ "$(sha_of "$dest")" != "$expected" ]; then
        rm -f "$dest"
        return 2
    fi
}

# fetch_compose_file DEST: the compose file of the release the image tag
# names: from this checkout when the script sits in one, else the
# release's own file, checked against its SHA256SUMS. A release from
# before the files were attached to releases (3.6.0-rc.4 and older) has
# it at its tag, at the repository's root. NEODESK_RAW_BASE takes a
# branch's file instead.
fetch_compose_file() {
    local src="$SCRIPT_DIR/docker-compose.quick.single.yml" name=docker-compose.quick.single.yml from rc=0 tag
    if [ -f "$src" ]; then
        cp "$src" "$1"
        return 0
    fi
    if [ -n "$NEODESK_RAW_BASE" ]; then
        from="$NEODESK_RAW_BASE/$name"
        curl -fsSL --connect-timeout 15 --max-time 60 -o "$1" "$from" \
            || die "Could not download the compose file from $from" \
                "Check the internet connection, or run the script from a checkout of the repository."
    else
        from=$(release_base) \
            || die "No release has the image tag $(image_tag), so there is no compose file for it." \
                "Run the script from a checkout of the repository, or give a release's tag (--tag)."
        fetch_from_release "$name" "$1" || rc=$?
        tag=$(release_tag 2>/dev/null || true)
        if [ "$rc" = 1 ] && [ -z "${RELEASE_BASE_URL:-}" ] && tag_has_root_layout "$tag"; then
            from="https://raw.githubusercontent.com/${NEODESK_REPO}/${tag}/$name"
            curl -fsSL --connect-timeout 15 --max-time 60 -o "$1" "$from" 2>/dev/null && rc=0
        fi
        case "$rc" in
            0) ;;
            2) die "The compose file of $from does not match the release's SHA256SUMS." "Try again later; nothing was changed." ;;
            *) die "Could not download the compose file of $from" \
                "Check the internet connection, or run the script from a checkout of the repository." ;;
        esac
    fi
    grep -q 'ghcr.io/neodeskapp/neodesk' "$1" || die "The downloaded compose file is not NeoDesk's ($from)"
}

# note_console_port_move MOVED: after the update of an install that ran on
# the old default port (MOVED true): the console moved, and how to keep the
# old port
note_console_port_move() {
    [ "$1" = true ] || return 0
    [ "$(console_port)" = "$CONSOLE_DEFAULT_PORT" ] || return 0
    say ""
    warn "The console now answers on port $CONSOLE_DEFAULT_PORT; it was $CONSOLE_OLD_DEFAULT_PORT. To keep $CONSOLE_OLD_DEFAULT_PORT set NEODESK_CONSOLE_PORT=$CONSOLE_OLD_DEFAULT_PORT in $(env_file), then: $(manager_cmd) update"
}

# update_manager_copy: run as the install's own copy
# ($NEODESK_DIR/neodesk-docker.sh), this manager becomes the one of the
# release the install moved to, checked against the release's SHA256SUMS.
# It stays as it is when that release has none (3.6.0-rc.4 and older), and
# when it takes a branch's files (NEODESK_RAW_BASE). The new copy replaces
# the file, so this run reads on from the old one.
update_manager_copy() {
    local dest="$NEODESK_DIR/neodesk-docker.sh" self new rc=0
    self=$(readlink -f "${BASH_SOURCE[0]:-$0}" 2>/dev/null || true)
    [ -n "$self" ] && [ "$self" = "$(readlink -f "$dest" 2>/dev/null || true)" ] || return 0
    [ -z "$NEODESK_RAW_BASE" ] || return 0
    new="$dest.new.$$"
    fetch_from_release neodesk-docker.sh "$new" || rc=$?
    case "$rc" in
        0)
            if grep -q 'NEODESK_DOCKER_SOURCED' "$new" && ! cmp -s "$new" "$dest"; then
                chmod 0755 "$new"
                mv -f "$new" "$dest"
                ok "neodesk-docker.sh is the release's now"
            else
                rm -f "$new"
            fi
            ;;
        2)
            rm -f "$new"
            warn "The release's neodesk-docker.sh does not match its SHA256SUMS, so $dest stays as it is"
            ;;
        *) rm -f "$new" ;;
    esac
    return 0
}

# place_manager_copy: an install made with a downloaded copy of this
# manager gets its own one in the install folder, which the hints name
place_manager_copy() {
    local dest="$NEODESK_DIR/neodesk-docker.sh" self
    [ ! -f "$dest" ] || return 0
    self=$(readlink -f "${BASH_SOURCE[0]:-}" 2>/dev/null || true)
    [ -n "$self" ] && [ -f "$self" ] && grep -q 'NEODESK_DOCKER_SOURCED' "$self" || return 0
    install -m 0755 "$self" "$dest" 2>/dev/null || true
}

# write_compose_file: docker-compose.yml of this release. A file the user
# changed since this script wrote it stays; the new one goes next to it.
write_compose_file() {
    local dest new record
    dest=$(compose_file)
    record="$NEODESK_DIR/.compose.sha256"
    new="$dest.new.$$"
    fetch_compose_file "$new"
    if [ -f "$dest" ]; then
        if [ -f "$record" ] && [ "$(sha_of "$dest")" != "$(cat "$record")" ]; then
            if cmp -s "$dest" "$new"; then
                rm -f "$new"
            else
                mv "$new" "$dest.new"
                warn "docker-compose.yml was changed by hand, so it stays. The release's file is $dest.new."
                warn "Keep your own changes in docker-compose.override.yml next to it; Docker Compose reads it as well."
            fi
            return 0
        fi
        if [ ! -f "$record" ] && ! cmp -s "$dest" "$new"; then
            cp -p "$dest" "$dest.bak-$(date +%Y%m%d-%H%M%S)"
            say "The previous docker-compose.yml is kept as $(basename "$dest").bak-*"
        fi
    fi
    mv "$new" "$dest"
    chmod 644 "$dest"
    sha_of "$dest" > "$record"
}

#===============================================================================
# Checks: sudo, Docker, Compose, ports, internet
#===============================================================================

need_root_or_docker() {
    if [ "$(id -u)" -eq 0 ]; then return 0; fi
    if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1 \
        && mkdir -p "$NEODESK_DIR" 2>/dev/null && [ -w "$NEODESK_DIR" ]; then
        return 0
    fi
    die "This needs root: run it with sudo." \
        "$(manager_cmd) ${COMMAND}" \
        "Without sudo it works when your user may use Docker (the docker group) and write $NEODESK_DIR (--dir)."
}

install_docker_engine() {
    if [ "$(id -u)" -ne 0 ]; then
        die "Docker is not installed, and installing it needs root." "Run: $(manager_cmd)"
    fi
    if ! command -v curl >/dev/null 2>&1; then
        die "Docker is not installed, and curl is missing to install it." \
            "Install curl (apt-get install -y curl), then run this again."
    fi
    step "Installing Docker with Docker's install script (get.docker.com)"
    local script
    script=$(mktemp)
    curl -fsSL --connect-timeout 15 --max-time 120 https://get.docker.com -o "$script" \
        || die "Could not download Docker's install script from get.docker.com." \
            "Check the internet connection, or install Docker yourself: https://docs.docker.com/engine/install/"
    sh "$script" >/dev/null || die "Docker's install script failed (see its output above)." \
        "Install Docker yourself: https://docs.docker.com/engine/install/"
    rm -f "$script"
    systemctl enable --now docker >/dev/null 2>&1 || true
    ok "Docker installed: $(docker --version 2>/dev/null)"
}

check_docker() {
    if ! command -v docker >/dev/null 2>&1; then
        if [ "$INSTALL_DOCKER" = true ]; then
            install_docker_engine
        else
            die "Docker is not installed." \
                "Install it: curl -fsSL https://get.docker.com | sudo sh" \
                "or run this script without --no-install-docker, which does that."
        fi
    fi
    if ! docker info >/dev/null 2>&1; then
        if [ "$(id -u)" -eq 0 ] && command -v systemctl >/dev/null 2>&1; then
            systemctl start docker >/dev/null 2>&1 || true
        fi
        if ! docker info >/dev/null 2>&1; then
            if docker info 2>&1 | grep -qi 'permission denied'; then
                die "Your user may not use Docker." "Run with sudo, or add your user to the docker group and sign in again."
            fi
            die "Docker is installed but its daemon is not running." \
                "Start it: sudo systemctl start docker" "Its log: sudo journalctl -u docker --no-pager | tail -n 50"
        fi
    fi
    if ! docker compose version >/dev/null 2>&1; then
        if command -v docker-compose >/dev/null 2>&1; then
            die "Only the old docker-compose (v1) is installed; this needs Docker Compose v2 (docker compose)." \
                "Ubuntu: sudo apt-get install -y docker-compose-v2" \
                "Docker's repository (Debian, Ubuntu): sudo apt-get install -y docker-compose-plugin" \
                "Or install Docker with its compose plugin: curl -fsSL https://get.docker.com | sudo sh"
        fi
        die "Docker Compose v2 (docker compose) is missing." \
            "Ubuntu: sudo apt-get install -y docker-compose-v2" \
            "Docker's repository (Debian, Ubuntu): sudo apt-get install -y docker-compose-plugin"
    fi
    local version
    version=$(docker compose version --short 2>/dev/null | sed 's/^v//')
    if ! version_at_least "$version" 2.24.0; then
        die "Docker Compose $version is too old: 2.24 or newer is needed (it reads .env through env_file)." \
            "Update it: sudo apt-get install --only-upgrade docker-compose-plugin (or docker-compose-v2)"
    fi
}

# version_at_least A B: A >= B for dotted numbers
version_at_least() {
    [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n 1)" = "$2" ]
}

# port_user PROTO PORT: what listens on the port, empty when it is free
port_user() {
    local flag=-Htln line name
    [ "$1" = udp ] && flag=-Huln
    command -v ss >/dev/null 2>&1 || return 0
    line=$(ss "${flag}p" "sport = :$2" 2>/dev/null | head -n 1 || true)
    [ -n "$line" ] || return 0
    name=$(printf '%s' "$line" | grep -oE 'users:\(\("[^"]+"' | head -n 1 | cut -d'"' -f2 || true)
    printf '%s\n' "${name:-another program}"
}

check_ports() {
    local port user taken=() tcp=("$(console_port)" "$(console_https_port)" "${DOCKER_PORTS_TCP[@]}")
    ! traefik_on || tcp+=(80 443)
    for port in "${tcp[@]}"; do
        user=$(port_user tcp "$port")
        [ -z "$user" ] || taken+=("TCP $port: $user")
    done
    for port in "${DOCKER_PORTS_UDP[@]}"; do
        user=$(port_user udp "$port")
        [ -z "$user" ] || taken+=("UDP $port: $user")
    done
    [ "${#taken[@]}" -eq 0 ] && return 0
    local hint="Stop what uses them, then run this again."
    if printf '%s\n' "${taken[@]}" | grep -qE ': (hbbs|hbbr|rustdesk)'; then
        hint="A RustDesk server (hbbs, hbbr) uses them: stop it first, then run this again. To keep its clients, add --import-keys <its data folder, with id_ed25519 and id_ed25519.pub>."
    fi
    if [ "${#taken[@]}" -eq 1 ] && [[ "${taken[0]}" == "TCP $(console_port):"* ]]; then
        hint="Stop it, or give the console another port: --console-port 5080"
    fi
    if [ "${#taken[@]}" -eq 1 ] && [[ "${taken[0]}" == "TCP $(console_https_port):"* ]]; then
        hint="Stop it, or give the console's HTTPS another port: NEODESK_CONSOLE_HTTPS_PORT=5444 in $(env_file)"
    fi
    if printf '%s\n' "${taken[@]}" | grep -qE '^TCP (80|443):'; then
        hint="Traefik needs ports 80 and 443 for the certificate and HTTPS: stop the web server that has them (or run without --domain and put NeoDesk behind it)."
    fi
    die "Ports NeoDesk needs are in use:" "${taken[@]}" "$hint"
}

# check_traefik_ports: 80 and 443 are free for a Traefik that does not run
# yet (an install that turns it on)
check_traefik_ports() {
    traefik_on || return 0
    [ "$(docker container inspect -f '{{.State.Running}}' "$TRAEFIK_CONTAINER" 2>/dev/null || true)" != true ] || return 0
    local port user taken=()
    for port in 80 443; do
        user=$(port_user tcp "$port")
        [ -z "$user" ] || taken+=("TCP $port: $user")
    done
    [ "${#taken[@]}" -eq 0 ] && return 0
    die "Traefik needs ports 80 and 443, but they are in use; nothing was changed:" "${taken[@]}" \
        "Stop the web server that has them, or run without --domain and put NeoDesk behind it (TRUST_PROXY=1)."
}

check_internet() {
    if [ "$NO_PULL" = true ] || [ "$BUILD_LOCAL" = true ]; then return 0; fi
    if ! curl -sS --connect-timeout 10 --max-time 20 -o /dev/null https://ghcr.io/v2/ 2>/dev/null; then
        die "This machine cannot reach ghcr.io, where the image is published." \
            "Check the internet connection and DNS (curl -I https://ghcr.io)." \
            "Behind a proxy, Docker needs it in its own settings: https://docs.docker.com/engine/daemon/proxy/" \
            "Without internet: docker load the image, then run this with --no-pull."
    fi
}

#===============================================================================
# The host firewall: ufw or firewalld
#===============================================================================

# Docker publishes IPv4 ports past ufw and firewalld, and IPv6 ports too
# when the containers' network has IPv6 (NEODESK_IPV6=true). Without it
# IPv6 visitors come in through docker-proxy and the INPUT chain, where the
# host firewall decides. So the ports NeoDesk publishes are opened there
# when one of them is on, before the container starts (Let's Encrypt's
# challenge comes in on 80), and closed again when they are no longer
# served or at uninstall. Only rules this manager added are closed: in ufw the ones
# with the comment "NeoDesk ...", in both the ones in FIREWALL_RECORD.

firewall_record() { printf '%s\n' "$NEODESK_DIR/.firewall"; }

# active_firewall: ufw or firewalld when one of them is on, else nothing.
# "ufw status" prints "Status: active" (in English with LC_ALL=C); rules
# added to an inactive ufw would go live with the next "ufw enable".
active_firewall() {
    # The status is read whole first: grep -q on the pipe could end ufw
    # early (SIGPIPE), which pipefail reports as a failure
    local status=""
    if command -v ufw >/dev/null 2>&1; then status=$(LC_ALL=C ufw status 2>/dev/null || true); fi
    if printf '%s\n' "$status" | grep -q '^Status: active'; then
        printf 'ufw\n'
    elif command -v firewall-cmd >/dev/null 2>&1 && [ "$(firewall-cmd --state 2>/dev/null)" = running ]; then
        printf 'firewalld\n'
    fi
}

# firewall_wanted: the rules NeoDesk needs, one per line (21116/udp): the
# client ports and the console's by console_firewall_ports
firewall_wanted() {
    local port
    for port in "${DOCKER_PORTS_TCP[@]}"; do printf '%s/tcp\n' "$port"; done
    for port in "${DOCKER_PORTS_UDP[@]}"; do printf '%s/udp\n' "$port"; done
    for port in $(console_firewall_ports "$(console_domain)" | tr ',' ' '); do printf '%s/tcp\n' "$port"; done
}

# firewall_ours FIREWALL: the rules of FIREWALL this manager added
firewall_ours() {
    {
        sed -n "s#^$1 ##p" "$(firewall_record)" 2>/dev/null || true
        if [ "$1" = ufw ]; then
            LC_ALL=C ufw status 2>/dev/null | awk '/# NeoDesk/ { print $1 }' || true
        fi
    } | grep -E '^[0-9]+/(tcp|udp)$' | sort -u || true
}

# firewall_open FIREWALL RULE: the firewall lets RULE in already
firewall_open() {
    case "$1" in
        ufw) LC_ALL=C ufw status 2>/dev/null | awk -v r="$2" '$1 == r && $2 == "ALLOW" { found = 1 } END { exit !found }' ;;
        firewalld) firewall-cmd --permanent --query-port="$2" >/dev/null 2>&1 ;;
    esac
}

firewall_note() {
    local file
    file=$(firewall_record)
    if [ "$2" = add ]; then
        printf '%s %s\n' "$1" "$3" >> "$file"
    elif [ -f "$file" ]; then
        grep -vxF "$1 $3" "$file" > "$file.tmp" || true
        mv "$file.tmp" "$file"
    fi
}

# sync_firewall [none]: the host firewall lets in what NeoDesk serves now
# (with "none": nothing, for uninstall); says what it opened and closed
sync_firewall() {
    local fw rule wanted opened=() closed=() hint=()
    [ "$SKIP_FIREWALL" != true ] || return 0
    fw=$(active_firewall)
    [ -n "$fw" ] || return 0
    if [ "$(id -u)" -ne 0 ]; then
        warn "$fw is on, but changing it needs root: run with sudo to open NeoDesk's ports there."
        return 0
    fi
    wanted=""
    [ "${1:-}" = none ] || wanted=$(firewall_wanted)
    mkdir -p "$NEODESK_DIR"
    for rule in $wanted; do
        firewall_open "$fw" "$rule" && continue
        case "$fw" in
            ufw) ufw allow "$rule" comment "NeoDesk port $rule" >/dev/null 2>&1 || continue ;;
            firewalld) firewall-cmd --permanent --add-port="$rule" >/dev/null 2>&1 || continue ;;
        esac
        firewall_note "$fw" add "$rule"
        opened+=("$rule")
    done
    for rule in $(firewall_ours "$fw"); do
        printf '%s\n' "$wanted" | grep -qxF "$rule" && continue
        case "$fw" in
            ufw) ufw delete allow "$rule" >/dev/null 2>&1 || true ;;
            firewalld) firewall-cmd --permanent --remove-port="$rule" >/dev/null 2>&1 || true ;;
        esac
        firewall_note "$fw" remove "$rule"
        closed+=("$rule")
    done
    if [ "$fw" = firewalld ] && [ $((${#opened[@]} + ${#closed[@]})) -gt 0 ]; then
        firewall-cmd --reload >/dev/null 2>&1 || true
    fi
    [ "${#opened[@]}" -eq 0 ] || ok "Opened in $fw: ${opened[*]}"
    [ "${#closed[@]}" -eq 0 ] || ok "Closed in $fw: ${closed[*]}"
    # Behind a reverse proxy of its own (TRUST_PROXY, the console on all
    # addresses) the console's port stays closed: say how to open it
    [ "${1:-}" != none ] && [ -z "$(console_domain)" ] && [ -z "$(console_firewall_ports "")" ] || return 0
    case "$(env_get NEODESK_CONSOLE_BIND)" in 127.*|::1|"[::1]"|localhost) return 0 ;; esac
    case "$fw" in
        ufw) hint=("sudo ufw allow $(console_port)/tcp") ;;
        firewalld) hint=("sudo firewall-cmd --permanent --add-port=$(console_port)/tcp" "sudo firewall-cmd --reload") ;;
    esac
    say "$fw keeps the console's port $(console_port) closed, as a reverse proxy is in front of it (TRUST_PROXY in $(env_file))."
    say "To reach the console directly, open it by hand: $(printf '%s; ' "${hint[@]}" | sed 's/; $//')"
}

#===============================================================================
# Containers: which install is this, images, health
#===============================================================================

container_exists() { docker container inspect "$1" >/dev/null 2>&1; }

# container_dir NAME: the compose folder the container was made from
container_dir() {
    docker container inspect -f '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' "$1" 2>/dev/null || true
}

real_dir() { (cd "$1" 2>/dev/null && pwd -P) || printf '%s\n' "$1"; }

# install_state: "new", "ours" (this folder's install, its container made)
# or "foreign" (a NeoDesk container of another install). A folder whose
# container was never made (a first install that stopped early) is new.
install_state() {
    local c dir own
    own=$(real_dir "$NEODESK_DIR")
    for c in "${OLD_CONTAINERS[@]}"; do
        container_exists "$c" || continue
        dir=$(container_dir "$c")
        if [ "$c" = "$CONTAINER" ] && [ -n "$dir" ] && [ "$(real_dir "$dir")" = "$own" ]; then
            continue
        fi
        printf 'foreign\n'
        return 0
    done
    if container_exists "$CONTAINER"; then
        printf 'ours\n'
    else
        printf 'new\n'
    fi
}

foreign_install_error() {
    local c dir lines=()
    for c in "${OLD_CONTAINERS[@]}"; do
        container_exists "$c" || continue
        dir=$(container_dir "$c")
        lines+=("container $c (${dir:-not made by docker compose})")
    done
    die "Found NeoDesk from another install, so nothing was changed:" "${lines[@]}" \
        "Take it over into $NEODESK_DIR (its data is copied, the old container is kept stopped):" \
        "  $(manager_cmd) --adopt" \
        "Or manage it in its own folder: $(NEODESK_DIR=$NEODESK_DEFAULT_DIR manager_cmd) --dir <that folder>"
}

pull_image() {
    if [ "$BUILD_LOCAL" = true ]; then
        build_image
        return 0
    fi
    if [ "$NO_PULL" = true ]; then
        docker image inspect "$(image_ref)" >/dev/null 2>&1 \
            || die "--no-pull, but the image $(image_ref) is not on this machine." "Load it first: docker load -i <file>"
        return 0
    fi
    step "Pulling $(image_ref)"
    local out ok=true
    out=$(compose pull --quiet neodesk 2>&1) || ok=false
    # Before the first release there is no latest image: without a tag given
    # or saved, the install runs the development image, as the native
    # installers take the development build then
    if [ "$ok" = false ] && printf '%s' "$out" | grep -qiE 'manifest unknown|not found' && [ "$(image_tag)" = latest ] \
        && [ -z "$NEODESK_IMAGE_TAG_SET" ] && [ -z "$(env_get NEODESK_IMAGE_TAG)" ]; then
        warn "ghcr.io has no release image yet (latest): running the development image dev instead."
        warn "Once a release is out: $(manager_cmd) update --tag latest"
        env_set NEODESK_IMAGE_TAG dev
        step "Pulling $(image_ref)"
        ok=true
        out=$(compose pull --quiet neodesk 2>&1) || ok=false
    fi
    if [ "$ok" = false ]; then
        if printf '%s' "$out" | grep -qiE 'manifest unknown|not found|denied|unauthorized'; then
            die "The image $(image_ref) was not found on ghcr.io." \
                "Check the tag (--tag, NEODESK_IMAGE_TAG in $(env_file)); latest is the newest release." \
                "Or build it from a checkout of the repository: sudo bash <checkout>/install/neodesk-docker.sh --build"
        fi
        printf '%s\n' "$out" >&2
        die "Pulling the image failed (output above)." "Check the internet connection and run this again."
    fi
    if on_postgres; then
        compose pull --quiet postgres >/dev/null 2>&1 || true
    fi
    if traefik_on; then
        compose pull --quiet traefik >/dev/null 2>&1 || true
    fi
}

# The data volume's place in images up to 3.6.0-rc.4. Images since
# 3.6.0-rc.5 have nothing there.
OLD_DATA_PATH=/opt/rustdesk

# set_data_path: where the compose file mounts the data volume for the
# image to run. An image of this release keeps its data in
# /opt/neodesk/data, the compose file's default, and the install's files
# that still name the old place move with it (move_old_data_path). One from
# before keeps it in /opt/rustdesk (its RUSTDESK_PATH), and .env says so
# with NEODESK_DATA_PATH.
set_data_path() {
    local path
    path=$(docker image inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$(image_ref)" 2>/dev/null \
        | sed -n 's/^RUSTDESK_PATH=//p' | head -n 1)
    if [ "$path" = "$OLD_DATA_PATH" ]; then
        env_set NEODESK_DATA_PATH "$OLD_DATA_PATH"
    else
        env_unset NEODESK_DATA_PATH
        move_old_data_path
    fi
}

# move_old_data_path: .env, a compose file changed by hand and
# docker-compose.override.yml get /opt/neodesk/data where they name the
# old place of the data volume (the compose files the data path of the
# release's compose file, so NEODESK_DATA_PATH counts there as well).
# Comments stay as they are. An update has the files as they were in its
# backup (keep_settings).
move_old_data_path() {
    local f new moved=()
    local old="$OLD_DATA_PATH([/\"':[:space:]]|\$)"
    for f in "$(env_file)" "$(compose_file)" "$NEODESK_DIR/docker-compose.override.yml"; do
        [ -f "$f" ] && grep -qE "^[^#]*$old" "$f" || continue
        if [ "$f" = "$(env_file)" ]; then
            new=/opt/neodesk/data
        else
            new='${NEODESK_DATA_PATH:-/opt/neodesk/data}'
        fi
        sed -i -E "/^[[:space:]]*#/!s#$old#$new\\1#g" "$f" || die "Could not rewrite $f"
        moved+=("$(basename "$f")")
    done
    [ "${#moved[@]}" -eq 0 ] \
        || say "Changed $OLD_DATA_PATH to /opt/neodesk/data, the data volume's place since 3.6.0-rc.5, in: ${moved[*]}"
}

build_image() {
    # The checkout this script is in: its install/ folder holds the script,
    # docker/ the Dockerfile
    local checkout
    checkout=$(cd "$SCRIPT_DIR/.." 2>/dev/null && pwd)
    [ -f "$checkout/docker/Dockerfile" ] && [ -d "$checkout/neodesk-server" ] \
        || die "--build needs a checkout of the repository, with this script in its install/ folder." \
            "git clone https://github.com/neodeskapp/neodesk.git && sudo bash neodesk/install/neodesk-docker.sh --build"
    NEODESK_IMAGE_TAG_SET="local"
    env_set NEODESK_IMAGE_TAG local
    step "Building $(image_ref) from $checkout (several minutes)"
    local commit
    commit=$(git -C "$checkout" rev-parse HEAD 2>/dev/null || true)
    docker build -f "$checkout/docker/Dockerfile" -t "$(image_ref)" --build-arg NEODESK_COMMIT_SHA="$commit" "$checkout" \
        || die "The image did not build (output above); the running container was not changed."
}

image_id() { docker image inspect -f '{{.Id}}' "$1" 2>/dev/null || true; }

container_image_id() { docker container inspect -f '{{.Image}}' "$CONTAINER" 2>/dev/null || true; }

container_running() {
    [ "$(docker container inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null || true)" = true ]
}

# answers URL: the URL answers, over HTTP or HTTPS
answers() {
    curl -fsk --max-time 3 -o /dev/null "$1" 2>/dev/null \
        || curl -fsk --max-time 3 -o /dev/null "${1/http:/https:}" 2>/dev/null
}

# wait_healthy: the API and the console answer on this machine within
# HEALTH_TIMEOUT seconds, while the container keeps running
wait_healthy() {
    local waited=0 port
    port=$(console_port)
    while [ "$waited" -lt "$HEALTH_TIMEOUT" ]; do
        if container_running \
            && answers "http://127.0.0.1:21121/api/health" \
            && answers "http://127.0.0.1:${port}/health"; then
            return 0
        fi
        sleep 2
        waited=$((waited + 2))
    done
    return 1
}

save_failed_log() {
    local file
    mkdir -p "$NEODESK_DIR/logs"
    file="$NEODESK_DIR/logs/failed-start-$(date +%Y%m%d-%H%M%S).log"
    docker logs --tail 300 "$CONTAINER" > "$file" 2>&1 || true
    printf '%s\n' "$file"
}

server_version() {
    docker exec "$CONTAINER" /usr/local/bin/neodesk-server -version 2>/dev/null | head -n 1 || printf 'version unknown\n'
}

#===============================================================================
# Backups of the volumes
#===============================================================================

backup_dir() { printf '%s\n' "$NEODESK_DIR/backups"; }

# backup_volumes [FOLDER]: a tar.gz of the data volumes, the folders
# neodesk (the data volume) and console (and a dump of PostgreSQL), taken
# while the container is stopped, with .env, docker-compose.yml and
# docker-compose.override.yml from FOLDER (an update's copies from before
# it) or the install folder. Prints the file.
backup_volumes() {
    local dir name image old from="${1:-$NEODESK_DIR}"
    dir=$(backup_dir)
    mkdir -p "$dir"
    chmod 700 "$dir"
    name="neodesk-$(date +%Y%m%d-%H%M%S)"
    image=$(docker container inspect -f '{{.Config.Image}}' "$CONTAINER" 2>/dev/null || true)
    if [ -z "$image" ] || ! docker image inspect "$image" >/dev/null 2>&1; then image=$(image_ref); fi
    docker run --rm --entrypoint tar --user 0 \
        -v "$DATA_VOLUME:/backup/neodesk:ro" -v "$CONSOLE_VOLUME:/backup/console:ro" -v "$dir:/out" \
        "$image" czf "/out/$name.tar.gz" -C /backup neodesk console >/dev/null \
        || die "The backup of the volumes failed; nothing was changed." "Is there free disk space? df -h $dir"
    cp -p "$from/docker-compose.yml" "$dir/$name.docker-compose.yml" 2>/dev/null || true
    cp -p "$from/docker-compose.override.yml" "$dir/$name.docker-compose.override.yml" 2>/dev/null || true
    cp -p "$from/.env" "$dir/$name.env" 2>/dev/null || true
    if on_postgres && container_exists "$PG_CONTAINER"; then
        compose exec -T postgres pg_dump -U neodesk neodesk 2>/dev/null | gzip > "$dir/$name.postgres.sql.gz" \
            || warn "The PostgreSQL dump failed; the volume backup is there."
    fi
    chmod 600 "$dir/$name".* 2>/dev/null || true
    # The last KEEP_BACKUPS stay
    ls -1t "$dir"/neodesk-*.tar.gz 2>/dev/null | tail -n +$((KEEP_BACKUPS + 1)) | while read -r old; do
        rm -f "$old" "${old%.tar.gz}".*
    done
    printf '%s\n' "$dir/$name.tar.gz"
}

# keep_settings: copies of .env, docker-compose.yml, its record and
# docker-compose.override.yml as they are before an update writes new ones,
# in a folder of the install folder that only its owner reads. The update's
# backup takes these, and a failed update puts them back. Prints the folder.
keep_settings() {
    local dir="$NEODESK_DIR/.before-update" f
    rm -rf "$dir"
    (umask 077 && mkdir -p "$dir")
    for f in "$(env_file)" "$(compose_file)" "$NEODESK_DIR/.compose.sha256" "$NEODESK_DIR/docker-compose.override.yml"; do
        [ ! -f "$f" ] || cp -p "$f" "$dir/"
    done
    printf '%s\n' "$dir"
}

# put_settings_back FOLDER: .env, docker-compose.yml, its record and
# docker-compose.override.yml as keep_settings kept them in FOLDER; one
# that was not there goes
put_settings_back() {
    local f
    for f in .env docker-compose.yml .compose.sha256 docker-compose.override.yml; do
        if [ -f "$1/$f" ]; then
            cp -p "$1/$f" "$NEODESK_DIR/$f"
        else
            rm -f "${NEODESK_DIR:?}/$f"
        fi
    done
}

# restore_volumes FILE: the volumes as the backup has them. The data volume
# is the archive's folder neodesk, or rustdesk in a backup of 3.6.0-rc.4 or
# older: it is mounted under both names.
restore_volumes() {
    docker run --rm --entrypoint sh --user 0 \
        -v "$DATA_VOLUME:/backup/neodesk" -v "$CONSOLE_VOLUME:/backup/console" \
        -v "$DATA_VOLUME:/backup/rustdesk" -v "$(dirname "$1"):/in:ro" \
        "$(image_ref)" -c 'find /backup/neodesk /backup/console -mindepth 1 -delete && tar xzf "/in/$1" -C /backup' \
        sh "$(basename "$1")"
}

#===============================================================================
# Install and update
#===============================================================================

detect_relay_address() {
    local ip=""
    case "$RELAY_MODE" in
        local|lan) ;;
        *)
            ip=$(curl -4 -fsS --max-time 5 https://checkip.amazonaws.com 2>/dev/null \
                || curl -4 -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)
            ip=$(printf '%s' "$ip" | tr -d '[:space:]')
            ;;
    esac
    if [ -z "$ip" ]; then
        ip=$(ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -n 1 || true)
        [ -n "$ip" ] || ip=$(hostname -I 2>/dev/null | awk '{print $1}' || true)
        case "$RELAY_MODE" in
            local|lan) ;;
            *) warn "No public address found; clients get the LAN address $ip. Set another with --relay ADDRESS." ;;
        esac
    fi
    printf '%s\n' "$ip"
}

write_settings() {
    mkdir -p "$NEODESK_DIR"
    chmod 755 "$NEODESK_DIR"
    [ -f "$(env_file)" ] || env_set NEODESK_DOCKER_LAYOUT single
    [ -z "$NEODESK_IMAGE_TAG_SET" ] || env_set NEODESK_IMAGE_TAG "$NEODESK_IMAGE_TAG_SET"
    [ -z "$CONSOLE_PORT_SET" ] || env_set NEODESK_CONSOLE_PORT "$CONSOLE_PORT_SET"
    [ -z "${PUID:-}" ] || env_set PUID "$PUID"
    [ -z "${PGID:-}" ] || env_set PGID "$PGID"
    if [ -n "$RELAY_SERVERS_SET" ]; then
        env_set RELAY_SERVERS "$RELAY_SERVERS_SET"
    elif [ -z "$(env_get RELAY_SERVERS)" ]; then
        env_set RELAY_SERVERS "$(detect_relay_address)"
    fi
    case "$TRAEFIK_ACTION" in
        on) traefik_settings ;;
        off) no_traefik_settings ;;
    esac
}

# ipv6_settings: whether a new install's network gets IPv6
# (NEODESK_IPV6). With it Docker gives the containers IPv6 addresses and
# publishes the ports on IPv6 with NAT as on IPv4, so the server sees IPv6
# visitors' own addresses instead of the network's gateway. That needs
# Docker Engine 27 or newer (it picks the network's IPv6 subnet and sets
# up the IPv6 NAT by itself) and a host where Docker can make an IPv6
# network, which a throwaway network checks. NEODESK_IPV6 given to this
# script wins; on an older engine or without IPv6 the network stays IPv4
# and it says why. .env keeps the answer, so later runs leave it alone,
# and installs from before have none, so they stay on IPv4.
ipv6_settings() {
    local engine error probe="neodesk-ipv6-check"
    [ -z "$(env_get NEODESK_IPV6)" ] || return 0
    if [ -n "$IPV6_SET" ]; then
        env_set NEODESK_IPV6 "$IPV6_SET"
        return 0
    fi
    engine=$(docker version -f '{{.Server.Version}}' 2>/dev/null || true)
    if ! version_at_least "${engine:-0}" 27.0.0; then
        env_set NEODESK_IPV6 false
        say "IPv4 only on the containers' network: IPv6 needs Docker Engine 27 or newer, this is ${engine:-an unknown version}."
        ipv6_off_hint
        return 0
    fi
    docker network rm "$probe" >/dev/null 2>&1 || true
    if ! error=$(docker network create --ipv6 "$probe" 2>&1 >/dev/null); then
        env_set NEODESK_IPV6 false
        say "IPv4 only on the containers' network: Docker could not make an IPv6 network here (${error%%$'\n'*})."
        ipv6_off_hint
        return 0
    fi
    docker network rm "$probe" >/dev/null 2>&1 || true
    env_set NEODESK_IPV6 true
}

ipv6_off_hint() {
    say "  IPv6 visitors show up in the activity log as the network's gateway, and sign-in limits count them as one."
    say "  To change it later: NEODESK_IPV6=true in $(env_file), then cd $NEODESK_DIR && docker compose down && docker compose up -d"
}

# traefik_settings: Traefik with Let's Encrypt in front of the console:
# the profile, the domain and the contact, the console's own port on this
# host only, the client's address from Traefik and the address in mails
traefik_settings() {
    local old_domain
    old_domain=$(env_get NEODESK_DOMAIN)
    check_domain_dns "$DOMAIN_SET"
    env_set NEODESK_DOMAIN "$DOMAIN_SET"
    # The contact is optional; one given before stays
    [ -z "$LETSENCRYPT_EMAIL_SET" ] || env_set LETSENCRYPT_EMAIL "$LETSENCRYPT_EMAIL_SET"
    if [ "$LETSENCRYPT_STAGING" = true ]; then
        env_set LETSENCRYPT_CA_SERVER "$LETSENCRYPT_STAGING_CA"
    else
        env_unset LETSENCRYPT_CA_SERVER
    fi
    env_set NEODESK_CONSOLE_BIND 127.0.0.1
    env_set TRUST_PROXY 1
    # A mail address of the console set by hand stays, one this script set
    # for an older domain follows the new one
    case "$(env_get PANEL_PUBLIC_URL)" in
        ""|"https://$old_domain") env_set PANEL_PUBLIC_URL "https://$DOMAIN_SET" ;;
    esac
    profile_on traefik
}

# no_traefik_settings: the settings traefik_settings made go again, and
# the Traefik container with them; its certificate volume stays
no_traefik_settings() {
    local domain
    domain=$(env_get NEODESK_DOMAIN)
    case ",$(env_get COMPOSE_PROFILES)," in
        *,traefik,*) ;;
        *) [ -n "$domain" ] || return 0 ;;
    esac
    step "Removing Traefik; the console answers on port $(console_port) again"
    compose --profile traefik rm -sf traefik >/dev/null 2>&1 || true
    profile_off traefik
    [ "$(env_get PANEL_PUBLIC_URL)" != "https://$domain" ] || env_unset PANEL_PUBLIC_URL
    [ "$(env_get NEODESK_CONSOLE_BIND)" != 127.0.0.1 ] || env_unset NEODESK_CONSOLE_BIND
    env_unset TRUST_PROXY
    env_unset NEODESK_DOMAIN
    env_unset LETSENCRYPT_CA_SERVER
}

# own_addresses: this server's addresses as Let's Encrypt may see them:
# the IPv4 address clients use (RELAY_SERVERS, when it is one), its
# global IPv6 addresses and its public IPv6 address
own_addresses() {
    local relay
    relay="${RELAY_SERVERS_SET:-$(env_get RELAY_SERVERS)}"
    relay="${relay%%:*}"
    [[ ! "$relay" =~ ^[0-9.]+$ ]] || printf '%s\n' "$relay"
    ip -6 addr show scope global 2>/dev/null | awk '/inet6/ { sub(/\/.*/, "", $2); print $2 }' || true
    curl -6 -fsS --max-time 5 https://api64.ipify.org 2>/dev/null | tr -d '[:space:]' || true
    printf '\n'
}

# check_domain_dns NAME: warns when no address of NAME is one of this
# server's (own_addresses); Let's Encrypt checks the name over them
check_domain_dns() {
    local addrs ours addr
    command -v getent >/dev/null 2>&1 || return 0
    addrs=$(getent ahosts "$1" 2>/dev/null | awk '{print $1}' | sort -u | tr '\n' ' ' || true)
    if [ -z "$addrs" ]; then
        warn "$1 does not resolve yet. Let's Encrypt gives the certificate once it points at this server."
        warn "Then run this script again, which makes Traefik ask again."
        return 0
    fi
    ours=$(own_addresses | grep -v '^$' | sort -u | tr '\n' ' ')
    [ -n "$ours" ] || return 0
    for addr in $addrs; do
        [[ " $ours" != *" $addr "* ]] || return 0
    done
    warn "$1 points at ${addrs% }, not at this server (${ours% })."
    warn "Let's Encrypt reaches the name over ports 80 and 443; check the DNS record (or ignore this behind NAT)."
}

# cert_issuer DOMAIN: the issuer of the certificate Traefik serves for
# DOMAIN on this machine
cert_issuer() {
    if command -v openssl >/dev/null 2>&1; then
        openssl s_client -connect 127.0.0.1:443 -servername "$1" < /dev/null 2>/dev/null \
            | openssl x509 -noout -issuer 2>/dev/null || true
    else
        curl -vsk --max-time 5 -o /dev/null --resolve "$1:443:127.0.0.1" "https://$1/" 2>&1 \
            | sed -n 's/^\*[[:space:]]*issuer:[[:space:]]*//p' || true
    fi
}

# has_certificate DOMAIN: the console answers over HTTPS at DOMAIN with a
# certificate this machine trusts; with the staging server, one of its
# certificates (Traefik's own default certificate does not count)
has_certificate() {
    if [ "$(env_get LETSENCRYPT_CA_SERVER)" = "$LETSENCRYPT_STAGING_CA" ]; then
        [[ "$(cert_issuer "$1")" == *"(STAGING)"* ]] || return 1
        curl -fsSk --max-time 5 -o /dev/null --resolve "$1:443:127.0.0.1" "https://$1/health" 2>/dev/null
    else
        curl -fsS --max-time 5 -o /dev/null --resolve "$1:443:127.0.0.1" "https://$1/health" 2>/dev/null
    fi
}

# traefik_acme_error: the cause in Traefik's last failed ACME try, empty
# when its log has none
traefik_acme_error() {
    local line cause
    # Without colours: Traefik writes them into its log unless
    # --log.nocolor (the compose files of 3.6.22 and older)
    line=$(compose logs --no-color --tail 300 traefik 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' \
        | grep -iE 'acme|certificate' | grep -E ' ERR |level=error' | tail -n 1 || true)
    [ -n "$line" ] || return 0
    cause=$(printf '%s\n' "$line" | sed -nE 's/.*error="(([^"\\]|\\.)*)".*/\1/p')
    cause="${cause:-$line}"
    cause=$(printf '%s' "$cause" | sed -e 's/\\n/ /g' -e 's/\\"/"/g' -e 's/  */ /g')
    printf '%s\n' "${cause:0:400}"
}

# wait_certificate: the console answers over HTTPS at its domain with its
# certificate (has_certificate) within CERT_TIMEOUT seconds; when not, a
# warning with Traefik's cause and how to try again
wait_certificate() {
    local domain waited=0 cause
    domain=$(console_domain)
    [ -n "$domain" ] || return 0
    step "Waiting for the Let's Encrypt certificate of $domain"
    while [ "$waited" -lt "$CERT_TIMEOUT" ]; do
        if has_certificate "$domain"; then
            if [ "$(env_get LETSENCRYPT_CA_SERVER)" = "$LETSENCRYPT_STAGING_CA" ]; then
                ok "HTTPS: https://$domain has a certificate of Let's Encrypt's staging server (browsers do not trust it; run again without --letsencrypt-staging for a trusted one)"
            else
                ok "HTTPS: https://$domain has its certificate (Traefik renews it by itself)"
            fi
            return 0
        fi
        sleep 3
        waited=$((waited + 3))
    done
    warn "https://$domain has no certificate from Let's Encrypt yet."
    cause=$(traefik_acme_error)
    [ -z "$cause" ] || warn "Traefik's last try failed: $cause"
    warn "Let's Encrypt needs $domain to point at this server and ports 80 and 443 to reach it."
    warn "Traefik does not try again soon after a failure: once DNS and the ports are right, run this script again"
    warn "(or: cd $NEODESK_DIR && docker compose restart traefik). Its log: cd $NEODESK_DIR && docker compose logs traefik"
}

# acme_ca_host: the host of the ACME server Traefik uses
acme_ca_host() {
    local ca
    ca=$(env_get LETSENCRYPT_CA_SERVER)
    ca="${ca:-https://acme-v02.api.letsencrypt.org/directory}"
    ca="${ca#*://}"
    printf '%s\n' "${ca%%/*}"
}

# check_acme_storage: Traefik keeps one account and its certificates in
# acme.json, whichever server they came from, and does not ask the new
# one after a switch (staging to production): an acme.json of another
# server moves aside, with Traefik stopped, and Traefik is made again.
# Sets TRAEFIK_RECREATE then.
TRAEFIK_RECREATE=false
check_acme_storage() {
    traefik_on || return 0
    docker volume inspect "$TRAEFIK_VOLUME" >/dev/null 2>&1 || return 0
    local host check='f=/le/acme.json; [ -s "$f" ] && grep -q "\"uri\"" "$f" && ! grep -q "://$1/" "$f"'
    host=$(acme_ca_host)
    docker run --rm --entrypoint sh --user 0 -v "$TRAEFIK_VOLUME:/le:ro" "$(image_ref)" -c "$check" sh "$host" >/dev/null 2>&1 \
        || return 0
    compose --profile traefik stop traefik >/dev/null 2>&1 || true
    docker run --rm --entrypoint sh --user 0 -v "$TRAEFIK_VOLUME:/le" "$(image_ref)" \
        -c 'mv /le/acme.json "/le/acme.json.other-server-$1"' sh "$(date +%Y%m%d-%H%M%S)" >/dev/null \
        || die "Could not move the old acme.json aside in the volume $TRAEFIK_VOLUME."
    say "Traefik's certificates came from another ACME server than $host; they are kept as acme.json.other-server-* in $TRAEFIK_VOLUME."
    TRAEFIK_RECREATE=true
}

# renew_traefik: Traefik made again, so it reads its routing and asks
# Let's Encrypt again: after --domain (a new name, or a try that failed
# before) and after check_acme_storage moved its storage
renew_traefik() {
    traefik_on || return 0
    [ "$TRAEFIK_ACTION" = on ] || [ "$TRAEFIK_RECREATE" = true ] || return 0
    compose_quiet up -d --no-deps --force-recreate traefik || die "Traefik did not start (output above)." \
        "Its log: cd $NEODESK_DIR && docker compose logs traefik"
}

# import_keys: the key pair of IMPORT_KEYS into the data volume, while the
# container is stopped (or not made yet). A key of the install's own that
# differs stays next to it as id_ed25519.before-import-<time>.
import_keys() {
    [ -n "$IMPORT_KEYS" ] || return 0
    local uid gid out
    uid="${PUID:-$(env_get PUID)}"
    gid="${PGID:-$(env_get PGID)}"
    docker volume create "$DATA_VOLUME" >/dev/null 2>&1 || true
    out=$(docker run --rm --entrypoint sh --user 0 -v "$DATA_VOLUME:/data" -v "$IMPORT_KEYS:/in:ro" "$(image_ref)" -c '
        set -e
        if [ -f /data/id_ed25519 ] && ! cmp -s /in/id_ed25519 /data/id_ed25519; then
            mv /data/id_ed25519 "/data/id_ed25519.before-import-$1"
            [ ! -f /data/id_ed25519.pub ] || mv /data/id_ed25519.pub "/data/id_ed25519.pub.before-import-$1"
            echo replaced
        fi
        cp /in/id_ed25519 /data/id_ed25519
        cp /in/id_ed25519.pub /data/id_ed25519.pub
        chown "$2:$3" /data/id_ed25519 /data/id_ed25519.pub
        chmod 600 /data/id_ed25519
        chmod 644 /data/id_ed25519.pub' sh "$(date +%Y%m%d-%H%M%S)" "${uid:-10001}" "${gid:-10001}") \
        || die "The key pair of $IMPORT_KEYS could not be put into the volume $DATA_VOLUME." \
            "Check that the folder is readable, then run this again."
    if [ "$out" = replaced ]; then
        ok "Key pair of $IMPORT_KEYS imported; the install's previous one is in the volume as id_ed25519.before-import-*"
    else
        ok "Key pair of $IMPORT_KEYS imported: clients that have its key keep working"
    fi
}

new_secret() {
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -hex "$1"
    else
        head -c "$1" /dev/urandom | od -An -tx1 | tr -d ' \n'
    fi
}

# postgres_url PASSWORD: the server's address of the postgres service
postgres_url() { printf 'postgres://neodesk:%s@postgres:5432/neodesk?sslmode=disable\n' "$1"; }

# use_database ADDRESS: the server's database in .env, DATABASE_URL alone
# (the type follows from the address); the DB_TYPE of an older .env goes
use_database() {
    env_unset DB_TYPE
    env_set DATABASE_URL "$1"
}

# postgres_settings: the settings of the postgres service with a new
# password (kept when .env has one)
postgres_settings() {
    local pass
    pass=$(env_get POSTGRES_PASSWORD)
    [ -n "$pass" ] || pass=$(new_secret 24)
    env_set POSTGRES_PASSWORD "$pass"
    profile_on postgres
    use_database "$(postgres_url "$pass")"
}

do_install() {
    need_root_or_docker
    check_docker
    local state
    state=$(install_state)
    if [ "$state" = foreign ] && [ "$ADOPT" != true ]; then
        foreign_install_error
    fi
    if [ "$state" = ours ]; then
        [ "$COMMAND" != install ] || say "NeoDesk is installed in $NEODESK_DIR: updating it."
        do_update
        return
    fi
    if [ "$COMMAND" = update ]; then
        die "There is no install in $NEODESK_DIR to update." \
            "Install it: $(manager_cmd)" "Another folder: --dir <folder>"
    fi

    local started=$SECONDS
    say "${BOLD}Installing NeoDesk on Docker into $NEODESK_DIR${NC}"
    [ "$state" = foreign ] || check_ports
    check_internet
    if [ "$state" != foreign ] && docker volume inspect "$DATA_VOLUME" >/dev/null 2>&1; then
        say "The volume $DATA_VOLUME is there from an earlier install; its data is used."
    fi
    # Only a folder without settings is a new install for IPv6: one whose
    # container was removed (docker compose down) or that is taken over
    # keeps its network as it was
    local fresh=false
    [ "$state" != new ] || [ -f "$(env_file)" ] || fresh=true
    write_settings
    [ "$fresh" != true ] || ipv6_settings
    if [ "$USE_POSTGRES" = true ] && ! on_postgres; then
        postgres_settings
    fi
    write_compose_file
    place_manager_copy
    pull_image
    set_data_path
    if [ "$state" = foreign ]; then
        adopt_old_install
    fi
    import_keys
    check_acme_storage
    sync_firewall
    step "Starting NeoDesk"
    export ADMIN_PASSWORD
    compose_quiet up -d --remove-orphans \
        || die "docker compose up failed (output above)." "Its log: cd $NEODESK_DIR && docker compose logs neodesk"
    if ! wait_healthy; then
        local log
        log=$(save_failed_log)
        die "NeoDesk did not get healthy within ${HEALTH_TIMEOUT}s." "Its log is in $log" \
            "Follow it: cd $NEODESK_DIR && docker compose logs -f neodesk"
    fi
    remember_applied
    ok "NeoDesk runs ($((SECONDS - started))s)"
    wait_certificate
    update_manager_copy
    print_summary first
}

do_update() {
    need_root_or_docker
    check_docker
    case "$(install_state)" in
        ours) ;;
        foreign) foreign_install_error ;;
        *) die "There is no install in $NEODESK_DIR to update." "Install it: $(manager_cmd)" ;;
    esac
    check_internet
    check_traefik_ports
    local old_image old_ref new_image applied backup log before
    # The settings, the compose file and the image from before the update:
    # the backup takes these, and the way back puts them back
    before=$(keep_settings)
    # An install on the old default port (its compose file published
    # 5000, its .env names no host port) moves to the new one
    local moved_port=false
    if [ -z "${CONSOLE_PORT_SET:-}" ] && [ -z "$(env_get NEODESK_CONSOLE_PORT)" ] \
        && grep -qF "NEODESK_CONSOLE_PORT:-${CONSOLE_OLD_DEFAULT_PORT}}" "$(compose_file)" 2>/dev/null; then
        moved_port=true
    fi
    old_image=$(container_image_id)
    old_ref=$(docker container inspect -f '{{.Config.Image}}' "$CONTAINER" 2>/dev/null || true)
    write_settings
    write_compose_file
    pull_image
    set_data_path
    new_image=$(image_id "$(image_ref)")
    applied=$(cat "$NEODESK_DIR/.applied.sha256" 2>/dev/null || true)
    check_acme_storage
    sync_firewall
    if [ -z "$IMPORT_KEYS" ] && [ -n "$old_image" ] && [ "$old_image" = "$new_image" ] && container_running; then
        if [ "$applied" = "$(settings_fingerprint)" ] && [ "$TRAEFIK_ACTION" != on ] && [ "$TRAEFIK_RECREATE" != true ] && wait_healthy; then
            rm -rf "$before"
            ok "NeoDesk is up to date: $(server_version)"
            update_manager_copy
            print_summary
            return 0
        fi
        # The same image with other settings (--domain, --no-traefik, a
        # changed .env): Compose makes again what changed, without a stop
        # and a backup
        if apply_settings "$before"; then
            update_manager_copy
            print_summary
            note_console_port_move "$moved_port"
            return 0
        fi
    fi

    step "Stopping NeoDesk for the backup"
    compose stop -t 30 neodesk >/dev/null 2>&1 || true
    backup=$(backup_volumes "$before")
    ok "Backup: $backup"
    import_keys
    step "Starting $(image_ref)"
    compose_quiet up -d --remove-orphans || true
    if wait_healthy; then
        rm -rf "$before"
        remember_applied
        ok "Updated: $(server_version)"
        renew_traefik
        [ "$TRAEFIK_ACTION" != on ] && [ "$TRAEFIK_RECREATE" != true ] || wait_certificate
        update_manager_copy
        print_summary
        note_console_port_move "$moved_port"
        return 0
    fi

    log=$(save_failed_log)
    warn "The new container did not get healthy within ${HEALTH_TIMEOUT}s; its log is in $log"
    # The way back: .env and docker-compose.yml from before the update, so
    # Compose names the previous image again; neither --tag nor
    # NEODESK_IMAGE_TAG of this run counts any more
    put_settings_back "$before"
    rm -rf "$before"
    NEODESK_IMAGE_TAG_SET=""
    unset NEODESK_IMAGE_TAG
    if [ -n "$old_image" ] && [ "$old_image" != "$new_image" ]; then
        step "Going back to the previous image"
        # Under its own name: the pull may have moved that tag (latest) to
        # the new image
        if [ -n "$old_ref" ] && [ "${old_ref#sha256:}" = "$old_ref" ]; then
            docker tag "$old_image" "$old_ref" || warn "Could not name the previous image $old_ref again"
        fi
        compose_quiet up -d --force-recreate neodesk || true
        if wait_healthy; then
            die "The update failed; NeoDesk runs the previous version again: $(server_version)" \
                "The failed start's log: $log" "The data before the update: $backup"
        fi
    fi
    step "Putting the data of the backup back"
    compose stop -t 10 neodesk >/dev/null 2>&1 || true
    restore_volumes "$backup" || true
    compose_quiet up -d --force-recreate neodesk || true
    if wait_healthy; then
        die "The update failed; NeoDesk runs again with the data from before the update." \
            "The failed start's log: $log"
    fi
    die "NeoDesk does not start, also not with the previous version." \
        "The failed start's log: $log" "The data before the update: $backup" \
        "Follow the log: cd $NEODESK_DIR && docker compose logs -f neodesk"
}

# apply_settings BEFORE: the settings of this run for the running image:
# Compose makes again what they change, and Traefik is made again when
# it is turned on (renew_traefik). When NeoDesk does not get healthy with
# them, the settings BEFORE (keep_settings) go back and it fails.
apply_settings() {
    local log
    step "Applying the settings"
    compose_quiet up -d --remove-orphans || true
    if wait_healthy; then
        rm -rf "$1"
        remember_applied
        ok "Settings applied: $(server_version)"
        renew_traefik
        [ "$TRAEFIK_ACTION" != on ] && [ "$TRAEFIK_RECREATE" != true ] || wait_certificate
        return 0
    fi
    log=$(save_failed_log)
    warn "NeoDesk did not get healthy with the new settings within ${HEALTH_TIMEOUT}s; its log is in $log"
    put_settings_back "$1"
    rm -rf "$1"
    compose_quiet up -d --remove-orphans || true
    if wait_healthy; then
        die "The settings were not applied; NeoDesk runs with the previous ones again." "The failed start's log: $log"
    fi
    die "NeoDesk does not start, also not with the previous settings." "The failed start's log: $log" \
        "Follow the log: cd $NEODESK_DIR && docker compose logs -f neodesk"
}

# first_password: the admin's generated first password from the volume,
# empty when there is none
first_password() {
    docker exec -u neodesk "$CONTAINER" sh -c 'cat "${RUSTDESK_PATH:-/opt/neodesk/data}/.admin_credentials" 2>/dev/null' 2>/dev/null \
        | sed -n 's/^Admin Password:[[:space:]]*//p' | head -n 1 || true
}

public_key() {
    docker exec "$CONTAINER" sh -c 'cat "${RUSTDESK_PATH:-/opt/neodesk/data}/id_ed25519.pub" 2>/dev/null' 2>/dev/null | tr -d '\r\n' || true
}

# print_summary [first]: where the console is, how to sign in (the first
# password only right after the first install), the client settings and
# where the logs are
print_summary() {
    local addr port key password tag domain
    domain=$(console_domain)
    addr=$(env_get RELAY_SERVERS)
    addr="${addr%%:*}"
    addr="${addr:-<this server>}"
    port=$(console_port)
    key=$(public_key)
    tag=$(image_tag)
    say ""
    say "${BOLD}NeoDesk on Docker${NC}: $(server_version)"
    if [ "$tag" = latest ]; then
        say "Image:           $(image_ref), the newest release (pin one: --tag <version>)"
    else
        say "Image:           $(image_ref) (pinned; the newest release: --tag latest)"
    fi
    say ""
    if [ -n "$domain" ]; then
        say "Web console:     https://${domain}   (Let's Encrypt, renewed by Traefik; on this machine: http://127.0.0.1:${port})"
    else
        say "Web console:     http://${addr}:${port}   (on this machine: http://127.0.0.1:${port})"
    fi
    if [ "${1:-}" = first ]; then
        if [ -n "$ADMIN_PASSWORD" ]; then
            say "Sign in:         user admin, the password you set in ADMIN_PASSWORD"
        else
            password=$(first_password)
            if [ -n "$password" ]; then
                say "Sign in:         user admin, password ${BOLD}${password}${NC}"
                say "                 (shown this once; change it after the first sign-in)"
            else
                say "Sign in:         user admin; the password: cd $NEODESK_DIR && docker compose exec neodesk neodesk-show-admin-credentials"
            fi
        fi
    else
        say "Sign in:         with your accounts; a new admin password: $(manager_cmd) reset-password"
    fi
    say ""
    say "RustDesk clients (Settings, Network, ID/Relay server):"
    say "  ID server:     ${addr}"
    say "  Relay server:  ${addr}:21117"
    say "  API server:    http://${addr}:21121"
    say "  Key:           ${key:-not made yet; later: docker exec neodesk cat /opt/neodesk/data/id_ed25519.pub}"
    say ""
    say "Ports to open in a firewall in front of this machine: TCP $(console_firewall_ports "$domain")21114-21119, 21121-21123 and UDP 21116"
    if [ "$(env_get NEODESK_IPV6)" = true ]; then
        say "IPv6:            the containers' network has IPv6 (NEODESK_IPV6), so the console sees IPv6 visitors' own addresses."
        say "                 Docker publishes the ports past ufw and firewalld on IPv6 as on IPv4: closing one there does not block it."
    fi
    say "Logs:            cd $NEODESK_DIR && docker compose logs -f neodesk"
    say "Update:          $(manager_cmd)   (or: cd $NEODESK_DIR && docker compose pull && docker compose up -d)"
    say "Settings:        $(env_file)   (then: cd $NEODESK_DIR && docker compose up -d)"
    say "Help:            $NEODESK_HELP_URL"
}

#===============================================================================
# Taking over an older install
#===============================================================================

volume_is_empty() {
    docker volume inspect "$1" >/dev/null 2>&1 || return 0
    [ -z "$(docker run --rm --entrypoint sh -v "$1:/v:ro" "$(image_ref)" -c 'ls -A /v' 2>/dev/null)" ]
}

# mount_source CONTAINER PATH: the volume name or host folder mounted at PATH
mount_source() {
    docker container inspect -f "{{range .Mounts}}{{if eq .Destination \"$2\"}}{{if .Name}}{{.Name}}{{else}}{{.Source}}{{end}}{{end}}{{end}}" "$1" 2>/dev/null || true
}

# copy_mount CONTAINER PATH VOLUME: what the container has at PATH into the
# volume, unless it is that volume
copy_mount() {
    local src
    src=$(mount_source "$1" "$2")
    [ -n "$src" ] || return 0
    [ "$src" = "$3" ] && return 0
    if ! volume_is_empty "$3"; then
        die "The volume $3 holds data already, so $2 of $1 was not copied." \
            "Remove the volume if it is not needed (docker volume rm $3) and run --adopt again." \
            "The old container is stopped; start it again: docker start $1"
    fi
    docker volume create "$3" >/dev/null
    docker run --rm --entrypoint sh --user 0 --volumes-from "$1:ro" -v "$3:/to" "$(image_ref)" \
        -c 'cp -a "$1/." /to/' sh "$2" \
        || die "Copying $2 of $1 into $3 failed; the old container is stopped but unchanged." "Start it again: docker start $1"
    say "  copied $2 of $1 ($src) into the volume $3"
}

adopt_old_install() {
    local c stamp relay
    stamp=$(date +%Y%m%d-%H%M%S)
    for c in "${OLD_CONTAINERS[@]}"; do
        container_exists "$c" || continue
        if docker container inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$c" 2>/dev/null | grep -qE '^DATABASE_URL=postgres'; then
            die "The install of container $c runs on PostgreSQL; taking it over is not supported." \
                "Update it in its own folder instead: --dir <its folder>"
        fi
    done
    step "Taking over the old install (its containers are kept, stopped and renamed)"
    for c in "${OLD_CONTAINERS[@]}"; do
        container_exists "$c" || continue
        if [ -z "$RELAY_SERVERS_SET" ]; then
            relay=$(docker container inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$c" 2>/dev/null | sed -n 's/^RELAY_SERVERS=//p' | head -n 1)
            [ -z "$relay" ] || env_set RELAY_SERVERS "$relay"
        fi
        docker stop -t 30 "$c" >/dev/null 2>&1 || true
        # The data at /opt/neodesk/data, or at /opt/rustdesk in a container
        # of an image of 3.6.0-rc.4 or older
        copy_mount "$c" /opt/neodesk/data "$DATA_VOLUME"
        copy_mount "$c" "$OLD_DATA_PATH" "$DATA_VOLUME"
        copy_mount "$c" /app/data "$CONSOLE_VOLUME"
        docker rename "$c" "$c-old-$stamp" >/dev/null
        docker update --restart=no "$c-old-$stamp" >/dev/null 2>&1 || true
        say "  kept the old container as $c-old-$stamp (remove it later: docker rm $c-old-$stamp)"
    done
}

#===============================================================================
# Other commands
#===============================================================================

require_install() {
    need_root_or_docker
    check_docker
    [ -f "$(compose_file)" ] || die "There is no install in $NEODESK_DIR." \
        "Install it: $(manager_cmd)" "Another folder: --dir <folder>"
}

do_status() {
    require_install
    compose ps
    say ""
    if container_running; then
        say "Health: $(docker container inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}no check{{end}}' "$CONTAINER")"
        print_summary
    else
        say "NeoDesk is not running. Start it: cd $NEODESK_DIR && docker compose up -d"
    fi
}

do_logs() {
    require_install
    compose logs -f --tail 200 neodesk
}

do_backup() {
    require_install
    local was_running=false file
    container_running && was_running=true
    if [ "$was_running" = true ]; then
        step "Stopping NeoDesk for the backup"
        compose stop -t 30 neodesk >/dev/null
    fi
    file=$(backup_volumes)
    [ "$was_running" = false ] || compose start neodesk >/dev/null
    ok "Backup: $file"
}

do_reset_password() {
    require_install
    container_running || die "NeoDesk is not running." "Start it: cd $NEODESK_DIR && docker compose up -d"
    local password args=()
    password=$(new_secret 12)
    [ "$RESET_TWO_FACTOR" != true ] || args+=(--reset-two-factor)
    # reset-password also removes the first password in the volume, which
    # signs nobody in any more
    if ! printf '%s\n' "$password" | docker exec -i -u neodesk "$CONTAINER" \
        /usr/local/bin/neodesk-server reset-password "${args[@]}" "$RESET_USER" >/dev/null; then
        [ "$RESET_TWO_FACTOR" != true ] || die "The password of $RESET_USER was not changed (does the account exist?)." \
            "An image older than --reset-two-factor refuses the option: update first, $(manager_cmd) update"
        die "The password of $RESET_USER was not changed (does the account exist?)."
    fi
    say "New password of ${RESET_USER}: ${BOLD}${password}${NC}"
    say "(shown this once; sign in and change it)"
    [ "$RESET_TWO_FACTOR" != true ] || say "Two-factor sign-in of $RESET_USER is off; it can be set up again under Your account."
}

do_uninstall() {
    require_install
    local answer file
    if [ "$PURGE" = true ]; then
        if [ "$ASSUME_YES" != true ]; then
            [ -t 0 ] || die "--purge deletes every device, account and the server key; add --yes to do it without a question."
            read -r -p "Delete the volumes with all data and the server key? Type delete: " answer
            [ "$answer" = delete ] || die "Nothing was deleted."
        fi
        step "Backing up the data before it is deleted"
        # NeoDesk stops; the postgres service runs on for its dump
        compose stop -t 30 neodesk >/dev/null 2>&1 || true
        file=$(backup_volumes)
        ok "Backup: $file"
        compose_quiet --profile postgres --profile guacd --profile traefik down -v --remove-orphans
        docker volume rm "$DATA_VOLUME" "$CONSOLE_VOLUME" "$PG_VOLUME" "$TRAEFIK_VOLUME" >/dev/null 2>&1 || true
        ok "NeoDesk's containers and volumes are removed."
        sync_firewall none
    else
        compose_quiet --profile postgres --profile guacd --profile traefik down --remove-orphans
        ok "NeoDesk's containers are removed."
        sync_firewall none
        say "Left on this machine:"
        local listed="" removable="" v
        for v in "$PG_VOLUME" "$TRAEFIK_VOLUME"; do
            docker volume inspect "$v" >/dev/null 2>&1 || continue
            listed+=", $v"
            removable+=" $v"
        done
        say "  volumes:  $DATA_VOLUME (database, server key), $CONSOLE_VOLUME$listed"
        say "            an install uses them again; delete them: docker volume rm $DATA_VOLUME $CONSOLE_VOLUME$removable"
    fi
    say "  image:    $(image_ref)   (delete: docker image rm $(image_ref))"
    say "  folder:   $NEODESK_DIR with .env and the backups   (delete: sudo rm -rf $NEODESK_DIR)"
}

do_set_config() {
    require_install
    step "Applying allowed settings to $(env_file)"
    # The image's own neodesk-server checks the keys against its allowlist
    docker run --rm --user "$(id -u):$(id -g)" --entrypoint /usr/local/bin/neodesk-server \
        -v "$NEODESK_DIR:/cfg" -e NEODESK_ENV_FILE=/cfg/.env \
        "$(image_ref)" config set "${MANAGED_CONFIG_CHANGES[@]}" || die "The settings were refused (output above)."
    sync_firewall
    compose_quiet up -d || die "docker compose up failed (output above)."
    wait_healthy || die "NeoDesk did not get healthy after the change."
    remember_applied "Its log: cd $NEODESK_DIR && docker compose logs neodesk"
    ok "Settings applied"
}

do_check() {
    local failures=0
    if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
        warn "Docker is not usable"; failures=$((failures + 1))
    fi
    docker compose version >/dev/null 2>&1 || { warn "Docker Compose v2 is missing"; failures=$((failures + 1)); }
    [ -f "$(compose_file)" ] || { warn "No compose file: $(compose_file)"; failures=$((failures + 1)); }
    if ! { mkdir -p "$NEODESK_DIR" 2>/dev/null && [ -w "$NEODESK_DIR" ]; }; then
        warn "$NEODESK_DIR is not writable"; failures=$((failures + 1))
    fi
    if [ -f "$(compose_file)" ] && ! compose config --quiet 2>/dev/null; then
        warn "The compose configuration is invalid"; failures=$((failures + 1))
    fi
    if [ "$failures" -eq 0 ]; then
        ok "Docker, Compose and $NEODESK_DIR are usable"
        return 0
    fi
    return 1
}

do_repair_permissions() {
    require_install
    local uid gid v
    uid="${PUID:-$(env_get PUID)}"
    uid="${uid:-10001}"
    gid="${PGID:-$(env_get PGID)}"
    gid="${gid:-10001}"
    for v in "$DATA_VOLUME" "$CONSOLE_VOLUME"; do
        docker volume inspect "$v" >/dev/null 2>&1 || continue
        docker run --rm --entrypoint sh --user 0 -v "$v:/v" "$(image_ref)" -c "chown -R $uid:$gid /v && chmod -R u+rwX /v" \
            && ok "Owner of $v: $uid:$gid"
    done
}

do_rescue() {
    do_repair_permissions
    compose_quiet up -d || true
    if wait_healthy; then ok "NeoDesk runs"; else warn "NeoDesk is not healthy; see the diagnostics below."; fi
    do_diagnose
}

do_diagnose() {
    local port path
    if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
        say "Docker is not usable on this machine."
        return 0
    fi
    say "Install folder: $NEODESK_DIR"
    if [ -f "$(compose_file)" ]; then compose ps 2>/dev/null || true; else say "No compose file there."; fi
    say ""
    say "Last log lines of $CONTAINER:"
    docker logs --tail 30 "$CONTAINER" 2>&1 || say "  (no container $CONTAINER)"
    say ""
    for port in "$(console_port)" 21121; do
        path=health
        [ "$port" = 21121 ] && path=api/health
        if answers "http://127.0.0.1:${port}/${path}"; then say "Port $port: answers"; else say "Port $port: no answer"; fi
    done
    docker volume ls --format '{{.Name}}' 2>/dev/null | grep -E '^neodesk' | sed 's/^/Volume: /' || true
}

do_menu() {
    local choice
    while true; do
        say ""
        say "NeoDesk on Docker ($NEODESK_DIR)"
        say "  1) Install or update       5) Reset a password"
        say "  2) Status                  6) Move to PostgreSQL"
        say "  3) Logs                    7) Diagnostics"
        say "  4) Backup                  8) Uninstall (keeps the data)"
        say "  0) Quit"
        read -r -p "Choice: " choice || return 0
        case "$choice" in
            1) (COMMAND=install; do_install) || true ;;
            2) (do_status) || true ;;
            3) (do_logs) || true ;;
            4) (do_backup) || true ;;
            5) (do_reset_password) || true ;;
            6) (COMMAND=postgres; do_postgres) || true ;;
            7) (do_diagnose) || true ;;
            8) (do_uninstall) || true ;;
            0|q|"") return 0 ;;
        esac
    done
}

#===============================================================================
# SQLite to PostgreSQL
#===============================================================================

# The server's migrate command (sqlite2pg moves every table of the server
# and the console); an image older than the command answers its -h with 2
MIGRATE_TOOL="/usr/local/bin/neodesk-server migrate"

# wait_postgres: the postgres service answers within a minute
wait_postgres() {
    local waited=0
    while [ "$waited" -lt 60 ]; do
        [ "$(docker container inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$PG_CONTAINER" 2>/dev/null || true)" = healthy ] && return 0
        sleep 2
        waited=$((waited + 2))
    done
    return 1
}

# back_to_sqlite MESSAGE [HINT...]: the install as it was, on SQLite, and
# the error
back_to_sqlite() {
    env_unset DATABASE_URL
    env_unset DB_TYPE
    profile_off postgres
    compose --profile postgres stop -t 10 postgres >/dev/null 2>&1 || true
    compose_quiet up -d neodesk || true
    wait_healthy || warn "NeoDesk on SQLite did not answer either; its log: cd $NEODESK_DIR && docker compose logs neodesk"
    die "$@"
}

# do_postgres: moves the install from SQLite to the postgres service with
# the server's own tool (sqlite2pg: every table of the server and the
# console, ids kept). Declining the move changes nothing; a failed move
# or a server that does not get healthy on PostgreSQL leaves it on SQLite.
do_postgres() {
    require_install
    if on_postgres; then
        ok "The install runs on PostgreSQL already."
        return 0
    fi
    container_exists "$CONTAINER" || die "NeoDesk is not installed in $NEODESK_DIR yet." \
        "Install it on PostgreSQL right away: $(manager_cmd) --postgres"
    local image uid gid pass out
    image=$(docker container inspect -f '{{.Config.Image}}' "$CONTAINER")
    docker run --rm --entrypoint sh "$image" -c "$MIGRATE_TOOL -h" >/dev/null 2>&1 \
        || die "The image $image has no move tool yet." "Update first: $(manager_cmd), then run this again."

    say "This moves every device, account and setting from SQLite into a PostgreSQL"
    say "container (neodesk-postgres, volume $PG_VOLUME). NeoDesk stops for it;"
    say "the data volumes are backed up first, and the SQLite file stays as it is."
    if [ "$MOVE_DATA" = no ] || ! confirm "Move the data into PostgreSQL? Without the move the install stays on SQLite." y; then
        say "Nothing changed: the install stays on SQLite."
        return 0
    fi

    if docker volume inspect "$PG_VOLUME" >/dev/null 2>&1; then
        [ "$OVERWRITE_POSTGRES" = true ] || die "The volume $PG_VOLUME holds a PostgreSQL database from before; nothing was changed." \
            "Delete it and move again: $(manager_cmd) postgres --overwrite-postgres"
        compose --profile postgres rm -sf postgres >/dev/null 2>&1 || true
        docker volume rm "$PG_VOLUME" >/dev/null || die "The volume $PG_VOLUME could not be deleted (is a container using it?)."
        env_unset POSTGRES_PASSWORD
    fi
    pass=$(env_get POSTGRES_PASSWORD)
    [ -n "$pass" ] || pass=$(new_secret 24)
    env_set POSTGRES_PASSWORD "$pass"

    step "Stopping NeoDesk for the backup and the move"
    compose stop -t 30 neodesk >/dev/null 2>&1 || true
    local backup
    backup=$(backup_volumes)
    ok "Backup: $backup"

    step "Starting PostgreSQL"
    compose_quiet --profile postgres up -d postgres || back_to_sqlite "PostgreSQL did not start; the install stays on SQLite." \
        "Its log: cd $NEODESK_DIR && docker compose logs postgres"
    wait_postgres || back_to_sqlite "PostgreSQL did not get ready within a minute; the install stays on SQLite." \
        "Its log: cd $NEODESK_DIR && docker compose logs postgres"

    step "Moving the data (the server's sqlite2pg)"
    uid=$(env_get PUID)
    gid=$(env_get PGID)
    # The address reaches the tool through the container's environment,
    # not its arguments on this machine
    if ! out=$(DATABASE_URL="$(postgres_url "$pass")" compose run --rm --no-deps -T --user "${uid:-10001}:${gid:-10001}" \
        --entrypoint sh neodesk -c "exec $MIGRATE_TOOL -mode sqlite2pg -src \"\$DB_PATH\" -dst \"\$DATABASE_URL\"" 2>&1); then
        printf '%s\n' "$out" >&2
        back_to_sqlite "The move failed (output above); the install stays on SQLite and nothing of it changed." \
            "Run it again after the cause is fixed: $(manager_cmd) postgres --overwrite-postgres"
    fi
    printf '%s\n' "$out" | grep -E 'Migration complete|Backup created' || true

    step "Starting NeoDesk on PostgreSQL"
    profile_on postgres
    use_database "$(postgres_url "$pass")"
    compose_quiet up -d || true
    if ! wait_healthy; then
        local log
        log=$(save_failed_log)
        back_to_sqlite "NeoDesk did not get healthy on PostgreSQL; it runs on SQLite again with its data as it was." \
            "The failed start's log: $log"
    fi
    remember_applied
    ok "NeoDesk runs on PostgreSQL. The SQLite file stays in the volume $DATA_VOLUME; the backup is $backup."
    print_summary
}

main() {
    parse_args "$@"
    case "$COMMAND" in install|update|menu) print_header ;; esac
    case "$COMMAND" in
        install|update) do_install ;;
        status) do_status ;;
        logs) do_logs ;;
        backup) do_backup ;;
        reset-password) do_reset_password ;;
        postgres) do_postgres ;;
        uninstall) do_uninstall ;;
        menu) do_menu ;;
        rescue) do_rescue ;;
        diagnose) do_diagnose ;;
        repair-permissions) do_repair_permissions ;;
        check) do_check ;;
        set-config) do_set_config ;;
    esac
}

# Run (tests source the functions with NEODESK_DOCKER_SOURCED=1)
if [ "${NEODESK_DOCKER_SOURCED:-0}" != 1 ]; then
    main "$@"
fi
