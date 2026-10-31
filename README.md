# update-resolve

`update-resolve.sh` checks Blackmagic's API for the latest DaVinci Resolve release, compares it with the version you have installed, and if there is a newer one, downloads it (it fills in Blackmagic's registration form for you) and installs it. One script covers Arch Linux, other Linux distros and macOS. It detects the OS and picks the install route. The same command and registration prompt work on every platform. A few flags are platform-specific (`--timer` is Linux-only, see [Usage and flags](#usage-and-flags)), and each platform gets one extra setup question.

This is a fork of [drake495/Davinci-Resolve-Updater](https://github.com/drake495/Davinci-Resolve-Updater), which supports Arch Linux only. The Arch route works the same way as upstream. This fork adds macOS, other Linux distros, a Homebrew tap and automatic update checks.

**Script version:** 2026.10.2 | **Tested with DaVinci Resolve:** 21.1.2-1

## Contents

- [Quick start](#quick-start)
- [What happens on first run](#what-happens-on-first-run)
- [Usage and flags](#usage-and-flags)
- [macOS](#macos)
- [Linux: Arch](#linux-arch)
- [Linux: other distros](#linux-other-distros)
- [Automatic update checks (Linux)](#automatic-update-checks-linux)
- [Configuration file reference](#configuration-file-reference)
- [DaVinci Resolve Studio](#davinci-resolve-studio)
- [How it works](#how-it-works)
- [Troubleshooting](#troubleshooting)
- [Testing](#testing)
- [Versioning](#versioning)
- [License](#license)

## Quick start

Before you start:

- **git.** Fresh Ubuntu, Debian and Mint desktops and minimal Arch installs don't include it. Install it with `sudo apt install git` (Debian/Ubuntu/Mint), `sudo dnf install git` (Fedora/RHEL), or `sudo pacman -S --needed git base-devel` (Arch, which also needs `base-devel` to build the package). On macOS without Homebrew or the Command Line Tools, run `xcode-select --install` first. Or skip git and use **Code > Download ZIP** on GitHub (then `git pull` won't work; download the zip again to update).
- **Disk space.** Downloads and unpacking happen in `build/`, next to the script. Measured for Resolve 21.1.2: on other Linux distros about 18GB at the peak (the 4.5GB zip, the 4.5GB `.run` inside it and the 8.6GB unpacked installer), plus 8.6GB for `/opt/resolve`; on macOS about 8GB (the 3.9GB zip and the 4.1GB `.dmg` inside it), plus the installed app. The Arch `makepkg` build unpacks and repackages the same files, so plan for 25-30GB there (an estimate).
- **GPU driver (Linux).** Resolve needs a GPU compute driver (OpenCL or CUDA). Install your GPU's driver first, for example `nvidia` + `opencl-nvidia`, `rocm-opencl-runtime` (AMD) or `intel-compute-runtime`. The script doesn't pick one for your GPU (see [Runtime dependencies](#runtime-dependencies)).

This works the same on every platform:

```bash
git clone https://github.com/toineenzo/Davinci-Resolve-Updater.git
cd Davinci-Resolve-Updater
./update-resolve.sh
```

Run it as your normal user, not with `sudo`. It asks for your password when it needs root. Under `sudo`, `makepkg` refuses to run on Arch, `.config` and `build/` become root-owned, and the timer gets set up for root instead of you.

To update later, run `./update-resolve.sh` again, or `git pull` first to get the newest version of the script.

| Platform | How Resolve gets installed | Details |
|---|---|---|
| Arch Linux and Arch-based distros (Manjaro, EndeavourOS, …) | Builds the AUR `davinci-resolve` package with `makepkg`. pacman tracks the result. | [Linux: Arch](#linux-arch) |
| Ubuntu, Debian, Linux Mint, Fedora, Rocky, CentOS Stream, RHEL, openSUSE | Runs Blackmagic's own installer into `/opt/resolve` | [Linux: other distros](#linux-other-distros) |
| macOS | Runs the `.pkg` from Blackmagic's `.dmg`, or uses the Homebrew cask from this repo | [macOS](#macos) |

Don't symlink the script into your `PATH`. It keeps `.config` and `build/` next to the path you call it by, so a symlink in `~/.local/bin` would put them there. Use an alias instead:

```bash
alias update-resolve="$HOME/Davinci-Resolve-Updater/update-resolve.sh"
```

## What happens on first run

The script only needs your registration info to download, so the setup runs the first time a download is needed, or when you pass `--reconfigure`. If Resolve is already up to date, or you use `--check-only`, you aren't asked for registration info. (On Linux the script may still ask for your sudo password first, to install a missing `curl`, `jq`, `unzip`, `git` or `pacman-contrib`.)

**1. Registration info.** Blackmagic asks for this on its download page. The script asks for all of these fields, and all are required:

```
First name:
Last name:
Email:
Phone (digits only):
Country code (e.g., us, uk, de):
State/Province:
City:
Street address:
```

**2. Platform questions.** The script also asks:

| Question (exact prompt) | Platform | Options | Default (Enter) | Saved as |
|---|---|---|---|---|
| `Delete the downloaded installer zip from build/ after a successful update? [Y/n]:` | all | `y`, `n` | yes | `cleanup_zip=yes` / `no` |
| `Check for updates automatically with a systemd timer? [d]aily, [w]eekly, [m]onthly or [n]ever [w]:` | Linux | `d`, `w`, `m`, `n` | weekly | `check_interval=daily` / `weekly` / `monthly` / `never` ([details](#automatic-update-checks-linux)) |
| `Install and update DaVinci Resolve through Homebrew? [Y/n]:` | macOS, only if `brew` is installed | `y`, `n` | yes | `homebrew=yes` / `no` |

- If Homebrew isn't installed, the script doesn't ask and saves `homebrew=no`.
- If your `.config` is from an older version that lacks one of these keys, the script asks just that question once, on the next run that needs the config, and adds the answer to the file.
- Without a terminal (cron, the systemd timer) and with no `.config` yet, the script stops with an error.
- Without a terminal but with an existing `.config` that lacks one of the newer keys, the script uses `cleanup_zip=yes`, `check_interval=never` and `homebrew=no`. It never creates a timer or switches to Homebrew unattended.

Everything goes into `.config` next to the script, with mode `600`. To change it, edit the file or run `./update-resolve.sh --reconfigure`, which asks every question again. See the [Configuration file reference](#configuration-file-reference).

## Usage and flags

```
Usage: ./update-resolve.sh [--force] [--check-only] [--skip-install] [--reconfigure]
  --force        Update even if already on latest version
  --check-only   Just check for updates, don't download or install
  --skip-install Download and build but don't install
  --reconfigure  Re-enter registration info
  --timer        Unattended check, run by the systemd timer (Linux; see README)
```

| Flag | What it does |
|---|---|
| (none) | Checks the installed version against the latest one and, if they differ, downloads and installs it |
| `--force` | Installs even when you're on the latest version. It also downloads the zip again, even if one is already in `build/`. On the Homebrew route it runs `brew reinstall --cask`. |
| `--check-only` | Prints the installed and latest versions, then exits. It doesn't need registration info. |
| `--skip-install` | Arch: builds the package in `build/` (`makepkg -sf`) without installing it. Other Linux distros and the macOS script route: downloads the zip to `build/` and stops. The zip is always kept. The Homebrew route ignores this flag. |
| `--reconfigure` | Runs the full first-run setup again and rewrites `.config`. On Linux it also creates, changes or removes the timer to match your answer. |
| `--timer` | The unattended check that the systemd timer runs. You can also run it by hand. Linux only: on macOS it exits with `--timer is for Linux; on macOS use the Homebrew cask`. |
| `-h`, `--help` | Prints the usage text shown above |

You can combine flags, for example `./update-resolve.sh --reconfigure --check-only` to save your registration info without installing anything.

## macOS

There are two routes. Use one of them, not both.

The script picks the route from the Homebrew question during setup (`homebrew` in `.config`). If `brew` is installed, pressing Enter picks Homebrew. Answer `n` (or set `homebrew=no`) for the script route. To switch later, see [Switching routes](#switching-routes).

### Script route

```bash
./update-resolve.sh               # check, download, install
./update-resolve.sh --check-only  # compare installed vs latest
```

1. Reads the installed version from `/Applications/DaVinci Resolve/DaVinci Resolve.app` (`CFBundleShortVersionString`).
2. Asks Blackmagic's API for the latest Mac build and downloads `DaVinci_Resolve_<version>_Mac.zip` into `build/`.
3. Unzips it and mounts the `.dmg` inside, using `diskutil image attach` where available and `hdiutil attach` on older macOS.
4. If DaVinci Resolve is running, asks you to quit it and press Enter.
5. Runs the bundled `.pkg` with `sudo installer` (asks for your password) and shows a live progress line.
6. Deletes the zip from `build/` when `cleanup_zip=yes`.

Requirements: `curl`, `jq`, `unzip`, `hdiutil` and `installer`. All of them ship with macOS except `jq` on versions before macOS 15. Install it with `brew install jq`.

Resolve is installed to `/Applications/DaVinci Resolve`. To remove it, double-click **Uninstall Resolve** in `/Applications/DaVinci Resolve`, or run `open "/Applications/DaVinci Resolve/Uninstall Resolve.app"`.

### Homebrew route

This repo is also a Homebrew tap with a `davinci-resolve` cask, so Resolve updates along with the rest of your casks through `brew upgrade` (and apps like Updatest).

**Through the script (easiest).** Answer yes to the Homebrew question during setup (`homebrew=yes`). The script then:

- taps this repo as `toineenzo/resolve` and runs `brew trust toineenzo/resolve`
- copies your `.config` into the tap, where the cask's download step reads it
- runs `brew install --cask toineenzo/resolve/davinci-resolve`

Every later run of `./update-resolve.sh` that finds an update also goes through Homebrew. It runs `brew upgrade --cask`, or `brew reinstall --cask` with `--force`. With `cleanup_zip=yes` it also deletes Homebrew's cached download. If you switch to Homebrew with `./update-resolve.sh --reconfigure` while Resolve is up to date, the script installs the cask right away so Homebrew tracks it.

The tap is a second copy of this repo, separate from your clone: `git pull` updates the clone, `brew update` updates the tap and the cask. The script copies your clone's `.config` into the tap whenever it installs, upgrades or reinstalls the cask, overwriting the tap's copy, so edit the `.config` in your clone, not the tap's. A run where Resolve is up to date doesn't copy it, not even with `--reconfigure` once the cask is installed. After changing your info that way, copy it yourself so a plain `brew upgrade` uses it:

```bash
install -m 600 .config "$(brew --repo toineenzo/resolve)/.config"
```

**By hand:**

```bash
brew tap toineenzo/resolve https://github.com/toineenzo/Davinci-Resolve-Updater
brew trust toineenzo/resolve   # Homebrew 7+ only; on older versions skip this line (Unknown command)
"$(brew --repo toineenzo/resolve)/update-resolve.sh" --reconfigure --check-only   # save registration info once; answer y to the Homebrew question
brew install --cask toineenzo/resolve/davinci-resolve
```

The `--reconfigure` step asks the registration questions, then the cleanup question (Enter keeps the default, yes) and the Homebrew question (answer `y`).

After that, `brew update && brew upgrade` installs new releases.

**Why a separate tap and not homebrew-cask.** The official homebrew-cask repo doesn't accept Resolve. Downloads sit behind Blackmagic's registration form, and homebrew-cask doesn't allow the custom download strategy needed to fill it in ([Homebrew/homebrew-cask#263604](https://github.com/Homebrew/homebrew-cask/pull/263604)). This tap is the only Homebrew route.

**What to know about the cask:**

- **Registration.** The download strategy in [`lib/blackmagic_download_strategy.rb`](lib/blackmagic_download_strategy.rb) makes the same registration request as the script (see [How it works](#how-it-works)) at download time. It reads the `.config` at the root of the tap (`$(brew --repo toineenzo/resolve)/.config`). To use a different file, set `HOMEBREW_RESOLVE_CONFIG=/path/to/.config`.
- **Password.** The `.pkg` installs with `sudo`, so `brew install` and `brew upgrade` ask for your password.
- **Uninstalling.** `brew uninstall` only removes Homebrew's record of the cask. To remove Resolve, double-click **Uninstall Resolve** in `/Applications/DaVinci Resolve`, or run `open "/Applications/DaVinci Resolve/Uninstall Resolve.app"`. The cask leaves out the uninstall step on purpose: Homebrew runs that step before every upgrade, so it would delete Resolve before installing the new version.
- **One method only.** If you update with the script's own `.pkg` route while the cask is installed, Homebrew's recorded version falls behind.
- **Free edition only.** The cask installs the free DaVinci Resolve. It doesn't cover Studio.
- **Version bumps.** A GitHub Action ([`.github/workflows/bump-cask.yml`](.github/workflows/bump-cask.yml)) checks Blackmagic's API every 6 hours and bumps the cask's version, download ID and sha256. It never moves the version backwards. If you run the script right after a release, it can warn `Homebrew's cask isn't on <version> yet`. Try again later.
- **Secrets for the Action (only if you maintain your own copy of the tap).** Blackmagic publishes no checksums, so for each new release the Action downloads the zip once and computes its sha256. That download needs the registration form, which the Action fills from the repository secrets `BMD_FIRSTNAME`, `BMD_LASTNAME`, `BMD_EMAIL`, `BMD_PHONE`, `BMD_COUNTRY`, `BMD_STATE`, `BMD_CITY` and `BMD_STREET`. Without them (when `BMD_FIRSTNAME` or `BMD_EMAIL` is empty), the cask is still bumped, but with `sha256 :no_check`. To recompute the checksum without a version change, run the workflow manually with `rehash` enabled. A fork also has to change the hardcoded tap: `HOMEBREW_TAP` and `HOMEBREW_TAP_URL` in `update-resolve.sh`, and `brew --repo toineenzo/resolve` in the setup message of `lib/blackmagic_download_strategy.rb`, the cask's caveats and this README. GitHub doesn't run scheduled workflows in a fork until you enable Actions there, and it disables them after 60 days without repository activity. Either way the cask silently stops being bumped, and the `isn't on <version> yet` warning never goes away.

#### Switching routes

- **From Homebrew to the script route:** run `brew uninstall --cask toineenzo/resolve/davinci-resolve` (Resolve itself stays installed), then `./update-resolve.sh --reconfigure` and answer `n` to the Homebrew question, or set `homebrew=no` in `.config`. Without the uninstall, the cask stays recorded at a version that falls behind.
- **From the script route to Homebrew:** run `./update-resolve.sh --reconfigure` and answer `y`. The script installs Resolve again through the cask, which means a ~4GB download and your password, even if Resolve is up to date.

## Linux: Arch

The script takes this route when `/etc/os-release` says Arch or Arch-based (`ID` or `ID_LIKE` is `arch`, as on Manjaro and EndeavourOS), or, without a usable `/etc/os-release`, when `pacman` is installed. This route works the same way as upstream. The result is a normal `davinci-resolve` package that pacman and yay track.

Watch the how-to video from the upstream project (click the thumbnail):

[![Watch the video](https://img.youtube.com/vi/Tm3iNIgTRXw/maxresdefault.jpg)](https://www.youtube.com/watch?v=Tm3iNIgTRXw)

### What it does

1. Queries Blackmagic's API for the latest stable Linux version.
2. Compares it with the installed version (`pacman -Q davinci-resolve`).
3. Installs the runtime dependencies, read live from the AUR package.
4. Downloads `DaVinci_Resolve_<version>_Linux.zip` into `build/` and submits the registration form with your saved info.
5. Fetches the latest `davinci-resolve` PKGBUILD from the AUR.
6. Applies two defensive patches to the AUR `prepare()` step when it still contains the known-broken text (see [Troubleshooting](#troubleshooting)). Each patch matches the exact text, so it stops applying once the AUR maintainer changes that line.
7. Sets `pkgver` (and `pkgrel=1`) if the AUR is behind the latest release.
8. Regenerates the checksums with `updpkgsums`.
9. Builds and installs with `makepkg -sric`.
10. Checks that the runtime support directories Resolve needs exist and are writable, and prints the fix if they aren't.
11. Deletes the zip from `build/` when `cleanup_zip=yes`.

It asks for your sudo password, possibly more than once: for the dependencies before the ~4.5GB download, and again when `makepkg` installs the package after the long build. Stay nearby, or extend sudo's timeout.

Launch Resolve with `davinci-resolve` or from your app menu.

### Dependencies

- `base-devel` (`makepkg` needs `fakeroot`, and Arch's default `makepkg.conf` needs `binutils` and `debugedit`). The script doesn't install it: run `sudo pacman -S --needed base-devel git` once, or the first build stops with `Cannot find the fakeroot binary`.
- `curl`, `jq`, `git`
- `makepkg` and `pacman` (included with Arch)
- `updpkgsums` (from `pacman-contrib`)
- `yay` or `paru` (AUR helper), only needed if the AUR package ever adds an AUR-only dependency. None does today.

The script installs `curl`, `jq`, `git` and `pacman-contrib` with pacman if they're missing. If it needs an AUR-only package and finds no AUR helper, it prints how to install `yay`. If a dependency install fails, the script exits. Install that package by hand, then run the script again.

### Runtime dependencies

The script reads the dependency list live from the AUR `davinci-resolve` package on every run, so it always matches the PKGBUILD being built. It installs packages from the official repos with `pacman` and AUR-only packages with your AUR helper. When a package has several providers and none is installed, it picks pacman's default, which may not match your GPU. Install your GPU's OpenCL driver first (for example `opencl-nvidia`, `rocm-opencl-runtime` or `intel-compute-runtime`): an installed provider satisfies `opencl-driver`, so the script won't pick one.

Example snapshot from Resolve 21.1.2-1 (the live list may differ), where every dependency is in the official repos:

| Package | Source |
|---------|--------|
| `glu` | extra |
| `fuse2` | extra |
| `opencl-driver` | extra (multiple providers) |
| `qt5-x11extras` | extra |
| `qt5-svg` | extra |
| `qt5-quickcontrols2` | extra |
| `qt5-multimedia` | extra |
| `libxcrypt-compat` | core |
| `xmlsec` | extra |
| `java-runtime` | extra (multiple providers) |
| `ffmpeg4.4` | extra |
| `gst-plugins-bad-libs` | extra |
| `python-numpy` | extra |
| `tbb` | extra (provided by `onetbb`) |
| `apr-util` | extra |
| `luajit` | extra |
| `libc++` | extra |
| `libc++abi` | extra |

## Linux: other distros

On Linux distros other than Arch, the script runs Blackmagic's own installer. It decides by `ID` and `ID_LIKE` in `/etc/os-release`, so a second package manager doesn't confuse it (Debian can install `pacman`, openSUSE can install `dnf`). Only when `/etc/os-release` matches none of these does it go by which package manager it finds, in this order:

| Found | Distros | Dependency list it reads from Blackmagic's installer |
|---|---|---|
| `apt-get` | Debian, Ubuntu, Linux Mint | `check_ubuntu_package_deps` |
| `dnf` or `yum` | Fedora, Rocky, CentOS Stream, RHEL | `check_centos_package_deps` |
| `zypper` | openSUSE | `check_suse_package_deps` |

What it does:

1. Installs `curl`, `jq` and `unzip` if they're missing.
2. Reads the installed version from `/opt/resolve/docs/Welcome.txt`. Blackmagic's installer doesn't register a package, so this file is the only source.
3. Downloads `DaVinci_Resolve_<version>_Linux.zip` into `build/` and unpacks the `.run` inside it. The `.run` is an AppImage, which the script extracts with `--appimage-extract`, so FUSE isn't needed.
4. Installs the dependencies Blackmagic's installer checks for. It reads the list from that installer's `AppRun`, so the list always matches the version being installed:
   - **apt:** if `apt-get update` fails (for example because of one broken third-party repo), it warns and continues with the cached package lists. Also installs `libgl1`, which the installer needs but leaves off its list. Ubuntu 24.04+ and Debian 13 renamed some libraries with a `t64` suffix, so for each package the script installs the plain name, falls back to `<name>t64`, and skips the package with a warning if neither exists.
   - **dnf/yum:** also installs `libxcrypt-compat` (`libcrypt.so.1`) and `ocl-icd` (`libOpenCL.so.1`), which Resolve links against but the list leaves off. The list is written for CentOS 7, so the script skips names a newer release doesn't ship (`--skip-unavailable` on dnf5, `--setopt=strict=0` on older dnf, `--skip-broken` on yum).
   - **zypper:** also installs `libOpenCL1` (`libOpenCL.so.1`), which the list leaves off. Installs with `--no-recommends`.
   - With an unknown package manager, it warns and leaves the dependencies to you.
5. Runs the installer with `sudo env SKIP_PACKAGE_CHECK=1 AppRun -i -y -a` (no GUI, no questions). The installer's own package check doesn't know the `t64` names and would refuse to run on Ubuntu 24.04+ and Debian 13, so the script skips it. It has already installed that list itself.
6. Checks `/opt/resolve/docs/Welcome.txt` again, because the installer exits 0 even when it fails. If any step after the unzip fails, the unpacked installer in `build/extract` is removed, so it doesn't leave ~13GB behind.
7. Checks the runtime support directories, the same way as on Arch.

It asks for your sudo password, possibly more than once: for missing tools before the download, and again for the dependencies and the installer after the long unpack. Stay nearby, or extend sudo's timeout.

Nothing here installs a GPU compute driver. Install your GPU's CUDA, ROCm or OpenCL driver yourself, or Resolve opens with a GPU error.

Resolve is installed to `/opt/resolve`. Launch it from your app menu or with `/opt/resolve/bin/resolve`. No package manager tracks it, so to remove it, use the uninstaller entry in your app menu if the installer added one. Otherwise run `sudo rm -rf /opt/resolve` and delete the DaVinci Resolve `.desktop` files it added (`grep -l /opt/resolve /usr/share/applications/*.desktop` lists them).

Unpacking needs about 13GB free in `build/` on top of the 4.5GB zip: the 4.5GB `.run` stays until the 8.6GB unpacked installer is complete (measured for 21.1.2). The install in `/opt/resolve` takes another 8.6GB.

**Tested distros.** With Resolve 21.1.2, `tests/test-distros.sh` passes in containers for Ubuntu 22.04, Ubuntu 24.04, Linux Mint 22, Debian 12, Debian 13, Fedora 42, Rocky 9, CentOS Stream 9 and openSUSE Leap 15.6: every library Resolve links against is installed and the version is read correctly (see [Testing](#testing)). A full install with Blackmagic's installer was run on Ubuntu 24.04. Launching the GUI with a real GPU hasn't been tested in containers.

## Automatic update checks (Linux)

The setup question (see [What happens on first run](#what-happens-on-first-run)) creates a systemd user timer and saves the interval as `check_interval`. Configs from before this setting get the question once. To change the interval, run `./update-resolve.sh --reconfigure` and answer the timer question; answering `n` removes the timer.

The timer runs `update-resolve.sh --timer` from where the script is now, with low CPU and I/O priority. It is a user timer, so it only runs while your systemd user instance does, which normally means while you're logged in. A check missed while the computer was off or you were logged out runs the next time you log in. `loginctl enable-linger $USER` keeps it running while you're logged out. Each check is delayed by up to an hour at random. If there is no systemd user session, the script skips the timer with a warning.

- **Arch:** the timer builds new versions in the background and puts them in a local pacman repository, `[resolve-local]`. The packages live in `/var/lib/resolve-local`, and the repo is registered in `/etc/pacman.conf` with `SigLevel = Optional TrustAll` and `Server = file:///var/lib/resolve-local`. A normal `sudo pacman -Syu`, `yay -Syu` or a GUI updater then installs DaVinci Resolve with the rest of your updates, and each new build replaces the previous one in the repo. If you run `./update-resolve.sh` yourself after the timer has built a version, it installs that build with `pacman -U` instead of downloading and building again. Setting this up asks for your password once. The background build can't ask for a password, so if the new version needs packages you don't have, the timer sends `DaVinci Resolve <version> needs packages` and leaves the build to an interactive run.
- **Other distros:** Blackmagic's installer doesn't create a package your package manager could update. The timer only sends a notification that a new version is available, and you then run `./update-resolve.sh`.

The script sends notifications with `notify-send` when it's installed. They also go to the journal. A failed check sends `DaVinci Resolve update failed`. If the API can't be reached (for example right after login), the check is skipped and runs again next time. Only one run happens at a time: while the timer is building, `./update-resolve.sh` stops with `Another update-resolve.sh run is in progress`, and a timer check that finds a manual run in progress skips itself (`.lock` next to the script, needs `flock`, which every systemd distro has).

```bash
systemctl --user list-timers resolve-update.timer   # next check
journalctl --user -u resolve-update                 # what the last checks did
./update-resolve.sh --timer                         # run a check now
```

The unit files are `~/.config/systemd/user/resolve-update.service` and `resolve-update.timer` (or the same files under `$XDG_CONFIG_HOME/systemd/user`). The service runs the script by its absolute path, so if you move the clone, run `./update-resolve.sh --reconfigure` to rewrite the units (this asks all setup questions again).

Answering `never` removes the timer but leaves the `[resolve-local]` repo. To remove the repo too, delete its section from `/etc/pacman.conf` and the `/var/lib/resolve-local` directory.

## Configuration file reference

`.config` lives next to `update-resolve.sh`. It has plain `key=value` lines, which the script reads as text and never runs as shell code. Git ignores the file. On the Homebrew route, the script copies it into the tap as well.

| Key | Platform | Values | Used for |
|---|---|---|---|
| `firstname` | all | text | Registration form |
| `lastname` | all | text | Registration form |
| `email` | all | text | Registration form |
| `phone` | all | digits | Registration form |
| `country` | all | country code, e.g. `us`, `uk`, `de` | Registration form |
| `state` | all | text | Registration form |
| `city` | all | text | Registration form |
| `street` | all | text | Registration form |
| `cleanup_zip` | all | `yes` (default), `no` | Delete the installer zip from `build/` after a successful update. On the Homebrew route, delete Homebrew's cached download instead. |
| `check_interval` | Linux | `daily`, `weekly` (default), `monthly`, `never` | [Automatic update checks](#automatic-update-checks-linux) |
| `homebrew` | macOS | `yes` (default when `brew` is installed), `no` | Install and update through the [Homebrew cask](#homebrew-route) |

To change the interval, run `./update-resolve.sh --reconfigure` and answer the timer question. Editing `check_interval` by hand doesn't change the timer, and `--reconfigure` asks the question again anyway.

## DaVinci Resolve Studio

The script has a `PRODUCT` variable near the top (`PRODUCT="davinci-resolve"`), but Studio is not supported or tested:

- The download is always saved as `DaVinci_Resolve_<version>_<Linux|Mac>.zip`, and the registration request names the free product.
- On Arch, the AUR `davinci-resolve-studio` PKGBUILD expects `DaVinci_Resolve_Studio_<version>_Linux.zip`, so `updpkgsums`/`makepkg` won't find the source.
- On macOS the Homebrew route ignores `PRODUCT`; the cask is free-only.

If you experiment with it anyway: on macOS also set `homebrew=no`. Editing the tracked script makes `git pull` fail with `Your local changes would be overwritten`; use `git stash && git pull && git stash pop` to keep your edit.

## How it works

1. The latest version comes from `https://www.blackmagicdesign.com/api/support/latest-stable-version/<product>/<linux|mac>`, which also returns a download ID.
2. Blackmagic only gives out a download URL after a registration POST to `https://www.blackmagicdesign.com/api/register/us/download/<downloadId>`. This is the same request their download page sends. The script sends your saved registration info there and gets back a signed, short-lived URL.
3. The zip downloads to `build/<name>.zip.part` and is renamed when complete, so an interrupted download is never taken for a finished one. A finished zip already in `build/` is reused unless you pass `--force`.

Your registration info goes only to Blackmagic and is never sent anywhere else. The Homebrew download strategy makes the same request at download time.

## Troubleshooting

### Arch: build aborts in `prepare()` with `rm: cannot remove ...libglib-2.0.so.0.6800.4`

The AUR PKGBUILD removes Resolve's bundled glib before symlinking to your system copies, but it names those files with a hardcoded version suffix. Blackmagic changes the bundled glib version between Resolve releases (2.68 in 20.x, 2.82 in 21.1), so the filename goes stale and the build aborts.

The script detects this and patches it automatically (`Patching known-fragile AUR prepare() step`, see step 6 under [What it does](#what-it-does)).

### Arch: build aborts with `cannot normalize PT_NOTE segment` (patchelf)

Resolve 21.1.2 started bundling CEF. `patchelf` can't rewrite its `chrome-sandbox` binary, and the AUR `prepare()` runs `patchelf --set-rpath` on every file. The script patches that loop to skip `chrome-sandbox` (`Patching AUR prepare() to skip patchelf on chrome-sandbox`). This is safe because `chrome-sandbox` only links libc and libpthread.

### Resolve installs but won't launch: `Failed to create application support directories`

Resolve creates support directories under `/opt/resolve` on first launch, but root owns that path, so creating them fails. The app then exits before it can even write a log. Resolve 21.1 added `Immersive/`. The AUR package creates it owned by root (and Blackmagic's installer may not create it at all), so Resolve can't write there. This applies to every Linux route.

```bash
sudo mkdir -p /opt/resolve/Immersive
sudo chown "$(id -un):$(id -gn)" /opt/resolve/Immersive
```

The script warns about known cases after install. Blackmagic adds to this set across releases, so a future version may need a directory not on that list. Find it with (use `/opt/resolve/bin/resolve` instead of `davinci-resolve` on non-Arch distros):

```bash
strace -f -e trace=mkdir,mkdirat davinci-resolve 2>&1 | grep -E 'EACCES|EPERM'
```

### Arch: install fails with `exists in filesystem`

pacman refuses to overwrite files it doesn't own. This happens if Resolve was ever installed outside pacman, for example with Blackmagic's own `.run` installer. Confirm the files are unowned, then let pacman take them over:

```bash
pacman -Qo /opt/resolve/libs/<file>          # "No package owns" = safe to overwrite
sudo pacman -U --overwrite '/opt/resolve/libs/<pattern>' <built-package>.pkg.tar.zst
```

### `Registration setup needs a terminal`

The script needs registration info but there's no terminal to ask in (cron, the timer, piped input). Run `./update-resolve.sh` once interactively first. The timer prints `No <path>/.config; run update-resolve.sh once interactively first` for the same reason.

### `Failed to get download URL`

Blackmagic rejected the registration POST. Check the fields in `.config` (all eight are required, phone as digits only), or enter them again with `./update-resolve.sh --reconfigure`.

### Other distros: `Installer finished, but /opt/resolve reports version X instead of Y`

Blackmagic's installer exits 0 even when it fails, so the script checks `/opt/resolve/docs/Welcome.txt` afterwards. Scroll up to the installer's own output for the cause, which is often a missing dependency. On Debian/Ubuntu/Mint, lines like `No package <name> (or <name>t64) on this release, skipping` show which packages from Blackmagic's list your release doesn't have. On dnf/yum/zypper, check the package manager's own output for skipped packages.

### Other distros: `Unknown package manager`

No `apt-get`, `dnf`, `yum` or `zypper` was found. Install `curl`, `jq` and `unzip` yourself, and install Resolve's dependencies by hand if it won't start.

### Arch: the timer reports `DaVinci Resolve <version> needs packages` or `DaVinci Resolve update failed`

The background build can't ask for your password. When the new version needs packages that aren't installed (for example `patchelf`, which `makepkg -sric` removes again after an interactive build, or a dependency the AUR package added), the timer checks this before building and sends `needs packages` with the list. Other failures, such as a missing script tool, send `update failed`. In both cases, run `./update-resolve.sh` once interactively; `journalctl --user -u resolve-update` shows what happened.

### Linux: `No systemd user session here; skipping the automatic update check`

The timer needs a systemd user session (`systemctl --user`). Without one, for example in a container or over some SSH setups, the script skips it. Updating by hand still works.

### macOS: `Missing dependency: jq`

`jq` is built in from macOS 15. On older versions, install it with `brew install jq`.

### macOS (Homebrew): `No registration info at ...` or `... is missing ...`

The cask's download step found no `.config` in the tap, or the file lacks some fields. Run:

```bash
"$(brew --repo toineenzo/resolve)/update-resolve.sh" --reconfigure --check-only
```

`Blackmagic download API refused the request` means the saved info was rejected. Fix it with the same command.

### macOS (Homebrew): `Homebrew's cask isn't on <version> yet`

Blackmagic released a version the cask doesn't have yet. The GitHub Action bumps the cask within 6 hours. Run `brew update` and try again later.

## Testing

| Script | Checks | Platform | Needs |
|---|---|---|---|
| `tests/test-checksums.sh` | `setup_pkgbuild` leaves a PKGBUILD whose checksums `makepkg --verifysource` accepts, for the AUR's version and for a newer one (`pkgver` rewrite). A failing `updpkgsums` must stop the build. Uses a fake zip. | Arch | Network access to the AUR, `makepkg`, `updpkgsums`. No download, build or sudo. About 30 seconds. |
| `tests/test-cleanup.sh` | The `cleanup_zip` question is asked once for old configs, saved, reused, defaults to yes, and `cleanup_zip` keeps or deletes the zip accordingly | any | `jq`. No network or sudo. |
| `tests/test-homebrew-setup.sh` | The Homebrew question (`y`/`Y`/Enter means yes, `n`/`N` means no), no terminal means `no`, no `brew` means `no` without asking, and old configs get `homebrew=no` once | macOS | A fake `brew` is used. No brew commands run. |
| `tests/test-mac-install.sh` | `install_mac_pkg` finds the `.dmg` inside the zip and the `.pkg` inside that `.dmg`, and passes it to `installer` | macOS | `hdiutil`. `sudo` is replaced with a stub, so nothing is installed. |
| `tests/test-distros.sh` | In one container per distro: `install_run_dependencies` installs Blackmagic's list, `ldd` finds every library `resolve` links against, and the version is read from `Welcome.txt` | Docker host | Docker and an unpacked installer (`squashfs-root`) |
| `tests/test-timer.sh` | 29 checks in an Arch container: the interval prompt, the systemd units (`systemd-analyze verify`), the `[resolve-local]` repo (sync and files databases), publishing a dummy package, installing it from `[resolve-local]`, upgrading it with `pacman -Syu`, `run_timer` results (up to date, already built, offline), missing build dependencies, the run lock, ignoring a package file without a database entry, and a manual run installing the timer's build instead of downloading | Docker host | Docker. Pulls `archlinux:latest` (amd64). A few minutes. |

```bash
./tests/test-checksums.sh
./tests/test-cleanup.sh
./tests/test-homebrew-setup.sh
./tests/test-mac-install.sh
./tests/test-timer.sh

# test-distros.sh needs an unpacked installer:
unzip DaVinci_Resolve_*_Linux.zip && ./DaVinci_Resolve_*_Linux.run --appimage-extract
./tests/test-distros.sh /path/to/squashfs-root [image ...]
```

Without image arguments, `test-distros.sh` runs `ubuntu:22.04`, `ubuntu:24.04`, `linuxmintd/mint22-amd64`, `debian:12`, `debian:13`, `fedora:42`, `rockylinux/rockylinux:9`, `quay.io/centos/centos:stream9` and `opensuse/leap:15.6`. Instead of a path, `squashfs-root` can be a Docker volume given as `volume[:subdir]`.

## Versioning

Versions are date-based: `YYYY.MM.N`, for example `2026.10.0`, then `2026.10.1` for a second release in the same month. The version lives in `SCRIPT_VERSION` at the top of the script, in the line at the top of this README, and in a matching GitHub release and tag.

- A release is cut when users would notice a change (a bug fix or a feature), after it has passed the checks below. Docs-only changes don't get one. Fixes made close together ship as one release with a short changelog.
- "Tested with DaVinci Resolve" only changes after a full update on that Resolve version.
- `main` is what users get from `git pull`, and the Homebrew tap reads from it too, so nothing is pushed until it passes the checks for the platforms it touches:
  1. All platforms: `./tests/test-cleanup.sh`.
  2. Arch: `./tests/test-checksums.sh` and `./tests/test-timer.sh`, then a full update on a real Arch machine (`./update-resolve.sh --force` rebuilds even when you're current). Also do a full run on a clean Arch install when the change touches dependency setup.
  3. Other distros: `./tests/test-distros.sh`, then a full update on at least one real or container install.
  4. macOS: `./tests/test-mac-install.sh` and `./tests/test-homebrew-setup.sh`, then a full update through the script route, and through `brew upgrade` when the cask or `lib/` changes.

## License

MIT, see [LICENSE](LICENSE).
