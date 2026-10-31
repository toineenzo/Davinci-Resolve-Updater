#!/bin/bash
# test-timer.sh — checks the automatic update path on Arch, in a Docker container:
# the interval prompt, the systemd units, and a dummy davinci-resolve package going
# setup_local_repo -> publish_local_repo -> `pacman -Syu` -> get_installed_version.
# No Resolve download, no real systemd, nothing touches the host.
#
# Usage: ./tests/test-timer.sh

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

read -r -d '' INNER <<'EOS' || true
set -euo pipefail
failures=0
pass() { echo "PASS $1"; }
fail() { echo "FAIL $1"; failures=$((failures + 1)); }

sed -i '/^\[options\]/a DisableSandbox' /etc/pacman.conf   # pacman's sandbox fails under emulation
pacman -Sy --noconfirm --needed base-devel sudo systemd jq > /dev/null 2>&1
useradd -m t && echo 't ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/t
cp -r /src /home/t/repo && chown -R t /home/t/repo

su t -c 'bash -s' <<'EOT'
set -euo pipefail
cd /home/t/repo
source ./update-resolve.sh
set +e
failures=0
pass() { echo "PASS $1"; }
fail() { echo "FAIL $1"; failures=$((failures + 1)); }

[[ "$LINUX_FAMILY" == "arch" ]] && pass "Arch detected" || fail "LINUX_FAMILY=$LINUX_FAMILY"

# Interval prompt: needs a terminal, so type the answer into a pty from script(1);
# without a terminal it's "never"
for pair in d:daily w:weekly m:monthly n:never :weekly; do
    got=$( (sleep 1; printf '%s\n' "${pair%%:*}"; sleep 3) \
        | script -qc "bash -c 'source ./update-resolve.sh; ask_check_interval > /dev/null; echo RESULT=\$CHECK_INTERVAL'" /dev/null \
        | tr -d '\r' | sed -n 's/^RESULT=//p')
    [[ "$got" == "${pair#*:}" ]] && pass "answer '${pair%%:*}' -> ${got}" || fail "answer '${pair%%:*}' -> '${got}', expected ${pair#*:}"
done
ask_check_interval < /dev/null > /dev/null
[[ "$CHECK_INTERVAL" == "never" ]] && pass "no terminal -> never" || fail "no terminal -> $CHECK_INTERVAL"

# systemd units: valid, and the timer fires on the chosen interval
for interval in daily weekly monthly; do
    write_timer_units "$interval"
    if out=$(systemd-analyze verify "${SYSTEMD_USER_DIR}/resolve-update.timer" "${SYSTEMD_USER_DIR}/resolve-update.service" 2>&1) \
        && grep -q "^OnCalendar=${interval}$" "${SYSTEMD_USER_DIR}/resolve-update.timer"; then
        pass "units verify (${interval})"
    else
        fail "units (${interval}): ${out}"
    fi
done
grep -q "ExecStart=\"$(pwd)/update-resolve.sh\" --timer" "${SYSTEMD_USER_DIR}/resolve-update.service" \
    && pass "service runs this script with --timer" || fail "service ExecStart"

# Local repo: empty repo is valid for pacman -Sy, then a dummy package is published and installed
setup_local_repo > /dev/null
sudo pacman -Sy > /dev/null 2>&1 && pass "empty [resolve-local] syncs" || fail "pacman -Sy with empty repo"
sudo pacman -Fy > /dev/null 2>&1 && pass "empty [resolve-local] has a files database (pacman -Fy)" || fail "pacman -Fy with empty repo"
[[ "$LOCAL_REPO_DIR" == /var/lib/* ]] && pass "repo lives under /var/lib" || fail "repo dir ${LOCAL_REPO_DIR}"

# A package file without a database entry (interrupted publish) must not count as built
touch "${LOCAL_REPO_DIR}/davinci-resolve-98.0.0-1-any.pkg.tar.zst"
local_repo_package 98.0.0 > /dev/null && fail "stray package file counted as built" || pass "stray package file isn't counted as built"
rm -f "${LOCAL_REPO_DIR}/davinci-resolve-98.0.0-1-any.pkg.tar.zst"

BUILD_DIR=$(mktemp -d)
cat > "${BUILD_DIR}/PKGBUILD" <<'PKG'
pkgname=davinci-resolve
pkgver=99.0.0
pkgrel=1
pkgdesc="dummy for test-timer.sh"
arch=(any)
package() { mkdir -p "$pkgdir/opt/resolve"; touch "$pkgdir/opt/resolve/dummy"; }
PKG
(cd "$BUILD_DIR" && makepkg -f > /dev/null 2>&1)
publish_local_repo > /dev/null && pass "publish_local_repo" || fail "publish_local_repo"
[[ "$(local_repo_package 99.0.0)" == "${LOCAL_REPO_DIR}/davinci-resolve-99.0.0-1-any.pkg.tar.zst" ]] \
    && pass "local_repo_package finds the published build" || fail "local_repo_package: '$(local_repo_package 99.0.0)'"
local_repo_package 99.0 > /dev/null && fail "local_repo_package matched a version prefix" || pass "local_repo_package doesn't match version prefixes"
ls "$LOCAL_REPO_DIR"/davinci-resolve-99.0.0-1-any.pkg.tar.* > /dev/null 2>&1 && pass "package moved into repo" || fail "package not in repo"

sudo pacman -Syu --noconfirm > /dev/null 2>&1 || true
sudo pacman -S --noconfirm resolve-local/davinci-resolve > /dev/null 2>&1
[[ "$(get_installed_version)" == "99.0.0" ]] && pass "pacman installs it from [resolve-local]" || fail "installed: $(get_installed_version)"

# run_timer: up to date, and "already built, waiting for pacman"
CONFIG_FILE=$(mktemp); echo "firstname=a" > "$CONFIG_FILE"
get_latest_version() { echo "99.0.0|0123456789abcdef0123456789abcdef"; }
out=$( (set -e; run_timer) 2>&1); [[ "$out" == *"Up to date (99.0.0)"* ]] && pass "timer: up to date" || fail "timer up to date: $out"
get_installed_version() { echo "21.1.1"; }
out=$( (set -e; run_timer) 2>&1); [[ "$out" == *"already built"* ]] && pass "timer: waits for pacman -Syu" || fail "timer already built: $out"
get_latest_version() { return 1; }
out=$( (set -e; run_timer) 2>&1); [[ "$out" == *"unreachable"* ]] && pass "timer: offline is skipped" || fail "timer offline: $out"

# Missing build dependencies are reported (the timer can't sudo-install them)
DEPS_DIR=$(mktemp -d)
printf 'pkgname=x\npkgver=1\npkgrel=1\narch=(any)\ndepends=(bash)\nmakedepends=(no-such-pkg-xyz)\npackage() { :; }\n' > "${DEPS_DIR}/PKGBUILD"
[[ "$(BUILD_DIR=$DEPS_DIR missing_build_deps)" == "no-such-pkg-xyz" ]] && pass "missing_build_deps lists only what's missing" \
    || fail "missing_build_deps: '$(BUILD_DIR=$DEPS_DIR missing_build_deps)'"

# Only one run at a time: a second run while the lock is held exits (the timer quietly)
( exec 9> ./.lock; flock 9; sleep 20 ) &
sleep 2
out=$(./update-resolve.sh --timer 2>&1); rc=$?
[[ $rc == 0 && "$out" == *"Another run is in progress"* ]] && pass "timer skips while another run holds the lock" || fail "lock (timer) rc=$rc: $out"
out=$(./update-resolve.sh --force < /dev/null 2>&1); rc=$?
[[ $rc == 1 && "$out" == *"in progress"* ]] && pass "manual run refuses while another run holds the lock" || fail "lock (manual) rc=$rc: $out"
kill %1 2>/dev/null; wait 2>/dev/null

# A second publish replaces the old version (repo-add -R)
sed -i 's/^pkgver=.*/pkgver=99.0.1/' "${BUILD_DIR}/PKGBUILD"
(cd "$BUILD_DIR" && makepkg -f > /dev/null 2>&1) && publish_local_repo > /dev/null
[[ $(ls "$LOCAL_REPO_DIR"/davinci-resolve-*.pkg.tar.* | wc -l) == 1 ]] && pass "old package removed on update" || fail "old package kept: $(ls "$LOCAL_REPO_DIR")"
sudo pacman -Syu --noconfirm > /dev/null 2>&1
[[ "$(pacman -Q davinci-resolve | awk '{print $2}')" == "99.0.1-1" ]] && pass "pacman -Syu upgrades to the new build" || fail "after -Syu: $(pacman -Q davinci-resolve)"

# An interactive run installs what the timer already built instead of downloading again
latest=$(curl -fsS https://www.blackmagicdesign.com/api/support/latest-stable-version/davinci-resolve/linux \
    | jq -r '.linux | if .releaseNum == 0 then "\(.major).\(.minor)" else "\(.major).\(.minor).\(.releaseNum)" end')
sed -i "s/^pkgver=.*/pkgver=${latest}/" "${BUILD_DIR}/PKGBUILD"
(cd "$BUILD_DIR" && makepkg -f > /dev/null 2>&1) && publish_local_repo > /dev/null
out=$(./update-resolve.sh < /dev/null 2>&1); rc=$?
[[ $rc == 0 && "$out" == *"timer already built ${latest}"* && "$out" != *"Requesting download URL"* \
    && "$(pacman -Q davinci-resolve | awk '{print $2}')" == "${latest}-1" ]] \
    && pass "manual run installs the timer's build of ${latest} without downloading" \
    || fail "manual run rc=$rc, installed $(pacman -Q davinci-resolve): $(echo "$out" | tail -5)"

exit $failures
EOT
EOS

if docker run --rm --platform linux/amd64 -v "${REPO_DIR}:/src:ro" archlinux:latest bash -c "$INNER"; then
    echo -e "\033[0;32mAll timer tests passed.\033[0m"
else
    echo -e "\033[0;31mTimer tests failed.\033[0m"
    exit 1
fi
