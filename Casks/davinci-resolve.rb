require_relative "../lib/blackmagic_download_strategy"

cask "davinci-resolve" do
  # Bumped automatically by .github/workflows/bump-cask.yml from Blackmagic's API
  version "21.1.2"
  sha256 :no_check # every signed download URL is unique; Blackmagic publishes no checksum

  url "https://www.blackmagicdesign.com/api/register/us/download/cef11ad119494da5a908b9a05b332cc7",
      using: BlackmagicDownloadStrategy
  name "DaVinci Resolve"
  desc "Video editing, colour grading, VFX and audio post-production (free edition)"
  homepage "https://www.blackmagicdesign.com/products/davinciresolve"

  # The zip holds a .dmg that wraps the .pkg; names vary between releases, so find them
  installer script: {
    executable: "/bin/bash",
    args:       ["-c", <<~BASH, "install-resolve", staged_path.to_s],
      set -euo pipefail
      dmg=$(/usr/bin/find "$1" -name '*.dmg' -not -path '*/__MACOSX/*' -print -quit)
      [[ -n "$dmg" ]] || { echo "No .dmg found in $1" >&2; exit 1; }
      mnt=$(/usr/bin/mktemp -d /private/tmp/resolve-mount.XXXXXX)
      if /usr/sbin/diskutil image &> /dev/null; then # hdiutil attach is deprecated on newer macOS
        /usr/sbin/diskutil image attach --readOnly --nobrowse --mountPoint "$mnt" "$dmg" > /dev/null
      else
        /usr/bin/hdiutil attach -nobrowse -readonly -mountpoint "$mnt" "$dmg" > /dev/null
      fi
      trap '/usr/bin/hdiutil detach "$mnt" -force > /dev/null 2>&1 || true' EXIT
      pkg=$(/usr/bin/find "$mnt" -maxdepth 2 -name '*.pkg' -print -quit)
      [[ -n "$pkg" ]] || { echo "No .pkg found in $dmg" >&2; exit 1; }
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
      /Applications/DaVinci Resolve/Uninstall Resolve.app
  EOS
end
