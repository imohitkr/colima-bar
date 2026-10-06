#!/bin/bash
# Installs or updates ColimaBar from the latest GitHub release.
#
#   curl -fsSL https://raw.githubusercontent.com/imohitkr/colima-bar/main/scripts/install.sh | bash
#
# Set COLIMABAR_VERSION=v0.4.0 to install a specific release.
# curl does not mark its downloads as quarantined, so macOS opens the app
# without the Gatekeeper prompt that a browser download gets.
set -euo pipefail

# Everything runs inside main, so a partly downloaded script does nothing.
main() {
  local repo="imohitkr/colima-bar"
  local version="${COLIMABAR_VERSION:-}"
  local url
  if [ -n "$version" ]; then
    url="https://github.com/$repo/releases/download/$version/ColimaBar.zip"
  else
    url="https://github.com/$repo/releases/latest/download/ColimaBar.zip"
  fi

  [ "$(uname -s)" = Darwin ] || { echo "ColimaBar runs on macOS only." >&2; exit 1; }
  # uname -m says x86_64 under Rosetta; this sysctl is 1 on any Apple silicon Mac.
  [ "$(sysctl -n hw.optional.arm64 2>/dev/null)" = 1 ] || {
    echo "ColimaBar needs a Mac with Apple silicon." >&2
    exit 1
  }
  local major
  major=$(sw_vers -productVersion | cut -d. -f1)
  [ "$major" -ge 14 ] || { echo "ColimaBar needs macOS 14 or later." >&2; exit 1; }

  # Replace an existing copy where it is. Otherwise use /Applications if we
  # can write to it, else ~/Applications.
  local dest
  if [ -d /Applications/ColimaBar.app ]; then
    dest=/Applications
  elif [ -d "$HOME/Applications/ColimaBar.app" ]; then
    dest="$HOME/Applications"
  elif [ -w /Applications ]; then
    dest=/Applications
  else
    dest="$HOME/Applications"
  fi
  [ -w "$dest" ] || [ ! -e "$dest" ] || {
    echo "Cannot write to $dest. Remove $dest/ColimaBar.app or fix its permissions, then run again." >&2
    exit 1
  }

  # Global, not local: the EXIT trap runs after main returns.
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT

  echo "Downloading $url"
  curl -fL --progress-bar -o "$tmp/ColimaBar.zip" "$url"
  ditto -x -k "$tmp/ColimaBar.zip" "$tmp"
  [ -d "$tmp/ColimaBar.app" ] || { echo "The download does not contain ColimaBar.app." >&2; exit 1; }
  codesign --verify --deep "$tmp/ColimaBar.app" 2>/dev/null || {
    echo "The downloaded app has an invalid signature. Stopping." >&2
    exit 1
  }
  xattr -dr com.apple.quarantine "$tmp/ColimaBar.app" 2>/dev/null || true

  if pgrep -xq ColimaBar; then
    echo "Quitting the running ColimaBar"
    osascript -e 'quit app "ColimaBar"' >/dev/null 2>&1 || true
    local i
    for i in $(seq 1 20); do
      pgrep -xq ColimaBar || break
      sleep 0.5
    done
  fi

  mkdir -p "$dest"
  rm -rf "$dest/ColimaBar.app"
  ditto "$tmp/ColimaBar.app" "$dest/ColimaBar.app"
  echo "Installed $dest/ColimaBar.app"

  if ! command -v colima >/dev/null 2>&1 && [ ! -x /opt/homebrew/bin/colima ] && [ ! -x /usr/local/bin/colima ]; then
    echo "Colima is not installed. To install it, run: brew install colima docker"
  fi

  open "$dest/ColimaBar.app"
  echo "ColimaBar is running. Look for the box icon in the menu bar."
}

main "$@"
