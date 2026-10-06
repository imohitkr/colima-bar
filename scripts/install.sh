#!/bin/bash
# Installs or updates ColimaBar from the latest GitHub release.
#
#   curl -fsSL https://raw.githubusercontent.com/imohitkr/colima-bar/main/scripts/install.sh | bash
#
# Set COLIMABAR_VERSION=v0.4.0 to install a specific release (v0.4.0 or later).
# If gh 2.68 or later is installed and logged in to github.com, the installer
# verifies the download and stops when the check fails. If gh cannot verify the download,
# the installer prints a notice and continues. Set COLIMABAR_REQUIRE_VERIFY=1
# to stop in that case too.
# curl does not mark its downloads as quarantined, so macOS opens the app
# without the Gatekeeper prompt that a browser download gets.
set -euo pipefail

wait_for_exit() {
  for _ in $(seq 1 20); do
    pgrep -U "$(id -u)" -xq ColimaBar || return 0
    sleep 0.5
  done
}

# Prints the X.Y.Z version from "gh version X.Y.Z (date)", the first line
# of gh --version. Prints nothing if that line has another format.
gh_version() {
  local first
  first=$(gh --version 2>/dev/null | head -n 1) || return 0
  if [[ "$first" =~ ^gh\ version\ v?([0-9]+\.[0-9]+\.[0-9]+) ]]; then
    echo "${BASH_REMATCH[1]}"
  fi
}

# Succeeds if version $1 is $2 or later. Both have the form X.Y.Z.
# Compares each part as a number, so 2.100.0 is later than 2.68.0.
version_at_least() {
  local a1 a2 a3 b1 b2 b3
  IFS=. read -r a1 a2 a3 <<<"$1"
  IFS=. read -r b1 b2 b3 <<<"$2"
  (( 10#$a1 != 10#$b1 )) && { (( 10#$a1 > 10#$b1 )); return; }
  (( 10#$a2 != 10#$b2 )) && { (( 10#$a2 > 10#$b2 )); return; }
  (( 10#$a3 >= 10#$b3 ))
}

# Everything runs inside main, so a partly downloaded script does nothing.
main() {
  local repo="imohitkr/colima-bar"
  local requested="${COLIMABAR_VERSION:-}"
  local version="$requested"
  local none_yet="No release with ColimaBar.zip found yet. See https://github.com/$repo/releases."
  if [ -n "$version" ] && ! [[ "$version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "COLIMABAR_VERSION must look like v0.4.0, not: $version" >&2
    exit 1
  fi
  # Without COLIMABAR_VERSION, find the tag of the latest release first. The
  # download and the attestation check then both use that one tag.
  if [ -z "$version" ]; then
    local latest
    latest=$(curl --proto '=https' --tlsv1.2 -fsS -o /dev/null -w '%{redirect_url}' \
      "https://github.com/$repo/releases/latest") || latest=""
    version="${latest##*/}"
    if ! [[ "$version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      echo "$none_yet" >&2
      exit 1
    fi
  fi
  # Releases before v0.4.0 do not have ColimaBar.zip.
  local vmajor vminor
  IFS=. read -r vmajor vminor _ <<<"${version#v}"
  if (( 10#$vmajor == 0 && 10#$vminor < 4 )); then
    if [ -z "$requested" ]; then
      echo "$none_yet" >&2
    else
      echo "The installer supports v0.4.0 and later, not $version. Download older releases from https://github.com/$repo/releases." >&2
    fi
    exit 1
  fi
  local url="https://github.com/$repo/releases/download/$version/ColimaBar.zip"

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
  # No -f: the HTTP status lets us explain a missing release file.
  local status
  status=$(curl --proto '=https' --tlsv1.2 -L --progress-bar -w '%{http_code}' -o "$tmp/ColimaBar.zip" "$url") || {
    echo "The download failed. Check your network connection, then run again." >&2
    exit 1
  }
  if [ "$status" = 404 ] && [ -z "$requested" ]; then
    echo "$none_yet" >&2
    exit 1
  elif [ "$status" = 404 ]; then
    echo "Release $version has no ColimaBar.zip. See https://github.com/$repo/releases." >&2
    exit 1
  elif [ "$status" != 200 ]; then
    echo "The download failed with HTTP status $status. Try again later." >&2
    exit 1
  fi

  # CI attaches a build provenance attestation to each release file. It
  # proves that the release workflow (ci.yml) of this repo built the file on
  # a GitHub-hosted runner, from the requested tag when one is set.
  local workflow="$repo/.github/workflows/ci.yml"
  local verify=(gh attestation verify "$tmp/ColimaBar.zip" --hostname github.com
    --repo "$repo" --signer-workflow "$workflow" --deny-self-hosted-runners
    --source-ref "refs/tags/$version")
  # gh 2.68 is the first version that has all these flags. With an older gh,
  # verify fails on an unknown flag, which looks like a bad download.
  local skip="" ghv=""
  command -v gh >/dev/null 2>&1 && ghv=$(gh_version)
  if ! command -v gh >/dev/null 2>&1; then
    skip="gh is not installed"
  elif [ -z "$ghv" ]; then
    skip="cannot read the gh version; gh 2.68 or later is needed"
  elif ! version_at_least "$ghv" 2.68.0; then
    skip="gh $ghv is too old; gh 2.68 or later is needed"
  elif ! gh auth status --hostname github.com >/dev/null 2>&1; then
    skip="gh is not logged in to github.com"
  fi
  if [ -z "$skip" ]; then
    echo "Verifying the download with gh attestation verify"
    "${verify[@]}" >/dev/null || {
      echo "The download does not match a build from $repo. Stopping." >&2
      exit 1
    }
  else
    echo "Did not verify the download ($skip)."
    echo "To verify it, download $url and run: gh attestation verify ColimaBar.zip --repo $repo --signer-workflow $workflow"
    if [ "${COLIMABAR_REQUIRE_VERIFY:-}" = 1 ]; then
      echo "COLIMABAR_REQUIRE_VERIFY=1 is set. Stopping." >&2
      exit 1
    fi
  fi

  ditto -x -k "$tmp/ColimaBar.zip" "$tmp"
  [ -d "$tmp/ColimaBar.app" ] || { echo "The download does not contain ColimaBar.app." >&2; exit 1; }
  # Corruption check only. The ad-hoc signature does not prove who built the app.
  codesign --verify --deep "$tmp/ColimaBar.app" 2>/dev/null || {
    echo "The downloaded app is damaged (invalid signature). Stopping." >&2
    exit 1
  }
  xattr -dr com.apple.quarantine "$tmp/ColimaBar.app" 2>/dev/null || true

  if pgrep -U "$(id -u)" -xq ColimaBar; then
    echo "Quitting the running ColimaBar"
    osascript -e 'quit app "ColimaBar"' >/dev/null 2>&1 || true
    wait_for_exit
    # The Apple event can fail (Automation permission, an open alert).
    # ColimaBar also quits cleanly on SIGTERM, so launchd does not relaunch it.
    if pgrep -U "$(id -u)" -xq ColimaBar; then
      pkill -U "$(id -u)" -TERM -x ColimaBar 2>/dev/null || true
      wait_for_exit
    fi
    if pgrep -U "$(id -u)" -xq ColimaBar; then
      echo "ColimaBar is still running. Quit it from its menu, then run the installer again." >&2
      exit 1
    fi
  fi

  # Keep one copy only. A second copy could take over the login item.
  local other=/Applications/ColimaBar.app
  [ "$dest" = /Applications ] && other="$HOME/Applications/ColimaBar.app"
  if [ -d "$other" ]; then
    echo "Removing the other copy at $other"
    rm -rf "$other" || echo "Could not remove $other. Delete it by hand." >&2
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
