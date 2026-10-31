#!/bin/bash
# test-homebrew-setup.sh — macOS: checks the Homebrew question in the first-time
# setup and that older configs get it once. No brew commands are run.
#
# Usage: ./tests/test-homebrew-setup.sh

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../update-resolve.sh
source "${REPO_DIR}/update-resolve.sh"

failures=0
pass() { echo -e "${GREEN}PASS${NC} $1"; }
fail() { echo -e "${RED}FAIL${NC} $1"; failures=$((failures + 1)); }

work="$(mktemp -d)"
printf '#!/bin/sh\nexit 0\n' > "${work}/brew" && chmod +x "${work}/brew"   # a brew to find

# Answers typed into a real terminal (script(1)); Enter means yes
for pair in y:yes Y:yes :yes n:no N:no; do
    got=$( (sleep 1; printf '%s\n' "${pair%%:*}"; sleep 3) \
        | PATH="${work}:${PATH}" script -q /dev/null bash -c "source '${REPO_DIR}/update-resolve.sh'; ask_homebrew > /dev/null; echo RESULT=\$USE_HOMEBREW" \
        | tr -d '\r' | sed -n 's/^RESULT=//p')
    [[ "$got" == "${pair#*:}" ]] && pass "answer '${pair%%:*}' -> ${got}" || fail "answer '${pair%%:*}' -> '${got}', expected ${pair#*:}"
done

PATH="${work}:${PATH}" ask_homebrew < /dev/null > /dev/null
[[ "$USE_HOMEBREW" == "no" ]] && pass "no terminal -> no" || fail "no terminal -> ${USE_HOMEBREW}"

PATH="/usr/bin:/bin" ask_homebrew <<< "y" > /dev/null
[[ "$USE_HOMEBREW" == "no" ]] && pass "no Homebrew installed -> no, not asked" || fail "without brew -> ${USE_HOMEBREW}"

# A config from before this setting: asked once (no terminal -> no), appended, not duplicated
CONFIG_FILE="${work}/.config"
printf 'firstname=a\nlastname=b\nemail=c\nphone=1\ncountry=nl\nstate=x\ncity=y\nstreet=z\ncleanup_zip=yes\n' > "$CONFIG_FILE"
PATH="${work}:${PATH}" load_config < /dev/null > /dev/null
PATH="${work}:${PATH}" load_config < /dev/null > /dev/null
[[ "$(grep -c '^homebrew=no$' "$CONFIG_FILE")" == 1 && "$USE_HOMEBREW" == "no" ]] \
    && pass "older config gets homebrew=no once" || fail "older config: $(grep homebrew "$CONFIG_FILE" | tr '\n' ' ')"

rm -rf "$work"
echo ""
if [[ $failures -eq 0 ]]; then
    echo -e "${GREEN}All Homebrew setup tests passed.${NC}"
else
    echo -e "${RED}${failures} Homebrew setup test(s) failed.${NC}"
    exit 1
fi
