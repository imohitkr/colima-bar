#!/bin/bash
# Removes ColimaBar and points every docker client straight back at Colima.
set -uo pipefail

COLIMA_SOCK="$HOME/.config/colima/default/docker.sock"
STABLE="$HOME/.cache/colima-bar/docker.sock"

osascript -e 'quit app "ColimaBar"' >/dev/null 2>&1
launchctl bootout "gui/$(id -u)/com.imohitkr.ColimaBar.agent" 2>/dev/null
launchctl bootout "gui/$(id -u)/com.imohitkr.ColimaBar.login" 2>/dev/null
rm -f ~/Library/LaunchAgents/com.imohitkr.ColimaBar.login.plist

# docker context, launchd env, testcontainers
if [ "$(docker context show 2>/dev/null)" = colimabar ]; then
  docker context use colima >/dev/null 2>&1 || docker context use default >/dev/null 2>&1
fi
docker context rm -f colimabar >/dev/null 2>&1
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

rm -rf ~/Applications/ColimaBar.app /Applications/ColimaBar.app ~/.cache/colima-bar
rm -f ~/.local/bin/colima-ctl.sh
# Keep the stable path as a link to Colima's socket, so a DOCKER_HOST that
# still points at it (shell rc files, scripts) keeps working.
mkdir -p -m 700 "$(dirname "$STABLE")" && ln -sfn "$COLIMA_SOCK" "$STABLE"
defaults delete com.imohitkr.ColimaBar >/dev/null 2>&1

echo "ColimaBar removed. Docker clients now use Colima's socket: $COLIMA_SOCK"
echo "$STABLE now links to Colima's socket, so a DOCKER_HOST that points at it keeps working."
