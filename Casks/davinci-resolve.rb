require_relative "../lib/blackmagic_download_strategy"

cask "davinci-resolve" do
  # Bumped automatically by .github/workflows/bump-cask.yml from Blackmagic's API.
  # Blackmagic publishes no checksum; the workflow downloads each release once to compute it.
  version "21.1.2"
  sha256 "ddfd42ad960c32254752b5e68bc9e3021820ca2200a53a99c38848e110aa32f0"

  url "https://www.blackmagicdesign.com/api/register/us/download/cef11ad119494da5a908b9a05b332cc7",
      using: BlackmagicDownloadStrategy
  name "DaVinci Resolve"
  desc "Video editing, colour grading, VFX and audio post-production (free edition)"
  homepage "https://www.blackmagicdesign.com/products/davinciresolve"

  # The zip holds a .dmg wrapping the .pkg. Homebrew unpacks that nested .dmg itself, so the
  # .pkg is already in staged_path; its name varies between releases, so find it.
  installer script: {
    executable: "/bin/bash",
    args:       ["-c", <<~BASH, "install-resolve", staged_path.to_s],
      set -euo pipefail
      pkg=$(/usr/bin/find "$1" -maxdepth 2 -name '*.pkg' -print -quit)
      [[ -n "$pkg" ]] || { echo "No .pkg found in $1" >&2; exit 1; }
      /usr/sbin/installer -pkg "$pkg" -target /
    BASH
    sudo:       true,
  }

  # Deliberately no `uninstall` stanza (so `brew audit --strict` complains): Homebrew runs it
  # on every `brew upgrade` before installing the new pkg, so `uninstall pkgutil:` would delete
  # Resolve first, unrecoverably if the new install then fails. Without it, upgrades are the
  # same in-place pkg upgrade Blackmagic's installer does.

  caveats <<~EOS
    The download uses the registration info saved by update-resolve.sh.
    Set it up once with:
      "$(brew --repo toineenzo/resolve)/update-resolve.sh" --reconfigure --check-only

    `brew uninstall` only forgets the cask. To remove Resolve itself, run
      open "/Applications/DaVinci Resolve/Uninstall Resolve.app"
  EOS
end
