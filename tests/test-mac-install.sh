#!/bin/bash
# test-mac-install.sh — checks install_mac_pkg finds the .pkg inside the
# zip -> dmg layout Blackmagic ships and hands it to `installer`.
# Builds a fake zip/dmg locally; `sudo` is shimmed, so nothing is installed.
#
# Usage: ./tests/test-mac-install.sh

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../update-resolve.sh
source "${REPO_DIR}/update-resolve.sh"

work="$(mktemp -d)"
BUILD_DIR="${work}/build"
mkdir -p "${work}/dmgsrc" "$BUILD_DIR" "${work}/bin"
touch "${work}/dmgsrc/Install Resolve 99.0.0.pkg"
hdiutil create -quiet -srcfolder "${work}/dmgsrc" -format UDZO "${work}/DaVinci_Resolve_99.0.0_Mac.dmg"
(cd "$work" && zip -q "${BUILD_DIR}/DaVinci_Resolve_99.0.0_Mac.zip" DaVinci_Resolve_99.0.0_Mac.dmg)

# Fake sudo records the command instead of running it
printf '#!/bin/sh\necho "$@" > "%s/called"\n' "$work" > "${work}/bin/sudo"
chmod +x "${work}/bin/sudo"

PATH="${work}/bin:${PATH}" install_mac_pkg "99.0.0" > /dev/null

called=$(cat "${work}/called")
rm -rf "$work"
if [[ "$called" == "installer -pkg "*"/Install Resolve 99.0.0.pkg -target / -verboseR" ]]; then
    echo -e "${GREEN}PASS${NC} install_mac_pkg runs installer on the .pkg inside the dmg"
else
    echo -e "${RED}FAIL${NC} unexpected call: ${called}"
    exit 1
fi
