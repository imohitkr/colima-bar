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

# colima_dir -> the Colima config folder, with the rules of colima-ctl.sh and
# Paths.colimaDir in ColimaBar. The first rule that applies wins: COLIMA_HOME if
# that path exists, ~/.colima if it exists, ~/.config/colima if it exists,
# $XDG_CONFIG_HOME/colima if XDG_CONFIG_HOME is set, else ~/.colima.
colima_dir() {
  if [ -n "${COLIMA_HOME:-}" ] && [ -e "$COLIMA_HOME" ]; then
    echo "$COLIMA_HOME"
  elif [ -e "$HOME/.colima" ]; then
    echo "$HOME/.colima"
  elif [ -e "$HOME/.config/colima" ]; then
    echo "$HOME/.config/colima"
  elif [ -n "${XDG_CONFIG_HOME:-}" ]; then
    echo "$XDG_CONFIG_HOME/colima"
  else
    echo "$HOME/.colima"
  fi
}

# colima_context_for CONTEXT -> the docker context of Colima for the profile
# of a colimabar-PROFILE context: colima-PROFILE, or colima for default. For
# any other context, it prints colima.
colima_context_for() {
  case "$1" in
    colimabar-default) echo colima ;;
    colimabar-?*) echo "colima-${1#colimabar-}" ;;
    *) echo colima ;;
  esac
}

# leave_context CONTEXT -> switches docker away from CONTEXT, a context of
# ColimaBar. It uses the context of Colima for the same profile if that
# context exists. Else it uses colima, else default.
leave_context() {
  local target
  target=$(colima_context_for "$1")
  docker context use "$target" >/dev/null 2>&1 \
    || docker context use colima >/dev/null 2>&1 \
    || docker context use default >/dev/null 2>&1
  return 0
}

# profile_socket_names -> the profiles that have a socket in PROFILES_DIR:
# "work" for work.sock. It skips other files and invalid names.
profile_socket_names() {
  local f n
  for f in "$PROFILES_DIR"/*.sock; do
    [ -e "$f" ] || [ -L "$f" ] || continue
    n=${f##*/}
    n=${n%.sock}
    case "$n" in *[!ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-]*|.*|"") continue ;; esac
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

# Succeeds if $1 is a link to the command of a ColimaBar app: its target ends
# in /ColimaBar.app/Contents/Resources/bin/colimabar. The script removes no
# other file.
is_own_link() {
  local target
  [ -L "$1" ] || return 1
  target=$(readlink "$1") || return 1
  case "$target" in
    */ColimaBar.app/Contents/Resources/bin/colimabar) return 0 ;;
    *) return 1 ;;
  esac
}

# command_link_dirs -> the folders that can hold the colimabar link of
# Homebrew, of the installer or of the user.
command_link_dirs() {
  echo /opt/homebrew/bin
  echo /usr/local/bin
  echo "$HOME/.local/bin"
  echo "$HOME/bin"
}

# remove_command_links DIR... -> removes DIR/colimabar in each folder, but
# only if it is a link to the command of ColimaBar. A folder that the user
# cannot write to needs sudo, as for /var/run.
remove_command_links() {
  local d f
  for d in "$@"; do
    f="$d/colimabar"
    is_own_link "$f" || continue
    if [ -w "$d" ]; then
      rm -f "$f" && echo "Removed $f"
    else
      echo "Removing $f (needs sudo)"
      sudo rm -f "$f" || echo "Could not remove $f. Remove it by hand." >&2
    fi
  done
  return 0
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

# colimabar_ca_hashes KEYCHAIN -> the SHA-1 hashes (one for each line) of the
# certificates in KEYCHAIN with "ColimaBar Local CA" in their name: the local
# certificate authority of HTTPS for container domains.
colimabar_ca_hashes() {
  security find-certificate -a -Z -c "ColimaBar Local CA" "$1" 2>/dev/null \
    | sed -n 's/^SHA-1 hash: \([0-9A-Fa-f]*\)$/\1/p'
  return 0
}

# RESOLVER_MARKER is the first line of each file that ColimaBar adds for the
# custom suffix of container domains: ResolverFile.marker. A test checks that
# both strings are equal.
RESOLVER_MARKER="# Managed by ColimaBar (com.imohitkr.ColimaBar). ColimaBar changes and removes this file."

# own_resolver_files DIR -> the files in DIR that ColimaBar wrote: regular
# files (no links) with RESOLVER_MARKER on the first line. It lists the
# temporary files ".SUFFIX.colimabar-tmp" of a failed write too. Other files stay.
own_resolver_files() {
  local f
  for f in "$1"/* "$1"/.*.colimabar-tmp; do
    [ -f "$f" ] && [ ! -L "$f" ] || continue
    [ "$(head -n 1 "$f" 2>/dev/null)" = "$RESOLVER_MARKER" ] && echo "$f"
  done
  return 0
}

# remove_resolver_files DIR -> removes our files of own_resolver_files DIR
# with sudo (/etc needs it, as for /var/run). A failure only prints a hint.
remove_resolver_files() {
  local f found=0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    found=1
    echo "Removing $f (needs sudo)"
    sudo rm -f "$f" || echo "Could not remove $f. Remove it by hand." >&2
  done < <(own_resolver_files "$1")
  # rmdir removes only an empty folder, so a folder with other files stays.
  if [ "$found" = 1 ]; then sudo rmdir "$1" 2>/dev/null || true; fi
  return 0
}

# END helpers

COLIMA_SOCK="$(colima_dir)/default/docker.sock"

wait_for_exit() {
  for _ in $(seq 1 20); do
    app_running || return 0
    sleep 0.5
  done
}

# Stop ColimaBar before you delete it. A running copy recreates the colimabar
# context and the launchd DOCKER_HOST when the VM starts again.
if app_running; then
  echo "Quitting the running ColimaBar"
  osascript -e 'quit app "ColimaBar"' >/dev/null 2>&1
  wait_for_exit
fi
# Bootout also stops a copy that launchd runs.
launchctl bootout "gui/$(id -u)/com.imohitkr.ColimaBar.agent" 2>/dev/null
launchctl bootout "gui/$(id -u)/com.imohitkr.ColimaBar.login" 2>/dev/null
# The Apple event can fail (Automation permission, an open alert).
# ColimaBar also quits cleanly on SIGTERM.
if app_running; then
  term_app
  wait_for_exit
fi
if app_running; then
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
    leave_context "$ctx"
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
# One folder at a time: the home folder can have a space.
while IFS= read -r dir; do
  remove_command_links "$dir"
done < <(command_link_dirs)
# Keep the stable path as a link to Colima's socket, so a DOCKER_HOST that
# still points at it (shell rc files, scripts) keeps working.
(umask 077 && mkdir -p "$(dirname "$STABLE")") && ln -sfn "$COLIMA_SOCK" "$STABLE"
# The same for each profile socket: link it to the Colima socket of its profile.
link_profile_sockets ${PROFILE_NAMES[@]+"${PROFILE_NAMES[@]}"}
defaults delete com.imohitkr.ColimaBar >/dev/null 2>&1

# BEGIN ca removal: the tests run this block alone.
# The local certificate authority of HTTPS for container domains. The folder
# holds its key, so it goes first: the authority can never sign again. The
# script deletes only the folders that ColimaBar makes, and the parent folders
# only when they are empty. Then the certificate and its user trust setting
# go. -t deletes the trust setting too, and macOS can ask for your password.
SUPPORT_DIR="$HOME/Library/Application Support/ColimaBar"
CACHES_DIR="$HOME/Library/Caches/com.imohitkr.ColimaBar"
rm -rf "$SUPPORT_DIR/domains" "$SUPPORT_DIR/domains.new" "$CACHES_DIR/tls"
rmdir "$SUPPORT_DIR" "$CACHES_DIR" 2>/dev/null
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
while IFS= read -r hash; do
  [ -n "$hash" ] || continue
  security delete-certificate -t -Z "$hash" "$KEYCHAIN" >/dev/null 2>&1 \
    || echo "Could not remove the ColimaBar certificate authority. Remove it in Keychain Access." >&2
done < <(colimabar_ca_hashes "$KEYCHAIN")
# END ca removal

# The resolver file of the custom suffix. Only a file with our marker goes.
# /etc needs sudo, as for /var/run.
remove_resolver_files /etc/resolver

echo "ColimaBar removed. Docker clients now use Colima's socket: $COLIMA_SOCK"
echo "$STABLE now links to Colima's socket, so a DOCKER_HOST that points at it keeps working."
if [ "${#PROFILE_NAMES[@]}" -gt 0 ]; then
  echo "Each socket in $PROFILES_DIR now links to the Colima socket of its profile."
fi
