#!/bin/bash
# test-distros.sh — checks the non-Arch Linux route in a container per distro:
# install_run_dependencies installs Blackmagic's own package list (read from
# AppRun), then `ldd` must find every library DaVinci Resolve links against,
# and get_installed_version must read the version from Welcome.txt.
#
# Needs Docker and an unpacked Resolve installer (no download or install here):
#   unzip DaVinci_Resolve_*_Linux.zip && ./DaVinci_Resolve_*_Linux.run --appimage-extract
#   ./tests/test-distros.sh /path/to/squashfs-root [image ...]
# Instead of a path, squashfs-root may be a Docker volume as volume[:subdir].

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SQ="${1:?usage: $0 /path/to/squashfs-root [image ...]}"
shift
IMAGES=("$@")
if [[ ${#IMAGES[@]} -eq 0 ]]; then
    IMAGES=(ubuntu:22.04 ubuntu:24.04 linuxmintd/mint22-amd64 debian:12 debian:13
            fedora:42 rockylinux/rockylinux:9 quay.io/centos/centos:stream9 opensuse/leap:15.6)
fi

# Runs inside each container, as root; `sudo` is shimmed to plain exec
read -r -d '' INNER <<'EOF' || true
set -euo pipefail
printf '#!/bin/sh\nexec env "$@"\n' > /usr/local/bin/sudo && chmod +x /usr/local/bin/sudo
source /src/update-resolve.sh
echo "family=${LINUX_FAMILY}"
check_tools_run > /tmp/tools.log 2>&1 || { tail -5 /tmp/tools.log; exit 1; }
install_run_dependencies /sq/AppRun > /tmp/deps.log 2>&1 || { tail -15 /tmp/deps.log; exit 1; }
grep -E '^\[!\]|skipping' /tmp/deps.log || true

missing=$(LD_LIBRARY_PATH=/sq/libs ldd /sq/bin/resolve | grep 'not found' || true)
[[ -z "$missing" ]] || { echo "MISSING LIBS:"; echo "$missing"; exit 1; }

mkdir -p /opt/resolve/docs && cp /sq/docs/Welcome.txt /opt/resolve/docs/
expected=$(grep -o -m1 'Resolve [0-9.]*[0-9]' /sq/docs/Welcome.txt | awk '{print $2}')
[[ ! "$expected" =~ ^[0-9]+\.[0-9]+\.0$ ]] || expected=${expected%.0}
got=$(get_installed_version)
[[ "$got" == "$expected" ]] || { echo "version: got ${got}, expected ${expected}"; exit 1; }
echo "version=${got}"
EOF

if [[ -d "$SQ" ]]; then
    sq_mount=(-v "${SQ}:/sq:ro")
else
    subpath=""
    [[ "$SQ" != *:* ]] || subpath=",volume-subpath=${SQ#*:}"
    sq_mount=(--mount "type=volume,src=${SQ%%:*},dst=/sq,readonly${subpath}")
fi

failures=0
for image in "${IMAGES[@]}"; do
    if out=$(docker run --rm --platform linux/amd64 -v "${REPO_DIR}:/src:ro" "${sq_mount[@]}" \
            "$image" bash -c "$INNER" 2>&1); then
        echo -e "\033[0;32mPASS\033[0m ${image}: $(echo "$out" | grep -E '^(family|version)=' | tr '\n' ' ')"
        echo "$out" | grep -E '^\[!\]|skipping' | sed 's/^/      /' || true
    else
        echo -e "\033[0;31mFAIL\033[0m ${image}"
        echo "$out" | tail -20 | sed 's/^/      /'
        failures=$((failures + 1))
    fi
done

echo ""
if [[ $failures -eq 0 ]]; then
    echo "All ${#IMAGES[@]} distros passed."
else
    echo "${failures} of ${#IMAGES[@]} distros failed."
    exit 1
fi
