#Requires -RunAsAdministrator

<#
.SYNOPSIS
    NeoDesk Console Manager v3.6.7 - All-in-One Interactive Tool for Windows

.DESCRIPTION
    Features:
      - Fresh installation: one service, NeoDeskServer, that serves the
        signal and relay server, the API and the web console
      - Minimal installation (the same server with its web console off)
      - Update an installation (release binaries checked by SHA-256 and,
        from the second install on, the release signature)
      - Repair/fix issues (enhanced with graceful shutdown)
      - Validate installation
      - Backup & restore
      - Reset admin password
      - Build & deploy server (rebuild Go binary with rollback)
      - Full diagnostics
      - SHA-256 and signature checks of release binaries
      - Auto mode (non-interactive)
      - Enhanced service management with health verification
      - Port conflict detection
      - Fixed ban system (device-specific, not IP-based)
      - RustDesk Client API (login, address book sync)
      - TOTP Two-Factor Authentication
      - SSL/TLS certificate configuration
      - PostgreSQL database support
      - SQLite to PostgreSQL migration
      - CDAP (Custom Device API Protocol) support

.PARAMETER Auto
    Run installation in automatic mode (non-interactive)

.PARAMETER Uninstall
    Stop services and remove the native installation; data is preserved by default

.PARAMETER Purge
    With -Uninstall, also remove installation data and keys

.PARAMETER SkipVerify
    Skip the SHA-256 and signature checks of a downloaded binary

.PARAMETER Update
    Update without questions.

.PARAMETER Binary
    Install this neodesk-server.exe instead of the release.

.PARAMETER FromSource
    Build neodesk-server.exe from this checkout (needs Go, and Node.js
    unless web-ui\build exists).

.PARAMETER Channel
    Release channel: 'stable' (default, the newest release) or 'dev' (the
    development build). The install keeps it for later updates. Without
    it, a repository with no stable release yet installs 'dev'.

.PARAMETER Protocol
    Set protocol mode: 'http' or 'https'

.PARAMETER PostgreSQL
    Use PostgreSQL instead of SQLite

.PARAMETER PgUri
    PostgreSQL connection URI (implies -PostgreSQL)

.PARAMETER RelayMode
    Relay IP selection mode: 'auto' (detect public IP, default), 'local'/'lan'
    (use the server's LAN IP for LAN-only deployments), or 'public'/'wan'
    (force public IP detection). Overridden by -RelayServers / RELAY_SERVERS.

.PARAMETER RelayServers
    Force a fixed relay server address (IP or host[:port]). Always overrides
    -RelayMode. Equivalent to the RELAY_SERVERS environment variable.

.PARAMETER ResetPassword
    Give the account admin of the web console a new password without
    questions: ADMIN_PASSWORD, else a random one, shown once.

.PARAMETER ResetTwoFactor
    With -ResetPassword (implied): also turn off two-factor sign-in of admin
    and delete its authenticator secret and recovery codes, for an admin
    who lost both. Where two-factor sign-in is required, admin sets it up
    again at the next sign-in. Needs a neodesk-server that has
    reset-password --reset-two-factor.

.PARAMETER RunAsRoot
    Run the Windows service NeoDeskServer as LocalSystem instead of its own
    low-privilege account NT SERVICE\NeoDeskServer.

.PARAMETER CheckPermissions
    Report whether NeoDesk can update files, change configuration and control services.

.PARAMETER RepairPermissions
    Repair NeoDesk ACLs and recheck management capabilities.

.PARAMETER SetConfig
    Apply one or more allowlisted .env settings as KEY=VALUE.

.PARAMETER Minimal
    Install the server with its web console off (CONSOLE_PORT=0 in .env).

.PARAMETER Node
    Make this machine a relay node of a site instead of a server: the
    service NeoDeskRelayNode in C:\NeoDeskRelayNode, the server binary in
    node mode without database or console. A server install here stays as
    it is. Run again to update the node; with -Uninstall it is removed
    (-Purge also removes its key).

.PARAMETER Join
    With -Node: the join string the console shows under Sites (the first
    install only).

.PARAMETER LanAddr
    With -Node: host:port devices in the LAN dial the relay at (default:
    this machine's LAN address, port 21117).

.PARAMETER PublicAddr
    With -Node: host:port devices outside the LAN dial the relay at,
    through a port forward (default: none, only LAN devices use the node).

.PARAMETER Help
    Show this help: every parameter, and the environment variables
    ADMIN_PASSWORD, RELAY_SERVERS, RELAY_MODE, POSTGRESQL_URI,
    POSTGRESQL_USER, POSTGRESQL_PASS, POSTGRESQL_HOST, POSTGRESQL_PORT,
    POSTGRESQL_DB, UPDATE_GITHUB_BRANCH, UPDATE_GITHUB_OWNER,
    UPDATE_GITHUB_REPO, RELEASE_BASE_URL, SSL_DOMAIN, RUSTDESK_PATH,
    CONSOLE_PATH, BACKUP_DIR, GO_API_PORT, CLIENT_API_PORT,
    STORE_ADMIN_CREDENTIALS and NEODESK_RUN_AS_ROOT.

.EXAMPLE
    .\neodesk.ps1
    Interactive mode

.EXAMPLE
    .\neodesk.ps1 -Auto
    Automatic installation with SQLite, or an update of the install that is there

.EXAMPLE
    .\neodesk.ps1 -Update
    Update the install

.EXAMPLE
    .\neodesk.ps1 -Auto -PostgreSQL
    Automatic installation with PostgreSQL

.EXAMPLE
    .\neodesk.ps1 -Auto -RelayMode local
    Automatic LAN-only installation (relay uses the server's local IP)

.EXAMPLE
    .\neodesk.ps1 -Auto -RelayServers 203.0.113.10
    Automatic installation with a fixed public relay address

.EXAMPLE
    .\neodesk.ps1 -SkipVerify
    Skip binary verification

.EXAMPLE
    .\neodesk.ps1 -Node -Join nd1.xxxx -PublicAddr 203.0.113.20:21117
    Make this machine a relay node of the site the join string names

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File C:\NeoDesk\neodesk.ps1 -ResetPassword
    A new password for admin, from any elevated window whatever the
    machine's execution policy

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File C:\NeoDesk\neodesk.ps1 -ResetTwoFactor
    A new password for admin and its two-factor sign-in off, for an admin
    who lost the authenticator and the recovery codes
#>

param(
    [switch]$Auto,
    [switch]$Uninstall,
    [switch]$Purge,
    [switch]$SkipVerify,
    [switch]$Minimal,
    [switch]$NodeJs,  # No longer needed: the web console is part of the server
    [switch]$Update,
    [string]$Binary = "",
    [ValidateSet('stable', 'dev', '')]
    [string]$Channel = "",
    [switch]$FromSource,
    [switch]$PostgreSQL,
    [string]$PgUri = "",
    [ValidateSet('http', 'https', '')]
    [string]$Protocol = "",
    [ValidateSet('auto', 'local', 'lan', 'public', 'wan', '')]
    [string]$RelayMode = "",
    [string]$RelayServers = "",
    [switch]$ResetPassword,
    [switch]$ResetTwoFactor,
    [switch]$RunAsRoot,
    [switch]$CheckPermissions,
    [switch]$RepairPermissions,
    [string[]]$SetConfig = @(),
    [switch]$Flask,  # No longer needed: the web console is part of the server
    [switch]$Node,
    [string]$Join = "",
    [string]$LanAddr = "",
    [string]$PublicAddr = "",
    [switch]$Help
)

if ($Help) {
    Get-Help $MyInvocation.MyCommand.Path -Detailed
    exit 0
}

#===============================================================================
# Configuration
#===============================================================================

$script:VERSION = "3.6.7"
# Where people ask for help: the NeoDesk Discord
$script:HELP_URL = "https://discord.gg/nwERSawufr"
$script:ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
# The checkout's root when the script runs from a checkout (its install\
# folder), else the script's own folder: the source folders
# (neodesk-server, web-ui, remote-gateway) are there. A copy elsewhere has
# none of them.
function Get-RepoDir {
    $dir = $script:ScriptDir
    if ($dir -and (Split-Path -Leaf $dir) -eq "install" -and (Test-Path (Join-Path (Split-Path -Parent $dir) "neodesk-server"))) {
        return (Split-Path -Parent $dir)
    }
    return $dir
}
# This file; empty when the script runs from Invoke-Expression
$script:SELF_PATH = $MyInvocation.MyCommand.Path

# Auto mode flags
$script:AUTO_MODE = $Auto
$script:UNINSTALL_MODE = $Uninstall
$script:PURGE_MODE = $Purge
$script:SKIP_VERIFY = $SkipVerify
$script:MINIMAL_MODE = $Minimal
$script:CHECK_PERMISSIONS = $CheckPermissions
$script:REPAIR_PERMISSIONS = $RepairPermissions
$script:MANAGED_CONFIG_CHANGES = @($SetConfig)
$script:UPDATE_MODE = $Update
# -ResetTwoFactor is a reset of the password that also turns two-factor
# sign-in off, so it means -ResetPassword too
$script:RESET_PASSWORD_MODE = $ResetPassword -or $ResetTwoFactor
$script:RESET_TWO_FACTOR = [bool]$ResetTwoFactor
# Windows PowerShell 5.1 downloads many times slower while it draws
# Invoke-WebRequest's progress bar
$ProgressPreference = 'SilentlyContinue'
# Where the server binary comes from: a file (-Binary), a build of this
# checkout (-FromSource), else the release of the update channel.
$script:BINARY_FILE = if ($Binary) { (Resolve-Path $Binary -ErrorAction Stop).Path } else { "" }
$script:FROM_SOURCE = [bool]$FromSource
$script:STAGED_SERVER_DIR = ""
$script:STAGED_SERVER_BINARY = ""
$script:STAGED_SERVER_VERSION = ""

# The installer needs Administrator. The server is the Windows service
# NeoDeskServer under its own virtual account (NT SERVICE\NeoDeskServer),
# or LocalSystem with -RunAsRoot or NEODESK_RUN_AS_ROOT=1.
$script:RUN_AS_ROOT = $RunAsRoot -or ($env:NEODESK_RUN_AS_ROOT -eq "1") -or ($env:NEODESK_RUN_AS_ROOT -eq "true")

if ($NodeJs -or $Flask) {
    Write-Host "NOTE: -NodeJs and -Flask are no longer needed: the web console is part of neodesk-server" -ForegroundColor Yellow
}

# Database configuration. -PgUri names a PostgreSQL database, so it means
# -PostgreSQL too.
function Test-PostgreSQLWanted([bool]$Switch, [string]$Uri) {
    return $Switch -or -not [string]::IsNullOrEmpty($Uri) -or ($env:USE_POSTGRESQL -eq "true")
}
$script:USE_POSTGRESQL = Test-PostgreSQLWanted -Switch $PostgreSQL.IsPresent -Uri $PgUri
$script:POSTGRESQL_URI = if ($PgUri) { $PgUri } elseif ($env:POSTGRESQL_URI) { $env:POSTGRESQL_URI } else { "" }
$script:POSTGRESQL_USER = if ($env:POSTGRESQL_USER) { $env:POSTGRESQL_USER } else { "neodesk" }
$script:POSTGRESQL_PASS = if ($env:POSTGRESQL_PASS) { $env:POSTGRESQL_PASS } else { "" }
$script:POSTGRESQL_DB = if ($env:POSTGRESQL_DB) { $env:POSTGRESQL_DB } else { "neodesk" }
$script:POSTGRESQL_HOST = if ($env:POSTGRESQL_HOST) { $env:POSTGRESQL_HOST } else { "localhost" }
$script:POSTGRESQL_PORT = if ($env:POSTGRESQL_PORT) { $env:POSTGRESQL_PORT } else { "5432" }

# Relay server configuration
#   auto   - detect public IP (default, best for internet-facing servers)
#   local  - use the server's LAN IP (best for LAN-only deployments)
#   public - force public IP detection
# RELAY_SERVERS env var (or -RelayServers) always overrides this with a fixed value.
$script:RELAY_MODE = if ($RelayMode) { $RelayMode } elseif ($env:RELAY_MODE) { $env:RELAY_MODE } else { "auto" }
if ($script:RELAY_MODE -eq "lan") { $script:RELAY_MODE = "local" }
if ($script:RELAY_MODE -eq "wan") { $script:RELAY_MODE = "public" }
$script:RELAY_SERVERS = if ($RelayServers) { $RelayServers } elseif ($env:RELAY_SERVERS) { $env:RELAY_SERVERS } else { "" }

# Go server configuration
$script:GO_SERVER_SOURCE = Join-Path (Get-RepoDir) "neodesk-server"
# Must match the toolchain pinned in neodesk-server/go.mod.
$script:GO_MIN_VERSION = "1.26.11"
$script:GO_DOWNLOAD_VERSION = "1.26.11"
# Legacy Rust checksums (deprecated, kept for migration purposes)
$script:HBBS_WINDOWS_X86_64_SHA256 = "B790FA44CAC7482A057ED322412F6D178FB33F3B05327BFA753416E9879BD62F"
$script:HBBR_WINDOWS_X86_64_SHA256 = "368C71E8D3AEF4C5C65177FBBBB99EA045661697A89CB7C2A703759C575E8E9F"

# Default paths
$script:RUSTDESK_PATH = if ($env:RUSTDESK_PATH) { $env:RUSTDESK_PATH } else { "C:\NeoDesk" }
$script:CONSOLE_PATH = if ($env:CONSOLE_PATH) { $env:CONSOLE_PATH } else { "C:\NeoDeskConsole" }
$script:BACKUP_DIR = if ($env:BACKUP_DIR) { $env:BACKUP_DIR } else { "C:\NeoDesk-Backups" }
$script:DB_PATH = "$script:RUSTDESK_PATH\db_v2.sqlite3"

# API configuration
$script:GO_API_PORT = if ($env:GO_API_PORT) { $env:GO_API_PORT } elseif ($env:API_PORT) { $env:API_PORT } else { "21114" }
$script:CLIENT_API_PORT = if ($env:CLIENT_API_PORT) { $env:CLIENT_API_PORT } else { "21121" }
$script:API_PORT = $script:GO_API_PORT
$script:STORE_ADMIN_CREDENTIALS = ($env:STORE_ADMIN_CREDENTIALS -eq "true")

# Common installation paths to search
$script:COMMON_RUSTDESK_PATHS = @(
    "C:\NeoDesk",
    "C:\RustDesk",
    "C:\Program Files\NeoDesk",
    "C:\Program Files\RustDesk",
    "$env:LOCALAPPDATA\NeoDesk"
)

$script:COMMON_CONSOLE_PATHS = @(
    "C:\NeoDeskConsole",
    "C:\Program Files\NeoDeskConsole",
    "$env:LOCALAPPDATA\NeoDeskConsole"
)

# Service names
$script:SERVER_SERVICE = "NeoDeskServer"    # Go server (replaces HBBS + HBBR)
$script:HBBS_SERVICE = "NeoDeskSignal"      # Legacy Rust signal
$script:HBBR_SERVICE = "NeoDeskRelay"       # Legacy Rust relay
$script:CONSOLE_SERVICE = "NeoDeskConsole"

# Status variables
$script:INSTALL_STATUS = "none"
$script:SERVER_RUNNING = $false  # Go server
$script:HBBS_RUNNING = $false    # Legacy Rust
$script:HBBR_RUNNING = $false    # Legacy Rust
$script:CONSOLE_RUNNING = $false
$script:BINARIES_OK = $false
$script:DATABASE_OK = $false
$script:CONSOLE_TYPE = "none"  # none, nodejs
$script:SERVER_TYPE = "none"    # none, go, rust
# Logging
$script:LOG_FILE = "$env:TEMP\neodesk_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

#===============================================================================
# Helper Functions
#===============================================================================

function Write-Log {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "[$timestamp] $Message" | Out-File -FilePath $script:LOG_FILE -Append -Encoding UTF8
}

# Get-ColorMode: how this run colours its output, decided on first use.
#   vt       24-bit colour through escape sequences: the console of
#            Windows 10 1703 and newer, where PowerShell turns them on,
#            and Windows Terminal
#   console  the 16 console colours: older consoles and other hosts
#   none     plain text: the output goes to a file or a pipe, NO_COLOR is
#            set, or TERM is dumb
function Get-ColorMode {
    if (-not $script:COLOR_MODE) {
        $script:COLOR_MODE = 'console'
        if ($env:NO_COLOR -or $env:TERM -eq 'dumb' -or (Test-OutputRedirected)) {
            $script:COLOR_MODE = 'none'
        } elseif ($Host.Name -eq 'ConsoleHost' -and $Host.UI.SupportsVirtualTerminal -and
            ($PSVersionTable.PSEdition -eq 'Core' -or [Environment]::OSVersion.Version.Build -ge 15063)) {
            $script:COLOR_MODE = 'vt'
        }
    }
    return $script:COLOR_MODE
}

# Test-OutputRedirected: the output goes to a file or a pipe
function Test-OutputRedirected {
    return [Console]::IsOutputRedirected
}

# Write-Status SYMBOL KIND MESSAGE: a status line, SYMBOL in the colour of
# KIND (ok, error, warning, info; a step keeps the text colour). The
# 24-bit colours keep at least 3.8:1 on black, on PowerShell's blue
# (#012456) and on white; the console colours follow the background.
function Write-Status {
    param([string]$Symbol, [string]$Kind, [string]$Message)
    $mode = Get-ColorMode
    if ($Kind -eq 'step' -or $mode -eq 'none') {
        Write-Host "$Symbol $Message"
    } elseif ($mode -eq 'vt') {
        $esc = [char]27
        $rgb = @{ ok = '37;149;46'; error = '228;75;69'; warning = '178;116;9'; info = '26;143;147' }[$Kind]
        Write-Host "$esc[38;2;${rgb}m$Symbol$esc[39m $Message"
    } else {
        $light = $false
        try { $light = @('White', 'Gray', 'Yellow', 'Cyan', 'Green') -contains [string]$Host.UI.RawUI.BackgroundColor } catch { }
        $colors = @{ ok = 'Green'; error = 'Red'; warning = 'Yellow'; info = 'Cyan' }
        if ($light) { $colors = @{ ok = 'DarkGreen'; error = 'DarkRed'; warning = 'DarkYellow'; info = 'DarkCyan' } }
        Write-Host "$Symbol " -ForegroundColor $colors[$Kind] -NoNewline
        Write-Host $Message
    }
}

# Get-ConsoleWidth: the console's width in columns, 80 when the host
# can't say
function Get-ConsoleWidth {
    try { return $Host.UI.RawUI.WindowSize.Width } catch { return 80 }
}

# Write-Logo TITLE: the NeoDesk logo, drawn in half blocks, with TITLE
# on the second line under the wordmark. The lines carry colour tokens
# {N}: $vtCodes[N] is the code in 24-bit, $fgNames[N] and $bgNames[N]
# the console colours. A console narrower than the logo gets the name
# and TITLE on one line.
function Write-Logo {
    param([string]$Title)
    $lines = @(
        '             {0}▄▄███████▄▄',
        '           {0}▄█████████████▄',
        '         {0}▄█████████████████▄',
        '        {0}▄███████████████████▄                                                  {1}▄▄▄                          ▄▄▄',
        '  {2}▄▄████{3}█████████{4}▀▀{0}██████████                                                  {1}███                          ███',
        ' {2}███████{3}████████████{0}█████████    {1}▄▄▄▄▄ ▄▄▄▄▄     ▄▄▄▄▄▄▄     ▄▄▄▄▄▄▄     ▄▄▄▄▄▄███     ▄▄▄▄▄▄▄    ▄▄▄▄▄▄▄▄  ███    ▄▄▄▄',
        '{2}████████{3}█████████████{0}████████    {1}██████▀▀▀███▄ ▄███▀▀▀███▄ ▄███▀▀▀███▄ ▄███▀▀▀████   ▄███▀▀▀███▄ ███▀▀▀▀███ ███  ▄███▀',
        '{2}█████████{3}████████████{0}███████       {1}███     ███ ███▄▄▄▄▄███ ███     ███ ███     ███   ███▄▄▄▄▄███ ███▄▄▄▄▄▄  ███▄███▀',
        '{2}██████████{5}▀{3}██████████{0}█████▀        {1}███     ███ ███▀▀▀▀▀▀▀▀ ███     ███ ███     ███   ███▀▀▀▀▀▀▀▀ ▀█████████ ███▀▀███▄',
        '{2}████████████{5}▀{3}████████{0}███▀          {1}███     ███ ███▄   ▄▄▄▄ ███▄   ▄███ ███▄   ▄███▄▄ ███▄   ▄▄▄▄ ▄▄▄    ███ ███  ▀███▄',
        '{2}███████████████{5}▀▀▀▀▀▀{0}▀             {1}███     ███  ▀███████▀   ▀███████▀   ▀█████▀█████  ▀███████▀  ▀████████▀ ███   ▀███▄',
        '{2}█████████████████████',
        '{2}▀███████████████████▀',
        ' {2}▀█████████████████▀',
        '    {2}▀▀▀▀▀▀▀▀▀▀▀▀▀'
    )
    $vtCodes = @('38;2;163;230;53', '38;2;228;231;231', '38;2;88;166;255', '38;2;63;208;196', '38;2;163;230;53;48;2;63;208;196', '38;2;63;208;196;48;2;88;166;255')
    $fgNames = @('Green', '', 'Cyan', 'DarkCyan', 'Green', 'DarkCyan')
    $bgNames = @('', '', '', '', 'DarkCyan', 'Cyan')
    $columns = Get-ConsoleWidth
    if ($columns -gt 0 -and $columns -lt 119) {
        Write-Host "NeoDesk $Title"
        return
    }
    $vt = (Get-ColorMode) -eq 'vt'
    $esc = [char]27
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $after = if ($i -eq 12) { '              ' + $Title } else { '' }
        # Text and token numbers take turns: text, number, text, ...
        $parts = [regex]::Split($lines[$i], '\{(\d+)\}')
        if ($vt) {
            $text = $parts[0]
            for ($p = 1; $p -lt $parts.Count; $p += 2) {
                $text += "$esc[0m$esc[$($vtCodes[[int]$parts[$p]])m" + $parts[$p + 1]
            }
            Write-Host "$text$esc[0m$after"
            continue
        }
        Write-Host $parts[0] -NoNewline
        for ($p = 1; $p -lt $parts.Count; $p += 2) {
            $n = [int]$parts[$p]
            $colours = @{}
            if ($fgNames[$n]) { $colours.ForegroundColor = $fgNames[$n] }
            if ($bgNames[$n]) { $colours.BackgroundColor = $bgNames[$n] }
            Write-Host $parts[$p + 1] -NoNewline @colours
        }
        Write-Host $after
    }
}

# Print-Header: clears the console and shows the NeoDesk logo with
# what this script is and its version. Without colour (a file,
# a pipe, NO_COLOR) it is one plain line.
function Print-Header {
    $title = "Server installer $($script:VERSION)"
    if ((Get-ColorMode) -eq 'none') {
        Write-Host "NeoDesk $title"
    } else {
        Clear-Host
        Write-Host ''
        Write-Logo $title
        Write-Host ''
    }
    Write-Status '[!]' warning 'Windows support is experimental.'
    Write-Host '    Linux is the main platform. Report problems at https://github.com/neodeskapp/neodesk/issues'
    Write-Host ''
}

function Print-Success {
    param([string]$Message)
    Write-Status '[OK]' ok $Message
    Write-Log "SUCCESS: $Message"
}

function Print-Error {
    param([string]$Message)
    Write-Status '[X]' error $Message
    Write-Log "ERROR: $Message"
}

function Print-Warning {
    param([string]$Message)
    Write-Status '[!]' warning $Message
    Write-Log "WARNING: $Message"
}

function Print-Info {
    param([string]$Message)
    Write-Status '[i]' info $Message
    Write-Log "INFO: $Message"
}

function Print-Step {
    param([string]$Message)
    Write-Status '[>]' step $Message
    Write-Log "STEP: $Message"
}

#===============================================================================
# Management capabilities and allowlisted runtime configuration
#===============================================================================

function Test-ManagementCapabilities {
    Print-Step "Checking NeoDesk management capabilities..."
    $ok = Invoke-ManagementCli -Action "check"
    if ($ok) {
        Print-Success "NeoDesk management capabilities are ready"
    } else {
        Print-Warning "One or more management capabilities are blocked; see the report above"
    }
    return $ok
}

function Press-Enter {
    Write-Host ""
    Write-Host "Press Enter to continue..." -ForegroundColor Cyan
    if (-not $script:AUTO_MODE) {
        $null = Read-Host
    }
}

function Confirm-Action {
    param([string]$Prompt = "Continue?")
    if ($script:AUTO_MODE) { return $true }
    
    $response = Read-Host "$Prompt [y/N]"
    return $response -match "^[YyTt]"
}

#===============================================================================
# Interactive TUI (arrow-key navigable menu) — no external dependencies
#===============================================================================
$script:TUI_RESULT = -1
$script:MENU_CHOICE = ''

function Test-TuiAvailable {
    if ($env:NEODESK_CLASSIC_MENU -eq '1') { return $false }
    if ($script:AUTO_MODE) { return $false }
    try {
        if ([Console]::IsInputRedirected -or [Console]::IsOutputRedirected) { return $false }
    } catch { return $false }
    return $true
}

# Invoke-TuiSelect -Title T -Subtitle S -Items @("Label`tDesc", ...)
# Navigation: Up/Down or k/j to move, Enter/Right to choose, q/Esc/0 to cancel.
# Returns $true and sets $script:TUI_RESULT on selection, $false on cancel.
function Invoke-TuiSelect {
    param(
        [string]$Title,
        [string]$Subtitle,
        [string[]]$Items
    )
    $script:TUI_RESULT = -1
    $count = $Items.Count
    if (-not (Test-TuiAvailable) -or $count -eq 0) { return $false }

    $sel = 0
    try { [Console]::CursorVisible = $false } catch {}
    Clear-Host
    try {
        while ($true) {
            try { [Console]::SetCursorPosition(0, 0) } catch {}
            Write-Host "+--------------------------------------------------------------+" -ForegroundColor Cyan
            Write-Host ("| {0,-60} |" -f $Title) -ForegroundColor White
            if ($Subtitle) { Write-Host ("| {0,-60} |" -f $Subtitle) -ForegroundColor Gray }
            Write-Host "+--------------------------------------------------------------+" -ForegroundColor Cyan
            Write-Host ""

            for ($i = 0; $i -lt $count; $i++) {
                $parts = $Items[$i] -split "`t", 2
                $label = $parts[0]
                $desc  = if ($parts.Count -gt 1) { $parts[1] } else { '' }
                if ($i -eq $sel) {
                    $line = ("  > {0,-30}{1}" -f $label, $desc)
                    Write-Host ($line.PadRight(78)) -ForegroundColor Green
                } else {
                    $line = ("    {0,-30}{1}" -f $label, $desc)
                    Write-Host ($line.PadRight(78)) -ForegroundColor White
                }
            }

            Write-Host ""
            Write-Host ("  Up/Down navigate   Enter select   q/Esc back".PadRight(78)) -ForegroundColor Gray

            $key = [Console]::ReadKey($true)
            switch ($key.Key) {
                'UpArrow'    { $sel = (($sel - 1 + $count) % $count) }
                'DownArrow'  { $sel = (($sel + 1) % $count) }
                'Enter'      { $script:TUI_RESULT = $sel; return $true }
                'RightArrow' { $script:TUI_RESULT = $sel; return $true }
                'Escape'     { return $false }
                default {
                    $ch = $key.KeyChar
                    if     ($ch -eq 'k') { $sel = (($sel - 1 + $count) % $count) }
                    elseif ($ch -eq 'j') { $sel = (($sel + 1) % $count) }
                    elseif ($ch -eq 'q' -or $ch -eq 'Q' -or $ch -eq '0') { return $false }
                    elseif ($ch -ge '1' -and $ch -le '9') {
                        $idx = [int]::Parse($ch) - 1
                        if ($idx -lt $count) { $script:TUI_RESULT = $idx; return $true }
                    }
                }
            }
        }
    } finally {
        try { [Console]::CursorVisible = $true } catch {}
    }
}

function Show-PanelHeader {
    param([string]$Title, [string]$Subtitle)
    Clear-Host
    Write-Host "+--------------------------------------------------------------+" -ForegroundColor Cyan
    Write-Host ("| {0,-60} |" -f $Title) -ForegroundColor White
    if ($Subtitle) { Write-Host ("| {0,-60} |" -f $Subtitle) -ForegroundColor Gray }
    Write-Host "+--------------------------------------------------------------+" -ForegroundColor Cyan
    Write-Host ""
}

# Invoke-MenuChoose -Title T -Subtitle S -Items @(...) -Returns @(...)
# Uses the arrow-key TUI when available, a styled numeric prompt otherwise.
# The chosen token is stored in $script:MENU_CHOICE; on cancel the last entry
# is returned so existing switch blocks can treat it as "back".
function Invoke-MenuChoose {
    param(
        [string]$Title,
        [string]$Subtitle,
        [string[]]$Items,
        [string[]]$Returns
    )
    $script:MENU_CHOICE = ''
    $lastIdx = $Returns.Count - 1
    if ($lastIdx -lt 0) { $lastIdx = 0 }

    if (Test-TuiAvailable) {
        if (Invoke-TuiSelect -Title $Title -Subtitle $Subtitle -Items $Items) {
            $script:MENU_CHOICE = $Returns[$script:TUI_RESULT]
        } else {
            $script:MENU_CHOICE = $Returns[$lastIdx]
        }
        return
    }

    Show-PanelHeader $Title $Subtitle
    for ($i = 0; $i -lt $Items.Count; $i++) {
        $parts = $Items[$i] -split "`t", 2
        $label = $parts[0]
        $desc  = if ($parts.Count -gt 1) { $parts[1] } else { '' }
        Write-Host ("  {0,2}) " -f $Returns[$i]) -ForegroundColor Green -NoNewline
        Write-Host ("{0,-28}" -f $label) -NoNewline
        Write-Host " $desc" -ForegroundColor Gray
    }
    Write-Host ""
    $script:MENU_CHOICE = Read-Host "  Select option"
}

function Get-PublicIP {
    # Prefer IPv4 endpoints first: many RustDesk clients cannot use IPv6-only relay.
    $endpoints = @(
        "https://ipv4.icanhazip.com",
        "https://ifconfig.me/ip",
        "https://icanhazip.com"
    )
    foreach ($url in $endpoints) {
        try {
            $ip = (Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 10).Content.Trim()
            if ($ip) { return $ip }
        } catch {}
    }
    return "127.0.0.1"
}

# Detect the server's primary LAN/private IPv4 address.
# Used for LAN-only deployments where the public IP is unreachable by clients.
function Get-LocalIP {
    try {
        # Primary: source address used to reach an external destination
        $route = Get-NetIPConfiguration -ErrorAction SilentlyContinue |
            Where-Object { $_.IPv4DefaultGateway -and $_.NetAdapter.Status -eq 'Up' } |
            Select-Object -First 1
        if ($route -and $route.IPv4Address) {
            return $route.IPv4Address.IPAddress
        }
    } catch {}
    try {
        # Fallback: first non-loopback, non-APIPA IPv4 address
        $ip = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.IPAddress -ne '127.0.0.1' -and $_.IPAddress -notlike '169.254.*' -and $_.PrefixOrigin -ne 'WellKnown' } |
            Select-Object -First 1
        if ($ip) { return $ip.IPAddress }
    } catch {}
    return "127.0.0.1"
}

function Resolve-ConnectionModeEnv {
    $mode = if ($env:CONNECTION_MODE) { $env:CONNECTION_MODE } else { "p2p_first" }
    if (-not $script:AUTO_MODE -and -not $env:CONNECTION_MODE_SET) {
        Write-Host ""
        Print-Info "Connection strategy: P2P hole punch vs relay-only routing."
        Write-Host "  1) P2P first (recommended) — try direct, fall back to relay" -ForegroundColor Cyan
        Write-Host "  2) Relay only — all sessions via relay server" -ForegroundColor Cyan
        $choice = Read-Host "  Select connection mode [1]"
        if ($choice -eq "2") { $mode = "relay_only" } else { $mode = "p2p_first" }
        Write-Host ""
    }

    $fallbackMs = if ($env:P2P_FALLBACK_MS) { $env:P2P_FALLBACK_MS } else { "2000" }
    $sameNat = if ($env:SAME_NAT_RELAY) { $env:SAME_NAT_RELAY } else { "Y" }

    if ($mode -eq "relay_only") {
        $p2pFirst = "N"
        $alwaysRelay = "Y"
    } else {
        $p2pFirst = "Y"
        $alwaysRelay = "N"
    }

    Print-Info "Connection mode: $mode (P2P_FIRST=$p2pFirst, ALWAYS_USE_RELAY=$alwaysRelay)"
    return @(
        "P2P_FIRST=$p2pFirst",
        "ALWAYS_USE_RELAY=$alwaysRelay",
        "P2P_FALLBACK_MS=$fallbackMs",
        "SAME_NAT_RELAY=$sameNat"
    )
}

# Resolve the relay server address according to RELAY_MODE / RELAY_SERVERS.
# Returns the resolved address; warnings are written to the host (not the value).
function Resolve-RelayIp {
    # Explicit override always wins
    if ($script:RELAY_SERVERS) {
        Print-Info "Using fixed relay address (RelayServers): $($script:RELAY_SERVERS)"
        return $script:RELAY_SERVERS
    }

    $ip = ""
    switch ($script:RELAY_MODE) {
        "local" {
            $ip = Get-LocalIP
            Print-Info "Relay mode 'local': using LAN IP $ip (LAN-only deployment)"
        }
        "public" {
            $ip = Get-PublicIP
            Print-Info "Relay mode 'public': using public IP $ip"
        }
        default {
            $ip = Get-PublicIP
            if ($ip -eq "127.0.0.1" -or $ip -match '^10\.' -or $ip -match '^192\.168\.' -or $ip -match '^172\.(1[6-9]|2[0-9]|3[0-1])\.') {
                Print-Warning "Auto-detected private/loopback IP: $ip"
                Print-Warning "Remote (internet) clients will NOT connect via relay with this address."
                Print-Warning "For LAN-only use this is fine. For internet access run with: -RelayServers YOUR.PUBLIC.IP"
                Print-Warning "To use the LAN IP explicitly run with: -RelayMode local"
            }
        }
    }
    return $ip
}

# Letters and digits from the system's cryptographic generator, for
# passwords and secrets.
function Generate-RandomPassword {
    param([int]$Length = 16)
    $chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $byte = New-Object byte[] 1
    $out = New-Object System.Text.StringBuilder
    try {
        while ($out.Length -lt $Length) {
            $rng.GetBytes($byte)
            # 248 is 4 times 62: a byte above it would favour the first characters
            if ($byte[0] -lt 248) { [void]$out.Append($chars[$byte[0] % $chars.Length]) }
        }
    } finally {
        $rng.Dispose()
    }
    return $out.ToString()
}

# Write or merge the console's .env from the template built into the server,
# then let upgrade-env add what the server needs (CONSOLE_PORT,
# NEODESK_ENV_FILE, the pinned ports) and comment out what it does not.
function Merge-ConsoleEnv {
    param(
        [bool]$FreshInstall = $false
    )

    $bin = Get-ServerBinaryPath
    if (-not (Test-BinaryHasSubcommands -Path $bin)) {
        Print-Error "$bin is missing or too old to write .env"
        return $false
    }
    $envFile = Join-Path $script:CONSOLE_PATH ".env"

    $sslDir = Join-Path $script:RUSTDESK_PATH "ssl"
    $dbType = "sqlite"
    $databaseUrl = Join-Path $script:RUSTDESK_PATH "db_v2.sqlite3"
    if ($script:USE_POSTGRESQL -and $script:POSTGRESQL_URI) {
        $dbType = "postgres"
        $databaseUrl = $script:POSTGRESQL_URI
    }

    $adminPassword = $env:ADMIN_PASSWORD
    $sessionSecret = ""
    if ($FreshInstall) {
        if (-not $adminPassword) {
            $adminPassword = Generate-RandomPassword
        }
        $sessionSecret = Generate-RandomPassword -Length 64
    } else {
        $sessionSecret = Get-ConsoleEnvValue -Key "SESSION_SECRET"
        if (-not $adminPassword) { $adminPassword = Get-ConsoleEnvValue -Key "DEFAULT_ADMIN_PASSWORD" }
        if (-not $sessionSecret) {
            $sessionSecret = Generate-RandomPassword -Length 64
        }
    }
    $remoteTargetVaultKey = Get-ConsoleEnvValue -Key "REMOTE_TARGET_VAULT_KEY"
    if (-not $remoteTargetVaultKey) {
        $remoteTargetVaultKey = Generate-RandomPassword -Length 64
    }

    $goPort = if ($script:GO_API_PORT) { $script:GO_API_PORT } else { 21114 }
    $clientPort = if ($script:CLIENT_API_PORT) { $script:CLIENT_API_PORT } else { 21121 }
    $subst = [ordered]@{
        RUSTDESK_DIR            = $script:RUSTDESK_PATH
        PUB_KEY_PATH            = (Join-Path $script:RUSTDESK_PATH "id_ed25519.pub")
        API_KEY_PATH            = (Join-Path $script:RUSTDESK_PATH ".api_key")
        DB_TYPE                 = $dbType
        DB_PATH                 = (Join-Path $script:RUSTDESK_PATH "db_v2.sqlite3")
        DATABASE_URL            = $databaseUrl
        DATA_DIR                = (Join-Path $script:CONSOLE_PATH "data")
        GO_API_PORT             = [string]$goPort
        HBBS_API_URL            = "http://localhost:${goPort}/api"
        NEODESK_API_URL      = "http://localhost:${goPort}/api"
        API_PORT                = [string]$clientPort
        DEFAULT_ADMIN_PASSWORD  = [string]$adminPassword
        SESSION_SECRET          = [string]$sessionSecret
        REMOTE_TARGET_VAULT_KEY = [string]$remoteTargetVaultKey
        GUACD_ADDRESS           = "127.0.0.1:4822"
        SSL_CERT_PATH           = (Join-Path $sslDir "neodesk.crt")
        SSL_KEY_PATH            = (Join-Path $sslDir "neodesk.key")
    }
    foreach ($k in $subst.Keys) { [Environment]::SetEnvironmentVariable("ND_SUBST_$k", $subst[$k], "Process") }
    $savedEnvFile = $env:NEODESK_ENV_FILE
    $env:NEODESK_ENV_FILE = $null
    try {
        $mergeArgs = @("env", "merge", "--target", $envFile, "--subst-env")
        if ($FreshInstall) { $mergeArgs += "--fresh" }
        $output = & $bin @mergeArgs 2>&1
        $mergeCode = $LASTEXITCODE
    } finally {
        foreach ($k in $subst.Keys) { [Environment]::SetEnvironmentVariable("ND_SUBST_$k", $null, "Process") }
    }
    if ($mergeCode -ne 0 -or "$output" -notmatch '"success":true') {
        $env:NEODESK_ENV_FILE = $savedEnvFile
        Print-Error "Failed to write .env (neodesk-server env merge): $output"
        return $false
    }

    # The server's database is DATABASE_URL (the template's, filled above).
    # A file that names none gets it; an older binary reads DB_URL instead
    # (its template still writes DB_TYPE), which the old services passed in
    # their environment
    if (-not (Test-BinaryReadsDatabaseUrl -Path $bin)) {
        if (-not (Get-ConsoleEnvValue -Key "DB_URL")) { Set-ConsoleEnvValue -Key "DB_URL" -Value $databaseUrl }
    } elseif (-not (Get-EnvDatabaseUrl)) {
        Use-DatabaseInEnv -Type $dbType -Address $databaseUrl
    }
    # The server makes the first admin before the console starts, and the
    # console keeps an admin it did not make: both take the same password
    if ($FreshInstall -and -not (Get-ConsoleEnvValue -Key "INIT_ADMIN_PASS")) {
        Set-ConsoleEnvValue -Key "INIT_ADMIN_PASS" -Value ([string]$adminPassword)
    }
    # A new install starts in Managed: new clients wait for approval. This
    # is only the first default; a mode saved in the console wins.
    if ($FreshInstall -and -not (Get-ConsoleEnvValue -Key "ENROLLMENT_MODE")) {
        Set-ConsoleEnvValue -Key "ENROLLMENT_MODE" -Value "managed"
    }
    # The channel the installer was given, where the server's updater reads it
    if ($script:UPDATE_GITHUB_BRANCH_GIVEN) {
        Set-ConsoleEnvValue -Key "UPDATE_GITHUB_BRANCH" -Value $script:UPDATE_GITHUB_BRANCH_GIVEN
    }

    & $bin upgrade-env --from $envFile --write --supervisor windows-service | Out-Null
    $upgradeCode = $LASTEXITCODE
    $env:NEODESK_ENV_FILE = $savedEnvFile
    if ($upgradeCode -ne 0) {
        Print-Error "neodesk-server upgrade-env could not finish .env"
        return $false
    }
    # A fresh file has no older version to keep
    if ($FreshInstall) { Remove-Item -Path "$envFile.pre-go" -Force -ErrorAction SilentlyContinue }

    if ($FreshInstall) {
        Print-Info "Created .env configuration file (fresh install)"
    } else {
        Print-Info "Merged new .env keys (existing settings preserved)"
    }
    return $true
}

# The value the first line setting $Key has in the console's .env, or "".
function Get-ConsoleEnvValue {
    param([string]$Key)
    $envFile = Join-Path $script:CONSOLE_PATH ".env"
    if (-not (Test-Path $envFile)) { return "" }
    foreach ($line in Get-Content $envFile) {
        if ($line -match "^$([regex]::Escape($Key))=(.*)$") { return $Matches[1].Trim() }
    }
    return ""
}

# True for a postgres:// or postgresql:// address.
function Test-PostgresUrl {
    param([string]$Address)
    return [bool]($Address -match '^(?i)postgres(ql)?://')
}

# The database the server opens with the console's .env, read as the
# server reads it: DATABASE_URL, a postgres:// address or the SQLite file
# (sqlite:// before it allowed), else DB_URL of an older install.
# DB_TYPE=sqlite of an older install keeps it on SQLite where DATABASE_URL
# still names PostgreSQL. "" when .env names none: the server then opens
# db_v2.sqlite3 in its folder.
function Get-EnvDatabaseUrl {
    $url = Get-ConsoleEnvValue -Key "DATABASE_URL"
    $legacy = Get-ConsoleEnvValue -Key "DB_URL"
    if ($url -and (Test-PostgresUrl $url) -and (Get-ConsoleEnvValue -Key "DB_TYPE") -eq "sqlite") {
        $url = ""
        if (Test-PostgresUrl $legacy) { $legacy = "" }
    }
    if (-not $url) { $url = $legacy }
    if (-not (Test-PostgresUrl $url)) { $url = $url -replace '^(?i)sqlite:(//)?', '' }
    return $url
}

# "postgres" when the server opens PostgreSQL with the console's .env,
# else "sqlite".
function Get-EnvDatabaseType {
    if (Test-PostgresUrl (Get-EnvDatabaseUrl)) { return "postgres" }
    return "sqlite"
}

# True when the binary takes its database from DATABASE_URL; older ones
# read DB_URL and DB_TYPE only.
function Test-BinaryReadsDatabaseUrl {
    param([string]$Path = (Get-ServerBinaryPath))
    if (-not $Path -or -not (Test-Path $Path)) { return $false }
    return [bool](Select-String -Path $Path -Pattern 'Remove DB_TYPE to use DATABASE_URL' -SimpleMatch -Quiet)
}

# Points the console's .env at the database the server is to use:
# DATABASE_URL alone, its type from the scheme; the DB_TYPE, DB_URL and
# DB_PATH of an older install go. For an installed binary that reads only
# DB_URL and DB_TYPE, those are written as it reads them.
function Use-DatabaseInEnv {
    param([ValidateSet('postgres', 'sqlite')][string]$Type, [string]$Address)
    if (Test-BinaryReadsDatabaseUrl) {
        Remove-ConsoleEnvValue -Keys @("DB_TYPE", "DB_URL", "DB_PATH")
        Set-ConsoleEnvValue -Key "DATABASE_URL" -Value $Address
    } else {
        Set-ConsoleEnvValue -Key "DB_TYPE" -Value $Type
        Set-ConsoleEnvValue -Key "DATABASE_URL" -Value $(if ($Type -eq "postgres") { $Address } else { "" })
        Set-ConsoleEnvValue -Key "DB_URL" -Value $Address
    }
}
#===============================================================================
# The server with its web console: binary, console folder, service
#===============================================================================

function Get-ServerBinaryPath {
    return (Join-Path $script:RUSTDESK_PATH "neodesk-server.exe")
}

#===============================================================================
# The Windows service NeoDeskServer
#===============================================================================
# neodesk-server.exe is the service itself: the service manager starts it,
# and it answers stop and shutdown by stopping its parts. Older installs
# ran it through NSSM or as a scheduled task under SYSTEM; their next
# update or Repair services makes that the Windows service.

# The service's key in the registry; Environment there holds the settings
# the server starts with besides .env.
function Get-ServerServiceKey {
    return "HKLM:\SYSTEM\CurrentControlSet\Services\$($script:SERVER_SERVICE)"
}

# The service's command line and account as the service manager has them;
# $null when there is no service.
function Get-ServerServiceInfo {
    $svc = Get-CimInstance -ClassName Win32_Service -Filter "Name='$($script:SERVER_SERVICE)'" -ErrorAction SilentlyContinue
    if (-not $svc) { return $null }
    return [pscustomobject]@{ PathName = [string]$svc.PathName; StartName = [string]$svc.StartName }
}

# Gives the service a new command line. Win32_Service.Change takes the
# quotes around the binary as they are, which sc.exe binPath= does not get
# through Windows PowerShell. $false when Windows refused.
function Set-ServerServicePath {
    param([string]$PathName)
    $svc = Get-CimInstance -ClassName Win32_Service -Filter "Name='$($script:SERVER_SERVICE)'" -ErrorAction SilentlyContinue
    if (-not $svc) { return $false }
    $result = Invoke-CimMethod -InputObject $svc -MethodName Change -Arguments @{ PathName = $PathName }
    return ($result.ReturnValue -eq 0)
}

# Gives the service this account through Win32_Service.Change, which takes
# a virtual account's empty password as it is. $false when Windows refused.
function Set-ServerServiceAccount {
    param([string]$Account)
    $svc = Get-CimInstance -ClassName Win32_Service -Filter "Name='$($script:SERVER_SERVICE)'" -ErrorAction SilentlyContinue
    if (-not $svc) { return $false }
    $result = Invoke-CimMethod -InputObject $svc -MethodName Change -Arguments @{ StartName = $Account; StartPassword = "" }
    return ($result.ReturnValue -eq 0)
}

# sc.exe with these arguments; returns its exit code.
function Invoke-ServiceControl {
    & sc.exe @args | Out-Null
    return $LASTEXITCODE
}

# The settings in the service's environment, as KEY=VALUE lines.
function Get-ServerServiceEnvironment {
    $p = Get-ItemProperty -Path (Get-ServerServiceKey) -Name Environment -ErrorAction SilentlyContinue
    if (-not $p) { return @() }
    return @($p.Environment | Where-Object { $_ -match '^[A-Za-z_][A-Za-z0-9_]*=' })
}

function Set-ServerServiceEnvironment {
    param([string[]]$Environment)
    New-ItemProperty -Path (Get-ServerServiceKey) -Name Environment -PropertyType MultiString -Value ([string[]]@($Environment)) -Force | Out-Null
}

# A setting of an older install's NSSM service (AppParameters,
# AppEnvironmentExtra), read from its Parameters key, so nssm.exe need not
# be there any more.
function Get-NssmSetting {
    param([string]$Name)
    $p = Get-ItemProperty -Path "$(Get-ServerServiceKey)\Parameters" -Name $Name -ErrorAction SilentlyContinue
    if (-not $p) { return $null }
    return $p.$Name
}

# Removes the NSSM settings once the binary is the service.
function Remove-NssmSettings {
    Remove-Item -Path "$(Get-ServerServiceKey)\Parameters" -Recurse -Force -ErrorAction SilentlyContinue
}

# The environment of an older install's NSSM service as KEY=VALUE lines.
function Get-NssmEnvironment {
    return @(@(Get-NssmSetting -Name AppEnvironmentExtra) | ForEach-Object { "$_".Trim([char]0, ' ') } | Where-Object { $_ -match '^[A-Za-z_][A-Za-z0-9_]*=' })
}

# What runs the server: "service" (the Windows service), "nssm" (an older
# install's NSSM service), "task" (an older install's scheduled task), or
# "" when nothing does.
function Get-ServerSupervisor {
    $info = Get-ServerServiceInfo
    if ($info) {
        if ($info.PathName -match '(?i)(^|[\\"])nssm(\.exe)?("|\s|$)') { return "nssm" }
        return "service"
    }
    if (Get-ScheduledTask -TaskName $script:SERVER_SERVICE -ErrorAction SilentlyContinue) { return "task" }
    return ""
}

# The arguments of a command line after its program.
function Split-ServiceCommandLine {
    param([string]$PathName)
    if ($PathName -match '^\s*"[^"]*"\s*(.*)$') { return $Matches[1].Trim() }
    if ($PathName -match '^\s*\S+\s*(.*)$') { return $Matches[1].Trim() }
    return ""
}

# The service's command line for these server arguments.
function Get-ServerServiceCommandLine {
    param([string]$Arguments)
    $line = "`"$(Get-ServerBinaryPath)`""
    if ($Arguments) { $line += " $Arguments" }
    return $line
}

# The server's arguments, from what runs it; $null when nothing does.
function Get-ServerServiceArguments {
    switch (Get-ServerSupervisor) {
        "service" { return (Split-ServiceCommandLine -PathName (Get-ServerServiceInfo).PathName) }
        "nssm" { return "$(Get-NssmSetting -Name AppParameters)".Trim([char]0, ' ') }
        "task" { return (Get-LauncherArguments) }
    }
    return $null
}

# The server's settings besides .env, from what runs it.
function Get-ServerServiceSettings {
    switch (Get-ServerSupervisor) {
        "service" { return @(Get-ServerServiceEnvironment) }
        "nssm" { return @(Get-NssmEnvironment) }
        "task" { return @(Get-LauncherEnvironment) }
    }
    return @()
}

# New arguments for the server, used at its next start. An older install
# becomes the Windows service first. $false when there is no service.
function Set-ServerServiceArguments {
    param([string]$Arguments)
    if ((Get-ServerSupervisor) -notin @("service", "")) { Update-ServerServiceDefinition | Out-Null }
    if ((Get-ServerSupervisor) -ne "service") { return $false }
    return (Set-ServerServicePath -PathName (Get-ServerServiceCommandLine -Arguments $Arguments))
}

# New settings in the server's environment, used at its next start. An
# older install becomes the Windows service first.
function Set-ServerServiceSettings {
    param([string[]]$Environment)
    if ((Get-ServerSupervisor) -notin @("service", "")) { Update-ServerServiceDefinition | Out-Null }
    if ((Get-ServerSupervisor) -ne "service") { return $false }
    Set-ServerServiceEnvironment -Environment $Environment
    return $true
}

# The server's arguments without its TLS options and -force-https.
function Remove-TlsArguments {
    param([string]$Arguments)
    $a = $Arguments -replace '\s*-tls-(cert|key)(\s+|=)("[^"]*"|\S+)', ''
    $a = $a -replace '\s*-(tls-signal|tls-relay|tls-api|force-https)(=\S+)?(?=\s|$)', ''
    return $a.Trim()
}

# TLS of signal and relay with this certificate, or off without one; the
# API stays HTTP. Used at the server's next start.
function Set-ServerTls {
    param([string]$CertPath = "", [string]$KeyPath = "")
    $current = Get-ServerServiceArguments
    if ($null -eq $current) { return }
    $new = Remove-TlsArguments -Arguments $current
    if ($CertPath) { $new = "$new -tls-cert `"$CertPath`" -tls-key `"$KeyPath`" -tls-signal -tls-relay".Trim() }
    if ($new -ne $current) { Set-ServerServiceArguments -Arguments $new | Out-Null }
}

# True when the binary runs as a Windows service itself; older ones need
# NSSM or the scheduled task. Read from the file, as the other checks.
function Test-BinaryRunsAsService {
    param([string]$Path = (Get-ServerBinaryPath))
    if (-not $Path -or -not (Test-Path $Path)) { return $false }
    return [bool](Select-String -Path $Path -Pattern 'Service stop requested, shutting down' -SimpleMatch -Quiet)
}

# Get-ManagerCommand ARGS: the command that runs the install's copy of
# this script with ARGS from any elevated PowerShell or cmd window. It
# passes the execution policy, so it also works where scripts are off
# (Windows 10 and 11) and in a new window; a Group Policy still wins.
function Get-ManagerCommand {
    param([string]$Arguments = "")
    $cmd = "powershell -NoProfile -ExecutionPolicy Bypass -File `"$(Join-Path $script:RUSTDESK_PATH 'neodesk.ps1')`""
    if ($Arguments) { $cmd += " $Arguments" }
    return $cmd
}

# True when NeoDeskServer is a Windows service, false when it is an older
# install's scheduled task or missing.
function Test-ServerIsService {
    return [bool](Get-Service -Name $script:SERVER_SERVICE -ErrorAction SilentlyContinue)
}

# The command that restarts the server after a change of .env: the
# service's restart, or for an older install's scheduled task the end of
# the server, which its launcher starts again.
function Get-RestartCommand {
    if ((Get-ServerSupervisor) -eq "task") { return "Stop-Process -Name neodesk-server -Force (the task starts it again)" }
    return "Restart-Service $($script:SERVER_SERVICE)"
}

# How the server runs, for the summary and the warnings.
function Get-ServerAccountText {
    switch (Get-ServerSupervisor) {
        "task" { return "scheduled task $($script:SERVER_SERVICE), as SYSTEM (full rights on this machine); the next update makes it a Windows service" }
        "" { return "not set up (Repair installation, Repair services)" }
    }
    $account = (Get-ServerServiceInfo).StartName
    if (-not $account) { $account = "NT SERVICE\$($script:SERVER_SERVICE)" }
    if ($account -eq "LocalSystem") { $account = "LocalSystem (-RunAsRoot)" }
    return "Windows service $($script:SERVER_SERVICE), as $account"
}

# Protect-Folder PATH [-ServiceAccount]: only Administrators and SYSTEM
# (and with -ServiceAccount the server's NT SERVICE account, while the
# service exists) get into PATH and what it holds. A folder at the drive
# root inherits C:\'s ACL otherwise, which lets every user read it on
# Windows Server and change it on Windows 10 and 11. The SIDs work in
# every Windows language. Returns $false when icacls refused.
function Protect-Folder {
    param([string]$Path, [switch]$ServiceAccount)
    if (-not $Path -or -not (Test-Path $Path -PathType Container)) { return $true }
    & icacls $Path /inheritance:r /grant:r "*S-1-5-32-544:(OI)(CI)F" "*S-1-5-18:(OI)(CI)F" /C /Q 2>$null | Out-Null
    $ok = ($LASTEXITCODE -eq 0)
    if ($ServiceAccount -and (Test-ServerIsService)) {
        & icacls $Path /grant "NT SERVICE\$($script:SERVER_SERVICE):(OI)(CI)M" /C /Q 2>$null | Out-Null
    }
    if (-not $ok) { Print-Warning "Could not limit who can read $Path (icacls failed); check its permissions" }
    return $ok
}

# The install's folders hold the server's keys, the API key, the database,
# .env and the certificate's key, and the backups hold copies of them:
# only Administrators, SYSTEM and the server's service account get in.
function Protect-InstallFolders {
    $ok = $true
    foreach ($path in @($script:RUSTDESK_PATH, $script:CONSOLE_PATH)) {
        if (-not (Protect-Folder -Path $path -ServiceAccount)) { $ok = $false }
    }
    if (-not (Protect-Folder -Path $script:BACKUP_DIR)) { $ok = $false }
    return $ok
}

# True when the binary carries the commands of the release with the console
# inside (upgrade-env, env merge, config, reset-password, check, update).
# Read from the file: an older binary would take an unknown command for its
# own arguments and start a server.
function Test-BinaryHasSubcommands {
    param([string]$Path = (Get-ServerBinaryPath))
    if (-not $Path -or -not (Test-Path $Path)) { return $false }
    return [bool](Select-String -Path $Path -Pattern 'upgrade-env --from FILE' -SimpleMatch -Quiet)
}

# True when the binary can make the install's certificate (cert).
# True when the binary's reset-password can turn off the account's
# two-factor sign-in (--reset-two-factor).
function Test-BinaryResetsTwoFactor {
    param([string]$Path = (Get-ServerBinaryPath))
    if (-not $Path -or -not (Test-Path $Path)) { return $false }
    return [bool](Select-String -Path $Path -Pattern 'reset-password [--reset-two-factor]' -SimpleMatch -Quiet)
}

function Test-BinaryHasCertCommand {
    param([string]$Path = (Get-ServerBinaryPath))
    if (-not $Path -or -not (Test-Path $Path)) { return $false }
    return [bool](Select-String -Path $Path -Pattern 'cert --out DIR' -SimpleMatch -Quiet)
}

# True when NeoDeskServer runs the server with its web console: this
# installer puts NEODESK_SUPERVISOR into its environment (the service, an
# older NSSM service) or its launcher (an older scheduled task).
function Test-GoOnlyInstall {
    if (Get-ServerServiceSettings | Where-Object { $_ -like 'NEODESK_SUPERVISOR=*' }) {
        return $true
    }
    $launcher = Join-Path $script:RUSTDESK_PATH "start-neodesk-server.cmd"
    return ((Test-Path $launcher) -and [bool](Select-String -Path $launcher -Pattern 'NEODESK_SUPERVISOR=' -SimpleMatch -Quiet))
}

# Stop-NodeEraInstall says that an install which still runs the Node.js
# console is neither upgraded nor installed over: NeoDesk has no way from
# it.
function Stop-NodeEraInstall {
    Print-Error "This server runs the old Node.js web console, which this installer does not upgrade."
    Print-Info "Back up its data and install NeoDesk on a clean server."
}

# True when the install still runs the Node.js console.
function Test-NodeEraInstall {
    if (Test-GoOnlyInstall) { return $false }
    if (Test-Path (Join-Path $script:CONSOLE_PATH "server.js")) { return $true }
    if (Get-Service -Name $script:CONSOLE_SERVICE -ErrorAction SilentlyContinue) { return $true }
    return [bool](Get-ScheduledTask -TaskName $script:CONSOLE_SERVICE -ErrorAction SilentlyContinue)
}

# Runs a command of the installed binary with the console's env file; the
# text of -InputText goes to its standard input. Returns the exit code.
function Invoke-ServerCommand {
    param(
        [string[]]$Arguments,
        [string]$InputText = $null,
        [string]$Binary = (Get-ServerBinaryPath)
    )
    if (-not (Test-BinaryHasSubcommands -Path $Binary)) {
        Print-Error "$Binary is not a release with the web console inside; update first"
        return 1
    }
    $saved = @{}
    $vars = @{
        NEODESK_ENV_FILE     = (Join-Path $script:CONSOLE_PATH ".env")
        NEODESK_CONSOLE_PATH = $script:CONSOLE_PATH
        NEODESK_PATH         = $script:RUSTDESK_PATH
    }
    foreach ($k in $vars.Keys) {
        $saved[$k] = [Environment]::GetEnvironmentVariable($k, "Process")
        [Environment]::SetEnvironmentVariable($k, $vars[$k], "Process")
    }
    try {
        if ($null -ne $InputText) {
            $InputText | & $Binary @Arguments | ForEach-Object { Write-Host $_ }
        } else {
            & $Binary @Arguments | ForEach-Object { Write-Host $_ }
        }
        return $LASTEXITCODE
    } finally {
        foreach ($k in $vars.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k], "Process") }
    }
}

# Where the release files are: RELEASE_BASE_URL, else the newest release
# (stable channel, UPDATE_GITHUB_BRANCH main) or the "dev" pre-release
# (development channel, dev).
function Get-ReleaseBaseUrl {
    if ($env:RELEASE_BASE_URL) { return $env:RELEASE_BASE_URL.TrimEnd('/') }
    $releases = "https://github.com/$($script:UPDATE_GITHUB_OWNER)/$($script:UPDATE_GITHUB_REPO)/releases"
    if ($script:RELEASE_TAG) { return "$releases/download/$($script:RELEASE_TAG)" }
    if ($script:UPDATE_GITHUB_BRANCH -eq "dev") { return "$releases/download/dev" }
    return "$releases/latest/download"
}

# The tag of the newest published pre-release of the repository other than
# the rolling "dev" one, or "" when there is none or the API does not
# answer. GitHub lists the releases newest first.
function Get-NewestPrereleaseTag {
    try {
        $list = Invoke-RestMethod -Uri "https://api.github.com/repos/$($script:UPDATE_GITHUB_OWNER)/$($script:UPDATE_GITHUB_REPO)/releases?per_page=50" -Headers @{ Accept = "application/vnd.github+json" } -UseBasicParsing -ErrorAction Stop
    } catch {
        return ""
    }
    foreach ($r in @($list)) {
        if (-not $r.draft -and $r.prerelease -and $r.tag_name -ne "dev" -and "$($r.tag_name)" -match '^[A-Za-z0-9][A-Za-z0-9._-]*$') { return [string]$r.tag_name }
    }
    return ""
}

# The stable channel's release as GitHub's API names it: @{ Tag } of the
# newest stable release, @{ Missing } when the repository has none (the
# API answers 404), or @{} when the API gives no answer, and the download
# then asks releases/latest itself.
function Get-StableRelease {
    try {
        $r = Invoke-RestMethod -Uri "https://api.github.com/repos/$($script:UPDATE_GITHUB_OWNER)/$($script:UPDATE_GITHUB_REPO)/releases/latest" -Headers @{ Accept = "application/vnd.github+json" } -UseBasicParsing -ErrorAction Stop
        if ("$($r.tag_name)" -match '^[A-Za-z0-9][A-Za-z0-9._-]*$') { return @{ Tag = [string]$r.tag_name } }
    } catch {
        $code = 0
        if ($_.Exception.Response) { try { $code = [int]$_.Exception.Response.StatusCode } catch { $code = 0 } }
        if ($code -eq 404 -or (-not $code -and "$($_.Exception.Message)" -match '\b404\b')) { return @{ Missing = $true } }
    }
    return @{}
}

# Downloads the release binary for this machine into $Dir, checked against
# the release's SHA256SUMS and, when the installed binary can check it
# (verify-release), the signature of the release's manifest. Returns the
# path or $null.
function Get-ReleaseBinary {
    param([string]$Dir)
    $asset = "neodesk-server-windows-amd64.exe"
    if (-not [Environment]::Is64BitOperatingSystem) {
        Print-Error "There is no release binary for 32-bit Windows; use -FromSource"
        return $null
    }
    Read-UpdateGitHubBranchFromEnv
    # The repository given to the installer, else the one .env names
    if (-not $script:UPDATE_GITHUB_OWNER_GIVEN -and (Get-ConsoleEnvValue -Key "UPDATE_GITHUB_OWNER")) { $script:UPDATE_GITHUB_OWNER = Get-ConsoleEnvValue -Key "UPDATE_GITHUB_OWNER" }
    if (-not $script:UPDATE_GITHUB_REPO_GIVEN -and (Get-ConsoleEnvValue -Key "UPDATE_GITHUB_REPO")) { $script:UPDATE_GITHUB_REPO = Get-ConsoleEnvValue -Key "UPDATE_GITHUB_REPO" }
    $sums = Join-Path $Dir "SHA256SUMS"
    $file = Join-Path $Dir $asset
    $status = 0
    $failure = $null
    $fallback = -not $env:RELEASE_BASE_URL -and -not $script:UPDATE_GITHUB_BRANCH_GIVEN -and -not (Get-ConsoleEnvValue -Key "UPDATE_GITHUB_BRANCH")
    $askedForPrerelease = $false
    $script:RELEASE_TAG = ""
    # The stable channel's release is found through GitHub's API first:
    # while the repository has none, releases/latest/download answers in a
    # way Windows PowerShell 5.1 reports as a closed connection, not a 404
    if (-not $env:RELEASE_BASE_URL -and $script:UPDATE_GITHUB_BRANCH -ne "dev") {
        $stable = Get-StableRelease
        if ($stable.Tag) {
            $script:RELEASE_TAG = $stable.Tag
        } elseif ($stable.Missing) {
            $askedForPrerelease = $true
            $prerelease = Get-NewestPrereleaseTag
            if ($prerelease) {
                Print-Warning "$($script:UPDATE_GITHUB_OWNER)/$($script:UPDATE_GITHUB_REPO) has no stable release yet: installing the newest pre-release $prerelease"
                $script:RELEASE_TAG = $prerelease
            } elseif ($fallback) {
                Print-Warning "$($script:UPDATE_GITHUB_OWNER)/$($script:UPDATE_GITHUB_REPO) has no stable release or pre-release yet: installing the development build (-Channel dev) instead"
                Print-Info "Updates follow the development channel; once a stable release is out: $(Get-ManagerCommand '-Update -Channel stable')"
                $script:UPDATE_GITHUB_BRANCH = "dev"
                $script:UPDATE_GITHUB_BRANCH_GIVEN = "dev"
                $env:UPDATE_GITHUB_BRANCH = "dev"
            } else {
                Print-Error "$($script:UPDATE_GITHUB_OWNER)/$($script:UPDATE_GITHUB_REPO) has no stable release or pre-release yet"
                Print-Info "Install the development build with -Channel dev, or a binary you have with -Binary FILE"
                return $null
            }
        }
    }
    while ($true) {
        $base = Get-ReleaseBaseUrl
        Print-Info "Downloading $asset ($($script:UPDATE_GITHUB_BRANCH) channel) from $base"
        $status = 0
        $failure = $null
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            Invoke-WebRequest -Uri "$base/SHA256SUMS" -OutFile $sums -UseBasicParsing -ErrorAction Stop
            Invoke-WebRequest -Uri "$base/$asset" -OutFile $file -UseBasicParsing -ErrorAction Stop
        } catch {
            $failure = $_
            if ($_.Exception.Response) { try { $status = [int]$_.Exception.Response.StatusCode } catch { $status = 0 } }
            if (-not $status -and "$($_.Exception.Message)" -match '\b404\b') { $status = 404 }
        }
        # No stable release yet: the newest pre-release (a release candidate
        # of the stable channel), else, with no channel given or saved, the
        # development build and its channel for later updates (DECISIONS A183)
        if ($failure -and $status -eq 404 -and -not $env:RELEASE_BASE_URL -and $script:UPDATE_GITHUB_BRANCH -ne "dev" -and -not $askedForPrerelease) {
            $askedForPrerelease = $true
            $prerelease = Get-NewestPrereleaseTag
            if ($prerelease) {
                Print-Warning "$($script:UPDATE_GITHUB_OWNER)/$($script:UPDATE_GITHUB_REPO) has no stable release yet: installing the newest pre-release $prerelease"
                $script:RELEASE_TAG = $prerelease
                continue
            }
        }
        if ($failure -and $status -eq 404 -and $fallback -and -not $script:RELEASE_TAG -and $script:UPDATE_GITHUB_BRANCH -ne "dev") {
            Print-Warning "$($script:UPDATE_GITHUB_OWNER)/$($script:UPDATE_GITHUB_REPO) has no stable release or pre-release yet: installing the development build (-Channel dev) instead"
            Print-Info "Updates follow the development channel; once a stable release is out: $(Get-ManagerCommand '-Update -Channel stable')"
            $script:UPDATE_GITHUB_BRANCH = "dev"
            $script:UPDATE_GITHUB_BRANCH_GIVEN = "dev"
            $env:UPDATE_GITHUB_BRANCH = "dev"
            continue
        }
        break
    }
    if ($failure) {
        if ($status -eq 404 -and -not $env:RELEASE_BASE_URL -and $script:UPDATE_GITHUB_BRANCH -ne "dev") {
            Print-Error "$($script:UPDATE_GITHUB_OWNER)/$($script:UPDATE_GITHUB_REPO) has no stable release yet"
            Print-Info "Install the development build with -Channel dev, or a binary you have with -Binary FILE"
        } elseif ($status -eq 404) {
            Print-Error "There is no release at $base"
            Print-Info "Install a binary you have with -Binary FILE"
        } elseif (-not $status) {
            Print-Error "Could not reach ${base}: $($failure.Exception.Message)"
            Print-Info "Check this machine's internet access, DNS and proxy settings,"
            Print-Info "or install offline: download the binary elsewhere and run with -Binary FILE"
        } else {
            Print-Error "The download failed (HTTP $status); try again later, or use -Binary FILE"
        }
        return $null
    }
    $expected = $null
    foreach ($line in Get-Content $sums) {
        $parts = $line.Trim() -split '\s+', 2
        if ($parts.Count -eq 2 -and ($parts[1] -eq $asset -or $parts[1] -eq "*$asset")) { $expected = $parts[0].ToLower(); break }
    }
    $actual = (Get-FileHash -Path $file -Algorithm SHA256).Hash.ToLower()
    if ($script:SKIP_VERIFY) {
        Print-Warning "SHA-256 and signature checks skipped (-SkipVerify)"
    } elseif (-not $expected) {
        Print-Error "SHA256SUMS of the release does not list $asset"
        return $null
    } elseif ($actual -ne $expected) {
        Print-Error "SHA-256 of $asset does not match the release's SHA256SUMS"
        return $null
    } else {
        Print-Success "SHA-256 of $asset matches the release"
        if (-not (Test-ReleaseSignature -Dir $Dir -Base $base -Asset $asset)) {
            Print-Info "Nothing was installed. A release signed with another key (a fork's) installs with -SkipVerify"
            return $null
        }
    }
    $target = Join-Path $Dir "neodesk-server.exe"
    Move-Item -Path $file -Destination $target -Force
    # The installer's copy comes from the same release (Install-ManagerScript)
    $script:RELEASE_FOLDER_USED = $base
    return $target
}

# True when the binary checks a release's signature itself, with the
# release key it carries (verify-release).
function Test-BinaryVerifiesReleases {
    param([string]$Path = (Get-ServerBinaryPath))
    if (-not $Path -or -not (Test-Path $Path)) { return $false }
    return [bool](Select-String -Path $Path -Pattern 'verify-release --manifest FILE' -SimpleMatch -Quiet)
}

# Checks the downloaded $Dir\$Asset against the signed manifest of the
# release at $Base with the installed neodesk-server (verify-release).
# Windows has no tool for an ed25519 signature before the server is
# installed, so a first install (or one of a binary older than the release
# key) says so and keeps the SHA-256 check over HTTPS. Returns $false when
# the release is refused.
function Test-ReleaseSignature {
    param([string]$Dir, [string]$Base, [string]$Asset)
    $installed = Get-ServerBinaryPath
    if (-not (Test-BinaryVerifiesReleases -Path $installed)) {
        Print-Warning "The release signature is checked from the second install on: this install checks the binary's SHA-256 over HTTPS only."
        Print-Info "Windows has no tool for the signature before neodesk-server is installed; from the next update on, the installed neodesk-server checks it."
        return $true
    }
    $manifest = Join-Path $Dir "manifest.json"
    $signature = Join-Path $Dir "manifest.sig"
    foreach ($name in @("manifest.json", "manifest.sig")) {
        try {
            Invoke-WebRequest -Uri "$Base/$name" -OutFile (Join-Path $Dir $name) -UseBasicParsing -ErrorAction Stop
        } catch {
            Print-Error "The release has no signed manifest ($name could not be downloaded), so $Asset is not installed"
            return $false
        }
    }
    $output = @(& $installed verify-release --manifest $manifest --signature $signature --name $Asset (Join-Path $Dir $Asset) 2>&1 | ForEach-Object { "$_" })
    $code = $LASTEXITCODE
    if ($code -eq 0) {
        $branch = ""
        if ((Get-Content $manifest -Raw) -match '"branch"\s*:\s*"([A-Za-z0-9_./-]+)"') { $branch = $Matches[1] }
        if ($branch -ne $script:UPDATE_GITHUB_BRANCH) {
            Print-Error "The release is not one of the $($script:UPDATE_GITHUB_BRANCH) channel, so $Asset is not installed"
            return $false
        }
        Print-Success "Release signature checked by the installed neodesk-server ($((($output -join ' ') -replace '^verified: ', '')))"
        return $true
    }
    Print-Error "The installed neodesk-server refused the release: $((($output -join ' ') -replace '^neodesk-server verify-release: ', ''))"
    return $false
}

# A checked binary for this machine from -Binary, -FromSource or the
# release, in a temporary folder. Sets $script:STAGED_SERVER_BINARY and
# $script:STAGED_SERVER_VERSION; returns $true on success.
function Get-StagedServerBinary {
    $dir = Join-Path $env:TEMP "neodesk-server-$PID"
    Remove-Item -Path $dir -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $script:STAGED_SERVER_DIR = $dir
    $staged = Join-Path $dir "neodesk-server.exe"
    if ($script:BINARY_FILE) {
        Print-Info "Using the binary $($script:BINARY_FILE)"
        Copy-Item -Path $script:BINARY_FILE -Destination $staged -Force
    } elseif ($script:FROM_SOURCE) {
        if (-not (Compile-GoServer)) { return $false }
        Copy-Item -Path (Join-Path $script:GO_SERVER_SOURCE "neodesk-server.exe") -Destination $staged -Force
    } else {
        $downloaded = Get-ReleaseBinary -Dir $dir
        if (-not $downloaded) { return $false }
    }
    $line = (& $staged -version 2>$null | Select-Object -First 1)
    if ($LASTEXITCODE -ne 0 -or -not $line) {
        Print-Error "The new binary does not run on this machine"
        return $false
    }
    if (-not (Test-BinaryHasSubcommands -Path $staged)) {
        Print-Error "The new binary is not a release with the web console inside ($line)"
        return $false
    }
    $script:STAGED_SERVER_BINARY = $staged
    $script:STAGED_SERVER_VERSION = "$line"
    Print-Success "New binary: $line"
    return $true
}

# Puts the staged binary in place of the installed one and keeps the old
# one as neodesk-server.exe<Suffix>. The service must be stopped.
function Install-StagedBinary {
    param([string]$Suffix = ".prev")
    $target = Get-ServerBinaryPath
    New-Item -ItemType Directory -Path $script:RUSTDESK_PATH -Force | Out-Null
    try {
        if (Test-Path $target) {
            Copy-Item -Path $target -Destination "$target$Suffix" -Force -ErrorAction Stop
        }
        Copy-Item -Path $script:STAGED_SERVER_BINARY -Destination $target -Force -ErrorAction Stop
    } catch {
        Print-Error "Could not install ${target}: $_"
        return $false
    }
    Print-Success "Installed $target"
    return $true
}

function Install-Binaries {
    Print-Step "Installing neodesk-server..."
    $ok = Get-StagedServerBinary
    if ($ok) {
        Stop-AllServices
        $ok = Install-StagedBinary
    }
    Remove-Item -Path $script:STAGED_SERVER_DIR -Recurse -Force -ErrorAction SilentlyContinue
    return $ok
}

# The console's folder with its .env and data folder.
function Setup-ConsoleHome {
    Print-Step "Setting up the web console's folder $($script:CONSOLE_PATH)..."
    New-Item -ItemType Directory -Path (Join-Path $script:CONSOLE_PATH "data") -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $script:CONSOLE_PATH "logs") -Force | Out-Null
    $envFile = Join-Path $script:CONSOLE_PATH ".env"
    $isFresh = -not (Test-Path $envFile)
    $script:FRESH_CONSOLE_ENV = $isFresh
    if ($isFresh) {
        if (-not $env:ADMIN_PASSWORD) { $env:ADMIN_PASSWORD = Generate-RandomPassword }
        New-Item -ItemType File -Path (Join-Path $script:CONSOLE_PATH "data\.force_password_update") -Force | Out-Null
    } else {
        Print-Info "Keeping the existing .env and accounts"
    }
    if (-not (Merge-ConsoleEnv -FreshInstall $isFresh)) { return $false }
    if ($script:MINIMAL_MODE) {
        Set-ConsoleEnvValue -Key "CONSOLE_PORT" -Value "0"
        Print-Info "Minimal installation: the web console stays off (CONSOLE_PORT=0)"
    }
    $gateway = Join-Path (Get-RepoDir) "remote-gateway"
    if (Test-Path $gateway) {
        $to = Join-Path $script:CONSOLE_PATH "remote-gateway"
        New-Item -ItemType Directory -Path $to -Force | Out-Null
        Copy-Item -Path (Join-Path $gateway "*") -Destination $to -Recurse -Force
    }
    $script:CONSOLE_TYPE = "go"
    Print-Success "Web console folder ready"
    return $true
}

# The arguments of the server: relay address, keys, API port, rate limit
# and, when certificates exist, TLS for signal and relay (the API stays
# HTTP: RustDesk clients call it without TLS).
function Get-ServerArguments {
    param([string]$ServerIP)
    $signalRateLimit = if ($env:SIGNAL_RATE_LIMIT_PER_IP) { $env:SIGNAL_RATE_LIMIT_PER_IP } else { "20" }
    if ($signalRateLimit -notmatch '^\d+$') {
        Print-Warning "Invalid SIGNAL_RATE_LIMIT_PER_IP='$signalRateLimit'; using 20"
        $signalRateLimit = "20"
    }
    $serverArgs = "-mode all -relay-servers $ServerIP -key-file `"$script:RUSTDESK_PATH\id_ed25519`" -api-port $script:GO_API_PORT -signal-rate-limit-per-ip $signalRateLimit"
    $certPath = Join-Path $script:RUSTDESK_PATH "ssl\neodesk.crt"
    $keyPath = Join-Path $script:RUSTDESK_PATH "ssl\neodesk.key"
    if ((Test-Path $certPath) -and (Test-Path $keyPath)) {
        $serverArgs += " -tls-cert `"$certPath`" -tls-key `"$keyPath`" -tls-signal -tls-relay"
        Print-Info "TLS: on for signal and relay (API stays HTTP)"
    }
    return $serverArgs
}

# The settings NeoDeskServer gets besides those it reads from .env. The
# signal and relay ports are in .env, where the admin changes them.
# NEODESK_SUPERVISOR=windows-service tells the server that the service
# manager starts it again after it ends with a restart request.
function Get-ServerBaseEnvironment {
    return @(
        "NEODESK_ENV_FILE=$(Join-Path $script:CONSOLE_PATH '.env')",
        "NEODESK_SUPERVISOR=windows-service",
        "GO_API_PORT=$($script:GO_API_PORT)",
        "MESH_ENABLED=Y"
    )
}

# The host of the address clients get becomes PANEL_PUBLIC_HOST when .env
# has none, so the console's HTTP port redirects to HTTPS on that host. A
# value set before stays.
function Set-PanelPublicHost {
    param([string]$Address)
    $envFile = Join-Path $script:CONSOLE_PATH ".env"
    if (-not (Test-Path $envFile) -or (Get-ConsoleEnvValue -Key "PANEL_PUBLIC_HOST")) { return }
    $hostPart = ($Address -split ',')[0].Trim()
    if ($hostPart -match '^(\[[^\]]+\])') { $hostPart = $Matches[1] }
    elseif (($hostPart.ToCharArray() | Where-Object { $_ -eq ':' }).Count -eq 1) { $hostPart = $hostPart.Split(':')[0] }
    if ($hostPart) { Set-ConsoleEnvValue -Key "PANEL_PUBLIC_HOST" -Value $hostPart }
}

# The signal and relay ports an older service or launcher set (they won
# over .env) go into .env; returns the other settings.
function Move-PortsToEnvFile {
    param([string[]]$Environment)
    $rest = @()
    foreach ($line in @($Environment)) {
        if ($line -match '^(SIGNAL_PORT|RELAY_PORT)=(.+)$') {
            Set-ConsoleEnvValue -Key $Matches[1] -Value $Matches[2]
            continue
        }
        if ($line) { $rest += $line }
    }
    return , $rest
}

# Merges environment lists: the first list wins, later lists add keys it lacks.
function Merge-EnvironmentLists {
    param([object[]]$Lists)
    $seen = @{}
    $out = @()
    foreach ($list in $Lists) {
        foreach ($line in @($list)) {
            if (-not $line) { continue }
            $key = ($line -split '=', 2)[0]
            if ($seen.ContainsKey($key)) { continue }
            $seen[$key] = $true
            $out += $line
        }
    }
    return , $out
}

# Writes NeoDeskServer as the Windows service that neodesk-server.exe is:
# started with Windows, under its own virtual account NT SERVICE\NeoDeskServer
# (LocalSystem with -RunAsRoot), $Arguments on its command line and
# $Environment in its environment. A stop of the service stops the server
# cleanly. When the server ends any other way (a crash, an error, or exit
# status 3, its restart request after a restart, update or restore from
# the console) the service manager starts it again after 2, 5 and then 10
# seconds (sc.exe failure, and failureflag for the exit status). The server
# writes its log itself: logs\server.log, moved to server.log.1 at 10 MB.
# $false when Windows refused the service.
function Set-ServerService {
    # No version in the name: the console's own updates replace the binary, not the service
    param([string]$Arguments, [string[]]$Environment, [string]$DisplayName = "NeoDesk Server",
        [string]$Description = "NeoDesk server and web console (signal, relay, API, console)")
    $name = $script:SERVER_SERVICE
    $commandLine = Get-ServerServiceCommandLine -Arguments $Arguments
    $displayName = $DisplayName
    $description = $Description
    $info = Get-ServerServiceInfo
    try {
        if (-not $info) {
            New-Service -Name $name -BinaryPathName $commandLine -DisplayName $displayName -Description $description -StartupType Automatic -ErrorAction Stop | Out-Null
        } else {
            if ($info.PathName -ne $commandLine -and -not (Set-ServerServicePath -PathName $commandLine)) {
                Print-Error "Windows refused the new command line of the service $name"
                return $false
            }
            Set-Service -Name $name -DisplayName $displayName -Description $description -StartupType Automatic -ErrorAction Stop
        }
    } catch {
        Print-Error "Could not set up the Windows service $name`: $($_.Exception.Message)"
        return $false
    }
    Set-ServerServiceEnvironment -Environment $Environment
    # An older install's NSSM settings; the binary reads none of them
    Remove-NssmSettings
    $account = if ($script:RUN_AS_ROOT) { "LocalSystem" } else { "NT SERVICE\$name" }
    if ((Invoke-ServiceControl config $name obj= $account) -ne 0 -and -not (Set-ServerServiceAccount -Account $account)) {
        Print-Warning "Could not make $account the account of the service $name (sc.exe config)"
    }
    if ((Invoke-ServiceControl failure $name reset= 86400 actions= restart/2000/restart/5000/restart/10000) -ne 0 -or
        (Invoke-ServiceControl failureflag $name 1) -ne 0) {
        Print-Warning "Could not set the restart after a failure of the service $name (sc.exe failure)"
    }
    New-Item -ItemType Directory -Path (Split-Path -Parent (Get-ServerLogPath)) -Force | Out-Null
    # The service's account needs the server folder (its keys, database,
    # logs and the binary its updates replace) and the console's folder
    # (.env, data)
    Set-ServiceLeastPrivilege -ServiceName $name -Paths @($script:RUSTDESK_PATH, $script:CONSOLE_PATH)
    return $true
}

# Ends and removes an older install's scheduled task and its launcher,
# which would start a second server next to the service.
function Remove-ServerTask {
    $launcher = Join-Path $script:RUSTDESK_PATH "start-neodesk-server.cmd"
    if (Get-ScheduledTask -TaskName $script:SERVER_SERVICE -ErrorAction SilentlyContinue) {
        Stop-ScheduledTask -TaskName $script:SERVER_SERVICE -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $script:SERVER_SERVICE -Confirm:$false -ErrorAction SilentlyContinue
        # The task's launcher started the server; it does not end with it
        Get-Process -Name "neodesk-server" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    }
    Remove-Item -Path $launcher -Force -ErrorAction SilentlyContinue
}

# .env names the supervisor too (upgrade-env); an older install's nssm or
# task there becomes windows-service, so the file says what runs the server.
function Sync-SupervisorInEnv {
    $current = Get-ConsoleEnvValue -Key "NEODESK_SUPERVISOR"
    if ($current -and $current -ne "windows-service") { Set-ConsoleEnvValue -Key "NEODESK_SUPERVISOR" -Value "windows-service" }
}

# The environment of an older install's task launcher: its "set" lines.
function Get-LauncherEnvironment {
    $launcher = Join-Path $script:RUSTDESK_PATH "start-neodesk-server.cmd"
    if (-not (Test-Path $launcher)) { return @() }
    return @(Get-Content $launcher | ForEach-Object {
        if ($_ -match '^set "([A-Za-z_][A-Za-z0-9_]*=.*)"$') { $Matches[1] }
    })
}

# The arguments of an older install's task launcher's server line, without
# the redirect of its output.
function Get-LauncherArguments {
    $launcher = Join-Path $script:RUSTDESK_PATH "start-neodesk-server.cmd"
    if (-not (Test-Path $launcher)) { return $null }
    foreach ($line in Get-Content $launcher) {
        if ($line -match '^"[^"]*neodesk-server\.exe"\s*(.*)$') {
            return ($Matches[1] -replace '\s*>>\s*"[^"]*"\s*2>&1\s*$', '').Trim()
        }
    }
    return $null
}

# The server's log file, which the service writes itself (and an older
# install's NSSM service or task launcher wrote).
function Get-ServerLogPath {
    return (Join-Path $script:RUSTDESK_PATH "logs\server.log")
}

# The URL the web console answers /health on: HTTPS_PORT when HTTPS is on
# and its certificate is there, else CONSOLE_PORT; $null when it is off.
function Get-ConsoleHealthUrl {
    $port = Get-ConsoleHttpPort
    if ($port -eq "0") { return $null }
    $cert = Get-ConsoleEnvValue -Key "SSL_CERT_PATH"
    $key = Get-ConsoleEnvValue -Key "SSL_KEY_PATH"
    if ((Get-ConsoleEnvValue -Key "HTTPS_ENABLED") -eq "true" -and $cert -and $key -and (Test-Path $cert) -and (Test-Path $key)) {
        $httpsPort = Get-ConsoleEnvValue -Key "HTTPS_PORT"
        if (-not $httpsPort) { $httpsPort = "5443" }
        return "https://127.0.0.1:$httpsPort/health"
    }
    return "http://127.0.0.1:$port/health"
}

# The signal and relay ports the server listens on (.env).
function Get-SignalPort { $p = Get-ConsoleEnvValue -Key "SIGNAL_PORT"; if ($p) { $p } else { "21116" } }
function Get-RelayPort { $p = Get-ConsoleEnvValue -Key "RELAY_PORT"; if ($p) { $p } else { "21117" } }

# The server answers: API and web console /health, signal and relay ports
# (neodesk-server check).
function Test-GoInstall {
    param([int]$TimeoutSeconds = 90)
    $signal = Get-SignalPort
    $relay = Get-RelayPort
    $checkArgs = @("check", "--api", "http://127.0.0.1:$($script:GO_API_PORT)/api/health", "--port", "127.0.0.1:$signal", "--port", "127.0.0.1:$relay", "--insecure")
    $consoleUrl = Get-ConsoleHealthUrl
    if ($consoleUrl) { $checkArgs += @("--panel", $consoleUrl) }
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $code = Invoke-ServerCommand -Arguments $checkArgs 6>$null
        if ($code -eq 0) {
            Print-Success "neodesk-server answers: API :$($script:GO_API_PORT)$(if ($consoleUrl) { ", web console $consoleUrl" }), signal :$signal, relay :$relay"
            return $true
        }
        Start-Sleep -Seconds 3
    } while ((Get-Date) -lt $deadline)
    Invoke-ServerCommand -Arguments $checkArgs | Out-Null
    Print-Error "neodesk-server does not answer (logs: $script:RUSTDESK_PATH\logs)"
    return $false
}

function Start-ServerService {
    if (Get-Service -Name $script:SERVER_SERVICE -ErrorAction SilentlyContinue) {
        Start-Service -Name $script:SERVER_SERVICE -ErrorAction SilentlyContinue
    } else {
        Start-ScheduledTask -TaskName $script:SERVER_SERVICE -ErrorAction SilentlyContinue
    }
}

# Stops the server. Stop-Service waits until the service has stopped all
# its parts; what is left after that is an older install's task or a
# server started by hand.
function Stop-ServerService {
    Stop-Service -Name $script:SERVER_SERVICE -Force -ErrorAction SilentlyContinue
    Stop-ScheduledTask -TaskName $script:SERVER_SERVICE -ErrorAction SilentlyContinue
    Get-Process -Name "neodesk-server" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
}

# The update of the server with its console: the newest release of the
# update channel (or -Binary, -FromSource, RELEASE_BASE_URL), the service
# settings written again, a restart and a check. A new binary that does not
# come up is replaced by the previous one.
# The console's plain port: CONSOLE_PORT, else PORT (the old console's,
# which upgrade-env copies), else the server's default.
function Get-ConsoleHttpPort {
    $port = Get-ConsoleEnvValue -Key "CONSOLE_PORT"
    if (-not $port) { $port = Get-ConsoleEnvValue -Key "PORT" }
    # The server's default: 3375 since 3.6.0-rc.5 (DECISIONS A250), 5000 before
    if (-not $port) { $port = "3375" }
    return "$port"
}

# True when .env names the console's port (CONSOLE_PORT or PORT). An
# install that names none follows the server's default.
function Test-ConsolePortNamed {
    return [bool]((Get-ConsoleEnvValue -Key "CONSOLE_PORT") -or (Get-ConsoleEnvValue -Key "PORT"))
}

# After the update of an install that named no port (-Named $false), which
# ran on the old default: says the console moved and how to keep the old
# port, and opens the new one in the firewall.
function Show-ConsolePortMove {
    param([bool]$Named)
    if ($Named -or (Get-ConsoleHttpPort) -ne "3375") { return }
    try { Configure-Firewall } catch { }
    Print-Warning "The console now answers on port 3375; it was 5000. To keep 5000 set CONSOLE_PORT=5000 in $(Join-Path $script:CONSOLE_PATH '.env'), then: $(Get-RestartCommand)"
}

function Update-GoInstall {
    # Before .env is merged: an install that names no port moves to the new
    # default port (Show-ConsolePortMove)
    $portNamed = Test-ConsolePortNamed
    $serverExe = Get-ServerBinaryPath
    $before = if (Test-Path $serverExe) { (Get-FileHash $serverExe -Algorithm SHA256).Hash } else { "" }
    Print-Info "Creating backup before update..."
    Do-BackupSilent

    # An installed binary without verify-release is older than the release
    # key, and its updater would take a release without checking the
    # signature: this installer downloads the release itself and says what
    # it checked
    if ($script:BINARY_FILE -or $script:FROM_SOURCE -or $env:RELEASE_BASE_URL -or -not (Test-BinaryVerifiesReleases -Path $serverExe)) {
        if (-not (Get-StagedServerBinary)) {
            Remove-Item -Path $script:STAGED_SERVER_DIR -Recurse -Force -ErrorAction SilentlyContinue
            return $false
        }
        Stop-ServerService
        $installed = Install-StagedBinary -Suffix ".prev"
        Remove-Item -Path $script:STAGED_SERVER_DIR -Recurse -Force -ErrorAction SilentlyContinue
        if (-not $installed) { Start-ServerService; return $false }
    } else {
        # The server's own updater: the release of the channel, its manifest
        # signature (with the release key the installed binary carries) and
        # SHA-256 checked; the running exe is renamed aside and the old one
        # kept as .prev
        Print-Step "Installing the newest release with neodesk-server update (it checks the release signature)..."
        # The repository goes to the updater: an installed binary may have
        # an older default
        $owner = if ($script:UPDATE_GITHUB_OWNER_GIVEN) { $script:UPDATE_GITHUB_OWNER_GIVEN } else { Get-ConsoleEnvValue -Key "UPDATE_GITHUB_OWNER" }
        $repo = if ($script:UPDATE_GITHUB_REPO_GIVEN) { $script:UPDATE_GITHUB_REPO_GIVEN } else { Get-ConsoleEnvValue -Key "UPDATE_GITHUB_REPO" }
        $savedOwner, $savedRepo = $env:UPDATE_GITHUB_OWNER, $env:UPDATE_GITHUB_REPO
        $env:UPDATE_GITHUB_OWNER = if ($owner) { $owner } else { $script:UPDATE_GITHUB_OWNER }
        $env:UPDATE_GITHUB_REPO = if ($repo) { $repo } else { $script:UPDATE_GITHUB_REPO }
        try { $updateCode = Invoke-ServerCommand -Arguments @("update", "--yes") }
        finally { $env:UPDATE_GITHUB_OWNER, $env:UPDATE_GITHUB_REPO = $savedOwner, $savedRepo }
        if ($updateCode -ne 0) {
            Print-Error "neodesk-server update failed"
            return $false
        }
        Stop-ServerService
    }
    $after = (Get-FileHash $serverExe -Algorithm SHA256).Hash

    Merge-ConsoleEnv -FreshInstall $false | Out-Null
    if (-not (Update-ServerServiceDefinition)) {
        Print-Warning "The Windows service $($script:SERVER_SERVICE) was not written again; $(Get-ServerAccountText)"
    }
    # Installs made before the folders were locked keep their keys
    # readable to every user otherwise
    Protect-InstallFolders | Out-Null
    Start-ServerService
    if (-not (Test-GoInstall -TimeoutSeconds 90)) {
        if ($before -ne $after -and (Test-Path "$serverExe.prev")) {
            Print-Error "The new binary did not come up; putting the previous one back"
            Stop-ServerService
            Copy-Item -Path "$serverExe.prev" -Destination $serverExe -Force
            if ((Get-ServerSupervisor) -eq "service" -and -not (Test-BinaryRunsAsService)) {
                # A release from before the service cannot answer the
                # service manager, which ends it after 30 seconds
                Print-Error "The previous binary cannot run as the Windows service. Install a release again with -Binary, or see $(Get-ServerLogPath)"
            }
            Start-ServerService
            Test-GoInstall -TimeoutSeconds 60 | Out-Null
        }
        return $false
    }

    Remove-FirstAdminPassword
    Install-ManagerScript
    Install-CommandLine
    Print-Success "neodesk-server: $(& $serverExe -version 2>$null | Select-Object -First 1)"
    Show-ConsolePortMove -Named $portNamed
    return $true
}

# Writes NeoDeskServer again as the Windows service, keeping the server's
# arguments and its other settings. An older install's NSSM service or
# scheduled task becomes that service here, with the arguments and
# settings it had (the signal and relay ports go to .env); the task and its
# launcher go. Without any, the service is made new (Setup-Services).
# $false when the service could not be written.
function Update-ServerServiceDefinition {
    $kind = Get-ServerSupervisor
    if (-not $kind) { return (Setup-Services) }
    if (-not (Test-BinaryRunsAsService)) {
        Print-Error "$(Get-ServerBinaryPath) is too old to run as a Windows service; install the newest release with $(Get-ManagerCommand '-Update')"
        return $false
    }
    $serverArgs = Get-ServerServiceArguments
    if (-not $serverArgs) { $serverArgs = Get-ServerArguments -ServerIP (Resolve-RelayIp) }
    $serverArgs = ($serverArgs -replace '\s-tls-api-port(=\S+)?', '' -replace '\s-tls-api(=\S+)?', '').Trim()
    if ($serverArgs -match '-relay-servers\s+"?([^"\s]+)') { Set-PanelPublicHost -Address $Matches[1] }
    $current = Move-PortsToEnvFile (Get-ServerServiceSettings | Where-Object { $_ -notlike 'CONSOLE_PORT=0' })
    $environment = Merge-EnvironmentLists -Lists @((Get-ServerBaseEnvironment), $current)
    # NSSM's own process must end before its service runs the binary
    if ($kind -eq "nssm") { Stop-Service -Name $script:SERVER_SERVICE -Force -ErrorAction SilentlyContinue }
    if ($kind -eq "task") { Stop-ScheduledTask -TaskName $script:SERVER_SERVICE -ErrorAction SilentlyContinue }
    if (-not (Set-ServerService -Arguments $serverArgs -Environment $environment)) { return $false }
    Remove-ServerTask
    Sync-SupervisorInEnv
    if ($kind -eq "nssm") { Print-Success "The NSSM service $($script:SERVER_SERVICE) is now the server's own Windows service: $(Get-ServerAccountText)" }
    if ($kind -eq "task") { Print-Success "The scheduled task $($script:SERVER_SERVICE) is now a Windows service: $(Get-ServerAccountText)" }
    return $true
}
function Invoke-ManagementCli {
    param(
        [Parameter(Mandatory = $true)][string]$Action,
        [string[]]$Arguments = @()
    )
    if (-not (Test-BinaryHasSubcommands)) {
        Print-Error "The management check needs an installed neodesk-server.exe"
        return $false
    }
    $code = Invoke-ServerCommand -Arguments (@("config", $Action) + $Arguments)
    return ($code -eq 0)
}

function Repair-ManagementPermissions {
    Print-Step "Repairing NeoDesk management permissions..."
    foreach ($path in @($script:RUSTDESK_PATH, $script:CONSOLE_PATH)) {
        if (-not (Test-Path $path)) { New-Item -ItemType Directory -Path $path -Force | Out-Null }
    }
    # The folders: Administrators, SYSTEM and the server's account, which
    # writes both (its data and keys, the console's .env and data)
    Protect-InstallFolders | Out-Null
    $account = @()
    if (Test-ServerIsService) { $account = @("NT SERVICE\$($script:SERVER_SERVICE):M") }
    foreach ($path in @(
        (Join-Path $script:CONSOLE_PATH ".env"),
        (Join-Path $script:RUSTDESK_PATH ".api_key"),
        (Join-Path $script:RUSTDESK_PATH "db_v2.sqlite3"),
        (Join-Path $script:RUSTDESK_PATH "id_ed25519"),
        (Join-Path $script:RUSTDESK_PATH "ssl\neodesk.key")
    )) {
        if (Test-Path $path) {
            & icacls $path /inheritance:r /grant:r "*S-1-5-32-544:F" "*S-1-5-18:F" @account 2>$null | Out-Null
        }
    }
    $seed = Join-Path $script:CONSOLE_PATH "data\modules\neodesk-support-generator\custom-client-signing.seed"
    if (Test-Path $seed) {
        $reader = @()
        if (Test-ServerIsService) { $reader = @("NT SERVICE\$($script:SERVER_SERVICE):R") }
        & icacls $seed /inheritance:r /grant:r "*S-1-5-18:F" @reader 2>$null | Out-Null
    }
    Test-ManagementCapabilities | Out-Null
}

function Set-ManagedConfiguration {
    if (-not $script:MANAGED_CONFIG_CHANGES -or $script:MANAGED_CONFIG_CHANGES.Count -eq 0) {
        Print-Error "No allowlisted configuration changes supplied"
        return $false
    }
    Print-Step "Applying allowlisted NeoDesk configuration..."
    if (-not (Invoke-ManagementCli -Action "set" -Arguments $script:MANAGED_CONFIG_CHANGES)) {
        return $false
    }
    if (Test-BehindProxy) { Remove-ConsoleFirewallRules }
    Stop-ServerService
    return (Start-ServicesWithVerification)
}

function Compile-GoServer {
    Print-Step "Compiling NeoDesk Go Server..."

    if (-not (Test-Path $script:GO_SERVER_SOURCE)) {
        Print-Error "Go server source not found at: $script:GO_SERVER_SOURCE"
        return $false
    }
    if (-not (Get-Command go -ErrorAction SilentlyContinue)) {
        if (-not (Install-Golang)) { return $false }
    }

    # The binary carries the web app: its build goes into the module first.
    # Without web-ui\build it is built here, which needs Node.js 22 and npm.
    $webUi = Join-Path (Get-RepoDir) "web-ui"
    $webBuild = Join-Path $webUi "build"
    if (-not (Test-Path (Join-Path $webBuild "index.html"))) {
        if (-not (Get-Command npm -ErrorAction SilentlyContinue)) {
            Print-Error "A build from source needs the web app: $webBuild, or Node.js 22 and npm to build it"
            return $false
        }
        Print-Step "Building the web app (npm, a few minutes)..."
        Push-Location $webUi
        try {
            & npx -y npm@11.6.2 ci --no-audit --no-fund 2>&1 | Out-Null
            & npm run build 2>&1 | Out-Null
        } finally {
            Pop-Location
        }
        if (-not (Test-Path (Join-Path $webBuild "index.html"))) {
            Print-Error "The web app build failed"
            return $false
        }
    }

    $currentDir = Get-Location
    Set-Location $script:GO_SERVER_SOURCE
    try {
        & go run ./cmd/embed-webui -from $webBuild 2>&1 | ForEach-Object { Write-Host "  $_" }
        if ($LASTEXITCODE -ne 0) {
            Print-Error "Could not copy the web app build into the server module"
            return $false
        }
        Print-Info "Building static binary..."
        $env:CGO_ENABLED = "0"
        $env:GOOS = "windows"
        $env:GOARCH = "amd64"
        $commit = ""
        if (Get-Command git -ErrorAction SilentlyContinue) {
            $commit = "$(& git -C (Get-RepoDir) rev-parse HEAD 2>$null)".Trim()
        }
        & go build -trimpath -ldflags="-s -w -X main.Version=$($script:VERSION) -X main.Commit=$commit" -o "neodesk-server.exe" . 2>&1 | ForEach-Object { Write-Host "  $_" }
    } finally {
        Set-Location $currentDir
    }

    $outputBinary = Join-Path $script:GO_SERVER_SOURCE "neodesk-server.exe"
    if (Test-Path $outputBinary) {
        $size = [math]::Round((Get-Item $outputBinary).Length / 1MB, 2)
        Print-Success "Build successful: neodesk-server.exe ($size MB)"
        return $true
    } else {
        Print-Error "Build failed - binary not created"
        return $false
    }
}

function Setup-Services {
    Print-Step "Configuring the Windows service..."

    # The database settings from an existing .env, so a reinstall keeps
    # PostgreSQL
    if (-not $script:USE_POSTGRESQL -and (Get-EnvDatabaseType) -eq "postgres") {
        $script:USE_POSTGRESQL = $true
        $script:POSTGRESQL_URI = Get-EnvDatabaseUrl
        Print-Info "Recovered PostgreSQL config from existing .env"
    }

    # Relay address: RELAY_SERVERS, else the mode (auto = public IP, local =
    # LAN IP), asked for in an interactive run
    if (-not $script:AUTO_MODE -and -not $script:RELAY_SERVERS -and $script:RELAY_MODE -eq "auto") {
        $localIp = Get-LocalIP
        Write-Host ""
        Print-Info "Relay server address controls how clients connect for remote sessions."
        Write-Host "  1) Internet / public  (auto-detect public IP - default)" -ForegroundColor Cyan
        Write-Host "  2) LAN only           (use this server's local IP: $localIp)" -ForegroundColor Cyan
        Write-Host "  3) Custom address     (enter a specific IP or host)" -ForegroundColor Cyan
        $relayChoice = Read-Host "  Select relay mode [1]"
        switch ($relayChoice) {
            "2" { $script:RELAY_MODE = "local" }
            "3" { $script:RELAY_SERVERS = Read-Host "  Enter relay address (IP or host[:port])" }
            default { $script:RELAY_MODE = "auto" }
        }
        Write-Host ""
    }

    $serverIP = Resolve-RelayIp
    $connModeEnv = Resolve-ConnectionModeEnv
    Print-Info "Relay server IP: $serverIP (mode: $(if ($script:RELAY_SERVERS) { 'fixed' } else { $script:RELAY_MODE }))"
    Set-PanelPublicHost -Address $(if ($env:SSL_DOMAIN) { $env:SSL_DOMAIN } else { $serverIP })

    $apiKeyPath = Join-Path $script:RUSTDESK_PATH ".api_key"
    if (-not (Test-Path $apiKeyPath)) {
        $apiKeyBytes = New-Object byte[] 32
        $rng = New-Object System.Security.Cryptography.RNGCryptoServiceProvider
        $rng.GetBytes($apiKeyBytes)
        $rng.Dispose()
        $apiKey = [System.BitConverter]::ToString($apiKeyBytes) -replace '-', '' | ForEach-Object { $_.ToLower() }
        Set-Content -Path $apiKeyPath -Value $apiKey -NoNewline
    }

    $serverArgs = Get-ServerArguments -ServerIP $serverIP
    $extra = @($connModeEnv)

    if (-not (Test-BinaryRunsAsService)) {
        Print-Error "$(Get-ServerBinaryPath) is too old to run as a Windows service; install the newest release"
        return $false
    }

    # Retired services of older installs
    foreach ($svc in @($script:HBBS_SERVICE, $script:HBBR_SERVICE, "NeoDeskAPI")) {
        if (Get-Service -Name $svc -ErrorAction SilentlyContinue) {
            Stop-Service -Name $svc -Force -ErrorAction SilentlyContinue
            Invoke-ServiceControl delete $svc | Out-Null
        }
    }

    # A reinstall keeps the settings the server had
    $kind = Get-ServerSupervisor
    $current = @()
    if ($kind -and (Test-GoOnlyInstall)) {
        $current = Move-PortsToEnvFile (Get-ServerServiceSettings)
    }
    if ($kind -eq "nssm") { Stop-Service -Name $script:SERVER_SERVICE -Force -ErrorAction SilentlyContinue }
    if ($kind -eq "task") { Stop-ScheduledTask -TaskName $script:SERVER_SERVICE -ErrorAction SilentlyContinue }
    $environment = Merge-EnvironmentLists -Lists @((Get-ServerBaseEnvironment), $extra, $current)
    if (-not (Set-ServerService -Arguments $serverArgs -Environment $environment)) { return $false }
    Remove-ServerTask
    Sync-SupervisorInEnv

    Print-Success "Windows service $($script:SERVER_SERVICE) configured (server and web console): $(Get-ServerAccountText)"
    return $true
}

function Start-Services {
    Start-ServicesWithVerification | Out-Null
}

function Start-ServicesWithVerification {
    Print-Step "Starting $($script:SERVER_SERVICE) with health verification..."

    $running = Get-Process -Name "neodesk-server" -ErrorAction SilentlyContinue
    if (-not $running) {
        $hasErrors = $false
        if (-not (Test-PortAvailable -Port 21116 -ServiceName "neodesk-server")) { $hasErrors = $true }
        if (-not (Test-PortAvailable -Port 21117 -ServiceName "neodesk-server")) { $hasErrors = $true }
        if ($hasErrors) {
            Print-Error "Cannot start neodesk-server - ports in use"
            Print-Info "Use: Get-NetTCPConnection -State Listen | Where-Object LocalPort -in 21116,21117"
            return $false
        }
    }
    Start-ServerService
    if (-not (Test-GoInstall -TimeoutSeconds 90)) {
        Print-Error "neodesk-server did not come up"
        return $false
    }
    Print-Success "neodesk-server started and verified"
    return $true
}

# Minimal installation: the same server with its web console off
# (CONSOLE_PORT=0 in .env); setting a port there turns it on.
function Do-InstallMinimal {
    $script:MINIMAL_MODE = $true
    Do-Install
}

function Do-Update {
    Print-Header
    Write-Host "========== UPDATE ==========" -ForegroundColor White
    Write-Host ""

    Detect-Installation

    if (Test-NodeEraInstall) {
        Stop-NodeEraInstall
        Press-Enter
        return $false
    }
    if ($script:INSTALL_STATUS -eq "none") {
        Print-Error "NeoDesk is not installed!"
        Print-Info "Use 'FRESH INSTALLATION' option"
        Press-Enter
        return $false
    }

    # Detect Rust -> Go upgrade (major architecture change)
    if ($script:SERVER_TYPE -eq "rust") {
        Print-Warning "Legacy Rust server (hbbs/hbbr) detected!"
        Print-Warning "Upgrading from Rust to Go server requires a FRESH INSTALLATION."
        Print-Info "Your data (keys, database) will be preserved during migration."
        Write-Host ""
        if ($script:AUTO_MODE -or (Confirm-Action "Proceed with fresh installation (recommended)?")) {
            Do-Install
        }
        return $true
    }

    # CRITICAL: Preserve database configuration before the .env is merged
    Preserve-DatabaseConfig
    Read-UpdateGitHubBranchFromEnv


    $channel = if ($script:UPDATE_GITHUB_BRANCH -eq "dev") { "development" } else { "stable" }
    Print-Info "Update channel: $($script:UPDATE_GITHUB_BRANCH) ($channel)"
    if (-not $script:AUTO_MODE) {
        $items = @(
            "Update now`tInstall the newest release of the update channel",
            "Switch update channel`tChoose stable (main) or development (dev)",
            "Back`tReturn to the main menu"
        )
        $returns = @("1", "2", "0")
        Invoke-MenuChoose -Title "Update" -Subtitle "Releases are checked by SHA-256 and their signature before they replace the binary" -Items $items -Returns $returns
        switch ($script:MENU_CHOICE) {
            "0" { return $true }
            "2" { Switch-UpdateChannel; return $true }
        }
    }

    $ok = Update-GoInstall
    if (-not $ok) { Print-Error "Update failed" }
    Press-Enter
    return $ok
}

function Repair-Binaries {
    Print-Step "Repairing neodesk-server.exe..."
    if (Test-NodeEraInstall) {
        Stop-NodeEraInstall
        return
    }
    if (-not (Get-StagedServerBinary)) {
        Remove-Item -Path $script:STAGED_SERVER_DIR -Recurse -Force -ErrorAction SilentlyContinue
        Print-Error "Could not get a server binary"
        return
    }
    Stop-ServerService
    $installed = Install-StagedBinary -Suffix ".prev"
    Remove-Item -Path $script:STAGED_SERVER_DIR -Recurse -Force -ErrorAction SilentlyContinue
    if (-not $installed) { Start-ServerService; return }
    if (-not (Start-ServicesWithVerification)) {
        Print-Error "neodesk-server failed to start after the binary repair"
        return
    }
    Print-Success "Server binary repaired and verified!"
}

# The server migrates its tables at every start.
function Repair-Database {
    Print-Step "Repairing database..."
    Print-Info "neodesk-server migrates its tables at start; restarting it"
    Stop-ServerService
    if (Start-ServicesWithVerification) {
        Print-Success "Database checked by the server's start"
    }
}

function Repair-Services {
    Print-Step "Repairing the Windows service..."
    if (Test-NodeEraInstall) {
        Stop-NodeEraInstall
        return
    }
    if (-not (Test-Path (Get-ServerBinaryPath))) {
        Print-Error "neodesk-server.exe not found at $script:RUSTDESK_PATH"
        Print-Info "Run 'Repair binaries' first"
        return
    }
    Stop-ServerService
    if (-not (Update-ServerServiceDefinition)) {
        Print-Error "The Windows service $($script:SERVER_SERVICE) could not be written"
        return
    }
    if (-not (Start-ServicesWithVerification)) {
        Print-Error "neodesk-server failed to start after the repair"
        return
    }
    Print-Success "Service repaired and verified!"
}

function Do-ResetPassword {
    Print-Header
    Write-Host "========== ADMIN PASSWORD RESET ==========" -ForegroundColor White
    Write-Host ""

    Auto-DetectPaths
    Detect-Installation
    if (Test-NodeEraInstall) {
        Stop-NodeEraInstall
        Press-Enter
        return $false
    }

    $newPassword = $null
    if ($script:RESET_PASSWORD_MODE) {
        # -ResetPassword: ADMIN_PASSWORD, else a random one
        if ($env:ADMIN_PASSWORD) {
            $newPassword = $env:ADMIN_PASSWORD
            if ($newPassword.Length -lt 8) {
                Print-Error "ADMIN_PASSWORD must be at least 8 characters"
                return $false
            }
        } else {
            $newPassword = Generate-RandomPassword
        }
    } else {
        $items = @(
            "Generate random password`tCreate a strong random admin password",
            "Set custom password`tType a new password (min. 8 characters)",
            "Back`tReturn to the main menu"
        )
        $returns = @("1", "2", "0")
        Invoke-MenuChoose -Title "Admin Password Reset" -Subtitle "The account admin of the web console" -Items $items -Returns $returns
        switch ($script:MENU_CHOICE) {
            "1" { $newPassword = Generate-RandomPassword }
            "2" {
                $secure = Read-Host "Enter new password (min. 8 characters)" -AsSecureString
                $newPassword = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure))
                if ($newPassword.Length -lt 8) {
                    Print-Error "Password must be at least 8 characters!"
                    Press-Enter
                    return $false
                }
            }
            default { return $true }
        }
    }

    # The server sets it on the console's database (SQLite or PostgreSQL);
    # the password goes in on standard input, never in the arguments
    $resetArgs = @("reset-password")
    if ($script:RESET_TWO_FACTOR) {
        # An older binary takes the switch for a second name and refuses
        if (-not (Test-BinaryResetsTwoFactor)) {
            Print-Error "The installed neodesk-server cannot turn off two-factor sign-in; update it first: $(Get-ManagerCommand '-Update')"
            return $false
        }
        $resetArgs += "--reset-two-factor"
    }
    $resetArgs += "admin"
    $code = Invoke-ServerCommand -Arguments $resetArgs -InputText $newPassword
    Write-Host ""
    if ($code -eq 0) {
        # DEFAULT_ADMIN_PASSWORD in .env must match, or the next start with a
        # forced password update would set the old one again
        if (Get-ConsoleEnvValue -Key "DEFAULT_ADMIN_PASSWORD") {
            Set-ConsoleEnvValue -Key "DEFAULT_ADMIN_PASSWORD" -Value $newPassword
        }
        Write-Host "============================================================" -ForegroundColor Green
        Write-Host "              NEW LOGIN CREDENTIALS                         " -ForegroundColor Green
        Write-Host "============================================================" -ForegroundColor Green
        Write-Host "  Login:    " -NoNewline; Write-Host "admin" -ForegroundColor White
        Write-Host "  Password: " -NoNewline; Write-Host $newPassword -ForegroundColor White
        Write-Host "============================================================" -ForegroundColor Green
        if ($script:RESET_TWO_FACTOR) {
            Print-Info "Two-factor sign-in of admin is off; where it is required, admin sets it up again at the next sign-in"
        }
        if ($script:STORE_ADMIN_CREDENTIALS) {
            "admin:$newPassword" | Out-File -FilePath (Join-Path $script:RUSTDESK_PATH ".admin_credentials") -Encoding UTF8
        }
    } else {
        Print-Error "Failed to reset password!"
        Print-Info "Check the database settings in $(Join-Path $script:CONSOLE_PATH '.env')"
    }
    Press-Enter
    return ($code -eq 0)
}

# The admin's first password, only when this run made the console's .env;
# the summary at the end of the install shows it, once. The server makes
# the admin at its first start from DEFAULT_ADMIN_PASSWORD.
function Create-AdminUser {
    Print-Step "Admin account..."

    if (-not $script:FRESH_CONSOLE_ENV) {
        Print-Info "The admin account and its password stay as they are."
        Print-Info "Forgot it? $(Get-ManagerCommand '-ResetPassword')"
        return $null
    }
    $adminPassword = $env:ADMIN_PASSWORD
    if (-not $adminPassword) { $adminPassword = Get-ConsoleEnvValue -Key "DEFAULT_ADMIN_PASSWORD" }

    if ($adminPassword) {
        Print-Info "The admin's password is in the summary at the end"
        if ($script:STORE_ADMIN_CREDENTIALS) {
            $mainCredsFile = Join-Path $script:RUSTDESK_PATH ".admin_credentials"
            "admin:$adminPassword" | Out-File -FilePath $mainCredsFile -Encoding UTF8
            Print-Info "Credentials saved in: $mainCredsFile"
        }
        return $adminPassword
    }
    Print-Warning "No admin password found"
    Print-Info "Use password reset option to set a new admin password"
    return $null
}

# Once the server has started and made the admin, .env and its kept
# copies hold no admin password any more (the server reads
# DEFAULT_ADMIN_PASSWORD and INIT_ADMIN_PASS only to make the first account).
function Remove-FirstAdminPassword {
    $envFile = Join-Path $script:CONSOLE_PATH ".env"
    foreach ($f in @($envFile) + @(Get-ChildItem -Path $script:CONSOLE_PATH -Filter ".env.pre-go*" -Force -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })) {
        if (-not (Test-Path $f)) { continue }
        $lines = @(Get-Content $f)
        $kept = @($lines | Where-Object { $_ -notmatch '^INIT_ADMIN_PASS=' } | ForEach-Object { if ($_ -match '^DEFAULT_ADMIN_PASSWORD=') { 'DEFAULT_ADMIN_PASSWORD=' } else { $_ } })
        if (($kept -join "`n") -ne ($lines -join "`n")) { Set-Content -Path $f -Value $kept -Encoding UTF8 }
    }
}

# The folder of the release this installer's copy comes from:
# RELEASE_BASE_URL, else the one this run downloaded the binary from, else
# the release of the installed binary's version, or the "dev" release on
# the development channel. $null when none is known.
function Get-InstallerReleaseBase {
    if ($env:RELEASE_BASE_URL) { return $env:RELEASE_BASE_URL.TrimEnd('/') }
    if ($script:RELEASE_FOLDER_USED) { return $script:RELEASE_FOLDER_USED }
    $releases = "https://github.com/$($script:UPDATE_GITHUB_OWNER)/$($script:UPDATE_GITHUB_REPO)/releases/download"
    Read-UpdateGitHubBranchFromEnv
    if ($script:UPDATE_GITHUB_BRANCH -eq "dev") { return "$releases/dev" }
    $line = ""
    try { $line = "$(& (Get-ServerBinaryPath) -version 2>$null | Select-Object -First 1)" } catch { return $null }
    if ($line -match '^neodesk-server (\d+\.\d+\.\d+(-[0-9A-Za-z.]+)?) ') { return "$releases/v$($Matches[1])" }
    return $null
}

# True when the binary checks a file of a release against the release's
# signed SHA256SUMS (verify-release --sums).
function Test-BinaryChecksFileLists {
    param([string]$Path)
    if (-not $Path -or -not (Test-Path $Path)) { return $false }
    return [bool](Select-String -Path $Path -Pattern 'verify-release --sums FILE' -SimpleMatch -Quiet)
}

# neodesk.ps1 of the release (Get-InstallerReleaseBase) at $Dest, when the
# release's SHA256SUMS names it and the installed binary verifies the
# list's signature (verify-release --sums; an older binary or -SkipVerify:
# the SHA-256 only). Returns "ok", "none" when the release has no
# neodesk.ps1 (3.6.0-rc.4 and older) or "refused".
function Get-ReleaseInstaller {
    param([string]$Dest)
    $base = Get-InstallerReleaseBase
    if (-not $base) { return "none" }
    $dir = Join-Path ([IO.Path]::GetTempPath()) ("neodesk-installer-" + [Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $sums = Join-Path $dir "SHA256SUMS"
        $file = Join-Path $dir "neodesk.ps1"
        $sig = Join-Path $dir "SHA256SUMS.sig"
        try {
            Invoke-WebRequest -Uri "$base/SHA256SUMS" -OutFile $sums -UseBasicParsing -ErrorAction Stop
        } catch { return "none" }
        $expected = $null
        foreach ($line in Get-Content $sums) {
            $parts = $line.Trim() -split '\s+', 2
            if ($parts.Count -eq 2 -and ($parts[1] -eq "neodesk.ps1" -or $parts[1] -eq "*neodesk.ps1")) { $expected = $parts[0].ToLower(); break }
        }
        if (-not $expected) { return "none" }
        try {
            Invoke-WebRequest -Uri "$base/neodesk.ps1" -OutFile $file -UseBasicParsing -ErrorAction Stop
        } catch { return "none" }
        try { Invoke-WebRequest -Uri "$base/SHA256SUMS.sig" -OutFile $sig -UseBasicParsing -ErrorAction Stop } catch { }
        if ((Get-FileHash -Path $file -Algorithm SHA256).Hash.ToLower() -ne $expected) { return "refused" }
        if (-not (Select-String -Path $file -Pattern 'function Install-ManagerScript' -SimpleMatch -Quiet)) { return "refused" }
        $exe = Get-ServerBinaryPath
        if ($script:SKIP_VERIFY) {
            Print-Warning "The signature of the release's neodesk.ps1 is not checked (-SkipVerify)"
        } elseif (Test-BinaryChecksFileLists -Path $exe) {
            if (-not (Test-Path $sig)) { return "refused" }
            & $exe verify-release --sums $sums --signature $sig --name neodesk.ps1 $file 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) { return "refused" }
        } else {
            Print-Warning "The installed neodesk-server cannot check the signature of the release's neodesk.ps1, only its SHA-256"
        }
        Copy-Item -Path $file -Destination $Dest -Force -ErrorAction Stop
        return "ok"
    } finally {
        Remove-Item -Path $dir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# This script as C:\NeoDesk\neodesk.ps1, for updates, repairs and the
# uninstall later. Run from another file (a download, a checkout), it
# takes itself. Run from that copy (an update) or from Invoke-Expression,
# it takes neodesk.ps1 of the release it installs (Get-ReleaseInstaller),
# and keeps the copy when that release has none or it does not pass the
# check.
function Install-ManagerScript {
    $target = Join-Path $script:RUSTDESK_PATH "neodesk.ps1"
    try {
        if ($script:SELF_PATH -and (Test-Path $script:SELF_PATH) -and ((Resolve-Path $script:SELF_PATH).Path -ne $target)) {
            Copy-Item -Path $script:SELF_PATH -Destination $target -Force -ErrorAction Stop
        } else {
            $tmp = "$target.download"
            $got = Get-ReleaseInstaller -Dest $tmp
            if ($got -eq "ok") {
                Move-Item -Path $tmp -Destination $target -Force
            } else {
                Remove-Item -Path $tmp -Force -ErrorAction SilentlyContinue
                if ($got -eq "refused") { Print-Warning "The release's neodesk.ps1 did not pass its check, so $target stays as it is" }
                if (-not (Test-Path $target)) { throw "no installer copy" }
            }
        }
        Print-Info "Manage this install with: $(Get-ManagerCommand)"
        # An elevated PowerShell starts in System32, where a download
        # with a bare file name lands
        if ($script:SELF_PATH -and $env:windir -and (Split-Path -Parent $script:SELF_PATH) -like "$env:windir\*") {
            Print-Info "The downloaded $($script:SELF_PATH) is no longer needed: Remove-Item '$($script:SELF_PATH)'"
        }
    } catch {
        if (-not (Test-Path $target)) { Print-Warning "Could not keep a copy of the installer at ${target}: run this installer again for updates" }
    }
}

# The machine's Path, from the registry: the folders every new terminal
# finds commands in.
function Get-MachinePath { [Environment]::GetEnvironmentVariable("Path", "Machine") }
function Set-MachinePath([string]$Value) { [Environment]::SetEnvironmentVariable("Path", $Value, "Machine") }

# neodesk, the command line, on the Path: bin\neodesk.exe in the server's
# folder, a link to neodesk-server.exe (the binary is the command line
# when it is called neodesk), and that bin folder in the machine's Path.
# The link names the binary's path, so it follows the console's own
# updates, which put a new binary there.
function Install-CommandLine {
    $serverExe = Join-Path $script:RUSTDESK_PATH "neodesk-server.exe"
    $binDir = Join-Path $script:RUSTDESK_PATH "bin"
    $link = Join-Path $binDir "neodesk.exe"
    if (-not (Test-Path $serverExe)) { return }
    try {
        New-Item -ItemType Directory -Path $binDir -Force | Out-Null
        $item = Get-Item -LiteralPath $link -Force -ErrorAction SilentlyContinue
        if ($item -and $item.LinkType -ne "SymbolicLink") {
            Print-Warning "$link is another program, so it stays; the command line runs as: & '$serverExe' cli"
            return
        }
        if ($item) { Remove-Item -LiteralPath $link -Force -ErrorAction Stop }
        New-Item -ItemType SymbolicLink -Path $link -Target $serverExe -ErrorAction Stop | Out-Null
    } catch {
        Print-Warning "Could not make the command line ${link}: $($_.Exception.Message). It runs as: & '$serverExe' cli"
        return
    }
    $entries = @((Get-MachinePath) -split ';' | Where-Object { $_ })
    if ($entries -notcontains $binDir) { Set-MachinePath (($entries + $binDir) -join ';') }
    if (@($env:Path -split ';') -notcontains $binDir) { $env:Path = "$env:Path;$binDir" }
    Print-Info "The command line: neodesk --help (in a new window run as administrator)"
}

# Remove-CommandLine: the link bin\neodesk.exe and its folder in the
# machine's Path go (the uninstall).
function Remove-CommandLine {
    $binDir = Join-Path $script:RUSTDESK_PATH "bin"
    $link = Join-Path $binDir "neodesk.exe"
    $item = Get-Item -LiteralPath $link -Force -ErrorAction SilentlyContinue
    if ($item -and $item.LinkType -eq "SymbolicLink") { Remove-Item -LiteralPath $link -Force -ErrorAction SilentlyContinue }
    $entries = @((Get-MachinePath) -split ';' | Where-Object { $_ })
    if ($entries -contains $binDir) { Set-MachinePath (@($entries | Where-Object { $_ -ne $binDir }) -join ';') }
    $env:Path = (@($env:Path -split ';' | Where-Object { $_ -and $_ -ne $binDir }) -join ';')
}

# What the admin needs after an install: the console's address, also the
# one on this machine's network, the first sign-in with the password when
# this run made it (-AdminPassword; it is not shown again), what RustDesk
# clients are given, how the server runs, the log, the settings file and
# the commands for later.
function Show-InstallSummary {
    param([string]$AdminPassword = "")
    $envFile = Join-Path $script:CONSOLE_PATH ".env"
    $hostName = Get-ConsoleEnvValue -Key "PANEL_PUBLIC_HOST"
    if (-not $hostName) { $hostName = Get-PublicIP }
    $pubKeyPath = Join-Path $script:RUSTDESK_PATH "id_ed25519.pub"
    $key = if (Test-Path $pubKeyPath) { (Get-Content $pubKeyPath -Raw).Trim() } else { "" }
    $console = "off (set CONSOLE_PORT in $envFile to turn it on)"
    $lanConsole = ""
    $healthUrl = Get-ConsoleHealthUrl
    if (-not $script:MINIMAL_MODE -and $healthUrl) {
        $base = $healthUrl -replace '/health$', ''
        $console = $base -replace '127\.0\.0\.1', $hostName
        # Behind NAT the public address works from this network only with
        # port forwarding that loops back, so the LAN address goes with it
        $lanIP = Get-LocalIP
        if ($lanIP -and $lanIP -ne "127.0.0.1" -and $lanIP -ne $hostName) { $lanConsole = $base -replace '127\.0\.0\.1', $lanIP }
    }
    $signal = Get-SignalPort
    $relay = Get-RelayPort
    $idServer = if ($signal -eq "21116") { $hostName } else { "${hostName}:$signal" }
    $relayServer = if ($relay -eq "21117") { $hostName } else { "${hostName}:$relay" }
    Write-Host ""
    Write-Host "NeoDesk is installed" -ForegroundColor Green
    Write-Host ""
    Write-Host "  Web console:   " -NoNewline; Write-Host $console -ForegroundColor White
    if ($lanConsole) { Write-Host "  On your LAN:   " -NoNewline; Write-Host $lanConsole -ForegroundColor White }
    if ($AdminPassword) {
        Write-Host "  First sign-in: user " -NoNewline; Write-Host "admin" -ForegroundColor White -NoNewline
        Write-Host ", password " -NoNewline; Write-Host $AdminPassword -ForegroundColor White
        Write-Host "                 Copy the password now: it is not shown again."
    } else {
        Write-Host "  Sign in:       user admin; forgot the password? $(Get-ManagerCommand '-ResetPassword')"
    }
    Write-Host "  RustDesk clients (Settings > Network > ID/Relay server):"
    Write-Host "    ID server:     " -NoNewline; Write-Host $idServer -ForegroundColor White
    Write-Host "    Relay server:  " -NoNewline; Write-Host $relayServer -ForegroundColor White
    $apiPort = Get-ConsoleEnvValue -Key "API_PORT"
    if (-not $apiPort) { $apiPort = $script:CLIENT_API_PORT }
    $apiScheme = if ((Get-ConsoleEnvValue -Key "RUSTDESK_API_TLS") -match '^(?i)(true|1|on|https)$') { "https" } else { "http" }
    Write-Host "    API server:    " -NoNewline; Write-Host "${apiScheme}://${hostName}:$apiPort" -ForegroundColor White
    Write-Host "    Key:           " -NoNewline; Write-Host $key -ForegroundColor White
    Write-Host "  Runs as:       $(Get-ServerAccountText)"
    Write-Host "  Log:           $(Get-ServerLogPath)"
    Write-Host "  Settings:      $envFile (then: $(Get-RestartCommand))"
    Write-Host "  Commands for later, in a PowerShell or cmd window run as administrator:"
    Write-Host "    Update:          $(Get-ManagerCommand '-Update')"
    Write-Host "    Reset password:  $(Get-ManagerCommand '-ResetPassword')"
    Write-Host "    Uninstall:       $(Get-ManagerCommand '-Uninstall')"
    Write-Host "    Menu:            $(Get-ManagerCommand)"
    Write-Host "    Command line:    neodesk --help (in a new window)"
    if ("$healthUrl" -like 'https://*' -and (Get-ConsoleEnvValue -Key "SSL_CERT_PATH") -eq (Join-Path $script:RUSTDESK_PATH "ssl\neodesk.crt")) {
        Write-Host "  Certificate:   self-signed, so the browser warns once; your own: Configure SSL certificates, Custom certificate in the menu"
    }
    Write-Host "  Help:          $($script:HELP_URL)"
    Write-Host ""
}

function Update-EnvForTLS {
    param(
        [string]$CertPath,
        [string]$KeyPath,
        [bool]$UpdateApiUrls = $false
    )
    $envFile = Join-Path $script:CONSOLE_PATH ".env"
    if (Test-Path $envFile) {
        $content = Get-Content $envFile -Raw
        $content = $content -replace 'HTTPS_ENABLED=.*', 'HTTPS_ENABLED=true'
        $content = $content -replace 'SSL_CERT_PATH=.*', "SSL_CERT_PATH=$CertPath"
        $content = $content -replace 'SSL_KEY_PATH=.*', "SSL_KEY_PATH=$KeyPath"
        # Internal Go API URLs must stay HTTP for RustDesk client compatibility.
        $content = $content -replace 'HBBS_API_URL=https://localhost', 'HBBS_API_URL=http://localhost'
        $content = $content -replace 'NEODESK_API_URL=https://localhost', 'NEODESK_API_URL=http://localhost'
        # Only the Node.js console read NODE_EXTRA_CA_CERTS
        $content = $content -replace '(?m)^NODE_EXTRA_CA_CERTS=.*\r?\n?', ''
        Set-Content -Path $envFile -Value $content -NoNewline
        Print-Info "Updated .env with HTTPS configuration"
    }
}

#===============================================================================
# Detection Functions
#===============================================================================

function Detect-Installation {
    $script:INSTALL_STATUS = "none"
    $script:SERVER_RUNNING = $false
    $script:HBBS_RUNNING = $false
    $script:HBBR_RUNNING = $false
    $script:CONSOLE_RUNNING = $false
    $script:BINARIES_OK = $false
    $script:DATABASE_OK = $false
    $script:CONSOLE_TYPE = "none"
    $script:SERVER_TYPE = "none"
    
    # Check paths and binary type
    if (Test-Path $script:RUSTDESK_PATH) {
        # Check for Go server first
        if (Test-Path "$script:RUSTDESK_PATH\neodesk-server.exe") {
            $script:BINARIES_OK = $true
            $script:SERVER_TYPE = "go"
            $script:INSTALL_STATUS = "partial"
        }
        # Fallback: Check for legacy Rust binaries
        elseif ((Test-Path "$script:RUSTDESK_PATH\hbbs.exe") -or (Test-Path "$script:RUSTDESK_PATH\hbbs-v8-api.exe")) {
            $script:BINARIES_OK = $true
            $script:SERVER_TYPE = "rust"
            $script:INSTALL_STATUS = "partial"
            Print-Warning "Legacy Rust binaries detected. Consider upgrading to Go server."
        }
    }
    
    # Check database (SQLite file or PostgreSQL)
    if ((Get-EnvDatabaseType) -eq "postgres") {
        # PostgreSQL: we trust the config -- full validation is done by Do-Validate
        $script:DATABASE_OK = $true
    } elseif (Test-Path "$script:RUSTDESK_PATH\db_v2.sqlite3") {
        $script:DATABASE_OK = $true
    }
    
    # Detect console type: the console inside the server, or the old Node.js one
    if (Test-Path $script:CONSOLE_PATH) {
        if ((Test-GoOnlyInstall) -and (Test-Path "$script:CONSOLE_PATH\.env")) {
            $script:CONSOLE_TYPE = "go"
        } elseif ((Test-Path "$script:CONSOLE_PATH\server.js") -or (Test-Path "$script:CONSOLE_PATH\package.json")) {
            $script:CONSOLE_TYPE = "nodejs"
        }

        if ($script:CONSOLE_TYPE -ne "none" -and $script:BINARIES_OK) {
            $script:INSTALL_STATUS = "complete"
        }
    }
    
    # Check services - Go server first
    $serverService = Get-Service -Name $script:SERVER_SERVICE -ErrorAction SilentlyContinue
    if ($serverService -and $serverService.Status -eq 'Running') {
        $script:SERVER_RUNNING = $true
        $script:HBBS_RUNNING = $true  # Go handles both
        $script:HBBR_RUNNING = $true
    } else {
        # Check legacy Rust services
        $hbbsService = Get-Service -Name $script:HBBS_SERVICE -ErrorAction SilentlyContinue
        if ($hbbsService -and $hbbsService.Status -eq 'Running') {
            $script:HBBS_RUNNING = $true
        }
        
        $hbbrService = Get-Service -Name $script:HBBR_SERVICE -ErrorAction SilentlyContinue
        if ($hbbrService -and $hbbrService.Status -eq 'Running') {
            $script:HBBR_RUNNING = $true
        }
    }
    
    if ($script:CONSOLE_TYPE -eq "go") {
        $script:CONSOLE_RUNNING = $script:SERVER_RUNNING -or [bool](Get-Process -Name "neodesk-server" -ErrorAction SilentlyContinue)
    } else {
        $consoleService = Get-Service -Name $script:CONSOLE_SERVICE -ErrorAction SilentlyContinue
        if ($consoleService -and $consoleService.Status -eq 'Running') {
            $script:CONSOLE_RUNNING = $true
        }
    }
}

# Preserve database configuration from existing .env file
# This MUST be called before the .env is merged during UPDATE/REPAIR
# to prevent switching from PostgreSQL to SQLite
function Preserve-DatabaseConfig {
    $envFile = Join-Path $script:CONSOLE_PATH ".env"
    
    if (Test-Path $envFile) {
        if ((Get-EnvDatabaseType) -eq "postgres") {
            $script:USE_POSTGRESQL = $true
            $script:POSTGRESQL_URI = Get-EnvDatabaseUrl
            Print-Info "Preserving PostgreSQL configuration from existing .env"
        } else {
            $script:USE_POSTGRESQL = $false
            $script:POSTGRESQL_URI = ""
            Print-Info "Preserving SQLite configuration from existing .env"
        }
    }
}

function Auto-DetectPaths {
    $found = $false
    
    # Check configured path first - Go server or legacy Rust
    if ($script:RUSTDESK_PATH -and (Test-Path $script:RUSTDESK_PATH)) {
        if ((Test-Path "$script:RUSTDESK_PATH\neodesk-server.exe") -or 
            (Test-Path "$script:RUSTDESK_PATH\hbbs.exe") -or 
            (Test-Path "$script:RUSTDESK_PATH\hbbs-v8-api.exe")) {
            Print-Info "Using configured RustDesk path: $script:RUSTDESK_PATH"
            $found = $true
        }
    }
    
    # Auto-detect if not found
    if (-not $found) {
        foreach ($path in $script:COMMON_RUSTDESK_PATHS) {
            if ((Test-Path $path) -and 
                ((Test-Path "$path\neodesk-server.exe") -or 
                 (Test-Path "$path\hbbs.exe") -or 
                 (Test-Path "$path\hbbs-v8-api.exe"))) {
                $script:RUSTDESK_PATH = $path
                Print-Success "Detected RustDesk installation: $script:RUSTDESK_PATH"
                $found = $true
                break
            }
        }
    }
    
    # Default path for new installations
    if (-not $found) {
        $script:RUSTDESK_PATH = "C:\NeoDesk"
        Print-Info "No installation detected. Default path: $script:RUSTDESK_PATH"
    }
    
    # Auto-detect Console path and type
    $consoleFound = $false
    $script:CONSOLE_TYPE = "none"
    
    # The console's folder holds its .env and data (and, before the upgrade,
    # the Node.js console's code)
    foreach ($path in $script:COMMON_CONSOLE_PATHS) {
        if ((Test-Path $path) -and ((Test-Path "$path\.env") -or (Test-Path "$path\server.js"))) {
            $script:CONSOLE_PATH = $path
            Print-Success "Detected the console folder: $script:CONSOLE_PATH"
            $consoleFound = $true
            break
        }
    }

    if (-not $consoleFound) {
        $script:CONSOLE_PATH = "C:\NeoDeskConsole"
    }
    if (Test-GoOnlyInstall) {
        $script:CONSOLE_TYPE = "go"
    } elseif (Test-Path "$script:CONSOLE_PATH\server.js") {
        $script:CONSOLE_TYPE = "nodejs"
    }
    
    # Update DB_PATH
    $script:DB_PATH = "$script:RUSTDESK_PATH\db_v2.sqlite3"
}

function Print-Status {
    Detect-Installation
    
    Write-Host ""
    Write-Host "=== System Status ===" -ForegroundColor White
    Write-Host ""
    Write-Host "  System:       " -NoNewline; Write-Host "Windows $([System.Environment]::OSVersion.Version)" -ForegroundColor Cyan
    Write-Host "  Architecture: " -NoNewline; Write-Host $env:PROCESSOR_ARCHITECTURE -ForegroundColor Cyan
    Write-Host ""
    
    Write-Host "=== Configured Paths ===" -ForegroundColor White
    Write-Host ""
    Write-Host "  RustDesk:     " -NoNewline; Write-Host $script:RUSTDESK_PATH -ForegroundColor Cyan
    Write-Host "  Console:      " -NoNewline; Write-Host $script:CONSOLE_PATH -ForegroundColor Cyan
    Write-Host "  Database:     " -NoNewline; Write-Host $script:DB_PATH -ForegroundColor Cyan
    Write-Host ""
    
    Write-Host "=== Installation Status ===" -ForegroundColor White
    Write-Host ""
    
    switch ($script:INSTALL_STATUS) {
        "complete" { Write-Host "  Status:       " -NoNewline; Write-Host "[OK] Installed" -ForegroundColor Green }
        "partial"  { Write-Host "  Status:       " -NoNewline; Write-Host "[!] Partial installation" -ForegroundColor Yellow }
        "none"     { Write-Host "  Status:       " -NoNewline; Write-Host "[X] Not installed" -ForegroundColor Red }
    }
    
    if ($script:BINARIES_OK) {
        $serverLabel = if ($script:SERVER_TYPE -eq "go") { " (Go: signal + relay + API)" } else { " (Legacy Rust)" }
        Write-Host "  Server:       " -NoNewline; Write-Host "[OK]$serverLabel" -ForegroundColor Green
    } else {
        Write-Host "  Server:       " -NoNewline; Write-Host "[X] Not found" -ForegroundColor Red
    }
    
    if ($script:DATABASE_OK) {
        Write-Host "  Database:     " -NoNewline; Write-Host "[OK]" -ForegroundColor Green
    } else {
        Write-Host "  Database:     " -NoNewline; Write-Host "[X] Not found" -ForegroundColor Red
    }
    
    if (Test-Path $script:CONSOLE_PATH) {
        $consoleTypeLabel = switch ($script:CONSOLE_TYPE) {
            "go" { " (inside neodesk-server)" }
            "nodejs" { " (Node.js; Update moves it into neodesk-server)" }
            default { "" }
        }
        Write-Host "  Web Console:  " -NoNewline; Write-Host "[OK]$consoleTypeLabel" -ForegroundColor Green
    } else {
        Write-Host "  Web Console:  " -NoNewline; Write-Host "[X] Not found" -ForegroundColor Red
    }
    
    Write-Host ""
    Write-Host "=== Services Status ===" -ForegroundColor White
    Write-Host ""
    
    # Check if using Go server or legacy Rust
    if ($script:SERVER_RUNNING -or $script:SERVER_TYPE -eq "go") {
        if ($script:SERVER_RUNNING) {
            Write-Host "  NeoDesk Server (Go): " -NoNewline; Write-Host "* Active (Signal + Relay + API)" -ForegroundColor Green
        } else {
            # Check service state for better diagnostics
            $svc = Get-Service -Name $script:SERVER_SERVICE -ErrorAction SilentlyContinue
            if ($svc -and $svc.Status -eq 'Stopped') {
                Write-Host "  NeoDesk Server (Go): " -NoNewline; Write-Host "o Stopped" -ForegroundColor Red
                Write-Host "    Hint: Check the log $(Get-ServerLogPath)" -ForegroundColor Yellow
            } else {
                Write-Host "  NeoDesk Server (Go): " -NoNewline; Write-Host "o Inactive" -ForegroundColor Red
            }
        }
    } else {
        # Legacy Rust services
        if ($script:HBBS_RUNNING) {
            Write-Host "  HBBS (Signal): " -NoNewline; Write-Host "* Active " -ForegroundColor Green -NoNewline
            Write-Host "(Legacy Rust)" -ForegroundColor Yellow
        } else {
            Write-Host "  HBBS (Signal): " -NoNewline; Write-Host "o Inactive" -ForegroundColor Red
        }
        
        if ($script:HBBR_RUNNING) {
            Write-Host "  HBBR (Relay):  " -NoNewline; Write-Host "* Active " -ForegroundColor Green -NoNewline
            Write-Host "(Legacy Rust)" -ForegroundColor Yellow
        } else {
            Write-Host "  HBBR (Relay):  " -NoNewline; Write-Host "o Inactive" -ForegroundColor Red
        }
    }
    
    if ($script:CONSOLE_RUNNING) {
        Write-Host "  Web Console:   " -NoNewline; Write-Host "* Active" -ForegroundColor Green
    } elseif ($script:CONSOLE_TYPE -eq "go") {
        Write-Host "  Web Console:   " -NoNewline; Write-Host "o Inactive (part of $($script:SERVER_SERVICE))" -ForegroundColor Red
    } else {
        $consoleSvc = Get-Service -Name $script:CONSOLE_SERVICE -ErrorAction SilentlyContinue
        if ($consoleSvc -and $consoleSvc.Status -eq 'Stopped') {
            Write-Host "  Web Console:   " -NoNewline; Write-Host "o Stopped" -ForegroundColor Red
            Write-Host "    Hint: Check logs at $script:CONSOLE_PATH\logs\console_error.log" -ForegroundColor Yellow
        } else {
            Write-Host "  Web Console:   " -NoNewline; Write-Host "o Inactive" -ForegroundColor Red
        }
    }
    
    Write-Host ""
}

#===============================================================================
# Go Installation and Compilation Functions
#===============================================================================

function Get-GoVersionPart {
    param(
        [string]$Version,
        [int]$Index = 0
    )
    $normalized = ($Version -replace '[^0-9.]', '')
    $parts = $normalized -split '\.'
    if ($Index -lt $parts.Count -and $parts[$Index] -match '^\d+$') {
        return [int]$parts[$Index]
    }
    return 0
}

function Test-GoInstalled {
    $goCmd = Get-Command go -ErrorAction SilentlyContinue
    if (-not $goCmd) {
        return $false
    }
    
    $goVersionOutput = & go version 2>&1
    $goMatch = [regex]::Match($goVersionOutput, 'go(\d+)\.(\d+)(?:\.(\d+))?')
    if (-not $goMatch.Success) {
        return $false
    }

    $goVersion = $goMatch.Groups[0].Value.Replace('go', '')
    $currentMajor = [int]$goMatch.Groups[1].Value
    $currentMinor = [int]$goMatch.Groups[2].Value
    $currentPatch = if ($goMatch.Groups[3].Success) { [int]$goMatch.Groups[3].Value } else { 0 }

    # Security hardening: reject vulnerable Go 1.26.0 stdlib.
    if ($currentMajor -eq 1 -and $currentMinor -eq 26 -and $currentPatch -eq 0) {
        Print-Warning "Detected vulnerable Go version $goVersion (known stdlib CVEs)."
        return $false
    }
    $minMajor = Get-GoVersionPart -Version $script:GO_MIN_VERSION -Index 0
    $minMinor = Get-GoVersionPart -Version $script:GO_MIN_VERSION -Index 1
    $minPatch = Get-GoVersionPart -Version $script:GO_MIN_VERSION -Index 2
    
    if ($currentMajor -gt $minMajor -or
        ($currentMajor -eq $minMajor -and $currentMinor -gt $minMinor) -or
        ($currentMajor -eq $minMajor -and $currentMinor -eq $minMinor -and $currentPatch -ge $minPatch)) {
        return $true
    }
    
    Print-Warning "Go version $goVersion is older than required $script:GO_MIN_VERSION"
    return $false
}

function Install-Golang {
    Print-Step "Installing Go toolchain..."
    
    $goVersion = $script:GO_DOWNLOAD_VERSION
    $goUrl = "https://go.dev/dl/go$goVersion.windows-amd64.zip"
    $goZip = Join-Path $env:TEMP "go$goVersion.zip"
    $goRoot = "C:\Go"
    
    Print-Info "Downloading Go $goVersion..."
    try {
        Invoke-WebRequest -Uri $goUrl -OutFile $goZip -UseBasicParsing
    } catch {
        Print-Error "Failed to download Go: $_"
        return $false
    }
    
    Print-Info "Extracting Go..."
    if (Test-Path $goRoot) {
        Remove-Item -Path $goRoot -Recurse -Force
    }
    
    Expand-Archive -Path $goZip -DestinationPath "C:\" -Force
    Remove-Item -Path $goZip -Force
    
    # Add to PATH if not already there
    $envPath = [Environment]::GetEnvironmentVariable("Path", "Machine")
    $goPath = "$goRoot\bin"
    if ($envPath -notlike "*$goPath*") {
        [Environment]::SetEnvironmentVariable("Path", "$envPath;$goPath", "Machine")
        $env:Path = "$env:Path;$goPath"
    }
    
    # Verify installation
    if (Test-GoInstalled) {
        Print-Success "Go $goVersion installed successfully"
        return $true
    } else {
        Print-Error "Go installation verification failed"
        return $false
    }
}

#===============================================================================
# PostgreSQL Functions
#===============================================================================

function Choose-DatabaseType {
    # A database given with -PgUri needs no question
    if ($script:USE_POSTGRESQL -and $script:POSTGRESQL_URI) {
        Print-Info "Using the PostgreSQL database given with -PgUri"
        return
    }
    if ($script:AUTO_MODE) {
        if ($script:USE_POSTGRESQL) {
            Print-Info "Auto mode: Using PostgreSQL"
        } else {
            Print-Info "Auto mode: Using SQLite (default)"
        }
        return
    }
    
    Write-Host ""
    $items = @(
        "SQLite`tSingle-file DB, zero setup (recommended)",
        "PostgreSQL`tProduction backend with connection pooling"
    )
    $returns = @("1", "2")
    Invoke-MenuChoose -Title "Select Database Type" -Subtitle "SQLite is recommended for most installs" -Items $items -Returns $returns
    $dbChoice = $script:MENU_CHOICE
    if ([string]::IsNullOrEmpty($dbChoice)) { $dbChoice = "1" }
    
    switch ($dbChoice) {
        "2" {
            $script:USE_POSTGRESQL = $true
            Print-Info "Selected: PostgreSQL"
            
            Write-Host ""
            $pgHost = Read-Host "PostgreSQL host [$($script:POSTGRESQL_HOST)]"
            if (![string]::IsNullOrEmpty($pgHost)) { $script:POSTGRESQL_HOST = $pgHost }
            
            $pgPort = Read-Host "PostgreSQL port [$($script:POSTGRESQL_PORT)]"
            if (![string]::IsNullOrEmpty($pgPort)) { $script:POSTGRESQL_PORT = $pgPort }
            
            $pgDb = Read-Host "PostgreSQL database [$($script:POSTGRESQL_DB)]"
            if (![string]::IsNullOrEmpty($pgDb)) { $script:POSTGRESQL_DB = $pgDb }
            
            $pgUser = Read-Host "PostgreSQL user [$($script:POSTGRESQL_USER)]"
            if (![string]::IsNullOrEmpty($pgUser)) { $script:POSTGRESQL_USER = $pgUser }
            
            Print-Info "The database must exist: Windows does not install PostgreSQL. The next step asks for its password."
        }
        default {
            $script:USE_POSTGRESQL = $false
            Print-Info "Selected: SQLite"
        }
    }
}

# The PostgreSQL address. Windows does not install PostgreSQL or create
# its database, so the database must exist: the address comes from -PgUri
# or POSTGRESQL_URI as it is, else from its parts with the password of the
# existing user (POSTGRESQL_PASS, or asked for in an interactive run).
function Setup-PostgreSQLDatabase {
    Print-Step "Setting up PostgreSQL for NeoDesk..."
    $where = "$($script:POSTGRESQL_HOST):$($script:POSTGRESQL_PORT)/$($script:POSTGRESQL_DB)"
    if ($script:POSTGRESQL_URI) {
        Print-Info "Using the PostgreSQL address given (-PgUri or POSTGRESQL_URI)"
        return $true
    }
    if ([string]::IsNullOrEmpty($script:POSTGRESQL_PASS) -and -not $script:AUTO_MODE) {
        $secure = Read-Host "Password of the PostgreSQL user $($script:POSTGRESQL_USER) on $where" -AsSecureString
        $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        try { $script:POSTGRESQL_PASS = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr) }
        finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    }
    if ([string]::IsNullOrEmpty($script:POSTGRESQL_PASS)) {
        Print-Error "PostgreSQL needs an existing database and its password. The installer does not create one on Windows."
        Print-Info "Create the user and the database, then run the installer again with one of:"
        Print-Info "  -PgUri 'postgres://USER:PASSWORD@HOST:5432/DATABASE?sslmode=disable'"
        Print-Info "  `$env:POSTGRESQL_PASS (with POSTGRESQL_USER, POSTGRESQL_HOST, POSTGRESQL_PORT, POSTGRESQL_DB for other values than $($script:POSTGRESQL_USER)@$where)"
        Print-Info "Or leave out -PostgreSQL: SQLite needs no set-up."
        return $false
    }
    $user = [uri]::EscapeDataString($script:POSTGRESQL_USER)
    $pass = [uri]::EscapeDataString($script:POSTGRESQL_PASS)
    $script:POSTGRESQL_URI = "postgres://${user}:${pass}@$($script:POSTGRESQL_HOST):$($script:POSTGRESQL_PORT)/$($script:POSTGRESQL_DB)?sslmode=disable"
    Print-Info "PostgreSQL: $($script:POSTGRESQL_USER)@$where"
    return $true
}

function Migrate-SQLiteToPostgreSQL {
    Print-Step "Moving the existing SQLite install to PostgreSQL..."

    $sqliteDb = Join-Path $script:RUSTDESK_PATH "db_v2.sqlite3"

    if (-not (Test-Path $sqliteDb)) {
        Print-Info "No existing SQLite database found, skipping migration"
        return
    }

    $migrateBin = Get-MigrateBin
    if (-not $migrateBin) {
        Print-Warning "Migration binary not found: the server keeps using $sqliteDb"
        Print-Info "Move it later with: M -> 3 (SQLite -> PostgreSQL)"
        Use-SQLiteInstall $sqliteDb
        return
    }

    if (-not $script:AUTO_MODE -and -not (Confirm-Action "Move the existing SQLite install (every server and console table) to PostgreSQL?")) {
        Print-Info "The install stays on SQLite ($sqliteDb); move it later with the menu's Database migration"
        Use-SQLiteInstall $sqliteDb
        return
    }

    # The installer does not create the database on Windows, so -overwrite
    # only after the user agreed: otherwise the tool refuses a database with
    # rows in it
    $migrateArgs = @("-mode", "sqlite2pg", "-src", $sqliteDb, "-dst", $script:POSTGRESQL_URI)
    if (-not $script:AUTO_MODE -and (Confirm-Action "If the PostgreSQL database already holds data, replace all of it?")) {
        $migrateArgs += "-overwrite"
    }

    Print-Step "Creating backup before migration..."
    & $migrateBin -mode backup -src $sqliteDb 2>&1 | Out-Null

    Print-Step "Moving the SQLite install to PostgreSQL..."
    & $migrateBin @migrateArgs 2>&1 | ForEach-Object { Write-Host $_ }
    if ($LASTEXITCODE -eq 0) {
        Use-DatabaseInEnv -Type postgres -Address $script:POSTGRESQL_URI
        Print-Success "The install now runs on PostgreSQL"
    } else {
        Print-Warning "The move to PostgreSQL failed (output above): the server keeps using $sqliteDb"
        Use-SQLiteInstall $sqliteDb
    }
}

# Use-SQLiteInstall keeps the install on its SQLite file after the move to
# PostgreSQL did not happen.
function Use-SQLiteInstall {
    param([string]$Path)
    $script:USE_POSTGRESQL = $false
    $script:POSTGRESQL_URI = ""
    Use-DatabaseInEnv -Type sqlite -Address $Path
}

function Set-ConsoleEnvValue {
    param([string]$Key, [string]$Value)
    $envFile = Join-Path $script:CONSOLE_PATH ".env"
    if (-not (Test-Path $envFile)) { return }
    $lines = @(Get-Content $envFile -ErrorAction SilentlyContinue)
    $found = $false
    $updated = @(foreach ($line in $lines) {
        if ($line -match "^\s*$([regex]::Escape($Key))=") {
            $found = $true
            "$Key=$Value"
        } else {
            $line
        }
    })
    if (-not $found) { $updated += "$Key=$Value" }
    # UTF-8 without BOM: the console reads the first key literally
    [System.IO.File]::WriteAllLines($envFile, [string[]]$updated, (New-Object System.Text.UTF8Encoding($false)))
}

# Removes the lines that set any of $Keys from the console's .env.
function Remove-ConsoleEnvValue {
    param([string[]]$Keys)
    $envFile = Join-Path $script:CONSOLE_PATH ".env"
    if (-not (Test-Path $envFile)) { return }
    $pattern = '^\s*(' + (($Keys | ForEach-Object { [regex]::Escape($_) }) -join '|') + ')='
    $lines = @(Get-Content $envFile -ErrorAction SilentlyContinue)
    $kept = @($lines | Where-Object { $_ -notmatch $pattern })
    if ($kept.Count -ne $lines.Count) {
        [System.IO.File]::WriteAllLines($envFile, [string[]]$kept, (New-Object System.Text.UTF8Encoding($false)))
    }
}

# Install-FlaskConsole removed in v2.3.0 - Flask support deprecated

function Generate-SSLCertificates {
    Print-Step "Generating self-signed TLS certificates..."
    
    $sslDir = Join-Path $script:RUSTDESK_PATH "ssl"
    $certPath = Join-Path $sslDir "neodesk.crt"
    $keyPath = Join-Path $sslDir "neodesk.key"
    
    # Skip if certificates already exist
    if ((Test-Path $certPath) -and (Test-Path $keyPath)) {
        Print-Info "TLS certificates already exist at $sslDir"
        Print-Info "Skipping certificate generation (use SSL config menu to regenerate)"
        return $true
    }
    
    New-Item -ItemType Directory -Path $sslDir -Force | Out-Null
    
    # Detect server IP for SAN
    $serverIP = Get-PublicIP

    # The binary makes the pair as PEM files, no OpenSSL needed (ten years,
    # as on Linux); an older binary without the cert command leaves it to
    # Windows and OpenSSL
    if (Test-BinaryHasCertCommand) {
        $certArgs = @("cert", "--out", $sslDir, "--force")
        if ($env:SSL_DOMAIN) { $certArgs += @("--host", $env:SSL_DOMAIN) }
        $certArgs += @("--host", $serverIP)
        $lanIP = Get-LocalIP
        if ($lanIP -and $lanIP -ne $serverIP) { $certArgs += @("--host", $lanIP) }
        if (((Invoke-ServerCommand -Arguments $certArgs) -eq 0) -and (Test-Path $certPath) -and (Test-Path $keyPath)) {
            # HTTPS for the web console (5443, a redirect on its HTTP port)
            Update-EnvForTLS -CertPath $certPath -KeyPath $keyPath
            # RustDesk clients refuse a self-signed certificate: the client API port stays on HTTP
            Set-ConsoleEnvValue -Key "RUSTDESK_API_TLS" -Value "false"
            Print-Success "Self-signed TLS certificate made (valid 10 years): $sslDir"
            return $true
        }
        Print-Warning "neodesk-server cert failed (output above)"
    }

    # Try PowerShell native certificate generation first
    try {
        $cert = New-SelfSignedCertificate `
            -DnsName "localhost", $serverIP `
            -CertStoreLocation "Cert:\LocalMachine\My" `
            -NotAfter (Get-Date).AddYears(10) `
            -KeyAlgorithm RSA `
            -KeyLength 2048 `
            -FriendlyName "NeoDesk Server" `
            -TextExtension @("2.5.29.17={text}DNS=localhost&IPAddress=$serverIP&IPAddress=127.0.0.1")
        
        # Export certificate (public)
        Export-Certificate -Cert $cert -FilePath "$sslDir\neodesk.cer" -Type CERT | Out-Null
        
        # Export PFX then convert to PEM using openssl if available
        $pfxPath = Join-Path $sslDir "neodesk.pfx"
        $securePassword = ConvertTo-SecureString -String "neodesk-temp" -Force -AsPlainText
        Export-PfxCertificate -Cert $cert -FilePath $pfxPath -Password $securePassword | Out-Null
        
        # Check if openssl is available for PEM conversion
        $opensslCmd = Get-Command openssl -ErrorAction SilentlyContinue
        if ($opensslCmd) {
            & openssl pkcs12 -in $pfxPath -out $certPath -clcerts -nokeys -passin "pass:neodesk-temp" 2>$null
            & openssl pkcs12 -in $pfxPath -out $keyPath -nocerts -nodes -passin "pass:neodesk-temp" 2>$null
            Remove-Item $pfxPath -Force -ErrorAction SilentlyContinue
        } else {
            # Keep PFX format for Windows (Go server can use it)
            Print-Info "OpenSSL not found - certificate stored as PFX"
            Print-Info "PFX path: $pfxPath"
        }
        
        # Clean up certificate from store
        Remove-Item "Cert:\LocalMachine\My\$($cert.Thumbprint)" -ErrorAction SilentlyContinue

        # The server reads PEM files only: without them HTTPS stays off
        if (-not ((Test-Path $certPath) -and (Test-Path $keyPath))) {
            Print-Warning "The certificate could not be written as PEM files (OpenSSL is missing): the console stays on HTTP"
            Print-Info "Update to a release whose neodesk-server makes the certificate, or install OpenSSL, then use the SSL menu (option C)"
            return $false
        }

        # HTTPS for the web console (5443, a redirect on its HTTP port)
        Update-EnvForTLS -CertPath $certPath -KeyPath $keyPath
        # RustDesk clients refuse a self-signed certificate: the client API port stays on HTTP
        Set-ConsoleEnvValue -Key "RUSTDESK_API_TLS" -Value "false"
        
        Print-Success "Self-signed TLS certificate generated"
        Print-Info "Certificate: $sslDir"
        Print-Info "SAN: DNS:localhost, IP:$serverIP, IP:127.0.0.1"
        Print-Info "Valid for 10 years"
        return $true
    } catch {
        Print-Warning "PowerShell certificate generation failed: $_"
        
        # Fallback: try openssl if available
        $opensslCmd = Get-Command openssl -ErrorAction SilentlyContinue
        if ($opensslCmd) {
            Print-Info "Falling back to openssl..."
            try {
                & openssl req -x509 -nodes -days 3650 -newkey rsa:2048 `
                    -keyout $keyPath `
                    -out $certPath `
                    -subj "/CN=$serverIP/O=NeoDesk" `
                    -addext "subjectAltName=IP:$serverIP,IP:127.0.0.1,DNS:localhost" 2>$null
                
                if ((Test-Path $certPath) -and (Test-Path $keyPath)) {
                    Update-EnvForTLS -CertPath $certPath -KeyPath $keyPath
                    # RustDesk clients refuse a self-signed certificate: the client API port stays on HTTP
                    Set-ConsoleEnvValue -Key "RUSTDESK_API_TLS" -Value "false"
                    Print-Success "Self-signed TLS certificate generated (openssl)"
                    return $true
                }
            } catch {
                Print-Warning "OpenSSL fallback also failed"
            }
        }
        
        Print-Warning "Could not generate TLS certificates automatically"
        Print-Info "Use SSL config menu (option C) to generate later"
        return $false
    }
}

# Gives the service's virtual account NT SERVICE\<service> change rights
# on the folders it needs, below the lock of Protect-Folder. A virtual
# account is unprivileged, managed by Windows, needs no password and may
# log on as a service. Nothing with -RunAsRoot, where the service runs as
# LocalSystem.
function Set-ServiceLeastPrivilege {
    param(
        [string]$ServiceName,
        [string[]]$Paths
    )
    if ($script:RUN_AS_ROOT) { return }
    $account = "NT SERVICE\$ServiceName"
    foreach ($p in $Paths) {
        if ($p -and (Test-Path $p)) {
            & icacls "$p" /grant "${account}:(OI)(CI)M" /T /C /Q 2>$null | Out-Null
            if ($LASTEXITCODE -ne 0) { Print-Warning "Could not grant $account access to $p" }
        }
    }
    Print-Info "Service $ServiceName runs under least-privilege account ($account)"
}

function Stop-AllServices {
    Print-Step "Stopping services..."
    
    # Stop Windows services (Go server + legacy)
    Stop-Service -Name $script:SERVER_SERVICE -ErrorAction SilentlyContinue -Force
    Stop-Service -Name $script:HBBS_SERVICE -ErrorAction SilentlyContinue -Force
    Stop-Service -Name $script:HBBR_SERVICE -ErrorAction SilentlyContinue -Force
    Stop-Service -Name $script:CONSOLE_SERVICE -ErrorAction SilentlyContinue -Force
    
    # Stop scheduled tasks
    Stop-ScheduledTask -TaskName $script:SERVER_SERVICE -ErrorAction SilentlyContinue
    Stop-ScheduledTask -TaskName $script:HBBS_SERVICE -ErrorAction SilentlyContinue
    Stop-ScheduledTask -TaskName $script:HBBR_SERVICE -ErrorAction SilentlyContinue
    Stop-ScheduledTask -TaskName $script:CONSOLE_SERVICE -ErrorAction SilentlyContinue
    
    # Kill processes directly (Go server + legacy)
    Get-Process -Name "neodesk-server" -ErrorAction SilentlyContinue | Stop-Process -Force
    Get-Process -Name "hbbs" -ErrorAction SilentlyContinue | Stop-Process -Force
    Get-Process -Name "hbbr" -ErrorAction SilentlyContinue | Stop-Process -Force
    Get-Process -Name "node" -ErrorAction SilentlyContinue | Where-Object {
        $_.MainModule.FileName -like "*neodesk*" -or $_.CommandLine -like "*server.js*"
    } | Stop-Process -Force -ErrorAction SilentlyContinue
    
    Start-Sleep -Seconds 2
}

#===============================================================================
# Enhanced Service Management Functions (v2.1.2)
#===============================================================================

function Test-PortAvailable {
    param([int]$Port, [string]$ServiceName = "unknown")
    
    $listener = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
    
    if ($listener) {
        $process = Get-Process -Id $listener.OwningProcess -ErrorAction SilentlyContinue
        Print-Error "Port $Port is in use by: $($process.Name) (PID: $($listener.OwningProcess))"
        return $false
    }
    return $true
}

#=============================================================================
# Minimal Installation Function (Go server only, no web console)
#===============================================================================

#=============================================================================
# Main Installation Function
#===============================================================================

function Do-Install {
    Print-Header
    Write-Host "========== FRESH INSTALLATION ==========" -ForegroundColor White
    Write-Host ""
    
    Detect-Installation

    if (Test-NodeEraInstall) {
        Stop-NodeEraInstall
        return $false
    }

    if ($script:INSTALL_STATUS -eq "complete") {
        Print-Warning "NeoDesk is already installed!"
        if (-not $script:AUTO_MODE) {
            if (-not (Confirm-Action "Do you want to reinstall?")) {
                return
            }
        }
        Do-BackupSilent
    }

    Write-Host ""
    Print-Info "Starting NeoDesk v$script:VERSION installation..."
    Write-Host ""

    # Choose database type (SQLite or PostgreSQL)
    Choose-DatabaseType

    # Setup PostgreSQL if selected
    if ($script:USE_POSTGRESQL) {
        if (-not (Setup-PostgreSQLDatabase)) {
            Print-Error "PostgreSQL setup failed"
            return
        }
    }
    
    if (-not (Install-Binaries)) { Print-Error "Binary installation failed"; return }
    if (-not (Setup-ConsoleHome)) { Print-Error "Setting up the console folder failed"; return }
    # Before the keys and certificates are made, which then take the
    # folders' permissions
    Protect-InstallFolders | Out-Null

    # Generate self-signed TLS certificates (default for fresh installs)
    Generate-SSLCertificates | Out-Null

    # Migrate existing SQLite data to PostgreSQL if applicable
    if ($script:USE_POSTGRESQL) {
        Migrate-SQLiteToPostgreSQL
    }

    if (-not (Setup-Services)) { Print-Error "Setting up the Windows service failed"; return $false }
    $adminPassword = Create-AdminUser

    # Configure firewall rules
    Print-Step "Configuring Windows Firewall rules..."
    Configure-Firewall | Out-Null

    $installOk = Start-ServicesWithVerification
    if ($installOk) {
        Remove-FirstAdminPassword
        Install-ManagerScript
        Install-CommandLine
    }

    Write-Host ""
    if ($installOk) {
        Print-Success "Installation completed successfully!"
    } else {
        Print-Warning "Installation finished but neodesk-server does not answer; see $script:RUSTDESK_PATH\logs"
    }
    Write-Host ""
    
    # The summary is the last thing on the screen: the password in it is
    # not shown again, and the menu clears the screen after Enter
    $ports = (Get-FirewallPorts | ForEach-Object { "$($_.Port)/$($_.Proto)" }) -join ' '
    Write-Host "A firewall outside this machine (your network's or cloud provider's) needs these ports: $ports"
    Show-InstallSummary -AdminPassword $adminPassword

    if (-not $script:AUTO_MODE) {
        if ($adminPassword) {
            $null = Read-Host "Copy the admin password above, then press Enter"
        } else {
            Press-Enter
        }
    }
    return $installOk
}

#===============================================================================
# Update Functions
#===============================================================================

# GitHub repository configuration for online updates
# A repository given to the installer wins over .env, and .env over these
$script:UPDATE_GITHUB_OWNER_GIVEN = "$env:UPDATE_GITHUB_OWNER"
$script:UPDATE_GITHUB_REPO_GIVEN = "$env:UPDATE_GITHUB_REPO"
$script:UPDATE_GITHUB_OWNER = if ($env:UPDATE_GITHUB_OWNER) { $env:UPDATE_GITHUB_OWNER } else { "neodeskapp" }
$script:UPDATE_GITHUB_REPO = if ($env:UPDATE_GITHUB_REPO) { $env:UPDATE_GITHUB_REPO } else { "neodesk" }
# A channel given to the installer (-Channel, else UPDATE_GITHUB_BRANCH) wins
# over .env and is written into it. UPDATE_GITHUB_BRANCH holds the channel's
# id, main for stable and dev for development, not a git branch.
$script:UPDATE_GITHUB_BRANCH_GIVEN = if ($Channel -eq "dev") { "dev" } elseif ($Channel -eq "stable") { "main" } elseif ($env:UPDATE_GITHUB_BRANCH) { $env:UPDATE_GITHUB_BRANCH } else { "" }
$script:UPDATE_GITHUB_BRANCH = if ($script:UPDATE_GITHUB_BRANCH_GIVEN) { $script:UPDATE_GITHUB_BRANCH_GIVEN } else { "main" }
# The branch the installer itself comes from for its copy in the install
# folder: the repository's branch, main. The release channel above is
# separate.

function Read-UpdateGitHubBranchFromEnv {
    if ($script:UPDATE_GITHUB_BRANCH_GIVEN) { return }
    $envFile = Join-Path $script:CONSOLE_PATH ".env"
    if ($script:CONSOLE_PATH -and (Test-Path $envFile)) {
        $line = Get-Content $envFile -ErrorAction SilentlyContinue |
            Where-Object { $_ -match '^\s*UPDATE_GITHUB_BRANCH=' } |
            Select-Object -Last 1
        if ($line -match '^\s*UPDATE_GITHUB_BRANCH=(.+)$') {
            $script:UPDATE_GITHUB_BRANCH = $Matches[1].Trim().Trim('"')
            $env:UPDATE_GITHUB_BRANCH = $script:UPDATE_GITHUB_BRANCH
        }
    }
}

function Write-UpdateGitHubBranchToEnv {
    param([Parameter(Mandatory = $true)][ValidateSet('main', 'dev')][string]$Branch)
    $envFile = Join-Path $script:CONSOLE_PATH ".env"
    if (-not $script:CONSOLE_PATH) {
        Print-Error "Console path unknown — cannot save update channel"
        return $false
    }
    if (-not (Test-Path $envFile)) {
        New-Item -ItemType File -Path $envFile -Force | Out-Null
    }
    $lines = @(Get-Content $envFile -ErrorAction SilentlyContinue)
    $found = $false
    $updated = foreach ($line in $lines) {
        if ($line -match '^\s*UPDATE_GITHUB_BRANCH=') {
            $found = $true
            "UPDATE_GITHUB_BRANCH=$Branch"
        } else {
            $line
        }
    }
    if (-not $found) {
        $updated = @($updated) + "UPDATE_GITHUB_BRANCH=$Branch"
    }
    Set-Content -Path $envFile -Value $updated -Encoding UTF8
    $script:UPDATE_GITHUB_BRANCH = $Branch
    if ($script:UPDATE_GITHUB_BRANCH_GIVEN) { $script:UPDATE_GITHUB_BRANCH_GIVEN = $Branch }
    $env:UPDATE_GITHUB_BRANCH = $Branch
    Print-Success "Update channel saved: $Branch"
    return $true
}

function Switch-UpdateChannel {
    Print-Header
    Write-Host "========== UPDATE CHANNEL ==========" -ForegroundColor White
    Write-Host ""
    Detect-Installation
    if ($script:INSTALL_STATUS -eq "none") {
        Print-Error "NeoDesk is not installed!"
        Press-Enter
        return
    }
    Read-UpdateGitHubBranchFromEnv
    Print-Info "Current update channel: $($script:UPDATE_GITHUB_BRANCH)"
    Write-Host ""
    $items = @(
        "Stable (main)`tReleases from version tags",
        "Development (dev)`tThe newest build of the main branch",
        "Back`tReturn without changes"
    )
    $returns = @("main", "dev", "0")
    Invoke-MenuChoose -Title "Update Channel" -Subtitle "Stable is recommended for production servers" -Items $items -Returns $returns
    switch ($script:MENU_CHOICE) {
        "0" { return }
        "dev" {
            Print-Warning "Development channel may include unstable changes."
            Write-UpdateGitHubBranchToEnv -Branch "dev" | Out-Null
        }
        default {
            Write-UpdateGitHubBranchToEnv -Branch "main" | Out-Null
        }
    }
    Print-Info "Run 'Check for updates' in the console or use Online GitHub update to apply."
    Press-Enter
}

#===============================================================================
# Repair Functions
#===============================================================================

function Do-Repair {
    Print-Header
    Write-Host "========== REPAIR INSTALLATION ==========" -ForegroundColor White
    Write-Host ""
    
    Detect-Installation
    Test-ManagementCapabilities | Out-Null
    
    # CRITICAL: Preserve database configuration before any repair operation
    # This prevents PostgreSQL -> SQLite switch when regenerating service files
    Preserve-DatabaseConfig
    
    Print-Status
    
    $items = @(
        "Repair binaries`tReplace the server binary with NeoDesk",
        "Repair database`tAdd any missing columns",
        "Repair services`tRecreate the Windows services",
        "Full repair`tDo everything above",
        "Back`tReturn to the main menu"
    )
    $returns = @("1", "2", "3", "4", "0")
    Invoke-MenuChoose -Title "Repair Installation" -Subtitle "Choose what to repair" -Items $items -Returns $returns
    $choice = $script:MENU_CHOICE
    
    switch ($choice) {
        "1" { Repair-Binaries }
        "2" { Repair-Database }
        "3" { Repair-Services }
        "4" { 
            Repair-Binaries
            Repair-Database
            Repair-Services
            Print-Success "Full repair completed!"
        }
        "0" { return }
    }
    
    Press-Enter
}

#===============================================================================
# Validation Functions
#===============================================================================

function Do-Validate {
    Print-Header
    Write-Host "========== INSTALLATION VALIDATION ==========" -ForegroundColor White
    Write-Host ""
    
    $errors = 0
    $warnings = 0
    
    Detect-Installation
    
    Write-Host "Checking components..." -ForegroundColor White
    Write-Host ""
    
    # Check directories
    Write-Host "  RustDesk directory ($script:RUSTDESK_PATH): " -NoNewline
    if (Test-Path $script:RUSTDESK_PATH) {
        Write-Host "[OK]" -ForegroundColor Green
    } else {
        Write-Host "[X] Not found" -ForegroundColor Red
        $errors++
    }
    
    Write-Host "  Console directory ($script:CONSOLE_PATH): " -NoNewline
    if (Test-Path $script:CONSOLE_PATH) {
        Write-Host "[OK]" -ForegroundColor Green
    } else {
        Write-Host "[X] Not found" -ForegroundColor Red
        $errors++
    }
    
    # Check binaries (Go server or legacy Rust)
    Write-Host "  NeoDesk Server: " -NoNewline
    if (Test-Path (Join-Path $script:RUSTDESK_PATH "neodesk-server.exe")) {
        Write-Host "[OK] (Go: signal + relay + API)" -ForegroundColor Green
    } elseif ((Test-Path (Join-Path $script:RUSTDESK_PATH "hbbs.exe")) -and (Test-Path (Join-Path $script:RUSTDESK_PATH "hbbr.exe"))) {
        Write-Host "[OK] (Legacy Rust)" -ForegroundColor Yellow
        $warnings++
    } else {
        Write-Host "[X] Not found" -ForegroundColor Red
        $errors++
    }
    
    # Check database (SQLite or PostgreSQL)
    Write-Host "  Database: " -NoNewline
    if ((Get-EnvDatabaseType) -eq "postgres") {
        Write-Host "[OK] (PostgreSQL)" -ForegroundColor Green
    } elseif (Test-Path $script:DB_PATH) {
        Write-Host "[OK] (SQLite)" -ForegroundColor Green
    } else {
        # Go server creates DB on first start
        Write-Host "[!] Not yet created (will be created when server starts)" -ForegroundColor Yellow
        $warnings++
    }
    
    # Check keys
    Write-Host "  Public key: " -NoNewline
    $pubKeyPath = Join-Path $script:RUSTDESK_PATH "id_ed25519.pub"
    if (Test-Path $pubKeyPath) {
        Write-Host "[OK]" -ForegroundColor Green
    } else {
        Write-Host "[!] Will be generated on first start" -ForegroundColor Yellow
        $warnings++
    }
    
    # Check services
    Write-Host ""
    Write-Host "Checking services..." -ForegroundColor White
    Write-Host ""
    
    $services = @($script:SERVER_SERVICE)
    if (-not (Test-GoOnlyInstall)) { $services += $script:CONSOLE_SERVICE }
    foreach ($service in $services) {
        Write-Host "  ${service}: " -NoNewline
        $svc = Get-Service -Name $service -ErrorAction SilentlyContinue
        if ($svc) {
            if ($svc.Status -eq 'Running') {
                Write-Host "[OK] Running" -ForegroundColor Green
            } else {
                Write-Host "[!] Not running ($($svc.Status))" -ForegroundColor Yellow
                $warnings++
            }
        } else {
            $task = Get-ScheduledTask -TaskName $service -ErrorAction SilentlyContinue
            if ($task) {
                if ($task.State -eq 'Running') {
                    Write-Host "[OK] Running (task)" -ForegroundColor Green
                } else {
                    Write-Host "[!] Task exists but not running" -ForegroundColor Yellow
                    $warnings++
                }
            } else {
                Write-Host "[X] Not found" -ForegroundColor Red
                $errors++
            }
        }
    }
    
    # Check ports
    Write-Host ""
    Write-Host "Checking ports..." -ForegroundColor White
    Write-Host ""
    
    $consoleProcess = if (Test-GoOnlyInstall) { "neodesk-server" } else { "node" }
    $ports = @(
        @{Port=[int]$script:GO_API_PORT; Desc="Go API"; Expected="neodesk-server"},
        @{Port=[int]$script:CLIENT_API_PORT; Desc="Client API"; Expected=$consoleProcess},
        @{Port=21115; Desc="NAT Test"; Expected="hbbs"},
        @{Port=21116; Desc="ID Server"; Expected="hbbs"},
        @{Port=21117; Desc="Relay"; Expected="hbbr"},
        @{Port=[int](Get-ConsoleHttpPort); Desc="Web Console"; Expected=$consoleProcess}
    )
    foreach ($p in $ports) {
        $status = Check-PortStatus -Port $p.Port -Protocol "TCP" -ExpectedService $p.Expected
        Write-Host "  Port $($p.Port) ($($p.Desc)): " -NoNewline
        if ($status.Listening) {
            if ($status.Conflict) {
                Write-Host "[!] CONFLICT - $($status.ProcessName) (PID $($status.PID))" -ForegroundColor Red
                $errors++
            } else {
                Write-Host "[OK] $($status.ProcessName)" -ForegroundColor Green
            }
        } else {
            Write-Host "[!] Not listening" -ForegroundColor Yellow
            $warnings++
        }
    }
    
    # Check firewall
    Write-Host ""
    Write-Host "Checking firewall..." -ForegroundColor White
    Write-Host ""
    
    $firewallProfile = Get-NetFirewallProfile -ErrorAction SilentlyContinue
    $activeProfiles = $firewallProfile | Where-Object { $_.Enabled -eq $true }
    if ($activeProfiles) {
        # Ports that must be reachable for clients. The panel (3375/5443) is deliberately
        # absent: it is a local port and exposing it to WAN defeats the reverse-proxy setup.
        # See https://neode.sk/docs/operations/ports.
        $fwPorts = @(21116, 21117, [int]$script:GO_API_PORT)
        $fwMissing = 0
        foreach ($fwPort in $fwPorts) {
            $rules = Get-NetFirewallRule -Direction Inbound -Enabled True -ErrorAction SilentlyContinue | 
                Where-Object { $_.Action -eq 'Allow' } |
                Get-NetFirewallPortFilter -ErrorAction SilentlyContinue | 
                Where-Object { $_.LocalPort -eq $fwPort }
            if (-not $rules) { $fwMissing++ }
        }
        if ($fwMissing -gt 0) {
            Write-Host "  Firewall: $fwMissing rule(s) missing" -ForegroundColor Yellow
            Write-Host "  Use DIAGNOSTICS > F to auto-configure" -ForegroundColor Yellow
            $warnings += $fwMissing
        } else {
            Write-Host "  Firewall: All rules configured" -ForegroundColor Green
        }
    } else {
        Write-Host "  Firewall: Disabled" -ForegroundColor Green
    }
    
    # Summary
    Write-Host ""
    Write-Host "=======================================" -ForegroundColor White
    
    if ($errors -eq 0 -and $warnings -eq 0) {
        Write-Host "[OK] Installation correct - no problems found" -ForegroundColor Green
    } elseif ($errors -eq 0) {
        Write-Host "[!] Found $warnings warning(s)" -ForegroundColor Yellow
    } else {
        Write-Host "[X] Found $errors error(s) and $warnings warning(s)" -ForegroundColor Red
        Write-Host "Use 'REPAIR INSTALLATION' option to fix problems" -ForegroundColor Cyan
    }
    
    Press-Enter
}

#===============================================================================
# Backup Functions
#===============================================================================

function Do-Backup {
    Print-Header
    Write-Host "========== BACKUP ==========" -ForegroundColor White
    Write-Host ""
    
    Do-BackupSilent
    
    Print-Success "Backup completed!"
    Press-Enter
}

function Do-BackupSilent {
    $backupName = "neodesk_backup_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
    $backupPath = Join-Path $script:BACKUP_DIR $backupName
    
    if (-not (Test-Path $script:BACKUP_DIR)) {
        New-Item -ItemType Directory -Path $script:BACKUP_DIR -Force | Out-Null
    }
    # The backups hold the database, the keys and .env
    Protect-Folder -Path $script:BACKUP_DIR | Out-Null

    New-Item -ItemType Directory -Path $backupPath -Force | Out-Null
    
    Print-Step "Creating backup: $backupName"

    # The server's own backup: a consistent copy of the database (SQLite or
    # PostgreSQL), the env file, the console's data and its certificates,
    # also while the server runs. An older binary has none: the SQLite file
    # is copied as it is
    $serverBackup = $false
    if (Test-BinaryBacksUp) {
        $serverBackup = ((Invoke-ServerCommand -Arguments @("backup", "--out", $backupPath)) -eq 0)
        if ($serverBackup) { Print-Info "  - Database, settings and the console's data" }
        else { Print-Warning "neodesk-server backup failed (output above); the backup holds a copy of the database file instead" }
    }
    if (-not $serverBackup -and (Test-Path $script:DB_PATH)) {
        Copy-Item -Path $script:DB_PATH -Destination $backupPath
        Print-Info "  - Database"
    }
    
    # Backup keys
    $keyPath = Join-Path $script:RUSTDESK_PATH "id_ed25519"
    if (Test-Path $keyPath) {
        Copy-Item -Path $keyPath -Destination $backupPath
        Copy-Item -Path "$keyPath.pub" -Destination $backupPath -ErrorAction SilentlyContinue
        Print-Info "  - Keys"
    }
    
    # Backup API key
    $apiKeyPath = Join-Path $script:RUSTDESK_PATH ".api_key"
    if (Test-Path $apiKeyPath) {
        Copy-Item -Path $apiKeyPath -Destination $backupPath
        Print-Info "  - API key"
    }
    
    # Backup credentials (check both locations)
    $consoleCredPath = Join-Path $script:CONSOLE_PATH "data\.admin_credentials"
    $rustdeskCredPath = Join-Path $script:RUSTDESK_PATH ".admin_credentials"
    if (Test-Path $consoleCredPath) {
        Copy-Item -Path $consoleCredPath -Destination $backupPath
        Print-Info "  - Login credentials"
    } elseif (Test-Path $rustdeskCredPath) {
        Copy-Item -Path $rustdeskCredPath -Destination $backupPath
        Print-Info "  - Login credentials"
    }
    
    # Create zip archive
    $zipPath = "$backupPath.zip"
    Compress-Archive -Path $backupPath -DestinationPath $zipPath -Force
    Remove-Item -Path $backupPath -Recurse -Force
    
    Print-Success "Backup saved: $zipPath"
}

#===============================================================================
# Password Reset Function
#===============================================================================

#===============================================================================
# Diagnostics Function
#===============================================================================

function Check-PortStatus {
    param(
        [int]$Port,
        [string]$Protocol = "TCP",
        [string]$ExpectedService = ""
    )
    
    $result = @{
        Port = $Port
        Protocol = $Protocol
        Listening = $false
        ProcessName = ""
        PID = 0
        Conflict = $false
    }
    
    if ($Protocol -eq "TCP") {
        $conn = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
    } else {
        $conn = Get-NetUDPEndpoint -LocalPort $Port -ErrorAction SilentlyContinue
    }
    
    if ($conn) {
        $result.Listening = $true
        $result.PID = $conn[0].OwningProcess
        try {
            $proc = Get-Process -Id $result.PID -ErrorAction SilentlyContinue
            $result.ProcessName = $proc.ProcessName
        } catch { }
        
        if ($ExpectedService -and $result.ProcessName -and 
            $result.ProcessName -notmatch $ExpectedService) {
            $result.Conflict = $true
        }
    }
    
    return $result
}

# The ports the installers open: the API port a stock RustDesk client
# without an API server setting calls (the signal port minus 2, 21114:
# callers from other hosts get only the client API there), RustDesk's (NAT
# test, signal TCP and UDP, relay), the client API port, the CDAP gateway (21122) while CDAP is on,
# the relay nodes' control port (NODE_CONTROL_PORT, 21123, 0 is off),
# and the console's ports unless TLS ends at a reverse proxy (TRUST_PROXY).
function Get-FirewallPorts {
    $signal = [int](Get-SignalPort)
    $relay = [int](Get-RelayPort)
    $ports = @(
        @{Port = $signal - 2; Proto = "TCP"; Name = "NeoDesk API for clients without an API server setting"},
        @{Port = $signal - 1; Proto = "TCP"; Name = "NeoDesk NAT test"},
        @{Port = $signal; Proto = "TCP"; Name = "NeoDesk ID server TCP"},
        @{Port = $signal; Proto = "UDP"; Name = "NeoDesk ID server UDP"},
        @{Port = $relay; Proto = "TCP"; Name = "NeoDesk relay"}
    )
    $api = Get-ConsoleEnvValue -Key "API_PORT"
    if (-not $api) { $api = $script:CLIENT_API_PORT }
    $ports += @{Port = [int]$api; Proto = "TCP"; Name = "NeoDesk client API"}
    if ((Get-ConsoleEnvValue -Key "CDAP_ENABLED") -notmatch '^(?i)(n|no|0|false|off)$') {
        $ports += @{Port = 21122; Proto = "TCP"; Name = "NeoDesk CDAP gateway"}
    }
    $control = Get-ConsoleEnvValue -Key "NODE_CONTROL_PORT"
    if (-not $control) { $control = "21123" }
    if ($control -ne "0") { $ports += @{Port = [int]$control; Proto = "TCP"; Name = "NeoDesk relay node control"} }
    if (Test-BehindProxy) { return $ports }
    $http = Get-ConsoleEnvValue -Key "CONSOLE_PORT"
    if (-not $http) { $http = "3375" }
    if ($http -ne "0") { $ports += @{Port = [int]$http; Proto = "TCP"; Name = "NeoDesk web console"} }
    if ((Get-ConsoleEnvValue -Key "HTTPS_ENABLED") -eq "true") {
        $https = Get-ConsoleEnvValue -Key "HTTPS_PORT"
        if (-not $https) { $https = "5443" }
        $ports += @{Port = [int]$https; Proto = "TCP"; Name = "NeoDesk web console HTTPS"}
    }
    return $ports
}

function Check-FirewallRules {
    Write-Host ""
    Write-Host "=== Windows Firewall ===" -ForegroundColor White
    Write-Host ""

    $firewallProfile = Get-NetFirewallProfile -ErrorAction SilentlyContinue
    if (-not $firewallProfile) {
        Print-Warning "  Unable to query Windows Firewall"
        return
    }

    $activeProfiles = $firewallProfile | Where-Object { $_.Enabled -eq $true }
    if ($activeProfiles) {
        $profileNames = ($activeProfiles | ForEach-Object { $_.Name }) -join ", "
        Write-Host "  Firewall active: $profileNames" -ForegroundColor Yellow
    } else {
        Write-Host "  Firewall: Disabled" -ForegroundColor Green
        return
    }

    $requiredPorts = Get-FirewallPorts
    $missingRules = @()
    
    foreach ($p in $requiredPorts) {
        $rules = Get-NetFirewallRule -Direction Inbound -Enabled True -ErrorAction SilentlyContinue | 
            Where-Object { $_.Action -eq 'Allow' } |
            Get-NetFirewallPortFilter -ErrorAction SilentlyContinue | 
            Where-Object { $_.LocalPort -eq $p.Port -and ($_.Protocol -eq $p.Proto -or $_.Protocol -eq 'Any') }
        
        if ($rules) {
            Write-Host "  Port $($p.Port)/$($p.Proto) ($($p.Name)): " -NoNewline
            Write-Host "ALLOWED" -ForegroundColor Green
        } else {
            Write-Host "  Port $($p.Port)/$($p.Proto) ($($p.Name)): " -NoNewline
            Write-Host "NO RULE" -ForegroundColor Red
            $missingRules += $p
        }
    }
    
    return $missingRules
}

# True when TLS ends at a reverse proxy (TRUST_PROXY), which reaches the
# console on this machine.
function Test-BehindProxy {
    return ((Get-ConsoleEnvValue -Key "TRUST_PROXY") -match '^(?i)(y|yes|1|true|on)$')
}

# The rules this installer made for the console's ports go again: TLS ends
# at a reverse proxy, which reaches the console on this machine.
function Remove-ConsoleFirewallRules {
    $rules = @(Get-NetFirewallRule -DisplayName "NeoDesk - NeoDesk web console*" -ErrorAction SilentlyContinue)
    if ($rules.Count -eq 0) { return }
    $rules | Remove-NetFirewallRule -ErrorAction SilentlyContinue
    Print-Info "Closed the console's ports in Windows Firewall: the reverse proxy reaches the console on this machine"
}

# Every rule this installer made (NeoDesk - ...), for the uninstall.
function Remove-NeoDeskFirewallRules {
    $rules = @(Get-NetFirewallRule -DisplayName "NeoDesk - *" -ErrorAction SilentlyContinue)
    if ($rules.Count -eq 0) { return }
    $rules | Remove-NetFirewallRule -ErrorAction SilentlyContinue
    Print-Info "Removed $($rules.Count) NeoDesk rules from Windows Firewall"
}

function Configure-Firewall {
    param([array]$MissingRules = @())

    if (Test-BehindProxy) { Remove-ConsoleFirewallRules }

    if ($MissingRules.Count -eq 0) {
        $requiredPorts = Get-FirewallPorts
        foreach ($p in $requiredPorts) {
            $rules = Get-NetFirewallRule -Direction Inbound -Enabled True -ErrorAction SilentlyContinue | 
                Where-Object { $_.Action -eq 'Allow' } |
                Get-NetFirewallPortFilter -ErrorAction SilentlyContinue | 
                Where-Object { $_.LocalPort -eq $p.Port -and ($_.Protocol -eq $p.Proto -or $_.Protocol -eq 'Any') }
            
            if (-not $rules) {
                $MissingRules += $p
            }
        }
    }
    
    if ($MissingRules.Count -eq 0) {
        Print-Success "All firewall rules are already configured"
        return $true
    }
    
    Print-Info "Creating $($MissingRules.Count) missing firewall rules..."
    $created = 0
    
    foreach ($p in $MissingRules) {
        $ruleName = "NeoDesk - $($p.Name)"
        try {
            New-NetFirewallRule -DisplayName $ruleName `
                -Direction Inbound -Action Allow `
                -Protocol $p.Proto -LocalPort $p.Port `
                -Profile Any -ErrorAction Stop | Out-Null
            Print-Success "  Created rule: $ruleName (port $($p.Port)/$($p.Proto))"
            $created++
        } catch {
            Print-Error "  Failed to create rule: $ruleName - $($_.Exception.Message)"
        }
    }
    
    Print-Info "$created/$($MissingRules.Count) firewall rules created"
    return ($created -eq $MissingRules.Count)
}

function Do-Diagnostics {
    Print-Header
    Write-Host "========== DIAGNOSTICS ==========" -ForegroundColor White
    Write-Host ""
    
    Detect-Installation
    Print-Status
    
    Write-Host ""
    Write-Host "=== Process Information ===" -ForegroundColor White
    Write-Host ""
    
    $serverProc = Get-Process -Name "neodesk-server" -ErrorAction SilentlyContinue
    if ($serverProc) {
        Write-Host "  NeoDesk Server: PID $($serverProc.Id), Memory $('{0:N0}' -f ($serverProc.WorkingSet64/1MB)) MB" -ForegroundColor Green
    } else {
        # Fallback: check legacy hbbs/hbbr processes
        $hbbsProc = Get-Process -Name "hbbs" -ErrorAction SilentlyContinue
        $hbbrProc = Get-Process -Name "hbbr" -ErrorAction SilentlyContinue
        if ($hbbsProc -or $hbbrProc) {
            if ($hbbsProc) {
                Write-Host "  HBBS (legacy): PID $($hbbsProc.Id), Memory $('{0:N0}' -f ($hbbsProc.WorkingSet64/1MB)) MB" -ForegroundColor Yellow
            }
            if ($hbbrProc) {
                Write-Host "  HBBR (legacy): PID $($hbbrProc.Id), Memory $('{0:N0}' -f ($hbbrProc.WorkingSet64/1MB)) MB" -ForegroundColor Yellow
            }
            Print-Warning "Legacy Rust processes detected. Consider migrating to Go server."
        } else {
            Write-Host "  NeoDesk Server: Not running" -ForegroundColor Red
        }
    }
    
    Write-Host ""
    Write-Host "=== Database Statistics ===" -ForegroundColor White
    Write-Host ""
    
    if (Test-Path $script:DB_PATH) {
        $fileInfo = Get-Item $script:DB_PATH
        Write-Host "  Size: $('{0:N2}' -f ($fileInfo.Length/1KB)) KB"
        Write-Host "  Modified: $($fileInfo.LastWriteTime)"
        
        # Get database counts
        $pythonScript = @"
import sqlite3
db_path = r'$($script:DB_PATH)'
conn = sqlite3.connect(db_path)
cursor = conn.cursor()

try:
    cursor.execute("SELECT COUNT(*) FROM peer WHERE is_deleted = 0")
    devices = cursor.fetchone()[0]
    print(f"  Devices: {devices}")
except:
    print("  Devices: Unable to query")

try:
    cursor.execute("SELECT COUNT(*) FROM peer WHERE status = 1 AND is_deleted = 0")
    online = cursor.fetchone()[0]
    print(f"  Online:  {online}")
except:
    pass

try:
    cursor.execute("SELECT COUNT(*) FROM users")
    users = cursor.fetchone()[0]
    print(f"  Users:   {users}")
except:
    pass

conn.close()
"@
        $pythonScript | python
    } else {
        Write-Host "  Database does not exist"
    }
    
    # --- Port diagnostics ---
    Write-Host ""
    Write-Host "=== Port Diagnostics ===" -ForegroundColor White
    Write-Host ""
    
    $consoleProcess = if (Test-GoOnlyInstall) { "neodesk-server" } else { "node" }
    $portDefs = @(
        @{Port=[int]$script:GO_API_PORT; Proto="TCP"; Expected="neodesk-server"; Desc="Go API (default)"},
        @{Port=[int]$script:CLIENT_API_PORT; Proto="TCP"; Expected=$consoleProcess; Desc="Client API"},
        @{Port=21115; Proto="TCP"; Expected="neodesk-server"; Desc="NAT Test"},
        @{Port=21116; Proto="TCP"; Expected="neodesk-server"; Desc="ID Server (TCP)"},
        @{Port=21116; Proto="UDP"; Expected="neodesk-server"; Desc="ID Server (UDP)"},
        @{Port=21117; Proto="TCP"; Expected="neodesk-server"; Desc="Relay Server"},
        @{Port=[int](Get-ConsoleHttpPort); Proto="TCP"; Expected=$consoleProcess; Desc="Web Console"}
    )
    
    $portIssues = 0
    foreach ($pd in $portDefs) {
        $status = Check-PortStatus -Port $pd.Port -Protocol $pd.Proto -ExpectedService $pd.Expected
        
        $label = "  Port $($pd.Port)/$($pd.Proto) ($($pd.Desc)):"
        
        if ($status.Listening) {
            if ($status.Conflict) {
                Write-Host "$label " -NoNewline
                Write-Host "CONFLICT - used by $($status.ProcessName) (PID $($status.PID))" -ForegroundColor Red
                $portIssues++
            } else {
                Write-Host "$label " -NoNewline
                Write-Host "OK - $($status.ProcessName) (PID $($status.PID))" -ForegroundColor Green
            }
        } else {
            Write-Host "$label " -NoNewline
            Write-Host "NOT LISTENING" -ForegroundColor Yellow
        }
    }
    
    if ($portIssues -gt 0) {
        Write-Host ""
        Print-Warning "$portIssues port conflict(s) detected!"
        Write-Host "  Tip: Stop conflicting processes or change ports in configuration" -ForegroundColor Yellow
        Write-Host "  Common fix: Ensure no other app uses ports 21115-21117, $(Get-ConsoleHttpPort), $($script:GO_API_PORT), $($script:CLIENT_API_PORT)" -ForegroundColor Yellow
    }
    
    # --- Firewall diagnostics ---
    $missingRules = Check-FirewallRules
    
    if ($missingRules -and $missingRules.Count -gt 0) {
        Write-Host ""
        Print-Warning "$($missingRules.Count) firewall rule(s) missing!"
        Write-Host "  Use option 'F' from diagnostics menu to auto-configure firewall" -ForegroundColor Yellow
    }
    
    # --- API connectivity test ---
    Write-Host ""
    Write-Host "=== API Connectivity ===" -ForegroundColor White
    Write-Host ""
    
    $apiUrl = "http://127.0.0.1:$($script:API_PORT)/api/server-info"
    try {
        $response = Invoke-WebRequest -Uri $apiUrl -TimeoutSec 5 -UseBasicParsing -ErrorAction Stop
        Write-Host "  Server API ($($script:API_PORT)): " -NoNewline
        Write-Host "OK (HTTP $($response.StatusCode))" -ForegroundColor Green
    } catch {
        Write-Host "  Server API ($($script:API_PORT)): " -NoNewline
        Write-Host "UNREACHABLE" -ForegroundColor Red
    }
    
    $consoleUrl = "http://127.0.0.1:$(Get-ConsoleHttpPort)/health"
    try {
        $response = Invoke-WebRequest -Uri $consoleUrl -TimeoutSec 5 -UseBasicParsing -ErrorAction Stop
        Write-Host "  Web Console ($(Get-ConsoleHttpPort)):   " -NoNewline
        Write-Host "OK (HTTP $($response.StatusCode))" -ForegroundColor Green
    } catch {
        Write-Host "  Web Console ($(Get-ConsoleHttpPort)):   " -NoNewline
        Write-Host "UNREACHABLE" -ForegroundColor Red
    }
    
    # --- Diagnostics sub-menu ---
    Write-Host ""
    $items = @(
        "Configure firewall rules`tAuto-create any missing rules",
        "Test port connectivity`tProbe ports from outside",
        "Back`tReturn to the main menu"
    )
    $returns = @("F", "P", "0")
    Invoke-MenuChoose -Title "Diagnostics Actions" -Subtitle "Optional follow-up checks" -Items $items -Returns $returns
    $subChoice = $script:MENU_CHOICE
    
    switch ($subChoice) {
        "F" {
            Write-Host ""
            Configure-Firewall -MissingRules $missingRules
            Press-Enter
        }
        "P" {
            Write-Host ""
            Write-Host "=== External Port Test ===" -ForegroundColor White
            Write-Host ""
            $serverIP = Get-PublicIP
            Print-Info "Public IP: $serverIP"
            Print-Info "Testing external port accessibility... (this may take a moment)"
            Write-Host ""
            
            foreach ($port in @(21115, 21116, 21117)) {
                Write-Host "  Port ${port}: " -NoNewline
                try {
                    $tcp = New-Object System.Net.Sockets.TcpClient
                    $result = $tcp.BeginConnect($serverIP, $port, $null, $null)
                    $success = $result.AsyncWaitHandle.WaitOne(3000)
                    if ($success -and $tcp.Connected) {
                        Write-Host "REACHABLE" -ForegroundColor Green
                    } else {
                        Write-Host "BLOCKED/UNREACHABLE" -ForegroundColor Red
                    }
                    $tcp.Close()
                } catch {
                    Write-Host "BLOCKED/UNREACHABLE" -ForegroundColor Red
                }
            }
            Press-Enter
        }
        default { return }
    }
}

#===============================================================================
# Uninstall Function
#===============================================================================

function Do-Uninstall {
    Print-Header
    Write-Host "========== UNINSTALL ==========" -ForegroundColor Red
    Write-Host ""
    
    Print-Warning "This operation will remove NeoDesk Console!"
    Write-Host ""
    
    if (-not $script:AUTO_MODE -and -not $script:UNINSTALL_MODE) {
        if (-not (Confirm-Action "Are you sure you want to continue?")) {
            return
        }
    }
    
    if ($script:AUTO_MODE -or (Confirm-Action "Create backup before uninstall?")) {
        Do-BackupSilent
    }
    
    Print-Step "Stopping services..."
    Stop-AllServices
    
    Print-Step "Removing services..."
    
    # The services, the server's own and those of older installs (NSSM
    # services are Windows services too)
    foreach ($serviceName in @(
        $script:SERVER_SERVICE,
        $script:HBBS_SERVICE,
        $script:HBBR_SERVICE,
        $script:CONSOLE_SERVICE,
        "NeoDeskAPI"
    )) {
        if (Get-Service -Name $serviceName -ErrorAction SilentlyContinue) {
            Stop-Service -Name $serviceName -Force -ErrorAction SilentlyContinue
            Invoke-ServiceControl delete $serviceName | Out-Null
        }
    }
    
    # Remove the scheduled tasks of older installs
    Unregister-ScheduledTask -TaskName $script:SERVER_SERVICE -Confirm:$false -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $script:HBBS_SERVICE -Confirm:$false -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $script:HBBR_SERVICE -Confirm:$false -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $script:CONSOLE_SERVICE -Confirm:$false -ErrorAction SilentlyContinue

    # Without the server, its firewall rules and the command line go too,
    # also when the data stays
    Remove-NeoDeskFirewallRules
    Remove-CommandLine

    $kept = @()
    if ($script:PURGE_MODE -or (-not $script:AUTO_MODE -and (Confirm-Action "Remove installation files ($script:RUSTDESK_PATH)?"))) {
        Remove-Item -Path $script:RUSTDESK_PATH -Recurse -Force -ErrorAction SilentlyContinue
        Print-Info "Removed: $script:RUSTDESK_PATH"
    } elseif (Test-Path $script:RUSTDESK_PATH) {
        $kept += "$($script:RUSTDESK_PATH) (keys, database)"
    }

    if ($script:PURGE_MODE -or (-not $script:AUTO_MODE -and (Confirm-Action "Remove Web Console ($script:CONSOLE_PATH)?"))) {
        Remove-Item -Path $script:CONSOLE_PATH -Recurse -Force -ErrorAction SilentlyContinue
        Print-Info "Removed: $script:CONSOLE_PATH"
    } elseif (Test-Path $script:CONSOLE_PATH) {
        $kept += "$($script:CONSOLE_PATH) (.env, the console's data)"
    }

    if ((Test-Path $script:BACKUP_DIR) -and ($script:PURGE_MODE -or (-not $script:AUTO_MODE -and (Confirm-Action "Remove the backups ($script:BACKUP_DIR)? They hold the database, the keys and .env")))) {
        Remove-Item -Path $script:BACKUP_DIR -Recurse -Force -ErrorAction SilentlyContinue
        Print-Info "Removed: $script:BACKUP_DIR"
    } elseif (Test-Path $script:BACKUP_DIR) {
        $kept += "$($script:BACKUP_DIR) (backups)"
    }

    Print-Success "NeoDesk has been uninstalled"
    if ($kept.Count -gt 0) {
        Print-Info "Kept on this machine: $($kept -join ', '); -Uninstall -Purge removes them"
    }
    Press-Enter
}

#===============================================================================
# Path Configuration
#===============================================================================

function Configure-Paths {
    Print-Header
    Write-Host ""
    Write-Host "=== Path Configuration ===" -ForegroundColor White
    Write-Host ""
    Write-Host "  Current RustDesk path: " -NoNewline; Write-Host $script:RUSTDESK_PATH -ForegroundColor Cyan
    Write-Host "  Current Console path:  " -NoNewline; Write-Host $script:CONSOLE_PATH -ForegroundColor Cyan
    Write-Host "  Database path:         " -NoNewline; Write-Host $script:DB_PATH -ForegroundColor Cyan
    Write-Host ""
    
    $items = @(
        "Auto-detect paths`tProbe for an existing installation",
        "Set server path`tEnter the NeoDesk server path",
        "Set console path`tEnter the web console path",
        "Reset to defaults`tRestore the default paths",
        "Back`tReturn to the main menu"
    )
    $returns = @("1", "2", "3", "4", "0")
    Invoke-MenuChoose -Title "Path Configuration" -Subtitle "Server: $script:RUSTDESK_PATH" -Items $items -Returns $returns
    $choice = $script:MENU_CHOICE
    
    switch ($choice) {
        "1" {
            $script:RUSTDESK_PATH = ""
            $script:CONSOLE_PATH = ""
            Auto-DetectPaths
            Press-Enter
            Configure-Paths
        }
        "2" {
            Write-Host ""
            $newPath = Read-Host "Enter RustDesk server path (e.g., C:\NeoDesk)"
            if ($newPath) {
                if (Test-Path $newPath) {
                    $script:RUSTDESK_PATH = $newPath
                    $script:DB_PATH = "$script:RUSTDESK_PATH\db_v2.sqlite3"
                    Print-Success "RustDesk path set to: $script:RUSTDESK_PATH"
                } else {
                    Print-Warning "Directory does not exist: $newPath"
                    if (Confirm-Action "Create this directory?") {
                        New-Item -ItemType Directory -Path $newPath -Force | Out-Null
                        $script:RUSTDESK_PATH = $newPath
                        $script:DB_PATH = "$script:RUSTDESK_PATH\db_v2.sqlite3"
                        Print-Success "Created and set RustDesk path: $script:RUSTDESK_PATH"
                    }
                }
            }
            Press-Enter
            Configure-Paths
        }
        "3" {
            Write-Host ""
            $newPath = Read-Host "Enter Console path (e.g., C:\NeoDeskConsole)"
            if ($newPath) {
                if (Test-Path $newPath) {
                    $script:CONSOLE_PATH = $newPath
                    Print-Success "Console path set to: $script:CONSOLE_PATH"
                } else {
                    Print-Warning "Directory does not exist: $newPath"
                    if (Confirm-Action "Create this directory?") {
                        New-Item -ItemType Directory -Path $newPath -Force | Out-Null
                        $script:CONSOLE_PATH = $newPath
                        Print-Success "Created and set Console path: $script:CONSOLE_PATH"
                    }
                }
            }
            Press-Enter
            Configure-Paths
        }
        "4" {
            $script:RUSTDESK_PATH = "C:\NeoDesk"
            $script:CONSOLE_PATH = "C:\NeoDeskConsole"
            $script:DB_PATH = "$script:RUSTDESK_PATH\db_v2.sqlite3"
            Print-Success "Paths reset to defaults"
            Press-Enter
            Configure-Paths
        }
        "0" { return }
        default {
            Print-Error "Invalid option"
            Start-Sleep -Seconds 1
            Configure-Paths
        }
    }
}

#===============================================================================
# Build Functions
#===============================================================================

function Do-Build {
    Print-Header
    $items = @(
        "Rebuild & deploy Go server`tCompile, stop, replace, start",
        "Compile Go server only`tBuild without deploying",
        "Build legacy Rust binaries`tArchived hbbs/hbbr",
        "Back`tReturn to the main menu"
    )
    $returns = @("1", "2", "3", "0")
    Invoke-MenuChoose -Title "Build & Deploy" -Subtitle "Compile the NeoDesk server" -Items $items -Returns $returns
    $buildChoice = $script:MENU_CHOICE
    if ([string]::IsNullOrEmpty($buildChoice)) { $buildChoice = "1" }

    switch ($buildChoice) {
        "1" { Do-RebuildGoServer }
        "2" { Do-CompileGoOnly }
        "3" { Do-BuildLegacyRust }
        "0" { return }
        default { Print-Warning "Invalid option"; Start-Sleep -Seconds 1 }
    }
}

# Rebuild & deploy Go server: compile -> backup -> stop -> replace -> start -> verify
function Do-RebuildGoServer {
    Print-Header
    Write-Host "========== REBUILD & DEPLOY GO SERVER ==========" -ForegroundColor White
    Write-Host ""

    Detect-Installation

    if ($script:INSTALL_STATUS -eq "none") {
        Print-Warning "NeoDesk is not installed. Binary will be compiled but not deployed."
        if (-not (Confirm-Action "Continue with compilation only?")) {
            Press-Enter
            return
        }
        Do-CompileGoOnly
        return
    }

    # Step 1: Compile
    Print-Step "[1/5] Compiling Go server from source..."
    if (-not (Compile-GoServer)) {
        Print-Error "Compilation failed - aborting. Current installation is untouched."
        Press-Enter
        return
    }

    $newBinary = Join-Path $script:GO_SERVER_SOURCE "neodesk-server.exe"
    if (-not (Test-Path $newBinary)) {
        Print-Error "Compiled binary not found at $newBinary"
        Press-Enter
        return
    }

    # Step 2: Backup current binary
    Print-Step "[2/5] Backing up current binary..."
    $installedBinary = Join-Path $script:RUSTDESK_PATH "neodesk-server.exe"
    $ts = Get-Date -Format "yyyyMMdd_HHmmss"
    $backupPath = "${installedBinary}.backup.${ts}"
    if (Test-Path $installedBinary) {
        Copy-Item -Path $installedBinary -Destination $backupPath -Force
        Print-Info "Backup: $backupPath"
    } else {
        Print-Info "No existing binary to backup"
    }

    # Step 3: Stop services
    Print-Step "[3/5] Stopping services..."
    Stop-AllServices

    # Step 4: Replace binary
    Print-Step "[4/5] Deploying new binary..."
    if (-not (Test-Path $script:RUSTDESK_PATH)) {
        New-Item -ItemType Directory -Path $script:RUSTDESK_PATH -Force | Out-Null
    }

    # Verify file is not locked
    if (Test-Path $installedBinary) {
        try {
            $stream = [System.IO.File]::Open($installedBinary, 'Open', 'ReadWrite', 'None')
            $stream.Close()
        } catch {
            Print-Warning "File is locked, waiting..."
            Start-Sleep -Seconds 3
            Get-Process -Name "neodesk-server" -ErrorAction SilentlyContinue | Stop-Process -Force
            Start-Sleep -Seconds 2
        }
    }

    Copy-Item -Path $newBinary -Destination $installedBinary -Force
    $size = [math]::Round((Get-Item $installedBinary).Length / 1MB, 2)
    Print-Success "Deployed: $installedBinary ($size MB)"

    # Step 5: Start services and verify
    Print-Step "[5/5] Starting services..."
    Start-ServicesWithVerification

    # Verify
    Start-Sleep -Seconds 3
    $serverProcess = Get-Process -Name "neodesk-server" -ErrorAction SilentlyContinue
    if ($serverProcess) {
        Write-Host ""
        Print-Success "Go server rebuilt and deployed successfully!"
    } else {
        Print-Error "Service failed to start after rebuild!"
        Write-Host ""
        Write-Host "Rolling back to previous binary..." -ForegroundColor Yellow
        if (Test-Path $backupPath) {
            # Stop again
            Get-Process -Name "neodesk-server" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 2
            Copy-Item -Path $backupPath -Destination $installedBinary -Force
            Start-Services
            Start-Sleep -Seconds 3
            $rollbackProcess = Get-Process -Name "neodesk-server" -ErrorAction SilentlyContinue
            if ($rollbackProcess) {
                Print-Success "Rollback successful - previous binary restored"
            } else {
                Print-Error "Rollback also failed. Check event log for details."
            }
        } else {
            Print-Error "No backup to rollback to."
        }
    }

    Press-Enter
}

# Compile Go server only (no deployment)
function Do-CompileGoOnly {
    Print-Header
    Write-Host "========== COMPILE GO SERVER ==========" -ForegroundColor White
    Write-Host ""

    if (-not (Compile-GoServer)) {
        Print-Error "Compilation failed"
        Press-Enter
        return
    }

    $newBinary = Join-Path $script:GO_SERVER_SOURCE "neodesk-server.exe"
    $size = [math]::Round((Get-Item $newBinary).Length / 1MB, 2)
    Print-Success "Binary compiled: $newBinary ($size MB)"
    Print-Info "Use option 7 -> 1 to deploy it, or copy manually."

    Press-Enter
}

# Legacy Rust build (archived - hbbs/hbbr)
function Do-BuildLegacyRust {
    Print-Header
    Write-Host "========== BUILD LEGACY RUST BINARIES ==========" -ForegroundColor White
    Write-Host ""
    Print-Warning "Legacy Rust binaries (hbbs/hbbr) are archived."
    Print-Info "The Go server is the current architecture."
    Write-Host ""
    if (-not (Confirm-Action "Continue with legacy Rust build anyway?")) {
        return
    }

    # Check Rust
    $cargoCmd = Get-Command cargo -ErrorAction SilentlyContinue
    if (-not $cargoCmd) {
        Print-Error "Rust is not installed!"
        Print-Info "Install from: https://rustup.rs"
        if (Confirm-Action "Open Rust installation page?") {
            Start-Process "https://rustup.rs"
        }
        Press-Enter
        return
    }

    $rustVersion = rustc --version
    Print-Info "Rust: $rustVersion"
    Write-Host ""

    $buildDir = Join-Path $env:TEMP "neodesk_build_$((Get-Date).Ticks)"
    New-Item -ItemType Directory -Path $buildDir -Force | Out-Null

    Push-Location $buildDir

    try {
        Print-Step "Downloading RustDesk Server sources..."
        git clone --depth 1 --branch 1.1.14 https://github.com/rustdesk/rustdesk-server.git
        Set-Location "rustdesk-server"
        git submodule update --init --recursive

        Print-Step "Applying NeoDesk modifications..."

        $srcDir = Join-Path (Get-RepoDir) "hbbs-patch-v2\src"
        if (Test-Path $srcDir) {
            Copy-Item -Path "$srcDir\main.rs" -Destination "src\main.rs" -Force
            Copy-Item -Path "$srcDir\http_api.rs" -Destination "src\http_api.rs" -Force
            Copy-Item -Path "$srcDir\database.rs" -Destination "src\database.rs" -Force
            Copy-Item -Path "$srcDir\peer.rs" -Destination "src\peer.rs" -Force -ErrorAction SilentlyContinue
            Copy-Item -Path "$srcDir\rendezvous_server.rs" -Destination "src\rendezvous_server.rs" -Force -ErrorAction SilentlyContinue
        } else {
            Print-Error "Source modifications not found: $srcDir"
            return
        }

        Print-Step "Compiling (may take several minutes)..."
        cargo build --release

        Print-Step "Copying binaries..."

        $outputDir = Join-Path (Get-RepoDir) "hbbs-patch-v2"
        Copy-Item -Path "target\release\hbbs.exe" -Destination "$outputDir\hbbs-windows-x86_64.exe" -Force
        Copy-Item -Path "target\release\hbbr.exe" -Destination "$outputDir\hbbr-windows-x86_64.exe" -Force

        Print-Success "Legacy Rust compilation completed!"
        Print-Info "Binaries saved in: $outputDir"

    } finally {
        Pop-Location
        Remove-Item -Path $buildDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    Press-Enter
}

#===============================================================================
# SSL Certificate Configuration
#===============================================================================

function Do-ConfigureSSL {
    Print-Header
    Write-Host "========== SSL CERTIFICATE CONFIGURATION ==========" -ForegroundColor White
    Write-Host ""
    
    $envFile = Join-Path $script:CONSOLE_PATH ".env"
    if (-not (Test-Path $envFile)) {
        Print-Error "Console .env not found at $envFile"
        Print-Info "Please install NeoDesk first (option 1)"
        Press-Enter
        return
    }
    
    $items = @(
        "Let's Encrypt`tNot built in on Windows: how to get a trusted certificate",
        "Custom certificate`tProvide your own cert + key files",
        "Self-signed certificate`tQuick HTTPS for testing",
        "Disable SSL`tRevert the panel back to HTTP",
        "Self-signed, client API too`tPanel, signal, relay and the client API (clients must trust it)",
        "Back`tReturn to the main menu"
    )
    $returns = @("1", "2", "3", "4", "5", "0")
    Invoke-MenuChoose -Title "SSL Certificate Configuration" -Subtitle "Enables HTTPS for the admin panel" -Items $items -Returns $returns
    $sslChoice = $script:MENU_CHOICE
    if ([string]::IsNullOrEmpty($sslChoice)) { $sslChoice = "3" }
    
    $envContent = Get-Content $envFile -Raw
    $sslDir = Join-Path $script:RUSTDESK_PATH "ssl"
    
    switch ($sslChoice) {
        "0" { return }
        "1" {
            # Let's Encrypt
            Print-Warning "This script does not get Let's Encrypt certificates on Windows."
            Print-Info "For a trusted certificate: get one for your domain (for example with an ACME client such as win-acme),"
            Print-Info "then choose Custom certificate here with its PEM files, or put a reverse proxy with its own certificate in front."
            Press-Enter
            return
        }
        "2" {
            # Custom certificate
            Write-Host ""
            $certPath = Read-Host "Path to certificate file (PEM)"
            $keyPath = Read-Host "Path to private key file (PEM)"
            $caPath = Read-Host "Path to CA bundle (optional, press Enter to skip)"
            
            if (-not (Test-Path $certPath)) {
                Print-Error "Certificate file not found: $certPath"
                Press-Enter
                return
            }
            if (-not (Test-Path $keyPath)) {
                Print-Error "Key file not found: $keyPath"
                Press-Enter
                return
            }
            
            $envContent = $envContent -replace 'HTTPS_ENABLED=.*', 'HTTPS_ENABLED=true'
            $envContent = $envContent -replace 'SSL_CERT_PATH=.*', "SSL_CERT_PATH=$certPath"
            $envContent = $envContent -replace 'SSL_KEY_PATH=.*', "SSL_KEY_PATH=$keyPath"
            if (-not [string]::IsNullOrEmpty($caPath) -and (Test-Path $caPath)) {
                $envContent = $envContent -replace 'SSL_CA_PATH=.*', "SSL_CA_PATH=$caPath"
            }
            $envContent = $envContent -replace 'HTTP_REDIRECT_HTTPS=.*', 'HTTP_REDIRECT_HTTPS=true'
            if ($envContent -match 'RUSTDESK_API_TLS=') {
                $envContent = $envContent -replace 'RUSTDESK_API_TLS=.*', 'RUSTDESK_API_TLS=true'
            } else {
                $envContent = $envContent.TrimEnd() + "`nRUSTDESK_API_TLS=true`n"
            }
            
            Set-Content $envFile -Value $envContent -NoNewline
            Print-Success "Custom SSL certificate configured"
        }
        "3" {
            # Self-signed with full SANs
            New-Item -ItemType Directory -Path $sslDir -Force | Out-Null
            
            $certPath = Join-Path $sslDir "neodesk.crt"
            $keyPath = Join-Path $sslDir "neodesk.key"
            
            Write-Host ""
            $certDomain = Read-Host "Enter domain name (optional, press Enter to skip)"
            
            # Detect IPs
            $serverIp = Get-PublicIP
            $lanIp = ""
            try {
                $lanIp = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object { 
                    $_.IPAddress -notmatch '^127\.' -and $_.IPAddress -notmatch '^169\.254\.' 
                } | Select-Object -First 1).IPAddress
            } catch {
                $lanIp = [System.Net.Dns]::GetHostAddresses($env:COMPUTERNAME) | 
                    Where-Object { $_.AddressFamily -eq 'InterNetwork' -and $_.IPAddressToString -notmatch '^127\.' } | 
                    Select-Object -First 1 -ExpandProperty IPAddressToString
            }
            
            # Build SAN list
            $sanList = "IP:$serverIp,IP:127.0.0.1,DNS:localhost"
            if ($lanIp -and $lanIp -ne $serverIp) {
                $sanList = "$sanList,IP:$lanIp"
            }
            if ($certDomain) {
                $sanList = "DNS:$certDomain,$sanList"
            }
            
            $cn = if ($certDomain) { $certDomain } else { $serverIp }
            
            Print-Step "Generating self-signed certificate..."
            Print-Info "SANs: $sanList"
            
            # Use openssl if available, otherwise PowerShell
            $openssl = Get-Command openssl -ErrorAction SilentlyContinue
            if ($openssl) {
                $sanArg = "subjectAltName=$sanList"
                & openssl req -x509 -nodes -days 3650 -newkey rsa:2048 `
                    -keyout $keyPath -out $certPath `
                    -subj "/CN=$cn/O=NeoDesk" `
                    -addext $sanArg 2>&1 | Out-Null
                    
                if (-not (Test-Path $certPath)) {
                    # Fallback for older openssl without -addext
                    & openssl req -x509 -nodes -days 3650 -newkey rsa:2048 `
                        -keyout $keyPath -out $certPath `
                        -subj "/CN=$cn/O=NeoDesk" 2>&1 | Out-Null
                }
            } else {
                # PowerShell self-signed cert
                $dnsNames = @("localhost")
                if ($certDomain) { $dnsNames += $certDomain }
                
                $cert = New-SelfSignedCertificate -DnsName $dnsNames `
                    -CertStoreLocation "cert:\LocalMachine\My" `
                    -NotAfter (Get-Date).AddYears(10) `
                    -KeyExportPolicy Exportable
                    
                # Export as PFX then convert to PEM via openssl if available
                $pfxPath = Join-Path $sslDir "neodesk.pfx"
                $certBytes = $cert.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Pfx)
                [System.IO.File]::WriteAllBytes($pfxPath, $certBytes)
                
                Print-Warning "Generated PFX certificate at $pfxPath"
                Print-Warning "For full PEM support, install OpenSSL for Windows."
                $certPath = $pfxPath
                $keyPath = $pfxPath
            }
            
            $envContent = $envContent -replace 'HTTPS_ENABLED=.*', 'HTTPS_ENABLED=true'
            $envContent = $envContent -replace 'SSL_CERT_PATH=.*', "SSL_CERT_PATH=$certPath"
            $envContent = $envContent -replace 'SSL_KEY_PATH=.*', "SSL_KEY_PATH=$keyPath"
            $envContent = $envContent -replace 'HTTP_REDIRECT_HTTPS=.*', 'HTTP_REDIRECT_HTTPS=true'
            if ($envContent -match 'RUSTDESK_API_TLS=') {
                $envContent = $envContent -replace 'RUSTDESK_API_TLS=.*', 'RUSTDESK_API_TLS=false'
            } else {
                $envContent = $envContent.TrimEnd() + "`nRUSTDESK_API_TLS=false`n"
            }
            
            # Configure NODE_EXTRA_CA_CERTS for self-signed
            if ($envContent -match 'NODE_EXTRA_CA_CERTS=') {
                $envContent = $envContent -replace 'NODE_EXTRA_CA_CERTS=.*', "NODE_EXTRA_CA_CERTS=$certPath"
            } else {
                $envContent = $envContent.TrimEnd() + "`nNODE_EXTRA_CA_CERTS=$certPath`n"
            }
            
            Set-Content $envFile -Value $envContent -NoNewline
            
            # Configure Go server with TLS for signal/relay
            Set-ServerTls -CertPath $certPath -KeyPath $keyPath
            
            Print-Success "Self-signed certificate generated (valid 10 years)"
            Print-Info "Certificate: $certPath"
            if ($lanIp -and $lanIp -ne $serverIp) {
                Print-Info "LAN IP included: $lanIp"
            }
            Print-Warning "Browsers will show security warning. Use Let's Encrypt for public servers."
        }
        "4" {
            # Disable SSL
            $envContent = $envContent -replace 'HTTPS_ENABLED=.*', 'HTTPS_ENABLED=false'
            $envContent = $envContent -replace 'SSL_CERT_PATH=.*', 'SSL_CERT_PATH='
            $envContent = $envContent -replace 'SSL_KEY_PATH=.*', 'SSL_KEY_PATH='
            $envContent = $envContent -replace 'HTTP_REDIRECT_HTTPS=.*', 'HTTP_REDIRECT_HTTPS=false'
            if ($envContent -match 'RUSTDESK_API_TLS=') {
                $envContent = $envContent -replace 'RUSTDESK_API_TLS=.*', 'RUSTDESK_API_TLS=false'
            } else {
                $envContent = $envContent.TrimEnd() + "`nRUSTDESK_API_TLS=false`n"
            }
            
            # Remove TLS args from Go server
            Set-ServerTls
            
            Set-Content $envFile -Value $envContent -NoNewline
            Print-Success "SSL disabled. Running in HTTP mode."
        }
        "5" {
            # Self-signed for the panel, signal, relay and the client API
            Print-Header
            Write-Host "========== SELF-SIGNED TLS, CLIENT API TOO ==========" -ForegroundColor Yellow
            Write-Host ""
            Write-Host "  The client API :$($script:CLIENT_API_PORT) uses this self-signed certificate too: RustDesk clients refuse it" -ForegroundColor Yellow
            Write-Host "  unless their machine trusts the certificate. The internal API :$($script:GO_API_PORT) stays HTTP." -ForegroundColor Yellow
            Write-Host ""
            
            New-Item -ItemType Directory -Path $sslDir -Force | Out-Null
            
            $certPath = Join-Path $sslDir "neodesk.crt"
            $keyPath = Join-Path $sslDir "neodesk.key"
            
            $certDomain = Read-Host "Enter domain name (optional, press Enter to skip)"
            
            # Detect IPs
            $serverIp = Get-PublicIP
            $lanIp = ""
            try {
                $lanIp = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object { 
                    $_.IPAddress -notmatch '^127\.' -and $_.IPAddress -notmatch '^169\.254\.' 
                } | Select-Object -First 1).IPAddress
            } catch { }
            
            # Build comprehensive SAN list
            $sanList = "IP:$serverIp,IP:127.0.0.1,DNS:localhost"
            if ($lanIp -and $lanIp -ne $serverIp) {
                $sanList = "$sanList,IP:$lanIp"
            }
            if ($certDomain) {
                $sanList = "DNS:$certDomain,$sanList"
            }
            
            $cn = if ($certDomain) { $certDomain } else { $serverIp }
            
            Print-Step "Generating the certificate..."
            Print-Info "SANs: $sanList"
            
            $openssl = Get-Command openssl -ErrorAction SilentlyContinue
            if ($openssl) {
                $sanArg = "subjectAltName=$sanList"
                & openssl req -x509 -nodes -days 3650 -newkey rsa:4096 `
                    -keyout $keyPath -out $certPath `
                    -subj "/CN=$cn/O=NeoDesk" `
                    -addext $sanArg 2>&1 | Out-Null
                    
                if (-not (Test-Path $certPath)) {
                    & openssl req -x509 -nodes -days 3650 -newkey rsa:4096 `
                        -keyout $keyPath -out $certPath `
                        -subj "/CN=$cn/O=NeoDesk" 2>&1 | Out-Null
                }
            } else {
                $dnsNames = @("localhost")
                if ($certDomain) { $dnsNames += $certDomain }
                
                $cert = New-SelfSignedCertificate -DnsName $dnsNames `
                    -CertStoreLocation "cert:\LocalMachine\My" `
                    -NotAfter (Get-Date).AddYears(10) `
                    -KeyExportPolicy Exportable `
                    -KeyLength 4096
                    
                $pfxPath = Join-Path $sslDir "neodesk.pfx"
                $certBytes = $cert.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Pfx)
                [System.IO.File]::WriteAllBytes($pfxPath, $certBytes)
                $certPath = $pfxPath
                $keyPath = $pfxPath
                Print-Warning "Generated PFX certificate. Install OpenSSL for PEM format."
            }
            
            # === Configure Node.js Console for HTTPS ===
            $envContent = $envContent -replace 'HTTPS_ENABLED=.*', 'HTTPS_ENABLED=true'
            $envContent = $envContent -replace 'SSL_CERT_PATH=.*', "SSL_CERT_PATH=$certPath"
            $envContent = $envContent -replace 'SSL_KEY_PATH=.*', "SSL_KEY_PATH=$keyPath"
            $envContent = $envContent -replace 'HTTP_REDIRECT_HTTPS=.*', 'HTTP_REDIRECT_HTTPS=true'
            if ($envContent -match 'RUSTDESK_API_TLS=') {
                $envContent = $envContent -replace 'RUSTDESK_API_TLS=.*', 'RUSTDESK_API_TLS=true'
            } else {
                $envContent = $envContent.TrimEnd() + "`nRUSTDESK_API_TLS=true`n"
            }
            
            # Set ALLOW_SELF_SIGNED_CERTS
            if ($envContent -match 'ALLOW_SELF_SIGNED_CERTS=') {
                $envContent = $envContent -replace 'ALLOW_SELF_SIGNED_CERTS=.*', 'ALLOW_SELF_SIGNED_CERTS=true'
            } else {
                $envContent = $envContent.TrimEnd() + "`nALLOW_SELF_SIGNED_CERTS=true`n"
            }
            
            # Configure NODE_EXTRA_CA_CERTS
            if ($envContent -match 'NODE_EXTRA_CA_CERTS=') {
                $envContent = $envContent -replace 'NODE_EXTRA_CA_CERTS=.*', "NODE_EXTRA_CA_CERTS=$certPath"
            } else {
                $envContent = $envContent.TrimEnd() + "`nNODE_EXTRA_CA_CERTS=$certPath`n"
            }
            
            # Keep internal Go API URLs on HTTP for RustDesk client compatibility
            $envContent = $envContent -replace 'HBBS_API_URL=https://localhost', 'HBBS_API_URL=http://localhost'
            $envContent = $envContent -replace 'NEODESK_API_URL=https://localhost', 'NEODESK_API_URL=http://localhost'
            
            # Set ENTERPRISE_TLS marker
            if ($envContent -match 'ENTERPRISE_TLS=') {
                $envContent = $envContent -replace 'ENTERPRISE_TLS=.*', 'ENTERPRISE_TLS=true'
            } else {
                $envContent = $envContent.TrimEnd() + "`nENTERPRISE_TLS=true`n"
            }
            
            Set-Content $envFile -Value $envContent -NoNewline
            
            # === Configure Go server with TLS for signal + relay only ===
            Set-ServerTls -CertPath $certPath -KeyPath $keyPath
            
            Print-Success "TLS configured"
            Write-Host ""
            Print-Info "Certificate: $certPath"
            Print-Info "Valid: 10 years (RSA 4096-bit)"
            if ($lanIp -and $lanIp -ne $serverIp) {
                Print-Info "LAN IP: $lanIp"
            }
            Write-Host ""
            Write-Host "  TLS configured for external channels:" -ForegroundColor Yellow
            Print-Info "  - Panel HTTPS: :5443 (or configured port)"
            Print-Info "  - Signal TLS: :21116"
            Print-Info "  - Relay TLS: :21117"
            Print-Info "  - Client API HTTPS: :$($script:CLIENT_API_PORT)"
            Print-Info "  - Internal API HTTP: :$($script:GO_API_PORT)"
            Write-Host ""
            Print-Warning "For browsers/clients, you may need to import $certPath as trusted CA"
        }
        default {
            Print-Warning "Invalid option"
            Press-Enter
            return
        }
    }
    
    # ── Update API URLs in .env when SSL is enabled/disabled ──
    # Go API TLS (--tls-api) is intentionally not enabled by SSL options.
    # RustDesk desktop clients use plain HTTP on :GO_API_PORT or compat :CLIENT_API_PORT.
    $envContent = Get-Content $envFile -Raw
    
    if ($sslChoice -eq "5") {
        Print-Info "Panel, signal and relay use TLS; the internal Go API stays HTTP"
        $envContent = $envContent -replace 'HBBS_API_URL=https://localhost', 'HBBS_API_URL=http://localhost'
        $envContent = $envContent -replace 'NEODESK_API_URL=https://localhost', 'NEODESK_API_URL=http://localhost'
    } elseif ($sslChoice -ne "4") {
        # === Standard SSL (options 1-3): API stays HTTP for RustDesk client compatibility ===
        $envContent = $envContent -replace 'HBBS_API_URL=https://localhost', 'HBBS_API_URL=http://localhost'
        $envContent = $envContent -replace 'NEODESK_API_URL=https://localhost', 'NEODESK_API_URL=http://localhost'
        
        # Only the Node.js console read NODE_EXTRA_CA_CERTS
        $envContent = $envContent -replace '(?m)^NODE_EXTRA_CA_CERTS=.*\r?\n?', ''

        # The API stays HTTP: no -tls-api on the server
        $current = Get-ServerServiceArguments
        if ($current) {
            $kept = ($current -replace '\s*-(tls-api|force-https)(=\S+)?(?=\s|$)', '').Trim()
            if ($kept -ne $current) { Set-ServerServiceArguments -Arguments $kept | Out-Null }
        }
        
        Print-Info "Signal/relay TLS enabled, API stays HTTP (RustDesk client compatibility)"
    } else {
        # === SSL disabled (option 4) — revert API URLs to HTTP ===
        $envContent = $envContent -replace 'HBBS_API_URL=https://localhost', 'HBBS_API_URL=http://localhost'
        $envContent = $envContent -replace 'NEODESK_API_URL=https://localhost', 'NEODESK_API_URL=http://localhost'
        $envContent = $envContent -replace '(?m)^NODE_EXTRA_CA_CERTS=.*\r?\n?', ''
        $envContent = $envContent -replace '(?m)^ENTERPRISE_TLS=.*\r?\n?', ''
        $envContent = $envContent -replace 'ALLOW_SELF_SIGNED_CERTS=.*', 'ALLOW_SELF_SIGNED_CERTS=false'
        
        Print-Info "All TLS disabled, API URLs reverted to HTTP"
    }
    
    Set-Content $envFile -Value $envContent -NoNewline
    
    Write-Host ""
    if (Confirm-Action "Restart NeoDesk to apply changes?") {
        Stop-ServerService
        Start-ServerService
        Print-Success "NeoDesk restarted"
    }
    
    Press-Enter
}

#===============================================================================
# HTTP/HTTPS Protocol Toggle
#===============================================================================

# The server's settings without the HTTPS keys an older install's service
# carried, which won over .env: the protocol switch writes them to .env.
function Clear-TlsSettingsOfService {
    $settings = @(Get-ServerServiceSettings)
    $kept = @($settings | Where-Object { $_ -notmatch '^(HTTPS_ENABLED|ALLOW_SELF_SIGNED_CERTS|RUSTDESK_API_TLS|NODE_EXTRA_CA_CERTS|ENTERPRISE_TLS|HTTP_REDIRECT_HTTPS)=' } |
            ForEach-Object { $_ -replace '^(HBBS_API_URL|NEODESK_API_URL)=https://localhost', '$1=http://localhost' })
    if (($kept -join "`n") -ne ($settings -join "`n")) { Set-ServerServiceSettings -Environment $kept | Out-Null }
}

function Do-ToggleProtocol {
    Print-Header
    Write-Host "========== PROTOCOL TOGGLE (HTTP / HTTPS) ==========" -ForegroundColor White
    Write-Host ""

    $envFile = Join-Path $script:CONSOLE_PATH ".env"
    $sslDir = Join-Path $script:RUSTDESK_PATH "ssl"

    # The current mode: HTTPS_ENABLED of the server's settings, which win
    # over .env, else of .env
    $currentMode = "HTTP"
    $settings = @(Get-ServerServiceSettings)
    $https = @($settings | Where-Object { $_ -like 'HTTPS_ENABLED=*' } | Select-Object -First 1)
    if ($https.Count -gt 0) {
        if ($https[0] -eq 'HTTPS_ENABLED=true') { $currentMode = "HTTPS" }
    } elseif ((Get-ConsoleEnvValue -Key "HTTPS_ENABLED") -eq "true") {
        $currentMode = "HTTPS"
    }

    $serverArgs = "$(Get-ServerServiceArguments)"
    $tlsSignal = if ($serverArgs -match "-tls-signal") { "yes" } else { "no" }
    $tlsRelay = if ($serverArgs -match "-tls-relay") { "yes" } else { "no" }

    Write-Host "  Current mode: $currentMode" -ForegroundColor White
    Write-Host "  Signal TLS:   $tlsSignal"
    Write-Host "  Relay TLS:    $tlsRelay"
    Write-Host ""
    $items = @(
        "Switch to HTTP`tEverything plain - LAN / testing",
        "Switch to HTTPS`tPanel HTTPS + signal/relay TLS",
        "Back`tReturn to the main menu"
    )
    $returns = @("1", "2", "0")
    Invoke-MenuChoose -Title "Protocol Mode" -Subtitle "Current mode: $currentMode" -Items $items -Returns $returns
    $protoChoice = $script:MENU_CHOICE

    switch ($protoChoice) {
        "1" {
            # --- Switch to HTTP ---
            Write-Host ""
            Print-Step "Switching to HTTP mode..."

            # Update .env
            if (Test-Path $envFile) {
                $content = Get-Content $envFile -Raw
                $content = $content -replace "(?m)^HTTPS_ENABLED=.*$", "HTTPS_ENABLED=false"
                $content = $content -replace "(?m)^RUSTDESK_API_TLS=.*$", "RUSTDESK_API_TLS=false"
                $content = $content -replace "(?m)^ALLOW_SELF_SIGNED_CERTS=.*$", "ALLOW_SELF_SIGNED_CERTS=false"
                $content = $content -replace "(?m)^HBBS_API_URL=https://localhost", "HBBS_API_URL=http://localhost"
                $content = $content -replace "(?m)^NEODESK_API_URL=https://localhost", "NEODESK_API_URL=http://localhost"
                $content = $content -replace "(?m)^HTTP_REDIRECT_HTTPS=.*$", "HTTP_REDIRECT_HTTPS=false"
                $content = $content -replace "(?m)^NODE_EXTRA_CA_CERTS=.*`n?", ""
                $content = $content -replace "(?m)^ENTERPRISE_TLS=.*`n?", ""
                Set-Content -Path $envFile -Value $content.TrimEnd() -Encoding UTF8
            }

            Clear-TlsSettingsOfService
            # No TLS on the server
            Set-ServerTls

            Print-Success "Switched to HTTP mode"
            Write-Host ""
            Print-Info "  Panel:         HTTP :$(Get-ConsoleHttpPort)"
            Print-Info "  Signal:        TCP  :21116"
            Print-Info "  Relay:         TCP  :21117"
            Print-Info "  Go API:        HTTP :$($script:GO_API_PORT) (default)"
            Print-Info "  Client API:    HTTP :$($script:CLIENT_API_PORT) (compat proxy)"
            Write-Host ""
            Print-Warning "SSL certificates were NOT deleted (use option C > 4 to remove)"
        }
        "2" {
            # --- Switch to HTTPS ---
            Write-Host ""

            $certFile = Join-Path $sslDir "neodesk.crt"
            $keyFile = Join-Path $sslDir "neodesk.key"

            # Check for SSL certificates
            if (-not (Test-Path $certFile) -or -not (Test-Path $keyFile)) {
                Print-Warning "No SSL certificates found at $sslDir"
                Write-Host ""
                $gen = Read-Host "Generate self-signed certificate now? [Y/n]"
                if ($gen -ne "n" -and $gen -ne "N") {
                    if (-not (Test-Path $sslDir)) { New-Item -ItemType Directory -Path $sslDir -Force | Out-Null }

                    $serverIp = try {
                        (Invoke-WebRequest -Uri "https://api.ipify.org" -TimeoutSec 5 -UseBasicParsing).Content.Trim()
                    } catch { "127.0.0.1" }

                    & openssl req -x509 -nodes -days 3650 -newkey rsa:4096 `
                        -keyout $keyFile -out $certFile `
                        -subj "/CN=$serverIp/O=NeoDesk" 2>$null

                    if (Test-Path $certFile) {
                        Print-Success "Self-signed certificate generated"
                    } else {
                        Print-Error "Failed to generate certificate (is openssl installed?)"
                        Press-Enter
                        return
                    }
                } else {
                    Print-Error "Cannot enable HTTPS without certificates"
                    Print-Info "Use option C (SSL config) to set up certificates first"
                    Press-Enter
                    return
                }
            }

            Print-Step "Switching to HTTPS mode..."

            # Update .env
            if (Test-Path $envFile) {
                $content = Get-Content $envFile -Raw
                $content = $content -replace "(?m)^HTTPS_ENABLED=.*$", "HTTPS_ENABLED=true"
                $content = $content -replace "(?m)^SSL_CERT_PATH=.*$", "SSL_CERT_PATH=$certFile"
                $content = $content -replace "(?m)^SSL_KEY_PATH=.*$", "SSL_KEY_PATH=$keyFile"
                $content = $content -replace "(?m)^HTTP_REDIRECT_HTTPS=.*$", "HTTP_REDIRECT_HTTPS=true"
                # Keep Go API on HTTP
                $content = $content -replace "(?m)^HBBS_API_URL=https://localhost", "HBBS_API_URL=http://localhost"
                $content = $content -replace "(?m)^NEODESK_API_URL=https://localhost", "NEODESK_API_URL=http://localhost"
                if ($content -notmatch "ALLOW_SELF_SIGNED_CERTS=") {
                    $content += "`nALLOW_SELF_SIGNED_CERTS=true"
                } else {
                    $content = $content -replace "(?m)^ALLOW_SELF_SIGNED_CERTS=.*$", "ALLOW_SELF_SIGNED_CERTS=true"
                }
                if ($content -notmatch "NODE_EXTRA_CA_CERTS=") {
                    $content += "`nNODE_EXTRA_CA_CERTS=$certFile"
                } else {
                    $content = $content -replace "(?m)^NODE_EXTRA_CA_CERTS=.*$", "NODE_EXTRA_CA_CERTS=$certFile"
                }
                Set-Content -Path $envFile -Value $content.TrimEnd() -Encoding UTF8
            }

            Clear-TlsSettingsOfService
            # TLS for signal and relay only; the API stays HTTP
            Set-ServerTls -CertPath $certFile -KeyPath $keyFile

            Print-Success "Switched to HTTPS mode"
            Write-Host ""
            Print-Info "  Panel:         HTTPS :5443"
            Print-Info "  Signal:        TLS   :21116"
            Print-Info "  Relay:         TLS   :21117"
            Print-Info "  Go API:        HTTP  :$($script:GO_API_PORT) (default, always HTTP)"
            Print-Info "  Client API:    HTTP  :$($script:CLIENT_API_PORT) (compat proxy)"
        }
        default { return }
    }

    Write-Host ""
    $restart = Read-Host "Restart NeoDesk services now? [Y/n]"
    if ($restart -ne "n" -and $restart -ne "N") {
        Stop-ServerService
        Start-ServerService
        Start-Sleep -Seconds 2
        $status = (Get-Service -Name $script:SERVER_SERVICE -ErrorAction SilentlyContinue).Status
        if ("$status" -eq "Running") { Print-Success "NeoDesk restarted: $($script:SERVER_SERVICE) is running" }
        else { Print-Error "$($script:SERVER_SERVICE): $(if ($status) { $status } else { 'not found' }) (log: $(Get-ServerLogPath))" }
    }

    Press-Enter
}

#===============================================================================
# Database Migration Functions
#===============================================================================

# True when the binary carries the migrate command (sqlite2pg, pg2sqlite,
# rust2go and backup of a SQLite file).
function Test-BinaryMigrates {
    param([string]$Path = (Get-ServerBinaryPath))
    if (-not $Path -or -not (Test-Path $Path)) { return $false }
    return [bool](Select-String -Path $Path -Pattern 'migrate -mode sqlite2pg' -SimpleMatch -Quiet)
}

# True when the binary carries the backup command (the console's full
# backup, also of PostgreSQL, while the server runs).
function Test-BinaryBacksUp {
    param([string]$Path = (Get-ServerBinaryPath))
    if (-not $Path -or -not (Test-Path $Path)) { return $false }
    return [bool](Select-String -Path $Path -Pattern 'backup [--out DIR]' -SimpleMatch -Quiet)
}

# The installed binary's migrate command with the arguments given.
function Invoke-ServerMigrate {
    & (Get-ServerBinaryPath) migrate @args
}

# Get-MigrateBin returns the migration tool: the installed binary's migrate
# command (Invoke-ServerMigrate), or $null when the binary has none.
function Get-MigrateBin {
    if (Test-BinaryMigrates) { return "Invoke-ServerMigrate" }
    return $null
}

# Confirm-MigrateOverwrite decides whether the migration tool may replace
# the SQLite file at Destination. It sets $script:MIGRATE_OVERWRITE to
# "-overwrite" when the file (or a -wal, -shm or -journal of one) exists
# and the user agreed, to "" when there is nothing to replace, and returns
# $false when the user declined. A postgres:// destination needs nothing.
function Confirm-MigrateOverwrite {
    param([string]$Destination)
    $script:MIGRATE_OVERWRITE = ""
    if ($Destination -match '^postgres(ql)?://') { return $true }
    $existing = @(@("", "-wal", "-shm", "-journal") | Where-Object { Test-Path -LiteralPath ($Destination + $_) })
    if ($existing.Count -eq 0) { return $true }
    Print-Warning "Destination file exists: $Destination"
    if (-not (Confirm-Action "Overwrite (backup will be created first)?")) { return $false }
    $script:MIGRATE_OVERWRITE = "-overwrite"
    return $true
}

function Do-MigrateDatabase {
    Print-Header
    Write-Host "========== DATABASE MIGRATION ==========" -ForegroundColor White
    Write-Host ""

    $migrateBin = Get-MigrateBin
    if (-not $migrateBin) {
        Print-Error "No migration tool: $(Get-ServerBinaryPath) has no migrate command"
        Print-Info "Update first (-Update): the server's own migrate command moves the database"
        Press-Enter
        return
    }

    if ($migrateBin -eq "Invoke-ServerMigrate") { Print-Info "Migration tool: $(Get-ServerBinaryPath) migrate" }
    else { Print-Info "Migration binary: $migrateBin" }
    Write-Host ""
    $items = @(
        "Rust -> Go`tLegacy Rust hbbs database to Go server",
        "SQLite -> PostgreSQL`tWhole install (every server and console table) to PostgreSQL",
        "PostgreSQL -> SQLite`tWhole install from PostgreSQL to a SQLite file",
        "Backup`tCreate a timestamped SQLite backup",
        "Back`tReturn to the main menu"
    )
    $returns = @("1", "2", "3", "4", "0")
    Invoke-MenuChoose -Title "Database Migration" -Subtitle "Move data between NeoDesk components" -Items $items -Returns $returns
    $migChoice = $script:MENU_CHOICE

    switch ($migChoice) {
        "1" {
            # Rust -> Go
            Write-Host ""
            $defaultSrc = Join-Path $script:RUSTDESK_PATH "db_v2.sqlite3"
            $srcDb = Read-Host "Source Rust database [$defaultSrc]"
            if ([string]::IsNullOrEmpty($srcDb)) { $srcDb = $defaultSrc }

            if (-not (Test-Path $srcDb)) {
                Print-Error "Source database not found: $srcDb"
                Press-Enter
                return
            }

            $dstDb = Read-Host "Destination (SQLite path or postgres:// URI) [new file next to source]"
            if ([string]::IsNullOrEmpty($dstDb)) { $dstDb = Join-Path (Split-Path -Parent $srcDb) "neodesk.sqlite3" }
            if (-not (Confirm-MigrateOverwrite $dstDb)) {
                Press-Enter
                return
            }

            Print-Step "Creating backup before migration..."
            & $migrateBin -mode backup -src $srcDb 2>&1 | ForEach-Object { Write-Host $_ }
            if ($script:MIGRATE_OVERWRITE -and (Test-Path -LiteralPath $dstDb)) {
                & $migrateBin -mode backup -src $dstDb 2>&1 | ForEach-Object { Write-Host $_ }
            }

            Print-Step "Running Rust -> Go migration..."
            $migrateArgs = @("-mode", "rust2go", "-src", $srcDb, "-dst", $dstDb)
            if ($script:MIGRATE_OVERWRITE) { $migrateArgs += $script:MIGRATE_OVERWRITE }
            & $migrateBin @migrateArgs 2>&1 | ForEach-Object { Write-Host $_ }

            if ($LASTEXITCODE -eq 0) {
                Print-Success "Rust -> Go migration completed successfully!"
            } else {
                Print-Error "Migration failed. Check the output above for details."
            }
        }
        "2" {
            # SQLite -> PostgreSQL
            Write-Host ""
            $defaultSrc = Join-Path $script:RUSTDESK_PATH "db_v2.sqlite3"
            $srcDb = Read-Host "Source SQLite database [$defaultSrc]"
            if ([string]::IsNullOrEmpty($srcDb)) { $srcDb = $defaultSrc }

            if (-not (Test-Path $srcDb)) {
                Print-Error "Source database not found: $srcDb"
                Press-Enter
                return
            }

            $pgUri = Read-Host "PostgreSQL connection URI (postgres://user:pass@host:5432/dbname)"
            if ([string]::IsNullOrEmpty($pgUri)) {
                Print-Error "PostgreSQL URI is required"
                Press-Enter
                return
            }

            Print-Info "Every table of the server and the console moves: devices, users, settings, tickets, groups, audit log and the rest."
            $migrateArgs = @("-mode", "sqlite2pg", "-src", $srcDb, "-dst", $pgUri)
            if (Confirm-Action "If the PostgreSQL database already holds data, replace all of it?") { $migrateArgs += "-overwrite" }

            Print-Step "Creating backup before migration..."
            & $migrateBin -mode backup -src $srcDb 2>&1 | ForEach-Object { Write-Host $_ }

            # The install's own database: the server stops for the copy and
            # starts again on the new database
            $ownDb = ($srcDb -eq (Join-Path $script:RUSTDESK_PATH "db_v2.sqlite3")) -and (Test-Path (Join-Path $script:CONSOLE_PATH ".env"))
            if ($ownDb) { Stop-ServerService }

            Print-Step "Running SQLite -> PostgreSQL migration..."
            & $migrateBin @migrateArgs 2>&1 | ForEach-Object { Write-Host $_ }

            if ($LASTEXITCODE -eq 0) {
                Print-Success "SQLite -> PostgreSQL migration completed successfully!"
                if ($ownDb) {
                    Use-DatabaseInEnv -Type postgres -Address $pgUri
                    Print-Success "The install now runs on PostgreSQL"
                }
            } else {
                Print-Error "Migration failed. Check the output above for details."
                if ($ownDb) { Print-Info "The install stays on $srcDb" }
            }
            if ($ownDb) { Start-ServerService }
        }
        "3" {
            # PostgreSQL -> SQLite
            Write-Host ""
            $pgUri = Read-Host "PostgreSQL connection URI (postgres://user:pass@host:5432/dbname)"
            if ([string]::IsNullOrEmpty($pgUri)) {
                Print-Error "PostgreSQL URI is required"
                Press-Enter
                return
            }

            $defaultDst = Join-Path $script:RUSTDESK_PATH "db_v2.sqlite3"
            $dstDb = Read-Host "Destination SQLite file [$defaultDst]"
            if ([string]::IsNullOrEmpty($dstDb)) { $dstDb = $defaultDst }

            Print-Info "Every table of the server and the console moves: devices, users, settings, tickets, groups, audit log and the rest."
            if (-not (Confirm-MigrateOverwrite $dstDb)) {
                Press-Enter
                return
            }
            if ($script:MIGRATE_OVERWRITE -and (Test-Path -LiteralPath $dstDb)) {
                & $migrateBin -mode backup -src $dstDb 2>&1 | ForEach-Object { Write-Host $_ }
            }

            # The install's own database: the server stops for the copy and
            # starts again on the new database
            $ownPg = ((Get-EnvDatabaseUrl) -eq $pgUri) -and ($dstDb -eq (Join-Path $script:RUSTDESK_PATH "db_v2.sqlite3"))
            if ($ownPg) { Stop-ServerService }

            Print-Step "Running PostgreSQL -> SQLite migration..."
            $migrateArgs = @("-mode", "pg2sqlite", "-src", $pgUri, "-dst", $dstDb)
            if ($script:MIGRATE_OVERWRITE) { $migrateArgs += $script:MIGRATE_OVERWRITE }
            & $migrateBin @migrateArgs 2>&1 | ForEach-Object { Write-Host $_ }

            if ($LASTEXITCODE -eq 0) {
                Print-Success "PostgreSQL -> SQLite migration completed successfully!"
                if ($ownPg) {
                    Use-SQLiteInstall $dstDb
                    Print-Success "The install now runs on SQLite ($dstDb)"
                }
            } else {
                Print-Error "Migration failed. Check the output above for details."
            }
            if ($ownPg) { Start-ServerService }
        }
        "4" {
            # Backup
            Write-Host ""
            $defaultSrc = Join-Path $script:RUSTDESK_PATH "db_v2.sqlite3"
            $srcDb = Read-Host "SQLite database to backup [$defaultSrc]"
            if ([string]::IsNullOrEmpty($srcDb)) { $srcDb = $defaultSrc }

            if (-not (Test-Path $srcDb)) {
                Print-Error "Database not found: $srcDb"
                Press-Enter
                return
            }

            Print-Step "Creating backup..."
            & $migrateBin -mode backup -src $srcDb 2>&1 | ForEach-Object { Write-Host $_ }

            if ($LASTEXITCODE -eq 0) {
                Print-Success "Backup created successfully!"
            } else {
                Print-Error "Backup failed."
            }
        }
        "0" { return }
        default {
            Print-Warning "Invalid option"
        }
    }

    Press-Enter
}

#===============================================================================
# Main Menu
#===============================================================================

function Show-Menu {
    Print-Header
    Print-Status
    
    Write-Host "========== MAIN MENU ==========" -ForegroundColor White
    Write-Host ""
    Write-Host "  1. FRESH INSTALLATION"
    Write-Host "  2. UPDATE"
    Write-Host "  3. REPAIR INSTALLATION"
    Write-Host "  4. INSTALLATION VALIDATION"
    Write-Host "  5. Backup"
    Write-Host "  6. Reset admin password"
    Write-Host "  7. Build & deploy server"
    Write-Host "  8. DIAGNOSTICS"
    Write-Host "  9. UNINSTALL"
    Write-Host ""
    Write-Host "  L. MINIMAL INSTALLATION (web console off)"
    Write-Host "  C. Configure SSL certificates"
    Write-Host "  T. Toggle HTTP/HTTPS mode"
    Write-Host "  M. Database migration"
    Write-Host "  S. Settings (paths)"
    Write-Host "  P. Management capabilities and server settings"
    Write-Host "  0. Exit"
    Write-Host ""
}

# What a run without questions does here: install, update (an install of
# the server with its console is there), minimal or uninstall. -PostgreSQL
# on an install that runs on SQLite installs again, which moves it to
# PostgreSQL. An install with the Node.js console gets install, which
# refuses it.
function Get-AutoAction {
    if ($script:UNINSTALL_MODE) { return "uninstall" }
    if ((Test-GoOnlyInstall) -and (Test-Path (Get-ServerBinaryPath)) -and (Test-Path (Join-Path $script:CONSOLE_PATH ".env")) -and
        (-not $script:USE_POSTGRESQL -or (Get-EnvDatabaseType) -eq "postgres")) { return "update" }
    if ($script:MINIMAL_MODE) { return "minimal" }
    return "install"
}

#===============================================================================
# Relay node (-Node)
#===============================================================================
# A relay node is the server binary in node mode at a site: the site's
# devices relay through it. It has no database and no web console. A server
# install here stays as it is: the node is the service NeoDeskRelayNode,
# with its own folder and virtual account.

$script:NODE_PATH = if ($env:NEODESK_NODE_PATH) { $env:NEODESK_NODE_PATH } else { "C:\NeoDeskRelayNode" }

# The address as host:port, with the relay port 21117 when it names none;
# $null for anything but a host name, an IPv4 address or [IPv6].
function Get-NodeAddress {
    param([string]$Address)
    if ($Address -match '^(\[[0-9A-Fa-f:.]+\]|[A-Za-z0-9.-]+)$') { $Address += ":21117" }
    if ($Address -match '^(\[[0-9A-Fa-f:.]+\]|[A-Za-z0-9.-]+):\d{1,5}$') { return $Address }
    return $null
}

function Do-RelayNode {
    # From here on the server's helpers work on the node's folder and service
    $script:RUSTDESK_PATH = $script:NODE_PATH
    $script:CONSOLE_PATH = $script:NODE_PATH
    $script:SERVER_SERVICE = "NeoDeskRelayNode"
    $data = Join-Path $script:NODE_PATH "data"
    if ($script:UNINSTALL_MODE) {
        Stop-Service -Name $script:SERVER_SERVICE -Force -ErrorAction SilentlyContinue
        if (Test-ServerIsService) { Invoke-ServiceControl delete $script:SERVER_SERVICE | Out-Null }
        Get-NetFirewallRule -DisplayName "NeoDesk relay node - *" -ErrorAction SilentlyContinue | Remove-NetFirewallRule -ErrorAction SilentlyContinue
        Get-ChildItem $script:NODE_PATH -ErrorAction SilentlyContinue | Where-Object { $script:PURGE_MODE -or $_.Name -ne "data" } | Remove-Item -Recurse -Force
        if ($script:PURGE_MODE) { Remove-Item $script:NODE_PATH -Recurse -Force -ErrorAction SilentlyContinue; Print-Success "Relay node removed with its key; remove it in the console too (Sites)" }
        else { Print-Success "Relay node removed; its key stays in $data (-Purge removes it)" }
        return $true
    }
    $enrolled = Test-Path (Join-Path $data "node.json")
    $old = @{}
    foreach ($line in (Get-ServerServiceEnvironment)) { $pair = $line -split '=', 2; $old[$pair[0]] = $pair[1] }
    $joinValue = if ($Join) { $Join } else { $old["NODE_JOIN"] }
    if ($Join -and $Join -notmatch '^nd1\.[A-Za-z0-9_=-]+$') { Print-Error "-Join takes the join string the console shows under Sites (nd1. and the rest of it)"; return $false }
    if ($Join -and $enrolled) { Print-Error "This machine is a relay node already ($data\node.json). Run without -Join to update it; to join another site, first -Node -Uninstall -Purge"; return $false }
    if (-not $joinValue -and -not $enrolled) { Print-Error "-Join is needed: the join string the console shows under Sites"; return $false }
    $lan = Get-NodeAddress $(if ($LanAddr) { $LanAddr } elseif ($old["NODE_LAN_ADDR"]) { $old["NODE_LAN_ADDR"] } else { Get-LocalIP })
    $public = if ($PublicAddr) { Get-NodeAddress $PublicAddr } else { [string]$old["NODE_PUBLIC_ADDR"] }
    if (-not $lan -or ($PublicAddr -and -not $public)) { Print-Error "-LanAddr and -PublicAddr take host:port (an IPv6 address in brackets)"; return $false }
    if (-not (Get-StagedServerBinary)) { return $false }
    $ok = [bool](Select-String -Path $script:STAGED_SERVER_BINARY -Pattern 'NODE_JOIN' -SimpleMatch -Quiet)
    if (-not $ok) { Print-Error "This neodesk-server has no relay node mode yet ($($script:STAGED_SERVER_VERSION))" }
    if ($ok) { Stop-Service -Name $script:SERVER_SERVICE -Force -ErrorAction SilentlyContinue; $ok = Install-StagedBinary }
    Remove-Item -Path $script:STAGED_SERVER_DIR -Recurse -Force -ErrorAction SilentlyContinue
    if (-not $ok) { return $false }
    New-Item -ItemType Directory -Path $data -Force | Out-Null
    $environment = @("MODE=node", "NODE_DATA_DIR=$data", "NODE_LAN_ADDR=$lan", "NODE_PUBLIC_ADDR=$public", "NEODESK_SUPERVISOR=windows-service")
    if (-not $enrolled) { $environment += "NODE_JOIN=$joinValue" }
    if (-not (Set-ServerService -Arguments "node" -Environment $environment -DisplayName "NeoDesk Relay Node" -Description "NeoDesk relay node of a site")) { return $false }
    # Only Administrators, SYSTEM and the node's account read its key
    Protect-Folder -Path $script:NODE_PATH -ServiceAccount | Out-Null
    foreach ($rule in @(@{ Name = "relay"; Port = 21117 }, @{ Name = "relay over WebSocket"; Port = 21119 }, @{ Name = "legs from other sites"; Port = 21125 })) {
        if (-not (Get-NetFirewallRule -DisplayName "NeoDesk relay node - $($rule.Name)" -ErrorAction SilentlyContinue)) {
            New-NetFirewallRule -DisplayName "NeoDesk relay node - $($rule.Name)" -Direction Inbound -Action Allow -Protocol TCP -LocalPort $rule.Port -Profile Any -ErrorAction SilentlyContinue | Out-Null
        }
    }
    Start-Service -Name $script:SERVER_SERVICE -ErrorAction SilentlyContinue
    # The join string is good for one enrollment: it goes once the node has its node.json
    for ($i = 0; $i -lt 30 -and -not $enrolled; $i++) { Start-Sleep -Seconds 1; $enrolled = Test-Path (Join-Path $data "node.json") }
    if ($enrolled) { Set-ServerServiceEnvironment -Environment @($environment | Where-Object { $_ -notlike "NODE_JOIN=*" }) }
    if ((Get-Service -Name $script:SERVER_SERVICE).Status -ne 'Running') { Print-Error "The service $($script:SERVER_SERVICE) did not start; its log: $(Get-ServerLogPath)"; return $false }
    if ($enrolled) { Print-Success "Relay node running (LAN $lan, public $(if ($public) { $public } else { 'none' }))" }
    else { Print-Warning "The relay node runs but has not joined its site yet; its log: $(Get-ServerLogPath)" }
    return $true
}

function Main {
    # A relay node leaves a server install here alone: nothing below runs
    if ($Node) { exit ([int](-not (Do-RelayNode))) }

    # Auto-detect paths on startup
    Write-Host "Detecting installation..." -ForegroundColor Cyan
    Auto-DetectPaths
    Write-Host ""
    Start-Sleep -Seconds 1

    if ($script:CHECK_PERMISSIONS -or $script:REPAIR_PERMISSIONS -or
        ($script:MANAGED_CONFIG_CHANGES -and $script:MANAGED_CONFIG_CHANGES.Count -gt 0)) {
        if ($script:REPAIR_PERMISSIONS) { Repair-ManagementPermissions }
        $capabilitiesOk = Test-ManagementCapabilities
        if ($script:MANAGED_CONFIG_CHANGES -and $script:MANAGED_CONFIG_CHANGES.Count -gt 0) {
            if (-not (Set-ManagedConfiguration)) { $capabilitiesOk = $false }
        }
        exit ([int](-not $capabilitiesOk))
    }
    
    if ($script:UNINSTALL_MODE -and -not $script:AUTO_MODE) {
        Do-Uninstall
        exit 0
    }

    # A new admin password without questions
    if ($script:RESET_PASSWORD_MODE) {
        $script:AUTO_MODE = $true
        exit ([int](-not (Do-ResetPassword)))
    }

    # An update runs without questions
    if ($script:UPDATE_MODE) {
        $script:AUTO_MODE = $true
        exit ([int](-not (Do-Update)))
    }

    # Without questions: install, or update an install that is there (run
    # again, the installer updates)
    if ($script:AUTO_MODE) {
        $ok = $true
        switch (Get-AutoAction) {
            "uninstall" { Do-Uninstall }
            "update" { Print-Info "NeoDesk is installed here: updating it"; $ok = Do-Update }
            "minimal" { $ok = Do-InstallMinimal }
            default { $ok = Do-Install }
        }
        exit ([int](-not $ok))
    }

    while ($true) {
        $menuLabels = @(
            "Fresh installation`tFull install from scratch",
            "Update`tNewest release of the update channel",
            "Repair installation`tFix common problems",
            "Validate installation`tCheck correctness",
            "Backup`tCreate a backup",
            "Reset admin password`tReset the console admin",
            "Build & deploy server`tCompile and deploy the Go server",
            "Diagnostics`tDetailed problem analysis",
            "Uninstall`tRemove NeoDesk",
            "Minimal installation`tServer with its web console off",
            "Configure SSL certificates`tLet's Encrypt / custom / self-signed",
            "Toggle HTTP/HTTPS`tSwitch protocol mode",
            "Database migration`tMigrate between backends",
            "Settings (paths)`tConfigure install paths",
            "Management capabilities`tCheck permissions and change allowlisted server settings",
            "Exit`tQuit the manager"
        )
        $menuActions = @("1", "2", "3", "4", "5", "6", "7", "8", "9", "L", "C", "T", "M", "S", "P", "0")

        $choice = ""
        if (Test-TuiAvailable) {
            $statusLine = "NeoDesk Console Manager v$VERSION"
            if (Invoke-TuiSelect -Title "NeoDesk Console Manager v$VERSION" -Subtitle "Use arrow keys, Enter to select" -Items $menuLabels) {
                $choice = $menuActions[$script:TUI_RESULT]
            } else {
                $choice = "0"
            }
        } else {
            Show-Menu
            $choice = Read-Host "Select option"
        }
        
        switch ($choice) {
            "1" { Do-Install | Out-Null }
            "2" { Do-Update | Out-Null }
            "3" { Do-Repair }
            "4" { Do-Validate }
            "5" { Do-Backup }
            "6" { Do-ResetPassword | Out-Null }
            "7" { Do-Build }
            "8" { Do-Diagnostics }
            "9" { Do-Uninstall }
            "L" { Do-InstallMinimal | Out-Null }
            "l" { Do-InstallMinimal | Out-Null }
            "C" { Do-ConfigureSSL }
            "c" { Do-ConfigureSSL }
            "T" { Do-ToggleProtocol }
            "t" { Do-ToggleProtocol }
            "M" { Do-MigrateDatabase }
            "m" { Do-MigrateDatabase }
            "S" { Configure-Paths }
            "s" { Configure-Paths }
            "P" {
                Print-Header
                Test-ManagementCapabilities | Out-Null
                $managementChoice = Read-Host "Choose: 1=repair permissions, 2=set KEY=VALUE, Enter=back"
                if ($managementChoice -eq "1") {
                    Repair-ManagementPermissions
                } elseif ($managementChoice -eq "2") {
                    $script:MANAGED_CONFIG_CHANGES = @(Read-Host "KEY=VALUE (repeat manually via comma-separated values)" -ErrorAction SilentlyContinue)
                    $script:MANAGED_CONFIG_CHANGES = @($script:MANAGED_CONFIG_CHANGES -split "," | ForEach-Object { $_.Trim() } | Where-Object { $_ })
                    Set-ManagedConfiguration | Out-Null
                }
                Press-Enter
            }
            "p" {
                Print-Header
                Test-ManagementCapabilities | Out-Null
                Press-Enter
            }
            "0" {
                Write-Host ""
                Print-Info "Goodbye!"
                exit 0
            }
            default {
                Print-Warning "Invalid option"
                Start-Sleep -Seconds 1
            }
        }
    }
}

# Run
Main
