#!/bin/bash
# update-resolve-mac.sh — Automated DaVinci Resolve updater for macOS
# Checks for updates, downloads via Blackmagic API, installs the bundled .pkg
#
# Usage: ./update-resolve-mac.sh [--force] [--check-only] [--skip-install] [--reconfigure]
#
# Dependencies: curl, jq (built into macOS 15+, else `brew install jq`),
# unzip, hdiutil, installer (all built into macOS)
#
# Written for the bash 3.2 that ships with macOS (no mapfile, no assoc arrays).

set -euo pipefail

# Version info
SCRIPT_VERSION="2026.10.1"
RESOLVE_TESTED="21.1.2"

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${SCRIPT_DIR}/build"
CONFIG_FILE="${SCRIPT_DIR}/.config"
PRODUCT="davinci-resolve"  # Change to "davinci-resolve-studio" for Studio edition
APP_PATH="/Applications/DaVinci Resolve/DaVinci Resolve.app"

# Blackmagic API endpoints
API_BASE="https://www.blackmagicdesign.com/api"

# Generic product/page identifier for the DaVinci Resolve download page (not user-specific).
REFER_ID="77ef91f67a9e411bbbe299e595b4cfcc"

UA="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/133.0.0.0 Safari/537.36"

# Static Google Analytics cookies so requests look like normal browser traffic (not tied to a user).
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
for arg in "$@"; do
    case $arg in
        --force) FORCE=true ;;
        --check-only) CHECK_ONLY=true ;;
        --skip-install) SKIP_INSTALL=true ;;
        --reconfigure) RECONFIGURE=true ;;
        -h|--help)
            echo "Usage: $0 [--force] [--check-only] [--skip-install] [--reconfigure]"
            echo "  --force        Update even if already on latest version"
            echo "  --check-only   Just check for updates, don't download or install"
            echo "  --skip-install Download but don't install"
            echo "  --reconfigure  Re-enter registration info"
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

    if [[ -z "$REG_FIRSTNAME" || -z "$REG_LASTNAME" || -z "$REG_EMAIL" || -z "$REG_PHONE" || -z "$REG_COUNTRY" || -z "$REG_STATE" || -z "$REG_CITY" || -z "$REG_STREET" ]]; then
        err "All fields are required"
        exit 1
    fi

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
    } > "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE"
    ok "Configuration saved to ${CONFIG_FILE}"
    echo ""
}

load_config() {
    if [[ "$RECONFIGURE" == "true" || ! -f "$CONFIG_FILE" ]]; then
        prompt_config
    fi

    # Read config safely — no shell evaluation, just plain key=value parsing
    _cfg() { grep "^$1=" "$CONFIG_FILE" | cut -d= -f2-; }

    REG_DATA=$(jq -n \
        --arg fn "$(_cfg firstname)" \
        --arg ln "$(_cfg lastname)" \
        --arg em "$(_cfg email)" \
        --arg ph "$(_cfg phone)" \
        --arg co "$(_cfg country)" \
        --arg st "$(_cfg state)" \
        --arg ci "$(_cfg city)" \
        --arg sr "$(_cfg street)" \
        '{firstname:$fn, lastname:$ln, email:$em, phone:$ph, country:$co, state:$st, city:$ci, street:$sr, product:"DaVinci Resolve"}')
}

# --- Core Functions ---

# Installed version from the app bundle, e.g. "21.0.0"
get_installed_version() {
    defaults read "${APP_PATH}/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo "none"
}

# Latest version from Blackmagic API, always major.minor.release to match CFBundleShortVersionString
get_latest_version() {
    local response
    response=$(curl -s "${API_BASE}/support/latest-stable-version/${PRODUCT}/mac")

    if [[ -z "$response" || "$response" == *"error"* ]]; then
        err "Failed to query Blackmagic API for latest version"
        return 1
    fi

    echo "$response" | jq -r '.mac | "\(.major).\(.minor).\(.releaseNum)|\(.downloadId)"'
}

download_resolve() {
    local download_id="$1"
    local version="$2"
    local zip_path="${BUILD_DIR}/DaVinci_Resolve_${version}_Mac.zip"

    if [[ -f "$zip_path" && "$FORCE" != "true" ]]; then
        ok "Zip already downloaded: $(basename "$zip_path")"
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
        -H "Referer: https://www.blackmagicdesign.com/support/download/${REFER_ID}/Mac%20OS%20X" \
        -b "${COOKIES}" \
        -d "${REG_DATA}")

    if [[ -z "$download_url" || "$download_url" == *"Error"* || "$download_url" == *"Bad Request"* ]]; then
        err "Failed to get download URL: ${download_url}"
        return 1
    fi

    log "Downloading $(basename "$zip_path")..."
    # Download to .part so an interrupted run isn't mistaken for a finished zip next time
    curl -fL --progress-bar -H "User-Agent: ${UA}" -o "${zip_path}.part" "$download_url"
    mv "${zip_path}.part" "$zip_path"
    ok "Downloaded: $(basename "$zip_path") ($(du -h "$zip_path" | cut -f1))"
}

# Zip -> .dmg -> .pkg -> installer
install_resolve() {
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
    hdiutil attach "$dmg" -nobrowse -readonly -mountpoint "$mount_dir" > /dev/null
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
    sudo installer -pkg "$pkg" -target /

    hdiutil detach "$mount_dir" -quiet
    trap - EXIT
    rm -rf "$extract_dir"
    ok "Installed $(basename "$pkg")"
}

# --- Main ---
main() {
    echo ""
    echo -e "${BLUE}╔══════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║    DaVinci Resolve Updater for macOS     ║${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════════╝${NC}"
    echo ""

    if [[ "$(uname -s)" != "Darwin" ]]; then
        err "This script is for macOS. Use update-resolve.sh on Arch Linux."
        exit 1
    fi

    for cmd in curl jq unzip hdiutil installer; do
        if ! command -v "$cmd" &>/dev/null; then
            err "Missing dependency: $cmd"
            [[ "$cmd" != "jq" ]] || err "Install it with: brew install jq"
            exit 1
        fi
    done

    local installed_version
    installed_version=$(get_installed_version)
    log "Installed version: ${installed_version}"

    log "Checking Blackmagic API for latest version..."
    local latest_info latest_version download_id
    latest_info=$(get_latest_version)
    latest_version=${latest_info%%|*}
    download_id=${latest_info#*|}
    ok "Latest version: ${latest_version}"

    if [[ "$installed_version" == "$latest_version" && "$FORCE" != "true" ]]; then
        ok "Already on latest version (${installed_version}). Nothing to do."
        [[ "$CHECK_ONLY" == "true" ]] || { echo ""; echo "Use --force to reinstall anyway."; }
        exit 0
    fi

    if [[ "$installed_version" != "$latest_version" ]]; then
        log "Update available: ${installed_version} → ${latest_version}"
    fi

    if [[ "$CHECK_ONLY" == "true" ]]; then
        warn "Check-only mode. Exiting."
        exit 0
    fi

    load_config
    mkdir -p "$BUILD_DIR"
    download_resolve "$download_id" "$latest_version"

    if [[ "$SKIP_INSTALL" == "true" ]]; then
        ok "Downloaded to ${BUILD_DIR} (not installed due to --skip-install)"
        exit 0
    fi

    install_resolve "$latest_version"

    echo ""
    ok "DaVinci Resolve ${latest_version} installed successfully!"
    log "Launch it from /Applications/DaVinci Resolve."
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
