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
# The installer also compares the SHA-256 digest of the download with the digest
# that the GitHub API lists for the release file. If the API does not answer,
# it prints a notice and continues.
# curl does not mark its downloads as quarantined, so macOS opens the app
# without the Gatekeeper prompt that a browser download gets.
set -euo pipefail

# BEGIN helpers: functions only. Tests source this block.

# Succeeds if $1 is a link to the command of a ColimaBar app: its target ends
# in /ColimaBar.app/Contents/Resources/bin/colimabar. The installer changes
# no other file.
is_own_link() {
  local target
  [ -L "$1" ] || return 1
  target=$(readlink "$1") || return 1
  case "$target" in
    */ColimaBar.app/Contents/Resources/bin/colimabar) return 0 ;;
    *) return 1 ;;
  esac
}

# Succeeds if $1 is a folder in PATH.
on_path() {
  case ":$PATH:" in
    *":$1:"*) return 0 ;;
    *) return 1 ;;
  esac
}

# Prints the first of ~/.local/bin and ~/bin that exists, that the user can
# write to and that is in PATH. Prints nothing if there is none.
command_dir() {
  local d
  for d in "$HOME/.local/bin" "$HOME/bin"; do
    if [ -d "$d" ] && [ -w "$d" ] && on_path "$d"; then
      echo "$d"
      return 0
    fi
  done
  return 0
}

# link_command WRAPPER -> links the colimabar command to WRAPPER, the command
# in the app. It never asks and never uses sudo. It leaves a colimabar that
# is not a link of ColimaBar alone, and a link that works already.
link_command() {
  local wrapper=$1 found dir
  [ -x "$wrapper" ] || return 0
  found=$(command -v colimabar 2>/dev/null || true)
  if [ -n "$found" ]; then
    if is_own_link "$found"; then
      echo "The colimabar command is linked: $found"
    else
      echo "Notice: $found is not a link of ColimaBar. The installer left it."
    fi
    return 0
  fi
  dir=$(command_dir)
  if [ -n "$dir" ]; then
    if [ -e "$dir/colimabar" ] || [ -L "$dir/colimabar" ]; then
      if ! is_own_link "$dir/colimabar"; then
        echo "Notice: $dir/colimabar is not a link of ColimaBar. The installer left it."
        return 0
      fi
    fi
    if ln -sfn "$wrapper" "$dir/colimabar"; then
      echo "Linked the colimabar command: $dir/colimabar"
    else
      echo "Could not link $dir/colimabar."
    fi
    return 0
  fi
  echo "To use the colimabar command, run: sudo ln -sf '$wrapper' /usr/local/bin/colimabar"
}

# app_pids -> prints the PID of each ColimaBar app of this user. The
# `colimabar` command runs the same binary with --cli. It is not the app: do
# not wait for it and do not stop it.
app_pids() {
  local pid args
  for pid in $(pgrep -U "$(id -u)" -x ColimaBar 2>/dev/null); do
    args=$(ps -o command= -p "$pid" 2>/dev/null) || continue
    case " $args" in *" --cli"*) continue ;; esac
    echo "$pid"
  done
  return 0
}

# app_running -> succeeds if a ColimaBar app of this user runs.
app_running() {
  [ -n "$(app_pids)" ]
}

# term_app -> sends SIGTERM to each ColimaBar app of this user.
term_app() {
  local pid
  for pid in $(app_pids); do
    kill -TERM "$pid" 2>/dev/null
  done
  return 0
}

# END helpers

wait_for_exit() {
  for _ in $(seq 1 20); do
    app_running || return 0
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

# Prints the SHA-256 digest (64 hex digits) that the release JSON file $1 lists
# for the asset ColimaBar.zip. Prints nothing if the file has no such asset.
listed_digest() {
  local i name digest
  for i in $(seq 0 49); do
    name=$(plutil -extract "assets.$i.name" raw -o - "$1" 2>/dev/null) || return 0
    if [ "$name" = ColimaBar.zip ]; then
      digest=$(plutil -extract "assets.$i.digest" raw -o - "$1" 2>/dev/null) || return 0
      if [[ "$digest" =~ ^sha256:([0-9a-fA-F]{64})$ ]]; then
        echo "${BASH_REMATCH[1]}" | tr '[:upper:]' '[:lower:]'
      fi
      return 0
    fi
  done
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

  # The API lists a SHA-256 digest for each asset of a release. The digest
  # shows that the download is whole and is the file that GitHub stores.
  # It does not show who built the file (see the attestation check below).
  if curl --proto '=https' --tlsv1.2 -fsS -H 'Accept: application/vnd.github+json' \
    -o "$tmp/release.json" "https://api.github.com/repos/$repo/releases/tags/$version" 2>/dev/null; then
    local want have
    want=$(listed_digest "$tmp/release.json")
    have=$(shasum -a 256 "$tmp/ColimaBar.zip" | cut -d ' ' -f 1)
    if [ -z "$want" ]; then
      echo "Did not check the SHA-256 digest (the release lists none for ColimaBar.zip)."
    elif [ "$want" != "$have" ]; then
      echo "The download does not match the SHA-256 digest that GitHub lists for it. Stopping." >&2
      exit 1
    else
      echo "The SHA-256 digest matches the one that GitHub lists."
    fi
  else
    echo "Did not check the SHA-256 digest (the GitHub API did not answer)."
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
  # The requirement checks that the code identifier is the one of ColimaBar.
  codesign --verify --deep --strict -R '=identifier "com.imohitkr.ColimaBar"' "$tmp/ColimaBar.app" || {
    echo "The downloaded app is damaged or is not ColimaBar (invalid signature). Stopping." >&2
    exit 1
  }
  local app_version
  app_version=$(plutil -extract CFBundleShortVersionString raw -o - "$tmp/ColimaBar.app/Contents/Info.plist" 2>/dev/null) || app_version=""
  if [ "$app_version" != "${version#v}" ]; then
    echo "The downloaded app has version ${app_version:-unknown}, not ${version#v}. Stopping." >&2
    exit 1
  fi
  xattr -dr com.apple.quarantine "$tmp/ColimaBar.app" 2>/dev/null || true

  if app_running; then
    echo "Quitting the running ColimaBar"
    osascript -e 'quit app "ColimaBar"' >/dev/null 2>&1 || true
    wait_for_exit
    # The Apple event can fail (Automation permission, an open alert).
    # ColimaBar also quits cleanly on SIGTERM, so launchd does not relaunch it.
    if app_running; then
      term_app
      wait_for_exit
    fi
    if app_running; then
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

  if [ -d /opt/homebrew/Caskroom/colima-bar ] || [ -d /usr/local/Caskroom/colima-bar ]; then
    echo "Notice: Homebrew also has ColimaBar. Its next upgrade replaces this copy. To use Homebrew only, run: brew upgrade --cask colima-bar"
  fi

  mkdir -p "$dest"
  rm -rf "$dest/ColimaBar.app"
  ditto "$tmp/ColimaBar.app" "$dest/ColimaBar.app"
  echo "Installed $dest/ColimaBar.app"
  link_command "$dest/ColimaBar.app/Contents/Resources/bin/colimabar"

  if ! command -v colima >/dev/null 2>&1 && [ ! -x /opt/homebrew/bin/colima ] && [ ! -x /usr/local/bin/colima ]; then
    echo "Colima is not installed. To install it, run: brew install colima docker"
  fi

  open "$dest/ColimaBar.app"
  echo "ColimaBar is running. Look for the box icon in the menu bar."
}

main "$@"
