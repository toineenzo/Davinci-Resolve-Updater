#!/bin/bash
# test-windows.sh — checks the Windows (Git Bash) route without Windows: uname,
# cygpath, powershell.exe and schtasks.exe are stubs that record their calls.
# Covers platform detection, reading the installed version, running the installer
# from the zip (exit codes, admin prompt), and creating/removing the scheduled task.
#
# Usage: ./tests/test-windows.sh   (needs jq 1.7+ and zip; no network, nothing installed)

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "${work}/bin" "${work}/build"

stub() { printf '#!/bin/bash\n%s\n' "$2" > "${work}/bin/$1"; chmod +x "${work}/bin/$1"; }
stub uname 'echo MINGW64_NT-10.0-26100'
stub cygpath 'case "$1" in -w) echo "C:\\fake${2//\//\\}" ;; -S) echo /fake/System32 ;; *) echo "$1" ;; esac'
# powershell.exe: answers by what the -Command script asks for
stub powershell.exe "W='${work}'"'
script="${@: -1}"
echo "MSYS_NO_PATHCONV=${MSYS_NO_PATHCONV:-}" >> "$W/ps.log"
case "$script" in
    *Uninstall*)      printf "%s\r\n" "$(cat "$W/version" 2>/dev/null)" ;;
    *Get-Process*)    exit 1 ;;
    *Start-Process*)  echo "installer=$RESOLVE_INSTALLER" >> "$W/ps.log"
                      [[ "$(cat "$W/rc")" == 0 || "$(cat "$W/rc")" == 3 ]] && cat "$W/new" > "$W/version"
                      exit "$(cat "$W/rc")" ;;
esac'
stub schtasks.exe "echo \"MSYS_NO_PATHCONV=\${MSYS_NO_PATHCONV:-} \$*\" >> '${work}/schtasks.log'; [[ \"\$1\" != /Query ]] || exit \"\$(cat '${work}/query')\""
PATH="${work}/bin:${PATH}"

# shellcheck source=../update-resolve.sh
source "${REPO_DIR}/update-resolve.sh"
BUILD_DIR="${work}/build"

fails=0
check() {
    if [[ "$2" == "$3" ]]; then echo -e "${GREEN}PASS${NC} $1"
    else echo -e "${RED}FAIL${NC} $1: got '$2', expected '$3'"; fails=$((fails + 1)); fi
}

check "MINGW is detected as windows" "${PLATFORM}/${ZIP_SUFFIX}" "windows/Windows"
# Windows' jq writes CRLF without -b; this host's jq doesn't, so check the wrapper and that -b is accepted
check "jq is wrapped with -b" "$(declare -f jq | grep -c 'command jq -b "\$@"')" 1
check "jq -b works here" "$(echo '{"a":"x"}' | jq -r .a)" "x"

for pair in "21.2.0.6=21.2.0" "21.1.2.10=21.1.2" "21.2=21.2.0" "=none"; do
    echo "${pair%%=*}" > "${work}/version"
    check "installed version '${pair%%=*}' reads as ${pair#*=}" "$(get_installed_version)" "${pair#*=}"
done

# Blackmagic's layout: DaVinci_Resolve_<ver>_Windows.zip holds one .exe
mkdir -p "${work}/zipsrc"
touch "${work}/zipsrc/DaVinci_Resolve_21.2_Windows.exe"
(cd "${work}/zipsrc" && zip -q "${BUILD_DIR}/DaVinci_Resolve_21.2.0_Windows.zip" DaVinci_Resolve_21.2_Windows.exe)
echo "21.2.0.6" > "${work}/new"

for case in "0=ok" "3=ok" "1=fail"; do
    echo "21.1.2.10" > "${work}/version"
    echo "${case%%=*}" > "${work}/rc"
    : > "${work}/ps.log"
    result=fail
    install_windows_exe "21.2.0" > "${work}/out" 2>&1 && result=ok
    check "installer exit ${case%%=*} means ${case#*=}" "$result" "${case#*=}"
done
check "installer gets the .exe from the zip" "$(grep -c 'installer=C:\\fake.*\\DaVinci_Resolve_21.2_Windows.exe' "${work}/ps.log")" 1
check "PowerShell runs without MSYS path conversion" "$(grep -c '^MSYS_NO_PATHCONV=1$' "${work}/ps.log")" "$(grep -c '^MSYS_NO_PATHCONV' "${work}/ps.log")"
check "unpacked installer is removed afterwards" "$(ls "${BUILD_DIR}")" "DaVinci_Resolve_21.2.0_Windows.zip"

: > "${work}/schtasks.log"
setup_timer weekly > /dev/null
check "weekly check creates the task" \
    "$(grep -c '^MSYS_NO_PATHCONV=1 /Create /F /TN DaVinci Resolve Updater /SC WEEKLY /ST 12:00 /TR "C:\\fake.*bash.exe" -l "C:\\fake.*\\update-resolve.sh" --timer$' "${work}/schtasks.log")" 1

: > "${work}/schtasks.log"; echo 0 > "${work}/query"
setup_timer never > /dev/null
check "never removes an existing task" "$(grep -c '/Delete /TN DaVinci Resolve Updater /F' "${work}/schtasks.log")" 1

: > "${work}/schtasks.log"; echo 1 > "${work}/query"
setup_timer never > /dev/null
check "never without a task deletes nothing" "$(grep -c '/Delete' "${work}/schtasks.log" || true)" 0

[[ $fails -eq 0 ]] || { echo "${fails} failed"; exit 1; }
