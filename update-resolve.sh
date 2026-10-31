#!/bin/bash
# update-resolve.sh — Automated DaVinci Resolve updater for Arch Linux and macOS
# Checks for updates, downloads via Blackmagic API, then builds via makepkg
# (Arch Linux) or installs the bundled .pkg (macOS). The OS is detected automatically.
#
# Usage: ./update-resolve.sh [--force] [--check-only] [--skip-install] [--reconfigure]
#
# Dependencies (Arch Linux): curl, jq, makepkg, pacman, git, updpkgsums (pacman-contrib)
# Dependencies (macOS): curl, jq (built into macOS 15+, else `brew install jq`),
#                       unzip, hdiutil/diskutil, installer (built in)
#
# macOS ships bash 3.2: everything that runs there must avoid mapfile and
# associative arrays. Those are fine inside the Linux-only functions.
#
# On first run, you'll be prompted for registration info (required by
# Blackmagic's download API). Your info is saved locally in a config
# file and reused on subsequent runs.

set -euo pipefail

# Version info
SCRIPT_VERSION="2026.10.2"
RESOLVE_TESTED="21.1.2-1"

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${SCRIPT_DIR}/build"
CONFIG_FILE="${SCRIPT_DIR}/.config"
PRODUCT="davinci-resolve"  # Change to "davinci-resolve-studio" for Studio edition
APP_PATH="/Applications/DaVinci Resolve/DaVinci Resolve.app"  # macOS only

# Platform: Blackmagic's API serves both from the same endpoints, keyed by these names
case "$(uname -s)" in
    Darwin) PLATFORM="mac";   ZIP_SUFFIX="Mac";   REFER_PLATFORM="Mac%20OS%20X" ;;
    *)      PLATFORM="linux"; ZIP_SUFFIX="Linux"; REFER_PLATFORM="Linux" ;;
esac

# Linux install route: Arch builds the AUR package; every other distro runs Blackmagic's
# own installer, after installing the dependency list that installer itself checks for
# (apt: Debian/Ubuntu/Mint, dnf/yum: RHEL/CentOS/Rocky/Fedora, zypper: openSUSE).
# /etc/os-release decides first: a second package manager (Debian ships `pacman`,
# openSUSE ships `dnf`) must not pull a distro onto the wrong route.
LINUX_FAMILY=""
if [[ "$PLATFORM" == "linux" ]]; then
    os_ids=$( (. /etc/os-release 2>/dev/null && echo " ${ID:-} ${ID_LIKE:-} ") || true)
    case "$os_ids" in
        *" arch "*)                                    LINUX_FAMILY="arch" ;;
        *" debian "*|*" ubuntu "*)                     LINUX_FAMILY="deb" ;;
        *" suse "*|*" opensuse "*|*opensuse-*)         LINUX_FAMILY="suse" ;;
        *" fedora "*|*" rhel "*|*" centos "*)          LINUX_FAMILY="rpm" ;;
    esac
    unset os_ids
fi
if [[ "$PLATFORM" == "linux" && -z "$LINUX_FAMILY" ]]; then
    if command -v pacman &>/dev/null; then LINUX_FAMILY="arch"
    elif command -v apt-get &>/dev/null; then LINUX_FAMILY="deb"
    elif command -v dnf &>/dev/null || command -v yum &>/dev/null; then LINUX_FAMILY="rpm"
    elif command -v zypper &>/dev/null; then LINUX_FAMILY="suse"
    else LINUX_FAMILY="other"
    fi
fi

# Blackmagic API endpoints
API_BASE="https://www.blackmagicdesign.com/api"

# This is a generic product/page identifier for the DaVinci Resolve download page.
# It is NOT user-specific. Source: Blackmagic's website download page URL structure.
# Also used in other open-source downloaders (e.g., Kimiblock/resolve-download).
REFER_ID="77ef91f67a9e411bbbe299e595b4cfcc"

# Shared curl options
if [[ "$PLATFORM" == "mac" ]]; then
    UA="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/133.0.0.0 Safari/537.36"
else
    UA="Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/133.0.0.0 Safari/537.36"
fi

# Static Google Analytics cookies to make requests look like normal browser traffic.
# These are NOT tied to any real user session — they're generic values used to avoid
# potential bot detection by Blackmagic's API.
COOKIES="_ga=GA1.2.1849503966.1518103294; _gid=GA1.2.953840595.1518103294"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()  { echo -e "${BLUE}[resolve-update]${NC} $*"; }
ok()   { echo -e "${GREEN}[✓]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[✗]${NC} $*" >&2; }

# Parse arguments
FORCE=false
CHECK_ONLY=false
SKIP_INSTALL=false
RECONFIGURE=false
TIMER=false
for arg in "$@"; do
    case $arg in
        --force) FORCE=true ;;
        --check-only) CHECK_ONLY=true ;;
        --skip-install) SKIP_INSTALL=true ;;
        --reconfigure) RECONFIGURE=true ;;
        --timer) TIMER=true ;;
        -h|--help)
            echo "Usage: $0 [--force] [--check-only] [--skip-install] [--reconfigure]"
            echo "  --force        Update even if already on latest version"
            echo "  --check-only   Just check for updates, don't download or install"
            echo "  --skip-install Download and build but don't install"
            echo "  --reconfigure  Re-enter registration info"
            echo "  --timer        Unattended check, run by the systemd timer (Linux; see README)"
            exit 0
            ;;
        *) err "Unknown argument: $arg"; exit 1 ;;
    esac
done

# --- Configuration Management ---

prompt_config() {
    echo ""
    echo -e "${BLUE}╔══════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║  First-time Setup: Registration Info                ║${NC}"
    echo -e "${BLUE}╠══════════════════════════════════════════════════════╣${NC}"
    echo -e "${BLUE}║  Blackmagic requires registration to download.      ║${NC}"
    echo -e "${BLUE}║  This is the same info you'd enter on their site.   ║${NC}"
    echo -e "${BLUE}║  All fields are currently required to register.     ║${NC}"
    echo -e "${BLUE}║  It's saved locally and never shared elsewhere.     ║${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════════════════════╝${NC}"
    echo ""

    read -rp "First name: " REG_FIRSTNAME
    read -rp "Last name: " REG_LASTNAME
    read -rp "Email: " REG_EMAIL
    read -rp "Phone (digits only): " REG_PHONE
    read -rp "Country code (e.g., us, uk, de): " REG_COUNTRY
    read -rp "State/Province: " REG_STATE
    read -rp "City: " REG_CITY
    read -rp "Street address: " REG_STREET

    # Validate required fields
    if [[ -z "$REG_FIRSTNAME" || -z "$REG_LASTNAME" || -z "$REG_EMAIL" || -z "$REG_PHONE" || -z "$REG_COUNTRY" || -z "$REG_STATE" || -z "$REG_CITY" || -z "$REG_STREET" ]]; then
        err "All fields are required"
        exit 1
    fi

    echo ""
    ask_cleanup_zip
    [[ "$PLATFORM" != "linux" ]] || ask_check_interval
    [[ "$PLATFORM" != "mac" ]] || ask_homebrew

    # Save config (values are stored verbatim, not as shell code)
    {
        echo "# update-resolve configuration (auto-generated)"
        echo "# Re-run with --reconfigure to change these values"
        printf 'firstname=%s\n' "$REG_FIRSTNAME"
        printf 'lastname=%s\n' "$REG_LASTNAME"
        printf 'email=%s\n' "$REG_EMAIL"
        printf 'phone=%s\n' "$REG_PHONE"
        printf 'country=%s\n' "$REG_COUNTRY"
        printf 'state=%s\n' "$REG_STATE"
        printf 'city=%s\n' "$REG_CITY"
        printf 'street=%s\n' "$REG_STREET"
        printf 'cleanup_zip=%s\n' "$CLEANUP_ZIP"
        [[ "$PLATFORM" != "linux" ]] || printf 'check_interval=%s\n' "$CHECK_INTERVAL"
        [[ "$PLATFORM" != "mac" ]] || printf 'homebrew=%s\n' "$USE_HOMEBREW"
    } > "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE"
    ok "Configuration saved to ${CONFIG_FILE}"
    [[ "$PLATFORM" != "linux" ]] || setup_timer "$CHECK_INTERVAL"
    echo ""
}

ask_homebrew() {
    local answer=""
    if ! command -v brew &>/dev/null; then
        USE_HOMEBREW="no"
        return 0
    fi
    if [[ -t 0 ]]; then
        echo "Homebrew can install DaVinci Resolve as a cask, so it updates with \`brew upgrade\` (and apps like Updatest)."
        read -rp "Install and update DaVinci Resolve through Homebrew? [Y/n]: " answer || true
    else
        answer="n"
    fi
    case "$answer" in
        [nN]*) USE_HOMEBREW="no" ;;
        *)     USE_HOMEBREW="yes" ;;
    esac
}

ask_check_interval() {
    local answer=""
    # No terminal (the timer itself, cron): never create timers unattended
    if [[ -t 0 ]]; then
        read -rp "Check for updates automatically with a systemd timer? [d]aily, [w]eekly, [m]onthly or [n]ever [w]: " answer || true
    else
        answer="n"
    fi
    case "$answer" in
        [dD]*) CHECK_INTERVAL="daily" ;;
        [mM]*) CHECK_INTERVAL="monthly" ;;
        [nN]*) CHECK_INTERVAL="never" ;;
        *)     CHECK_INTERVAL="weekly" ;;
    esac
}

ask_cleanup_zip() {
    local answer
    # `|| true`: with no terminal (cron), read hits EOF and the default applies instead of set -e exiting
    read -rp "Delete the downloaded installer zip from build/ after a successful update? [Y/n]: " answer || true
    case "$answer" in
        [nN]*) CLEANUP_ZIP="no" ;;
        *)     CLEANUP_ZIP="yes" ;;
    esac
}

# Remove the installer zip once the update succeeded, if the user opted in
cleanup_zip() {
    local zip_path="${BUILD_DIR}/DaVinci_Resolve_${1}_${ZIP_SUFFIX}.zip"
    if [[ "$CLEANUP_ZIP" == "yes" && -f "$zip_path" ]]; then
        rm -f "$zip_path"
        ok "Removed $(basename "$zip_path") (cleanup_zip=yes in ${CONFIG_FILE})"
    fi
}

load_config() {
    if [[ "$RECONFIGURE" == "true" || ! -f "$CONFIG_FILE" ]]; then
        if [[ ! -t 0 ]]; then
            err "Registration setup needs a terminal. Run ./update-resolve.sh once interactively first."
            exit 1
        fi
        prompt_config
    fi

    # Read config safely — no shell evaluation, just plain key=value parsing
    _cfg() { grep "^$1=" "$CONFIG_FILE" | cut -d= -f2- || true; }

    # Configs written before cleanup_zip existed: ask once and append, no full re-setup
    CLEANUP_ZIP=$(_cfg cleanup_zip)
    if [[ -z "$CLEANUP_ZIP" ]]; then
        ask_cleanup_zip
        printf 'cleanup_zip=%s\n' "$CLEANUP_ZIP" >> "$CONFIG_FILE"
        ok "Saved cleanup preference to ${CONFIG_FILE}"
    fi
    USE_HOMEBREW=$(_cfg homebrew)
    if [[ "$PLATFORM" == "mac" && -z "$USE_HOMEBREW" ]]; then
        ask_homebrew
        printf 'homebrew=%s\n' "$USE_HOMEBREW" >> "$CONFIG_FILE"
        ok "Saved Homebrew preference to ${CONFIG_FILE}"
    fi
    CHECK_INTERVAL=$(_cfg check_interval)
    if [[ "$PLATFORM" == "linux" && -z "$CHECK_INTERVAL" ]]; then
        ask_check_interval
        printf 'check_interval=%s\n' "$CHECK_INTERVAL" >> "$CONFIG_FILE"
        ok "Saved update check preference to ${CONFIG_FILE}"
        # "never" here (often the no-terminal default) must not remove a timer; only
        # --reconfigure, which asks every question, may do that
        [[ "$CHECK_INTERVAL" == "never" ]] || setup_timer "$CHECK_INTERVAL"
    fi
    local cfg_firstname cfg_lastname cfg_email cfg_phone cfg_country cfg_state cfg_city cfg_street
    cfg_firstname=$(_cfg firstname)
    cfg_lastname=$(_cfg lastname)
    cfg_email=$(_cfg email)
    cfg_phone=$(_cfg phone)
    cfg_country=$(_cfg country)
    cfg_state=$(_cfg state)
    cfg_city=$(_cfg city)
    cfg_street=$(_cfg street)

    # Build the JSON registration payload (jq handles escaping)
    REG_DATA=$(jq -n \
        --arg fn "$cfg_firstname" \
        --arg ln "$cfg_lastname" \
        --arg em "$cfg_email" \
        --arg ph "$cfg_phone" \
        --arg co "$cfg_country" \
        --arg st "$cfg_state" \
        --arg ci "$cfg_city" \
        --arg sr "$cfg_street" \
        '{firstname:$fn, lastname:$ln, email:$em, phone:$ph, country:$co, state:$st, city:$ci, street:$sr, product:"DaVinci Resolve"}')
}

# --- Dependency Management ---

# Runtime dependencies, read live from the AUR package so this list can't drift
# from the PKGBUILD that actually gets built. (A hardcoded copy here went stale
# and kept installing gtk2, libpng12, qt5-webengine and qt5-websockets from the
# AUR after the PKGBUILD had dropped them.)
get_resolve_deps() {
    curl -fsS "https://aur.archlinux.org/rpc/v5/info?arg[]=${PRODUCT}" \
        | jq -r '.results[0].Depends // empty | .[]'
}

install_dependencies() {
    log "Checking runtime dependencies..."

    local resolve_deps=()
    mapfile -t resolve_deps < <(get_resolve_deps)
    if [[ ${#resolve_deps[@]} -eq 0 ]]; then
        err "Could not read ${PRODUCT} dependencies from the AUR (network?)"
        return 1
    fi

    local missing_repo=()
    local missing_aur=()

    for pkg in "${resolve_deps[@]}"; do
        # pacman -T and -Sp resolve virtual packages (opencl-driver, java-runtime,
        # tbb); -Q and -Si don't, which sent those to the AUR helper by mistake.
        if pacman -T "$pkg" &>/dev/null; then
            continue
        fi

        # Check if available in official repos
        if pacman -Sp "$pkg" </dev/null &>/dev/null; then
            missing_repo+=("$pkg")
        else
            missing_aur+=("$pkg")
        fi
    done

    # Install official repo packages
    if [[ ${#missing_repo[@]} -gt 0 ]]; then
        log "Installing from official repos: ${missing_repo[*]}"
        # yes "" auto-selects the default when pacman prompts for a provider choice.
        # When pacman finishes it closes stdin, causing yes to exit 141 (SIGPIPE).
        # With pipefail that would kill the script, so we check pacman's exit code directly.
        yes "" | sudo pacman -S --needed --noconfirm "${missing_repo[@]}" || [[ ${PIPESTATUS[1]} -eq 0 ]]
        ok "Repo dependencies installed"
    fi

    # Install AUR packages
    if [[ ${#missing_aur[@]} -gt 0 ]]; then
        local aur_helper=""
        if command -v yay &>/dev/null; then
            aur_helper="yay"
        elif command -v paru &>/dev/null; then
            aur_helper="paru"
        fi

        if [[ -n "$aur_helper" ]]; then
            log "Installing from AUR via ${aur_helper}: ${missing_aur[*]}"
            yes "" | "$aur_helper" -S --needed --noconfirm "${missing_aur[@]}" || [[ ${PIPESTATUS[1]} -eq 0 ]]
            ok "AUR dependencies installed"
        else
            err "The following packages are only available in the AUR: ${missing_aur[*]}"
            err "Install an AUR helper first: sudo pacman -S --needed git base-devel && git clone https://aur.archlinux.org/yay.git && cd yay && makepkg -si"
            return 1
        fi
    fi

    if [[ ${#missing_repo[@]} -eq 0 && ${#missing_aur[@]} -eq 0 ]]; then
        ok "All dependencies already installed"
    fi
}

# --- Core Functions ---

# Step 1: Get installed version
get_installed_version() {
    if [[ "$PLATFORM" == "mac" ]]; then
        defaults read "${APP_PATH}/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo "none"
    elif [[ "$LINUX_FAMILY" == "arch" ]]; then
        pacman -Q "${PRODUCT}" 2>/dev/null | awk '{print $2}' | cut -d- -f1 || echo "none"
    else
        # Blackmagic's installer registers no package; its Welcome.txt opens with
        # "You are about to install DaVinci Resolve [Studio] 21.1.2."
        local v
        v=$(grep -o -m1 'DaVinci Resolve \(Studio \)\?[0-9][0-9.]*[0-9]' /opt/resolve/docs/Welcome.txt 2>/dev/null \
            | awk '{print $NF}') || true
        # Match get_latest_version's Linux format, which drops a trailing .0
        [[ ! "$v" =~ ^[0-9]+\.[0-9]+\.0$ ]] || v=${v%.0}
        echo "${v:-none}"
    fi
}

# Step 2: Get latest version from Blackmagic API
get_latest_version() {
    local response
    response=$(curl -s "${API_BASE}/support/latest-stable-version/${PRODUCT}/${PLATFORM}")

    if [[ -z "$response" || "$response" == *"error"* ]]; then
        err "Failed to query Blackmagic API for latest version"
        return 1
    fi

    local major minor release download_id
    major=$(echo "$response" | jq -r ".${PLATFORM}.major")
    minor=$(echo "$response" | jq -r ".${PLATFORM}.minor")
    release=$(echo "$response" | jq -r ".${PLATFORM}.releaseNum")
    download_id=$(echo "$response" | jq -r ".${PLATFORM}.downloadId")

    # pacman/AUR versions drop a trailing .0; the macOS app bundle keeps it (21.0.0)
    if [[ "$release" == "0" && "$PLATFORM" == "linux" ]]; then
        echo "${major}.${minor}|${download_id}"
    else
        echo "${major}.${minor}.${release}|${download_id}"
    fi
}

# Step 3: Download the zip
download_resolve() {
    local download_id="$1"
    local version="$2"
    local zip_name="DaVinci_Resolve_${version}_${ZIP_SUFFIX}.zip"
    local zip_path="${BUILD_DIR}/${zip_name}"

    if [[ -f "$zip_path" && "$FORCE" != "true" ]]; then
        ok "Zip already downloaded: ${zip_name}"
        return 0
    fi

    log "Requesting download URL from Blackmagic..."
    local download_url
    download_url=$(curl -s -X POST "${API_BASE}/register/us/download/${download_id}" \
        -H "Host: www.blackmagicdesign.com" \
        -H "Accept: application/json, text/plain, */*" \
        -H "Origin: https://www.blackmagicdesign.com" \
        -H "User-Agent: ${UA}" \
        -H "Content-Type: application/json;charset=UTF-8" \
        -H "Referer: https://www.blackmagicdesign.com/support/download/${REFER_ID}/${REFER_PLATFORM}" \
        -b "${COOKIES}" \
        -d "${REG_DATA}")

    if [[ -z "$download_url" || "$download_url" == *"Error"* || "$download_url" == *"Bad Request"* ]]; then
        err "Failed to get download URL: ${download_url}"
        return 1
    fi

    log "Downloading ${zip_name} (~3GB)..."

    # Download to .part so an interrupted run isn't mistaken for a finished zip next time
    if ! curl -fL --progress-bar \
        -H "User-Agent: ${UA}" \
        -o "${zip_path}.part" \
        "$download_url"; then
        err "Download failed"
        return 1
    fi
    mv "${zip_path}.part" "$zip_path"

    local size
    size=$(du -h "$zip_path" | cut -f1)
    ok "Downloaded: ${zip_name} (${size})"
}

# --- macOS through Homebrew (homebrew=yes in .config) ---

HOMEBREW_TAP="toineenzo/resolve"
HOMEBREW_TAP_URL="https://github.com/toineenzo/Davinci-Resolve-Updater"
HOMEBREW_CASK="${HOMEBREW_TAP}/davinci-resolve"

# Tap this repo and give its download strategy the registration info (it reads the
# .config at the tap's root). Safe to repeat: it also refreshes that copy after --reconfigure.
setup_homebrew_tap() {
    if ! brew tap | grep -qx "$HOMEBREW_TAP"; then
        log "Adding Homebrew tap ${HOMEBREW_TAP}..."
        brew tap "$HOMEBREW_TAP" "$HOMEBREW_TAP_URL"
    fi
    # Homebrew 7+ only loads casks from trusted taps; older versions have no `brew trust`
    brew trust "$HOMEBREW_TAP" &>/dev/null || true

    local tap_dir
    tap_dir=$(brew --repo "$HOMEBREW_TAP")
    if [[ "$(cd "$tap_dir" && pwd -P)" != "$(cd "$SCRIPT_DIR" && pwd -P)" ]]; then
        install -m 600 "$CONFIG_FILE" "${tap_dir}/.config"
    fi
}

# Install or upgrade the cask. Returns 0 when Resolve is now on the cask's version.
update_via_homebrew() {
    setup_homebrew_tap
    if brew list --cask "$HOMEBREW_CASK" &>/dev/null; then
        if [[ "$FORCE" == "true" ]]; then
            log "Reinstalling the ${HOMEBREW_CASK} cask (needs your password)..."
            brew reinstall --cask "$HOMEBREW_CASK"
        else
            log "Upgrading the ${HOMEBREW_CASK} cask (needs your password)..."
            brew upgrade --cask "$HOMEBREW_CASK"
        fi
    else
        # The cask is bumped up to 6 hours after a release; if Resolve is already newer
        # (installed by the script route), installing the cask now would downgrade it
        local cask_version installed
        cask_version=$(brew info --cask --json=v2 "$HOMEBREW_CASK" | jq -r '.casks[0].version')
        installed=$(get_installed_version)
        if [[ "$installed" != "none" && "$(printf '%s\n%s\n' "$cask_version" "$installed" | sort -V | tail -1)" != "$cask_version" ]]; then
            warn "The cask is on ${cask_version}, older than the installed ${installed}; not installing it now (it would downgrade). Run again once it has caught up."
            return 0
        fi
        log "Installing the ${HOMEBREW_CASK} cask (downloads ~4GB, needs your password)..."
        brew install --cask "$HOMEBREW_CASK"
    fi

    # Homebrew keeps the downloaded zip in its cache; honour cleanup_zip for it too
    # (found by name: `brew --cache --cask` resolves the URL, i.e. POSTs the registration)
    if [[ "$CLEANUP_ZIP" == "yes" ]]; then
        local cached removed=false
        for cached in "$(brew --cache)"/downloads/*--DaVinci_Resolve_*_Mac.zip; do
            [[ -f "$cached" ]] || continue
            rm -f "$cached"
            removed=true
        done
        [[ "$removed" == "false" ]] || ok "Removed Homebrew's cached download (cleanup_zip=yes in ${CONFIG_FILE})"
    fi
}

# macOS: zip -> .dmg -> .pkg -> installer
install_mac_pkg() {
    local version="$1"
    local zip_path="${BUILD_DIR}/DaVinci_Resolve_${version}_Mac.zip"
    local extract_dir="${BUILD_DIR}/extract"
    local mount_dir="${BUILD_DIR}/mnt"

    log "Extracting $(basename "$zip_path")..."
    rm -rf "$extract_dir"
    mkdir -p "$extract_dir"
    unzip -q "$zip_path" -d "$extract_dir"

    local dmg
    dmg=$(find "$extract_dir" -name '*.dmg' -not -path '*/__MACOSX/*' | head -1)
    if [[ -z "$dmg" ]]; then
        err "No .dmg found in $(basename "$zip_path")"
        return 1
    fi

    log "Mounting $(basename "$dmg")..."
    mkdir -p "$mount_dir"
    # `diskutil image` replaces `hdiutil attach` (deprecated on newer macOS); older macOS lacks it
    if diskutil image &>/dev/null; then
        diskutil image attach --readOnly --nobrowse --mountPoint "$mount_dir" "$dmg" > /dev/null
    else
        hdiutil attach "$dmg" -nobrowse -readonly -mountpoint "$mount_dir" > /dev/null
    fi
    trap 'hdiutil detach "'"$mount_dir"'" -quiet 2>/dev/null || true' EXIT

    local pkg
    pkg=$(find "$mount_dir" -maxdepth 2 -name '*.pkg' | head -1)
    if [[ -z "$pkg" ]]; then
        err "No .pkg installer found in $(basename "$dmg")"
        return 1
    fi

    if pgrep -xq "Resolve"; then
        warn "DaVinci Resolve is running — quit it before the installer continues"
        read -rp "Press Enter once Resolve is closed..."
    fi

    log "Installing $(basename "$pkg") (needs your password)..."
    # -verboseR emits machine-readable "installer:%NN.N" / "installer:PHASE:..." lines;
    # turn them into one live status line instead of minutes of silence
    local pct=0 phase="Starting"
    sudo installer -pkg "$pkg" -target / -verboseR | while IFS= read -r line; do
        case $line in
            installer:%*) pct=${line#installer:%}; pct=${pct%%.*} ;;
            installer:PHASE:*) phase=${line#installer:PHASE:} ;;
            *) continue ;;
        esac
        printf '\r\033[K    %3d%%  %s' "$pct" "$phase"
    done
    echo ""

    hdiutil detach "$mount_dir" -quiet
    trap - EXIT
    rm -rf "$extract_dir"
    ok "Installed $(basename "$pkg")"
}

# --- Other Linux distros: Blackmagic's own installer ---

# Blackmagic's AppRun checks a per-distro package list (name-minversion lines inside
# check_ubuntu_package_deps / check_centos_package_deps / check_suse_package_deps).
# Read that list from the installer being installed, so it can't drift.
read_apprun_packages() {
    sed -n "/^function $2()/,/^}/p" "$1" \
        | grep -E '^[[:space:]]+[A-Za-z0-9._+-]+-[0-9.]+$' \
        | sed -E 's/^[[:space:]]+//; s/-[0-9.]+$//'
}

install_run_dependencies() {
    local apprun="$1" pkgs=() p
    log "Installing DaVinci Resolve's dependencies..."
    case "$LINUX_FAMILY" in
        deb)
            # One broken third-party repo shouldn't stop the update; the cached lists do
            sudo apt-get update || warn "apt-get update failed; using the cached package lists"
            # libgl1: the installer itself needs libGL.so.1, which Blackmagic's list leaves out
            pkgs=(libgl1)
            # A real package has an install candidate; a virtual name shows "(none)"
            _apt_candidate() { apt-cache policy "$1" 2>/dev/null | awk '/Candidate:/ {print $2}'; }
            local cand
            while read -r p; do
                # Ubuntu 24.04+ / Debian 13 renamed some libraries with a t64 suffix, leaving
                # the old name as a virtual package
                cand=$(_apt_candidate "$p")
                if [[ -n "$cand" && "$cand" != "(none)" ]]; then
                    pkgs+=("$p")
                elif cand=$(_apt_candidate "${p}t64") && [[ -n "$cand" && "$cand" != "(none)" ]]; then
                    pkgs+=("${p}t64")
                else
                    warn "No package ${p} (or ${p}t64) on this release, skipping"
                fi
            done < <(read_apprun_packages "$apprun" check_ubuntu_package_deps)
            sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "${pkgs[@]}"
            ;;
        rpm)
            mapfile -t pkgs < <(read_apprun_packages "$apprun" check_centos_package_deps)
            # Not in Blackmagic's CentOS 7 list, but Resolve links libcrypt.so.1 (moved out
            # of glibc after CentOS 7) and libOpenCL.so.1 (the OpenCL loader)
            pkgs+=(libxcrypt-compat ocl-icd)
            # The list is written for CentOS 7; skip names a newer release doesn't ship
            if command -v dnf &>/dev/null; then
                if dnf --version 2>/dev/null | grep -q dnf5; then
                    sudo dnf install -y --skip-unavailable "${pkgs[@]}"
                else
                    sudo dnf install -y --setopt=strict=0 "${pkgs[@]}"
                fi
            else
                sudo yum install -y --skip-broken "${pkgs[@]}"
            fi
            ;;
        suse)
            mapfile -t pkgs < <(read_apprun_packages "$apprun" check_suse_package_deps)
            # Not in Blackmagic's list, but Resolve links libOpenCL.so.1 (the OpenCL loader)
            pkgs+=(libOpenCL1)
            sudo zypper --non-interactive install --no-recommends "${pkgs[@]}"
            ;;
        *)
            warn "Unknown package manager: install DaVinci Resolve's dependencies yourself if it won't start"
            ;;
    esac
}

# Zip -> .run (an AppImage) -> unpacked -> Blackmagic's installer
install_linux_run() {
    local version="$1"
    local zip_path="${BUILD_DIR}/DaVinci_Resolve_${version}_Linux.zip"
    local extract_dir="${BUILD_DIR}/extract"

    log "Extracting $(basename "$zip_path")..."
    rm -rf "$extract_dir"
    mkdir -p "$extract_dir"
    # Don't leave ~13GB of unpacked installer behind if any step below fails
    trap 'rm -rf "'"$extract_dir"'"' EXIT
    unzip -q "$zip_path" -d "$extract_dir"

    local run
    run=$(find "$extract_dir" -maxdepth 1 -name '*.run' | head -1)
    if [[ -z "$run" ]]; then
        err "No .run installer found in $(basename "$zip_path")"
        return 1
    fi

    # Unpack the AppImage (as the AUR PKGBUILD does) instead of running it, so FUSE isn't needed
    log "Unpacking $(basename "$run") (about 9GB)..."
    chmod u+x "$run"
    (cd "$extract_dir" && "$run" --appimage-extract > /dev/null)
    rm -f "$run"
    local apprun="${extract_dir}/squashfs-root/AppRun"
    if [[ ! -x "$apprun" ]]; then
        err "Unpacking $(basename "$run") did not produce AppRun"
        return 1
    fi

    install_run_dependencies "$apprun"

    log "Running Blackmagic's installer (needs your password)..."
    # SKIP_PACKAGE_CHECK: its list was installed above, and its own check doesn't know the
    # t64 package names of Ubuntu 24.04+ / Debian 13, so it would refuse to install there.
    # -i: no GUI, -y: don't ask, -a: allow running as root (it runs under sudo)
    sudo env SKIP_PACKAGE_CHECK=1 "$apprun" -i -y -a
    rm -rf "$extract_dir"
    trap - EXIT

    # AppRun exits 0 even when its installer fails, so check what actually got installed
    local now
    now=$(get_installed_version)
    if [[ "$now" != "$version" ]]; then
        err "Installer finished, but /opt/resolve reports version ${now} instead of ${version}"
        return 1
    fi
    ok "Installed DaVinci Resolve ${version} to /opt/resolve"
}

# Step 4: Fetch and update PKGBUILD
setup_pkgbuild() {
    local version="$1"

    log "Fetching latest PKGBUILD from AUR..."
    pushd "$BUILD_DIR" > /dev/null

    # Clean previous build artifacts but keep downloaded zips
    find . -maxdepth 1 ! -name "*.zip" ! -name "." -exec rm -rf {} + 2>/dev/null || true

    # Fetch PKGBUILD from AUR
    git clone --depth 1 "https://aur.archlinux.org/${PRODUCT}.git" _aur_pkg 2>/dev/null
    cp _aur_pkg/* . 2>/dev/null || true
    rm -rf _aur_pkg

    # Verify PKGBUILD exists
    if [[ ! -f "PKGBUILD" ]]; then
        err "Failed to fetch PKGBUILD from AUR"
        popd > /dev/null
        return 1
    fi

    # Defensive patch: AUR's prepare() hardcodes the exact glib version suffix
    # bundled inside the Resolve installer when stripping those bundled copies
    # before symlinking to the system libs. Blackmagic changes that bundled
    # version across Resolve releases (glib 2.68 -> 2.82 going from 20.x to
    # 21.1), so the literal filename goes stale and prepare() aborts on
    # `rm: cannot remove ...: No such file or directory`. Replacing the
    # hardcoded suffixes with globs keeps the same targets, version-agnostic.
    # Self-retiring: this is an exact literal match, not a pattern. The moment
    # the AUR maintainer edits this block at all, the old text disappears and
    # this substitution silently no-ops, so it is safe to leave in permanently.
    # NOTE: the pattern MUST stay quoted in the substitution below. Unquoted,
    # bash treats the backslash line-continuations in it as escapes and the
    # replacement silently does nothing while still reporting a match.
    local broken_rm_block='rm squashfs-root/libs/libglib-2.0.so.0{,.6800.4} \
     squashfs-root/libs/libgio-2.0.so.0{,.6800.4} \
     squashfs-root/libs/libgmodule-2.0.so.0{,.6800.4} \
     squashfs-root/libs/libgobject-2.0.so.0{,.6800.4} \
     squashfs-root/libs/libc++.so.1{,.0} \
     squashfs-root/libs/libc++abi.so.1{,.0}'
    local fixed_rm_block='rm -f squashfs-root/libs/libglib-2.0.so.0* \
     squashfs-root/libs/libgio-2.0.so.0* \
     squashfs-root/libs/libgmodule-2.0.so.0* \
     squashfs-root/libs/libgobject-2.0.so.0* \
     squashfs-root/libs/libc++.so.1* \
     squashfs-root/libs/libc++abi.so.1*'
    local pkgbuild_content
    pkgbuild_content=$(<PKGBUILD)
    if [[ "$pkgbuild_content" == *"$broken_rm_block"* ]]; then
        warn "Patching known-fragile AUR prepare() step (hardcoded glib bundle version)"
        pkgbuild_content="${pkgbuild_content//"$broken_rm_block"/"$fixed_rm_block"}"
        if [[ "$pkgbuild_content" == *"$broken_rm_block"* ]]; then
            err "Defensive patch failed to apply — build would abort in prepare()"
            popd > /dev/null
            return 1
        fi
        printf '%s\n' "$pkgbuild_content" > PKGBUILD
        ok "Patched AUR prepare() glib strip step to be version-agnostic"
    else
        log "AUR PKGBUILD prepare() already changed upstream — skipping defensive patch"
    fi

    # Defensive patch: prepare() runs `patchelf --set-rpath` on every ELF file.
    # Resolve 21.1.2 started bundling CEF, whose chrome-sandbox has a note layout
    # patchelf can't rewrite ("cannot normalize PT_NOTE segment: non-contiguous
    # SHT_NOTE sections"), so prepare() aborts. chrome-sandbox only links libc
    # and libpthread, so the rpath does nothing for it and skipping it is safe.
    # Self-retiring the same way as the glib patch: exact literal match.
    local broken_find_line='done < <(find "squashfs-root" -type f -size -32M -print0)'
    local fixed_find_line='done < <(find "squashfs-root" -type f -size -32M ! -name chrome-sandbox -print0)'
    pkgbuild_content=$(<PKGBUILD)
    if [[ "$pkgbuild_content" == *"$broken_find_line"* ]]; then
        warn "Patching AUR prepare() to skip patchelf on chrome-sandbox"
        printf '%s\n' "${pkgbuild_content//"$broken_find_line"/"$fixed_find_line"}" > PKGBUILD
        ok "Patched AUR prepare() patchelf loop"
    else
        log "AUR PKGBUILD patchelf loop already changed upstream — skipping defensive patch"
    fi

    # Check if AUR PKGBUILD version matches what we're building
    local aur_version
    aur_version=$(grep '^pkgver=' PKGBUILD | cut -d= -f2)
    if [[ "$aur_version" != "$version" ]]; then
        warn "AUR PKGBUILD is for ${aur_version}, but latest is ${version}"
        warn "Updating pkgver in PKGBUILD to ${version}"
        sed -i "s/^pkgver=.*/pkgver=${version}/" PKGBUILD
        sed -i "s/^pkgrel=.*/pkgrel=1/" PKGBUILD
    fi

    # Verify the zip file is in the build directory
    local zip_name="DaVinci_Resolve_${version}_Linux.zip"
    if [[ ! -f "$zip_name" ]]; then
        err "Zip file not found: ${BUILD_DIR}/${zip_name}"
        popd > /dev/null
        return 1
    fi

    # Update sha256sums for every source file (pacman-contrib, installed at startup)
    log "Generating sha256sums..."
    local sums_output
    if ! sums_output=$(updpkgsums 2>&1); then
        err "updpkgsums failed to update the PKGBUILD checksums:"
        echo "$sums_output" >&2
        popd > /dev/null
        return 1
    fi
    ok "Updated sha256sums via updpkgsums"

    popd > /dev/null
}

# Step 5: Build and install
build_and_install() {
    log "Building package with makepkg (this takes a while)..."
    pushd "$BUILD_DIR" > /dev/null

    if [[ "$SKIP_INSTALL" == "true" ]]; then
        yes "" | makepkg -sf --noconfirm || [[ ${PIPESTATUS[1]} -eq 0 ]]
        ok "Package built (not installed due to --skip-install)"
    else
        yes "" | makepkg -sric --noconfirm || [[ ${PIPESTATUS[1]} -eq 0 ]]
        ok "Package built and installed!"
    fi

    popd > /dev/null
}

# Step 6: Warn about runtime support directories Resolve cannot create itself.
# /opt/resolve is root-owned 0755, so any support directory Resolve still needs
# to create at first launch fails, and the app exits with "Failed to create
# application support directories" before it can even write a log. Blackmagic
# adds to this set across releases (21.1 introduced Immersive/), so this only
# warns and prints the fix rather than acting, and deliberately treats its list
# as a floor rather than pretending to be complete.
check_runtime_dirs() {
    local resolve_dir="/opt/resolve"
    [[ -d "$resolve_dir" ]] || return 0

    local needed=("Immersive")
    local broken=() d
    for d in "${needed[@]}"; do
        if [[ ! -d "${resolve_dir}/${d}" || ! -w "${resolve_dir}/${d}" ]]; then
            broken+=("$d")
        fi
    done

    if [[ ${#broken[@]} -eq 0 ]]; then
        ok "Resolve support directories look OK"
        return 0
    fi

    echo ""
    warn "Resolve will likely fail to launch with 'Failed to create application support directories'"
    warn "Missing or not writable by $(id -un):"
    for d in "${broken[@]}"; do
        echo "      ${resolve_dir}/${d}"
    done
    echo ""
    echo "  Fix with:"
    for d in "${broken[@]}"; do
        echo "      sudo mkdir -p '${resolve_dir}/${d}' && sudo chown $(id -un):$(id -gn) '${resolve_dir}/${d}'"
    done
    echo ""
    local launcher="davinci-resolve"  # AUR package wrapper; Blackmagic's installer has none
    [[ "$LINUX_FAMILY" == "arch" ]] || launcher="/opt/resolve/bin/resolve"
    echo "  If it still fails, find the next one with:"
    echo "      strace -f -e trace=mkdir,mkdirat ${launcher} 2>&1 | grep -E 'EACCES|EPERM'"
    echo ""
}

# --- Automatic update checks (Linux, systemd user timer) ---
#
# The timer runs `update-resolve.sh --timer` daily/weekly/monthly. On Arch it builds the
# new package into a local pacman repo, so a normal `pacman -Syu` / `yay -Syu` (or a GUI
# updater) installs it. Other distros have no package to hand to their package manager
# (Blackmagic's installer registers none), so there the timer only notifies.

LOCAL_REPO_NAME="resolve-local"
# /var/lib, not /var/cache: cache cleaners may wipe /var/cache, and a missing repo
# directory makes every `pacman -Syu` fail
LOCAL_REPO_DIR="/var/lib/${LOCAL_REPO_NAME}"
SYSTEMD_USER_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"

# Desktop notification when possible; the text also lands in the journal
notify() {
    echo "$1: $2"
    command -v notify-send &>/dev/null && notify-send -a "DaVinci Resolve Updater" "$1" "$2" 2>/dev/null || true
}

write_timer_units() {
    local interval="$1"
    mkdir -p "$SYSTEMD_USER_DIR"
    cat > "${SYSTEMD_USER_DIR}/resolve-update.service" <<EOF
[Unit]
Description=Check for DaVinci Resolve updates

[Service]
Type=oneshot
ExecStart="${SCRIPT_DIR}/update-resolve.sh" --timer
Nice=10
IOSchedulingClass=idle
EOF
    cat > "${SYSTEMD_USER_DIR}/resolve-update.timer" <<EOF
[Unit]
Description=Check for DaVinci Resolve updates (${interval})

[Timer]
OnCalendar=${interval}
# Catch up on a check missed while the computer was off
Persistent=true
RandomizedDelaySec=1h

[Install]
WantedBy=timers.target
EOF
}

setup_timer() {
    local interval="$1" have_systemd=true
    command -v systemctl &>/dev/null && systemctl --user show-environment &>/dev/null || have_systemd=false

    if [[ "$interval" == "never" ]]; then
        if [[ -f "${SYSTEMD_USER_DIR}/resolve-update.timer" ]]; then
            [[ "$have_systemd" == "false" ]] || systemctl --user disable --now resolve-update.timer 2>/dev/null || true
            # Without a user session (e.g. over SSH) disable can't run, so remove its link too
            rm -f "${SYSTEMD_USER_DIR}/resolve-update."{service,timer} \
                  "${SYSTEMD_USER_DIR}/timers.target.wants/resolve-update.timer"
            [[ "$have_systemd" == "false" ]] || systemctl --user daemon-reload
            ok "Removed the automatic update check"
        fi
        return 0
    fi

    if [[ "$have_systemd" == "false" ]]; then
        warn "No systemd user session here; skipping the automatic update check"
        return 0
    fi

    [[ "$LINUX_FAMILY" != "arch" ]] || setup_local_repo
    write_timer_units "$interval"
    systemctl --user daemon-reload
    systemctl --user enable --now resolve-update.timer
    ok "Checking for updates ${interval} (systemctl --user list-timers resolve-update.timer)"
    if [[ "$LINUX_FAMILY" == "arch" ]]; then
        log "New versions are built in the background; install them with: sudo pacman -Syu"
    else
        log "You'll get a notification when an update is available"
    fi
}

# One-time (sudo): a directory you own for built packages, registered in pacman.conf.
# It starts as an empty but valid repo, so `pacman -Sy` works before the first build.
setup_local_repo() {
    local db="${LOCAL_REPO_DIR}/${LOCAL_REPO_NAME}.db.tar.gz"
    if [[ ! -d "$LOCAL_REPO_DIR" || ! -w "$LOCAL_REPO_DIR" ]]; then
        log "Creating local package repo ${LOCAL_REPO_DIR} (needs your password)..."
        sudo install -d -o "$(id -un)" -g "$(id -gn)" -m 755 "$LOCAL_REPO_DIR"
    fi
    if [[ ! -e "$db" ]]; then
        # Both databases, so `pacman -Sy` and `pacman -Fy` work before the first build
        local f
        for f in db files; do
            bsdtar -czf "${LOCAL_REPO_DIR}/${LOCAL_REPO_NAME}.${f}.tar.gz" -T /dev/null
            ln -sf "${LOCAL_REPO_NAME}.${f}.tar.gz" "${LOCAL_REPO_DIR}/${LOCAL_REPO_NAME}.${f}"
        done
    fi
    if ! grep -q "^\[${LOCAL_REPO_NAME}\]" /etc/pacman.conf; then
        log "Adding [${LOCAL_REPO_NAME}] to /etc/pacman.conf (needs your password)..."
        printf '\n# DaVinci Resolve builds from update-resolve.sh\n[%s]\nSigLevel = Optional TrustAll\nServer = file://%s\n' \
            "$LOCAL_REPO_NAME" "$LOCAL_REPO_DIR" | sudo tee -a /etc/pacman.conf > /dev/null
    fi
    ok "Local package repo ready: [${LOCAL_REPO_NAME}] in /etc/pacman.conf"
}

# Path of the built package for version $1, if the repo's database lists it. A package
# file without a database entry (an interrupted publish) doesn't count.
local_repo_package() {
    local db="${LOCAL_REPO_DIR}/${LOCAL_REPO_NAME}.db.tar.gz" entries entry file
    [[ -f "$db" ]] || return 1
    entries=$(bsdtar -tf "$db" 2>/dev/null) || return 1
    entry=$(grep -m1 -E "^${PRODUCT}-${1//./\\.}-[^/-]+/\$" <<< "$entries") || return 1
    file=$(bsdtar -xOf "$db" "${entry}desc" | awk 'f { print; exit } /^%FILENAME%$/ { f = 1 }')
    [[ -n "$file" && -f "${LOCAL_REPO_DIR}/${file}" ]] || return 1
    echo "${LOCAL_REPO_DIR}/${file}"
}

# Move the packages makepkg just built into the local repo; -R drops the old versions
publish_local_repo() {
    local pkgs=() p
    # --packagelist also names a -debug package that makepkg only builds when there are
    # symbols to split, so publish what actually exists, but insist on the main package
    while read -r p; do
        [[ -f "$p" ]] && pkgs+=("$p")
    done < <(cd "$BUILD_DIR" && makepkg --packagelist)
    if ! printf '%s\n' "${pkgs[@]##*/}" | grep -q "^${PRODUCT}-[0-9]"; then
        err "makepkg did not produce a ${PRODUCT} package in ${BUILD_DIR}"
        return 1
    fi
    mv -f "${pkgs[@]}" "$LOCAL_REPO_DIR/"
    (cd "$LOCAL_REPO_DIR" && repo-add -q -R "${LOCAL_REPO_NAME}.db.tar.gz" "${pkgs[@]##*/}")
    # The unpacked build tree is ~2x the package; the next run starts from scratch anyway
    rm -rf "${BUILD_DIR}/src" "${BUILD_DIR}/pkg"
    ok "Published to [${LOCAL_REPO_NAME}]: ${pkgs[*]##*/}"
}

# Dependencies of the PKGBUILD in BUILD_DIR that aren't installed (pacman -T lists them)
missing_build_deps() {
    (cd "$BUILD_DIR" && makepkg --printsrcinfo) \
        | sed -n -E 's/^\t(make|check)?depends = //p' | xargs -r pacman -T || true
}

# Unattended run from the systemd timer
run_timer() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        err "No ${CONFIG_FILE}; run update-resolve.sh once interactively first"
        exit 1
    fi
    # Report any failure as a notification, not only in the journal
    set -o errtrace
    trap 'notify "DaVinci Resolve update failed" "See: journalctl --user -u resolve-update"' ERR

    local installed latest_info latest download_id
    installed=$(get_installed_version)
    # Offline (e.g. just after boot): try again next time instead of reporting a failure
    if ! latest_info=$(get_latest_version 2>/dev/null); then
        log "Blackmagic API unreachable; skipping this check"
        exit 0
    fi
    latest=${latest_info%%|*}
    download_id=${latest_info#*|}
    if [[ "$installed" == "$latest" ]]; then
        log "Up to date (${installed})"
        exit 0
    fi

    if [[ "$LINUX_FAMILY" != "arch" ]]; then
        notify "DaVinci Resolve ${latest} is available" "Installed: ${installed}. Update with: ${SCRIPT_DIR}/update-resolve.sh"
        exit 0
    fi

    if local_repo_package "$latest" > /dev/null; then
        log "${latest} is already built in [${LOCAL_REPO_NAME}]; waiting for pacman -Syu"
        exit 0
    fi

    load_config
    mkdir -p "$BUILD_DIR"
    download_resolve "$download_id" "$latest"
    setup_pkgbuild "$latest"

    # `makepkg -s` would need sudo for missing dependencies, which a background run
    # can't give (e.g. `makepkg -sric` removed patchelf after the last interactive build)
    local missing
    missing=$(missing_build_deps)
    if [[ -n "$missing" ]]; then
        notify "DaVinci Resolve ${latest} needs packages" \
            "Missing: $(echo $missing). Run ${SCRIPT_DIR}/update-resolve.sh once to build and install it."
        exit 0
    fi

    SKIP_INSTALL=true
    build_and_install
    publish_local_repo
    cleanup_zip "$latest"
    notify "DaVinci Resolve ${latest} is ready" "Install it with: sudo pacman -Syu"
}

# --- Main ---

check_tools_mac() {
    for cmd in curl jq unzip hdiutil installer; do
        if ! command -v "$cmd" &>/dev/null; then
            err "Missing dependency: $cmd"
            [[ "$cmd" != "jq" ]] || err "Install it with: brew install jq"
            exit 1
        fi
    done
}

check_tools_linux() {
    # Install script dependencies if missing (command -> package that provides it)
    local -A tool_pkgs=([curl]=curl [jq]=jq [git]=git [updpkgsums]=pacman-contrib)
    local missing_tools=()
    for cmd in "${!tool_pkgs[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            missing_tools+=("${tool_pkgs[$cmd]}")
        fi
    done
    if [[ ${#missing_tools[@]} -gt 0 ]]; then
        log "Installing missing tools: ${missing_tools[*]}"
        sudo pacman -S --needed --noconfirm "${missing_tools[@]}"
    fi

    # Verify core tools are available (makepkg/pacman should always exist on Arch)
    for cmd in curl jq makepkg pacman git updpkgsums; do
        if ! command -v "$cmd" &>/dev/null; then
            err "Missing dependency: $cmd (could not auto-install)"
            exit 1
        fi
    done
}

check_tools_run() {
    local missing=() cmd
    for cmd in curl jq unzip; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    [[ ${#missing[@]} -gt 0 ]] || return 0

    log "Installing missing tools: ${missing[*]}"
    case "$LINUX_FAMILY" in
        deb)  sudo apt-get update && sudo apt-get install -y "${missing[@]}" ;;
        rpm)  if command -v dnf &>/dev/null; then sudo dnf install -y "${missing[@]}"
              else sudo yum install -y "${missing[@]}"; fi ;;
        suse) sudo zypper --non-interactive install "${missing[@]}" ;;
        *)    err "Missing dependency: ${missing[*]}. Install it and re-run."; exit 1 ;;
    esac
}

main() {
    echo ""
    echo -e "${BLUE}╔══════════════════════════════════════════╗${NC}"
    if [[ "$PLATFORM" == "mac" ]]; then
        echo -e "${BLUE}║    DaVinci Resolve Updater for macOS     ║${NC}"
    elif [[ "$LINUX_FAMILY" == "arch" ]]; then
        echo -e "${BLUE}║  DaVinci Resolve Updater for Arch Linux  ║${NC}"
    else
        echo -e "${BLUE}║    DaVinci Resolve Updater for Linux     ║${NC}"
    fi
    echo -e "${BLUE}╚══════════════════════════════════════════╝${NC}"
    echo ""

    if [[ "$PLATFORM" == "mac" ]]; then
        check_tools_mac
    elif [[ "$LINUX_FAMILY" == "arch" ]]; then
        check_tools_linux
    else
        check_tools_run
    fi

    # One run at a time on Linux: the timer and an interactive run share build/
    if [[ "$PLATFORM" == "linux" && "$CHECK_ONLY" != "true" ]] && command -v flock &>/dev/null; then
        exec 9> "${SCRIPT_DIR}/.lock"
        if ! flock -n 9; then
            [[ "$TIMER" != "true" ]] || { log "Another run is in progress; skipping this check"; exit 0; }
            err "Another update-resolve.sh run is in progress (perhaps the timer). Try again when it's done."
            exit 1
        fi
    fi

    if [[ "$TIMER" == "true" ]]; then
        [[ "$PLATFORM" == "linux" ]] || { err "--timer is for Linux; on macOS use the Homebrew cask"; exit 1; }
        run_timer
        exit 0
    fi

    # Registration is only needed to download, so --check-only and up-to-date runs
    # skip it (below); --reconfigure still runs up front so it works when current
    [[ "$RECONFIGURE" != "true" ]] || load_config

    # Get versions
    local installed_version
    installed_version=$(get_installed_version)
    log "Installed version: ${installed_version}"

    log "Checking Blackmagic API for latest version..."
    local latest_info latest_version download_id
    latest_info=$(get_latest_version)
    latest_version=$(echo "$latest_info" | cut -d'|' -f1)
    download_id=$(echo "$latest_info" | cut -d'|' -f2)

    ok "Latest version: ${latest_version}"

    # Compare versions
    if [[ "$installed_version" == "$latest_version" && "$FORCE" != "true" ]]; then
        # Just chose Homebrew in --reconfigure: install the cask now, so Homebrew tracks
        # this version and `brew upgrade` takes over future updates
        if [[ "$PLATFORM" == "mac" && "${USE_HOMEBREW:-}" == "yes" && "$CHECK_ONLY" != "true" ]] \
            && ! brew list --cask "$HOMEBREW_CASK" &>/dev/null; then
            log "Resolve is up to date; installing it as a Homebrew cask so brew upgrade handles future updates"
            update_via_homebrew
            exit 0
        fi
        ok "Already on latest version (${installed_version}). Nothing to do."
        if [[ "$CHECK_ONLY" == "true" ]]; then
            exit 0
        fi
        echo ""
        echo "Use --force to reinstall anyway."
        exit 0
    fi

    if [[ "$installed_version" != "$latest_version" ]]; then
        log "Update available: ${installed_version} → ${latest_version}"
    fi

    if [[ "$CHECK_ONLY" == "true" ]]; then
        warn "Check-only mode. Exiting."
        exit 0
    fi

    [[ -n "${REG_DATA:-}" ]] || load_config

    if [[ "$PLATFORM" == "mac" && "$USE_HOMEBREW" == "yes" ]]; then
        update_via_homebrew
        local now
        now=$(get_installed_version)
        echo ""
        if [[ "$now" == "$latest_version" ]]; then
            ok "DaVinci Resolve ${latest_version} installed successfully (via Homebrew)!"
        else
            # The cask is bumped from Blackmagic's API every 6 hours by the tap's GitHub Action
            warn "Homebrew's cask isn't on ${latest_version} yet (installed: ${now}); it's updated every 6 hours, try again later"
        fi
        exit 0
    fi

    if [[ "$PLATFORM" == "mac" ]]; then
        mkdir -p "$BUILD_DIR"
        download_resolve "$download_id" "$latest_version"

        if [[ "$SKIP_INSTALL" == "true" ]]; then
            ok "Downloaded to ${BUILD_DIR} (not installed due to --skip-install)"
            exit 0
        fi

        install_mac_pkg "$latest_version"
        cleanup_zip "$latest_version"

        echo ""
        ok "DaVinci Resolve ${latest_version} installed successfully!"
        log "Launch it from /Applications/DaVinci Resolve."
        exit 0
    fi

    if [[ "$LINUX_FAMILY" != "arch" ]]; then
        mkdir -p "$BUILD_DIR"
        download_resolve "$download_id" "$latest_version"

        if [[ "$SKIP_INSTALL" == "true" ]]; then
            ok "Downloaded to ${BUILD_DIR} (not installed due to --skip-install)"
            exit 0
        fi

        install_linux_run "$latest_version"
        check_runtime_dirs
        cleanup_zip "$latest_version"

        echo ""
        ok "DaVinci Resolve ${latest_version} installed successfully!"
        log "Launch it from your app menu or with /opt/resolve/bin/resolve"
        exit 0
    fi

    # The timer may already have built this version: install that instead of rebuilding.
    # pacman -U installs just this file, so it's no partial upgrade like `pacman -Sy <pkg>`.
    local built
    if [[ "$SKIP_INSTALL" != "true" && "$FORCE" != "true" ]] && built=$(local_repo_package "$latest_version"); then
        log "The timer already built ${latest_version}; installing it from [${LOCAL_REPO_NAME}]"
        sudo pacman -U --noconfirm "$built"
        check_runtime_dirs
        cleanup_zip "$latest_version"
        echo ""
        ok "DaVinci Resolve ${latest_version} installed successfully!"
        log "Run 'davinci-resolve' to launch."
        exit 0
    fi

    # Install dependencies (repo + AUR)
    install_dependencies

    # Create build directory
    mkdir -p "$BUILD_DIR"

    # Download
    download_resolve "$download_id" "$latest_version"

    # Setup PKGBUILD
    setup_pkgbuild "$latest_version"

    # Build and install
    build_and_install

    if [[ "$SKIP_INSTALL" != "true" ]]; then
        check_runtime_dirs
        cleanup_zip "$latest_version"
    fi

    echo ""
    ok "DaVinci Resolve ${latest_version} installed successfully!"
    log "Run 'davinci-resolve' to launch."
}

# Run only when executed directly; tests/ sources this file to reach the functions.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
