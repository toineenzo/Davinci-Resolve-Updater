#!/bin/bash
# test-cleanup.sh — checks the cleanup_zip preference: asked once for configs
# that predate it, saved to .config, and honoured by cleanup_zip.
# No network, no download, no sudo.
#
# Usage: ./tests/test-cleanup.sh

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../update-resolve.sh
source "${REPO_DIR}/update-resolve.sh"

failures=0
pass() { echo -e "${GREEN}PASS${NC} $1"; }
fail() { echo -e "${RED}FAIL${NC} $1"; failures=$((failures + 1)); }

work="$(mktemp -d)"
BUILD_DIR="$work"
CONFIG_FILE="${work}/.config"
zip="${work}/DaVinci_Resolve_1.2.3_${ZIP_SUFFIX}.zip"

# Old config without cleanup_zip: asks once, "n" is saved as no, zip is kept
printf 'firstname=a\nlastname=b\nemail=c\nphone=1\ncountry=nl\nstate=x\ncity=y\nstreet=z\n' > "$CONFIG_FILE"
touch "$zip"
load_config <<< "n" > /dev/null
cleanup_zip "1.2.3" > /dev/null
[[ "$(grep -c '^cleanup_zip=no$' "$CONFIG_FILE")" == 1 ]] && pass "missing key: answer saved as cleanup_zip=no" || fail "missing key: not saved as no"
[[ -f "$zip" ]] && pass "cleanup_zip=no keeps the zip" || fail "cleanup_zip=no deleted the zip"

# Saved preference is reused without asking again (stdin closed: a prompt would read nothing and default to yes)
load_config < /dev/null > /dev/null
[[ "$CLEANUP_ZIP" == "no" && "$(grep -c '^cleanup_zip=' "$CONFIG_FILE")" == 1 ]] && pass "saved preference reused, not asked again" || fail "preference re-asked or duplicated"

# Yes (the default on Enter) removes the zip
sed -e 's/^cleanup_zip=no$/cleanup_zip=yes/' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
load_config < /dev/null > /dev/null
cleanup_zip "1.2.3" > /dev/null
[[ ! -f "$zip" ]] && pass "cleanup_zip=yes removes the zip" || fail "cleanup_zip=yes kept the zip"

# Empty answer defaults to yes
ask_cleanup_zip <<< "" > /dev/null
[[ "$CLEANUP_ZIP" == "yes" ]] && pass "Enter defaults to yes" || fail "Enter did not default to yes"

rm -rf "$work"
echo ""
if [[ $failures -eq 0 ]]; then
    echo -e "${GREEN}All cleanup tests passed.${NC}"
else
    echo -e "${RED}${failures} cleanup test(s) failed.${NC}"
    exit 1
fi
