#!/bin/bash
# Removes ColimaBar and points every docker client straight back at Colima.
set -uo pipefail

COLIMA_SOCK="$HOME/.config/colima/default/docker.sock"
STABLE="$HOME/.cache/colima-bar/docker.sock"

osascript -e 'quit app "ColimaBar"' >/dev/null 2>&1
launchctl bootout "gui/$(id -u)/com.imohitkr.ColimaBar.agent" 2>/dev/null

# docker context, launchd env, testcontainers
docker context use colima >/dev/null 2>&1 && docker context rm colimabar >/dev/null 2>&1
launchctl unsetenv DOCKER_HOST
if [ -f ~/.testcontainers.properties ]; then
  sed -i '' "\|^docker.host=unix://$STABLE\$|d" ~/.testcontainers.properties
fi
if [ "$(readlink /var/run/docker.sock 2>/dev/null)" = "$STABLE" ]; then
  echo "Removing /var/run/docker.sock (needs sudo)"
  sudo rm /var/run/docker.sock
fi

rm -rf ~/Applications/ColimaBar.app ~/.cache/colima-bar
rm -f ~/.local/bin/colima-ctl.sh
defaults delete com.imohitkr.ColimaBar >/dev/null 2>&1

echo "ColimaBar removed. Docker clients now use Colima's socket: $COLIMA_SOCK"
echo "If ~/.zshrc points DOCKER_HOST at $STABLE, it already falls back to Colima's socket."
