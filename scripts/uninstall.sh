#!/bin/bash
# Removes ColimaBar and points every docker client straight back at Colima.
set -uo pipefail

COLIMA_SOCK="$HOME/.config/colima/default/docker.sock"
STABLE="$HOME/.cache/colima-bar/docker.sock"
PROFILES_DIR="$HOME/.cache/colima-bar/profiles"

# BEGIN helpers: functions only. Tests source this block.

# colimabar_contexts -> the names of the colimabar-PROFILE docker contexts.
colimabar_contexts() {
  docker context ls --format '{{.Name}}' 2>/dev/null | grep -E '^colimabar-.' || true
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
  local n
  [ "$#" -gt 0 ] || return 0
  (umask 077 && mkdir -p "$PROFILES_DIR") || return 1
  for n in "$@"; do
    ln -sfn "$HOME/.config/colima/$n/docker.sock" "$PROFILES_DIR/$n.sock"
  done
}

# END helpers

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

# docker contexts: colimabar and each colimabar-PROFILE, launchd env, testcontainers
case "$(docker context show 2>/dev/null)" in
  colimabar|colimabar-*)
    docker context use colima >/dev/null 2>&1 || docker context use default >/dev/null 2>&1 ;;
esac
docker context rm -f colimabar >/dev/null 2>&1
for ctx in $(colimabar_contexts); do
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
