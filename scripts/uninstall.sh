#!/bin/bash
# Removes ColimaBar and points every docker client straight back at Colima.
set -uo pipefail

STABLE="$HOME/.cache/colima-bar/docker.sock"
PROFILES_DIR="$HOME/.cache/colima-bar/profiles"

# BEGIN helpers: functions only. Tests source this block.

# colimabar_contexts -> the names of the colimabar-PROFILE docker contexts
# that ColimaBar made: their description starts with "ColimaBar". This is the
# rule of ProfileContexts.isOurs. Other contexts stay.
colimabar_contexts() {
  local name desc
  docker context ls --format '{{.Name}}\t{{.Description}}' 2>/dev/null \
    | while IFS=$'\t' read -r name desc; do
        case "$name" in colimabar-?*) ;; *) continue ;; esac
        case "$desc" in ColimaBar*) echo "$name" ;; esac
      done
  return 0
}

# colima_dir -> the Colima config folder, with the rules of Colima 0.10.3
# (config/files.go) and colima-ctl.sh: COLIMA_HOME if that path exists,
# ~/.colima if it exists, else ~/.config/colima. ColimaBar pins
# XDG_CONFIG_HOME to ~/.config, so the XDG_CONFIG_HOME of this shell does not count.
colima_dir() {
  if [ -n "${COLIMA_HOME:-}" ] && [ -e "$COLIMA_HOME" ]; then
    echo "$COLIMA_HOME"
  elif [ -e "$HOME/.colima" ]; then
    echo "$HOME/.colima"
  else
    echo "$HOME/.config/colima"
  fi
}

# profile_socket_names -> the profiles that have a socket in PROFILES_DIR:
# "work" for work.sock. It skips other files and invalid names.
profile_socket_names() {
  local f n
  for f in "$PROFILES_DIR"/*.sock; do
    [ -e "$f" ] || [ -L "$f" ] || continue
    n=${f##*/}
    n=${n%.sock}
    case "$n" in *[!A-Za-z0-9._-]*|.*|"") continue ;; esac
    echo "$n"
  done
}

# link_profile_sockets NAME... -> makes each PROFILES_DIR/NAME.sock a symlink
# to the Colima socket of that profile, like the stable path.
link_profile_sockets() {
  local n dir
  [ "$#" -gt 0 ] || return 0
  dir=$(colima_dir)
  (umask 077 && mkdir -p "$PROFILES_DIR") || return 1
  for n in "$@"; do
    ln -sfn "$dir/$n/docker.sock" "$PROFILES_DIR/$n.sock"
  done
}

# END helpers

COLIMA_SOCK="$(colima_dir)/default/docker.sock"

wait_for_exit() {
  for _ in $(seq 1 20); do
    pgrep -U "$(id -u)" -xq ColimaBar || return 0
    sleep 0.5
  done
}

# Stop ColimaBar before you delete it. A running copy recreates the colimabar
# context and the launchd DOCKER_HOST when the VM starts again.
if pgrep -U "$(id -u)" -xq ColimaBar; then
  echo "Quitting the running ColimaBar"
  osascript -e 'quit app "ColimaBar"' >/dev/null 2>&1
  wait_for_exit
fi
# Bootout also stops a copy that launchd runs.
launchctl bootout "gui/$(id -u)/com.imohitkr.ColimaBar.agent" 2>/dev/null
launchctl bootout "gui/$(id -u)/com.imohitkr.ColimaBar.login" 2>/dev/null
# The Apple event can fail (Automation permission, an open alert).
# ColimaBar also quits cleanly on SIGTERM.
if pgrep -U "$(id -u)" -xq ColimaBar; then
  pkill -U "$(id -u)" -TERM -x ColimaBar 2>/dev/null
  wait_for_exit
fi
if pgrep -U "$(id -u)" -xq ColimaBar; then
  echo "ColimaBar is still running. Quit it from its menu, then run this script again." >&2
  exit 1
fi
rm -f ~/Library/LaunchAgents/com.imohitkr.ColimaBar.login.plist

# docker contexts: colimabar and each colimabar-PROFILE of ColimaBar, launchd env, testcontainers
# Docker context names have no spaces.
# shellcheck disable=SC2207
OUR_CONTEXTS=(colimabar $(colimabar_contexts))
CURRENT_CONTEXT=$(docker context show 2>/dev/null)
for ctx in "${OUR_CONTEXTS[@]}"; do
  if [ "$ctx" = "$CURRENT_CONTEXT" ]; then
    docker context use colima >/dev/null 2>&1 || docker context use default >/dev/null 2>&1
    break
  fi
done
for ctx in "${OUR_CONTEXTS[@]}"; do
  docker context rm -f "$ctx" >/dev/null 2>&1
done
if [ "$(launchctl getenv DOCKER_HOST)" = "unix://$STABLE" ]; then
  launchctl unsetenv DOCKER_HOST
fi
launchctl unsetenv TESTCONTAINERS_DOCKER_SOCKET_OVERRIDE
TC=~/.testcontainers.properties
if [ -L "$TC" ]; then
  # sed -i refuses symlinks (dotfile managers); edit the file it points at.
  t=$(readlink "$TC")
  case "$t" in /*) TC="$t" ;; *) TC="$HOME/$t" ;; esac
fi
if [ -f "$TC" ]; then
  sed -i '' "\|^docker.host=unix://$STABLE\$|d" "$TC"
fi
if [ "$(readlink /var/run/docker.sock 2>/dev/null)" = "$STABLE" ]; then
  echo "Removing /var/run/docker.sock (needs sudo)"
  sudo rm /var/run/docker.sock
fi

# Read the profile socket names before the cache folder goes away.
# shellcheck disable=SC2207 # profile names have no spaces (see the case above)
PROFILE_NAMES=($(profile_socket_names))
rm -rf ~/Applications/ColimaBar.app /Applications/ColimaBar.app ~/.cache/colima-bar
rm -f ~/.local/bin/colima-ctl.sh
# Keep the stable path as a link to Colima's socket, so a DOCKER_HOST that
# still points at it (shell rc files, scripts) keeps working.
(umask 077 && mkdir -p "$(dirname "$STABLE")") && ln -sfn "$COLIMA_SOCK" "$STABLE"
# The same for each profile socket: link it to the Colima socket of its profile.
link_profile_sockets ${PROFILE_NAMES[@]+"${PROFILE_NAMES[@]}"}
defaults delete com.imohitkr.ColimaBar >/dev/null 2>&1

echo "ColimaBar removed. Docker clients now use Colima's socket: $COLIMA_SOCK"
echo "$STABLE now links to Colima's socket, so a DOCKER_HOST that points at it keeps working."
if [ "${#PROFILE_NAMES[@]}" -gt 0 ]; then
  echo "Each socket in $PROFILES_DIR now links to the Colima socket of its profile."
fi
