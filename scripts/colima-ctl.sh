#!/bin/bash
# Action backend for ColimaBar.
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

# The Colima config folder. The first rule that applies wins. Paths.colimaDir
# in ColimaBar and uninstall.sh use the same rules.
#   1. COLIMA_HOME, if it is set and the path exists.
#   2. ~/.colima, if it exists.
#   3. ~/.config/colima, if it exists (older ColimaBar versions made it).
#   4. $XDG_CONFIG_HOME/colima, if XDG_CONFIG_HOME is set.
#   5. ~/.colima, the default of Colima on macOS.
# COLIMA_HOME as the caller set it. The rules run again before a colima call.
CALLER_COLIMA_HOME="${COLIMA_HOME:-}"
pick_colima_dir() {
  if [ -n "$CALLER_COLIMA_HOME" ] && [ -e "$CALLER_COLIMA_HOME" ]; then
    echo "$CALLER_COLIMA_HOME"
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
COLIMA_DIR=$(pick_colima_dir)
# Colima 0.10.3 (config/files.go) skips rule 3. COLIMA_HOME makes each colima
# call use COLIMA_DIR. Colima skips a COLIMA_HOME that does not exist, so
# colima_home creates the folder before each colima call.
export COLIMA_HOME="$COLIMA_DIR"
# An action can run for minutes. If the rules pick a different folder now
# (for example, the user deleted ~/.colima and ~/.config/colima exists),
# stop: a new empty folder here would hide the real one from then on.
# Create nothing if colima is not installed.
colima_home() {
  [ -e "$COLIMA_DIR" ] && return 0
  if [ "$(pick_colima_dir)" != "$COLIMA_DIR" ]; then
    # This can run in a subshell (with_busy), so leave a marker: cleanup tells
    # the user. A caller can also redirect stdout (colima status >/dev/null),
    # and bash 3.2 can keep that redirect in the EXIT trap. So ctl.log always
    # gets the reason.
    (umask 077 && mkdir -p "$STATE_DIR")
    echo "the Colima folder changed during the action: $COLIMA_DIR" >>"$CTL_LOG"
    touch "$FOLDER_CHANGED"
    exit 1
  fi
  # type -P finds only a file: the colima function below would match command -v.
  type -P colima >/dev/null || return 0
  mkdir -p "$COLIMA_DIR"
}
# Lima keeps its instances in LIMA_HOME if it is set, else in COLIMA_DIR/_lima.
LIMA_DIR="${LIMA_HOME:-$COLIMA_DIR/_lima}"

# Profile to act on: ColimaBar passes the selected one in COLIMABAR_PROFILE.
PROFILE="${COLIMABAR_PROFILE:-default}"
# A leading "." would allow "." and "..", which point outside the profile folder.
# The lists name each character: a range such as A-Z can match other letters
# in some locales.
case "$PROFILE" in
  *[!ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-]*|.*|"")
    echo "invalid profile name: $PROFILE" >&2; exit 1 ;;
esac
# Dialogs and notifications name the profile: "profile 'work'".
NAMED="profile '$PROFILE'"
PROFILE_DIR="$COLIMA_DIR/$PROFILE"
CONFIG="$PROFILE_DIR/colima.yaml"
SOCK="$PROFILE_DIR/docker.sock"
export DOCKER_HOST="unix://$SOCK"
# kubectl context Colima creates: "colima" for default, "colima-NAME" otherwise.
KCTX=$([ "$PROFILE" = default ] && echo colima || echo "colima-$PROFILE")
# The Lima instance of the profile: "colima" for default, "colima-NAME" otherwise.
LIMA_INST=$([ "$PROFILE" = default ] && echo colima || echo "colima-$PROFILE")
LIMA_LOG="$LIMA_DIR/$LIMA_INST/ha.stderr.log"

# Every colima call targets the selected profile.
colima() { colima_home; command colima "$@" --profile "$PROFILE"; }
STATE_DIR="$HOME/.cache/colima-bar"
BUSY="$STATE_DIR/busy.$PROFILE"
LOCK="$STATE_DIR/lock.$PROFILE"
CTL_LOG="$STATE_DIR/ctl.log"
# colima_home leaves this marker when the Colima folder changed ($$ is the
# PID of the script, also in subshells).
FOLDER_CHANGED="$STATE_DIR/folder-changed.$$"
# A marker left by a killed script with the same PID is not ours.
rm -f "$FOLDER_CHANGED"
# More text for that notice, for example where a backup is.
FOLDER_NOTE=""
SEE_LOG="see ~/.cache/colima-bar/ctl.log"

# Exit codes: 0 done, 1 failed (already notified), 2 cancelled or another
# VM action holds the lock (ColimaBar shows nothing for 2).

# Failures only. Run by ColimaBar, the message goes back to the app (native
# alert with ColimaBar's icon); run by hand, it falls back to osascript.
notify() {
  if [ -n "${COLIMABAR_APP:-}" ]; then
    printf 'COLIMABAR_NOTIFY:%s\n' "${1//$'\n'/ }"
  else
    # The text goes in as an argument, never into the AppleScript source.
    osascript -e 'on run argv' -e 'display notification (item 1 of argv) with title "Colima"' -e 'end run' \
      "$1" >/dev/null 2>&1
  fi
}

# confirm "message" -> 0 only if the user clicked OK. Cancel, an error or no
# answer within 5 minutes all count as "no".
confirm() {
  osascript -e 'on run argv' \
    -e 'display dialog (item 1 of argv) with title "Colima" buttons {"Cancel", "OK"} default button "OK" cancel button "Cancel" with icon caution giving up after 300' \
    -e 'if gave up of result then error number -128' \
    -e 'end run' "$1" >/dev/null 2>&1
}

# upgrade_confirm -> 0 if ColimaBar passed no upgrade note, or if the user
# clicked Continue. ColimaBar sets COLIMABAR_UPGRADE_NOTE when Colima or Lima
# changed in a risky way since the last good start of this profile. "Release
# Notes" opens the pages in COLIMABAR_RELEASE_NOTES, only on github.com and
# only for the release page of Colima or Lima, then it returns 1, like
# Cancel. Cancel, or no answer within 5 minutes, returns 1. If the dialog
# cannot show (an AppleScript error, no GUI session), the script tells the
# user and exits with 1.
upgrade_confirm() {
  [ -n "${COLIMABAR_UPGRADE_NOTE:-}" ] || return 0
  local answer url rc
  local pages_re='^https://github\.com/(abiosoft/colima|lima-vm/lima)/releases/tag/v[[:digit:]]+(\.[[:digit:]]+)*$'
  answer=$(osascript -e 'on run argv' \
    -e 'set r to display dialog (item 1 of argv) with title "Colima" buttons {"Cancel", "Release Notes", "Continue"} default button "Continue" cancel button "Cancel" with icon caution giving up after 300' \
    -e 'if gave up of r then error number -128' \
    -e 'return button returned of r' \
    -e 'end run' "$COLIMABAR_UPGRADE_NOTE" 2>&1)
  rc=$?
  if [ "$rc" -ne 0 ]; then
    # Error -128 is Cancel, and the give-up of the dialog.
    case "$answer" in *"(-128)"*) return 1 ;; esac
    echo "upgrade dialog failed: $answer" >&2
    notify "Couldn't show the upgrade dialog for $NAMED - $SEE_LOG"
    exit 1
  fi
  case "$answer" in
    Continue) return 0 ;;
    "Release Notes")
      for url in ${COLIMABAR_RELEASE_NOTES:-}; do
        # One pattern for the whole URL: a tag like v0.11.0 and nothing else.
        if [[ "$url" =~ $pages_re ]]; then
          open "$url" || echo "couldn't open $url" >&2
        fi
      done
      return 1 ;;
  esac
  return 1
}

# started_ok -> tells ColimaBar that the VM started. ColimaBar records the
# versions of Colima and Lima only after this line.
started_ok() {
  # The first newline keeps the marker a line of its own after a partial line.
  [ -z "${COLIMABAR_APP:-}" ] || printf '\nCOLIMABAR_STARTED\n'
}

# start_vm [ARGS...] -> colima start, then the marker of a good start.
# shellcheck disable=SC2120 # only profile-create passes flags for colima start
start_vm() {
  colima start "$@" && started_ok
}

# etime_seconds ETIME -> the seconds in the output of `ps -o etime=`
# ([[DD-]HH:]MM:SS).
etime_seconds() {
  local e="${1//[[:space:]]/}" d=0 a="" b="" c=""
  case "$e" in *-*) d=${e%%-*}; e=${e#*-} ;; esac
  IFS=: read -r a b c <<<"$e"
  if [ -n "$c" ]; then
    echo $((10#$d * 86400 + 10#$a * 3600 + 10#$b * 60 + 10#$c))
  else
    echo $((10#$d * 86400 + 10#${a:-0} * 60 + 10#${b:-0}))
  fi
}

# owner_check PID FILE PATTERN -> tells if PID is the process that wrote FILE
# (it runs, its command line contains PATTERN and it started before FILE was
# written). After a restart of the Mac, a PID can belong to an unrelated
# process that started later. Return code:
#   0  the owner runs.
#   1  the owner is gone: `ps` shows no process, or another one.
#   2  unknown: the PID or the file cannot be read.
owner_check() {
  local pid="$1" file="$2" pattern="$3" cmd et mtime age
  case "$pid" in ""|*[!0123456789]*) return 2 ;; esac
  cmd=$(ps -o command= -p "$pid" 2>/dev/null)
  [ -n "$cmd" ] || return 1
  case "$cmd" in *"$pattern"*) ;; *) return 1 ;; esac
  et=$(ps -o etime= -p "$pid" 2>/dev/null)
  [ -n "$et" ] || return 1
  mtime=$(stat -f %m "$file" 2>/dev/null) || return 2
  age=$(($(date +%s) - mtime))
  # The 2 seconds absorb the rounding of both times.
  [ "$(etime_seconds "$et")" -ge $((age - 2)) ] && return 0
  return 1
}

# owner_alive PID FILE PATTERN -> true if owner_check finds the owner.
owner_alive() {
  owner_check "$@"
}

# lock_stale DIR -> true if the lock folder DIR is left over from a script
# that is gone. With an owner PID, only the owner counts, so a long action
# (also a long sleep of the Mac) keeps its lock. The lock is stale only if
# `ps` shows that the owner is gone. If the PID cannot be read (the owner
# writes it now, or removes the lock now), and for a lock with no PID file
# (older versions), the lock is stale after 30 minutes.
lock_stale() {
  local pid rc=2
  if [ -f "$1/pid" ]; then
    pid=$(cat "$1/pid" 2>/dev/null)
    owner_check "$pid" "$1/pid" colima-ctl && rc=0 || rc=$?
  fi
  case "$rc" in
    0) return 1 ;;
    1) return 0 ;;
  esac
  [ -n "$(find "$1" -maxdepth 0 -mmin +30 2>/dev/null)" ]
}

# lock_vm -> takes this profile's lock for a VM action (confirm dialog
# included), so two starts/restarts can't run at once. The lock folder holds
# the PID of the script. A lock whose owner is gone is left over from a
# killed script and is taken over.
# lock_vm [quiet] -> "quiet" skips the notice (timer-driven auto-stop).
HOLD_LOCK=""
lock_vm() {
  (umask 077 && mkdir -p "$STATE_DIR")  # private: 0700
  if ! mkdir "$LOCK" 2>/dev/null; then
    # Take over a stale lock atomically: only one script wins the mv.
    if lock_stale "$LOCK" && mv "$LOCK" "$LOCK.stale.$$" 2>/dev/null; then
      # Another script may have taken over first and made a fresh lock that
      # we just moved. If so, give it back.
      if ! lock_stale "$LOCK.stale.$$"; then
        # A folder with no PID file is empty: its owner removed the lock just
        # now. Remove it. If we gave it back, no action could start for 30
        # minutes.
        [ -e "$LOCK.stale.$$/pid" ] && [ ! -e "$LOCK" ] && mv "$LOCK.stale.$$" "$LOCK" 2>/dev/null
        rm -rf "$LOCK.stale.$$"
        [ "${1:-}" = quiet ] || notify "Another Colima action is still running for $NAMED."
        exit 2
      fi
      rm -rf "$LOCK.stale.$$"
      mkdir "$LOCK" 2>/dev/null || exit 2
    else
      [ "${1:-}" = quiet ] || notify "Another Colima action is still running for $NAMED."
      exit 2
    fi
  fi
  HOLD_LOCK=1
  # Write the PID in one step: a reader never sees an empty file. If the
  # folder is gone, another script removed it as stale: do not run unlocked.
  if ! { echo "$$" >"$LOCK/pid.$$" && mv -f "$LOCK/pid.$$" "$LOCK/pid"; } 2>/dev/null; then
    HOLD_LOCK=""
    exit 2
  fi
}

# Clean up on any exit, and stop the running action when ColimaBar times
# us out. Bash runs a trap only after a foreground child exits, so long
# actions run in the background and we `wait` for them (wait is interruptible).
WROTE_BUSY=""
CHILD=""
# The file with the output of docker compose. Every exit prints it and removes it.
COMPOSE_OUT=""
# The file that vm-config got from ColimaBar. Every exit removes it.
STAGED=""
# Set while vm-config has put the new colima.yaml in place of the old one and
# the restart has not ended well. If the script ends in that time (a signal or
# the time limit of ColimaBar), cleanup puts the old file back.
INSTALLED=""
VM_BACKUP=""
cleanup() {
  compose_show
  if [ -n "$INSTALLED" ]; then
    INSTALLED=""
    if install_config "$VM_BACKUP"; then
      notify "The VM settings of $NAMED did not finish. ColimaBar put the old colima.yaml back. A copy is in $VM_BACKUP."
    else
      notify "The VM settings of $NAMED did not finish. ColimaBar could not put the old colima.yaml back. A copy is in $VM_BACKUP."
    fi
  fi
  if [ -e "$FOLDER_CHANGED" ]; then
    rm -f "$FOLDER_CHANGED"
    notify "The Colima folder changed during the action of $NAMED. Try again.$FOLDER_NOTE"
  fi
  [ -n "$WROTE_BUSY" ] && rm -f "$BUSY"
  [ -n "$STAGED" ] && rm -f "$STAGED"
  [ -n "$HOLD_LOCK" ] && { rm -f "$LOCK/pid" "$LOCK/pid.$$"; rmdir "$LOCK" 2>/dev/null; }
  return 0
}
on_term() {
  if [ -n "$CHILD" ]; then
    pkill -TERM -P "$CHILD" 2>/dev/null
    kill -TERM "$CHILD" 2>/dev/null
    # Compose: wait until docker ended, so ColimaBar keeps the project busy.
    [ -n "$COMPOSE_OUT" ] && wait "$CHILD" 2>/dev/null
  fi
  exit 143
}
trap cleanup EXIT
trap on_term TERM INT

# with_busy "label" cmd... -> writes the busy marker ColimaBar watches.
with_busy() {
  local label="$1"; shift
  (umask 077 && mkdir -p "$STATE_DIR")  # private: 0700
  # Line 1 is the label. Line 2 is the PID of this script: ColimaBar ignores
  # the marker when that process is gone.
  printf '%s\n%s\n' "$label" "$$" > "$BUSY"
  WROTE_BUSY=1
  # The extra subshell is needed. In a plain "$@" & bash 3.2 (macOS) can run
  # the first `command colima` of a function with exec. Then the action ends
  # after that call. For example, restart_vm then stops the VM (its `colima
  # status` runs in the subshell of vm_up), but does not start it again.
  ( "$@" ) &
  CHILD=$!
  wait "$CHILD"
  local rc=$?
  CHILD=""
  rm -f "$BUSY"
  WROTE_BUSY=""
  # cleanup gives the reason; skip the caller's general failure notice.
  [ -e "$FOLDER_CHANGED" ] && exit 1
  return $rc
}

running_count() {
  docker ps -q 2>/dev/null | wc -l | tr -d ' '
}

# set_key KEY VALUE [FILE] -> sets a top-level key in colima.yaml (or in
# FILE, a copy of it) and checks it took. It replaces the full line, also
# an inline comment, quotes and a CR.
set_key() {
  local file="${3:-$CONFIG}"
  [ -f "$file" ] || { notify "$file not found."; exit 1; }
  sed -i '' -E "s/^$1:.*/$1: $2/" "$file"
  # A "." in the value (memory: 2.5) must match only a ".".
  grep -qE "^$1: ${2//./\\.}\$" "$file" || { notify "Couldn't set $1 in colima.yaml (key not found)."; exit 1; }
}

# set_k8s true|false -> sets kubernetes.enabled in colima.yaml and checks it took.
set_k8s() {
  [ -f "$CONFIG" ] || { notify "$CONFIG not found."; exit 1; }
  sed -i '' -E "/^kubernetes:/,/^[a-z]/ s/^  enabled: .*/  enabled: $1/" "$CONFIG"
  sed -n '/^kubernetes:/,/^[a-z]/p' "$CONFIG" | grep -qE "^  enabled: $1\$" \
    || { notify "Couldn't set kubernetes.enabled in colima.yaml."; exit 1; }
}

# file_sha FILE -> the SHA-256 of FILE as hex, or nothing if it cannot be read.
file_sha() {
  local h
  h=$(shasum -a 256 "$1" 2>/dev/null) || return 0
  printf '%s' "${h%% *}"
}

# install_config FILE -> puts FILE in place of colima.yaml. It copies to a
# file in the same folder first, so colima.yaml is never half written.
install_config() {
  local tmp="$CONFIG.new.$$" mode=""
  [ -f "$CONFIG" ] && mode=$(stat -f %Lp "$CONFIG" 2>/dev/null)
  if cp "$1" "$tmp" && { [ -z "$mode" ] || chmod "$mode" "$tmp"; } && mv -f "$tmp" "$CONFIG"; then
    return 0
  fi
  rm -f "$tmp"
  return 1
}

# The smallest disk that disk-shrink accepts, in GB.
MIN_DISK=10

# The exit code of shrink_disk when the new disk exists but the last stop
# failed. The caller tells the user.
RESTOP_FAILED=3

# The exit code of restart_vm when `colima stop` failed. The VM still runs.
STOP_FAILED=4

# shrink_disk BACKUP [RESTOP] -> stops the VM, deletes it with its data,
# puts the edited colima.yaml back and starts the VM. `colima delete`
# removes the whole profile folder with colima.yaml, so the copy in BACKUP
# (with the new disk size) goes back before the start. Thus the other VM
# settings stay. Colima creates the new disk only at a start. Thus a VM that
# was stopped starts once: if RESTOP is set, the VM stops again at the end.
shrink_disk() {
  if colima status >/dev/null 2>&1; then
    colima stop || return 1
  fi
  colima delete --data --force || return 1
  # Create only the profile folder, inside a Colima folder that still exists.
  [ -d "$COLIMA_DIR" ] || return 1
  mkdir -p "$PROFILE_DIR" && cp -p "$1" "$CONFIG" || return 1
  # shellcheck disable=SC2119 # no flags: a plain colima start
  start_vm || return 1
  if [ -n "${2:-}" ]; then
    colima stop || return "$RESTOP_FAILED"
  fi
}

# The rules for a new profile name. They must match ProfileName.problem in
# ColimaBar: lowercase letters, digits and single hyphens, a letter or digit
# at both ends, 30 characters at most. Colima maps "colima" to "default" and
# removes a "colima-" prefix, so "colima-work" means "work".
new_name_ok() {
  case "$1" in
    default|colima|colima-*|*[!abcdefghijklmnopqrstuvwxyz0123456789-]*|-*|*-|*--*|"") return 1 ;;
  esac
  [ "${#1}" -le 30 ]
}

# profile_dir_exists -> true if COLIMA_DIR has a folder with the exact name
# of PROFILE. The Mac file system ignores case, so a plain -d test also
# finds the folder "default" for the name "Default".
profile_dir_exists() {
  local d
  [ -d "$PROFILE_DIR" ] || return 1
  for d in "$COLIMA_DIR"/*/; do
    d=${d%/}
    [ "${d##*/}" = "$PROFILE" ] && return 0
  done
  return 1
}

# is_num VALUE -> true for a whole number.
is_num() {
  case "$1" in *[!0123456789]*|"") return 1 ;; esac
}

# is_decimal VALUE -> true for a whole or decimal number, such as 2 or 2.5.
# Colima reads the memory as a decimal number of GiB.
is_decimal() {
  case "$1" in ""|.*|*.|*.*.*|*[!0123456789.]*) return 1 ;; esac
}

# vm_up -> true if `colima status` succeeds. The status runs in a subshell.
# If the Colima folder changed, colima_home exits that subshell. Then this
# function exits the main shell, without the redirect: bash 3.2 can keep a
# redirect in the EXIT trap, and the notice of cleanup must reach the app.
# Do not add file descriptors for this: Colima's daemon can keep them open.
vm_up() {
  ( colima status ) >/dev/null 2>&1
  local rc=$?
  [ -e "$FOLDER_CHANGED" ] && exit 1
  return $rc
}

# start_words WORD... -> true if the words of a command line are a
# `colima start` or `colima restart` in progress for PROFILE. The rules
# match ColimaModel.isStartInProgress in ColimaBar:
#   - `colima start -f` is a long-lived foreground supervisor, not a start
#     in progress. For `colima restart`, -f means --force and counts.
#   - The profile is the value of --profile or -p (also --profile=NAME and
#     -p=NAME). Else it is the first word after start or restart that is not
#     a flag and not the value of a flag. Else it is default.
#   - Colima reads "colima" as default and removes a "colima-" prefix.
start_words() {
  local words=("$@") n=$# i at=-1 verb w named="" first=""
  for ((i = 0; i < n; i++)); do
    case "${words[i]}" in colima|*/colima) at=$i; break ;; esac
  done
  [ "$at" -ge 0 ] && [ $((at + 1)) -lt "$n" ] || return 1
  verb="${words[at + 1]}"
  case "$verb" in start|restart) ;; *) return 1 ;; esac
  for ((i = at + 2; i < n; i++)); do
    w="${words[i]}"
    case "$w" in
      -f|--foreground) [ "$verb" = start ] && return 1 ;;
      --profile|-p) i=$((i + 1)); [ "$i" -lt "$n" ] && named="${words[i]}" ;;
      --profile=*) named="${w#--profile=}" ;;
      -p=*) named="${w#-p=}" ;;
      # The flags of `colima start` that take a value in the next word.
      -a|--arch|--cpu-type|-c|--cpu|--cpus|-d|--disk|-i|--disk-image|-n|--dns|--dns-host|--downloader|--editor|--env|--gateway-address|--hostname|--k3s-arg|--k3s-listen-port|--kubernetes-version|-m|--memory|--model-runner|-V|--mount|--mount-type|--network-interface|--network-mode|--port-forwarder|--root-disk|-r|--runtime|--ssh-port|-t|--vm-type)
        i=$((i + 1)) ;;
      -*) ;;
      *) [ -n "$first" ] || first="$w" ;;
    esac
  done
  named="${named:-${first:-default}}"
  [ "$named" = colima ] && named=default
  named="${named#colima-}"
  [ "$named" = "$PROFILE" ]
}

# start_in_progress -> true while a `colima start` or `colima restart` of
# this user runs for PROFILE, for example from a terminal. During a start,
# `colima status` still fails.
start_in_progress() {
  local pid cmd words
  for pid in $(pgrep -U "$(id -u)" -f 'colima (start|restart)' 2>/dev/null); do
    cmd=$(ps -o command= -p "$pid" 2>/dev/null) || continue
    read -r -a words <<<"$cmd"
    [ "${#words[@]}" -gt 0 ] && start_words "${words[@]}" && return 0
  done
  return 1
}

# vm_running -> true while the VM of the profile runs or starts.
vm_running() {
  vm_up || start_in_progress
}

# no_start_in_progress -> exits with 1 while a `colima start` or `colima
# restart` runs for PROFILE. A restart would run a second `colima start`
# during it, and a disk shrink would delete the VM while it starts. Call it
# before a dialog opens.
no_start_in_progress() {
  start_in_progress || return 0
  notify "A start of $NAMED runs now. Try again when it ends.${1:-}"
  exit 1
}

# same_state WAS -> true if the VM state is still WAS (1 running, 0 stopped).
# A dialog can stay open for minutes, and the VM can start or stop meanwhile.
same_state() {
  local now=0
  vm_running && now=1
  [ "$now" = "$1" ]
}

# vm_state -> sets VM_UP to 1 if the VM runs, else to 0. While a start runs,
# it stops the script (no_start_in_progress). If ColimaBar sent the state
# that it expects in COLIMABAR_EXPECT_RUNNING (1 or 0) and the VM is in the
# other state, it stops the script too. ColimaBar uses the expected state to
# decide if it closes its popover for a dialog. If the VM started or stopped
# outside the app, a dialog could open behind the popover. Run it in the main
# shell: it must exit the script.
vm_state() {
  no_start_in_progress
  VM_UP=0
  vm_up && VM_UP=1
  if [ -n "${COLIMABAR_EXPECT_RUNNING:-}" ] && [ "$COLIMABAR_EXPECT_RUNNING" != "$VM_UP" ]; then
    notify "The VM of $NAMED started or stopped. Nothing changed. Try again."
    exit 1
  fi
}

# state_changed -> tells the user that the VM state changed while a dialog
# was open.
state_changed() {
  notify "The VM of $NAMED started or stopped while the dialog was open. Nothing changed. Try again."
  exit 1
}

# yaml_value KEY [FILE] -> the value of a top-level key in colima.yaml (or
# FILE), or nothing. It reads the same forms as VMConfig.parse in ColimaBar:
# CRLF line ends, an inline comment (" #") and quotes. The first line with
# the key counts.
yaml_value() {
  local v
  v=$(tr -d '\r' <"${2:-$CONFIG}" 2>/dev/null | sed -n "/^$1:/{p;q;}")
  [ -n "$v" ] || return 0
  v=${v#"$1":}
  v=${v%% \#*}
  v=${v#"${v%%[![:space:]]*}"}
  v=${v%"${v##*[![:space:]]}"}
  case "$v" in \"*\"|\'*\') v=${v:1:${#v}-2} ;; esac
  printf '%s\n' "$v"
}

# whole VALUE -> the whole part of a number such as 2 or 2.5, or nothing for
# a value that is not a number. A fraction is cut off: 2.5 gives 2.
whole() {
  local w
  case "$1" in ""|.|*.*.*|*[!0123456789.]*) return 0 ;; esac
  w=${1%%.*}
  printf '%s\n' "$((10#${w:-0}))"
}

# file_pid FILE -> the first word of FILE, the PID of a pid file.
file_pid() {
  local p=""
  read -r p _ <"$1" 2>/dev/null || true
  printf '%s' "$p"
}

# pid_pattern FILE -> the text that the command line of the owner of a pid
# file contains. The daemon of Colima runs as `colima daemon start PROFILE`.
pid_pattern() {
  case "${1##*/}" in
    qemu.pid) echo qemu-system ;;
    krunkit.pid) echo krunkit ;;
    daemon.pid) echo "colima daemon start" ;;
    *) echo limactl ;;
  esac
}

# stale_check FILE -> prints "REASON<TAB>FILE<TAB>PID" if FILE is a pid file
# that Lima cannot use. Only a regular file counts, never a link.
#   invalid: the file has no PID.
#   gone:    no process has the PID.
#   reused:  another process has the PID (it started after the file).
stale_check() {
  local f="$1" pid
  [ -f "$f" ] && [ ! -L "$f" ] || return 0
  pid=$(file_pid "$f")
  case "$pid" in
    ""|*[!0123456789]*) printf 'invalid\t%s\t%s\n' "$f" "$pid"; return 0 ;;
  esac
  if [ -z "$(ps -o command= -p "$pid" 2>/dev/null)" ]; then
    printf 'gone\t%s\t%s\n' "$f" "$pid"
  elif ! owner_alive "$pid" "$f" "$(pid_pattern "$f")"; then
    printf 'reused\t%s\t%s\n' "$f" "$pid"
  fi
}

# live_pid_file FILE -> true if FILE is a regular file and its owner runs.
live_pid_file() {
  [ -f "$1" ] && [ ! -L "$1" ] && owner_alive "$(file_pid "$1")" "$1" "$(pid_pattern "$1")"
}

# instance_pid_files -> the pid files of the Lima instance of PROFILE.
instance_pid_files() {
  local inst="$LIMA_DIR/$LIMA_INST" f
  [ -d "$inst" ] && [ ! -L "$inst" ] || return 0
  for f in ha.pid vz.pid qemu.pid krunkit.pid; do echo "$inst/$f"; done
}

# daemon_pid_file -> the pid file of the Colima daemon of PROFILE. `colima
# stop` and `colima start` run `pkill -F` on it, with no check of the owner.
daemon_pid_file() {
  [ -d "$PROFILE_DIR" ] && [ ! -L "$PROFILE_DIR" ] || return 0
  [ -d "$PROFILE_DIR/daemon" ] && [ ! -L "$PROFILE_DIR/daemon" ] || return 0
  echo "$PROFILE_DIR/daemon/daemon.pid"
}

# own_pid_files -> the pid files of the instance and of the daemon.
own_pid_files() {
  instance_pid_files
  daemon_pid_file
}

# short_path FILE -> FILE without the Lima or the Colima folder.
short_path() {
  local p="${1#"$LIMA_DIR"/}"
  printf '%s' "${p#"$COLIMA_DIR"/}"
}

# stale_files -> prints a line for each pid file that Lima or Colima cannot
# use (see stale_check). It reads only these files, in the instance of
# PROFILE, the daemon folder of PROFILE and the network folder of Lima. All instances share the network folder, so
# it counts only when no instance has a live host agent. It changes nothing.
stale_files() {
  local f d net_ok=1
  while IFS= read -r f; do [ -n "$f" ] && stale_check "$f"; done <<<"$(own_pid_files)"
  [ -d "$LIMA_DIR/_networks" ] && [ ! -L "$LIMA_DIR/_networks" ] || return 0
  for d in "$LIMA_DIR"/*/; do
    d=${d%/}
    case "${d##*/}" in _*) continue ;; esac
    [ -d "$d" ] && [ ! -L "$d" ] || continue
    live_pid_file "$d/ha.pid" && net_ok=""
  done
  [ -n "$net_ok" ] || return 0
  for d in "$LIMA_DIR"/_networks/*/; do
    d=${d%/}
    [ -d "$d" ] && [ ! -L "$d" ] || continue
    for f in "$d"/usernet_*.pid; do stale_check "$f"; done
  done
}

# remove_stale REASON FILE PID -> removes a regular file and logs it.
remove_stale() {
  [ -f "$2" ] && [ ! -L "$2" ] || return 0
  rm -f "$2" && echo "repair: removed $2 ($1, pid ${3:-none})" >&2
}

# The return code of repair_vm when a Lima process of the VM still runs.
STILL_RUNS=4

# The return code of repair_vm when it cannot remove a file that names
# another process. It has stopped nothing then.
REMOVE_FAILED=5

# repair_vm -> removes the stale pid files and starts the VM again.
#  1. Remove the files whose PID another process has, before the force stop.
#     Else Lima sends SIGKILL to that process, and Colima sends SIGTERM.
#     If a file stays, stop here: the force stop must not run.
#  2. Stop the VM by force. A failure is logged, and the repair goes on.
#  3. If a Lima process of the VM still runs, stop here.
#  4. Remove the other stale files.
#  5. Start the VM.
repair_vm() {
  local reason path pid f
  while IFS=$'\t' read -r reason path pid; do
    case "$reason" in
      reused|invalid)
        remove_stale "$reason" "$path" "$pid" || {
          echo "repair: cannot remove $path" >&2
          notify "Can't remove $(short_path "$path"). Nothing was stopped."
          return "$REMOVE_FAILED"
        } ;;
    esac
  done <<<"$(stale_files)"
  colima stop --force || echo "repair: colima stop --force failed" >&2
  while IFS= read -r f; do
    [ -n "$f" ] && live_pid_file "$f" && return "$STILL_RUNS"
  done <<<"$(instance_pid_files)"
  while IFS=$'\t' read -r reason path pid; do
    [ -n "$reason" ] && remove_stale "$reason" "$path" "$pid"
  done <<<"$(stale_files)"
  # shellcheck disable=SC2119 # no flags: a plain colima start
  start_vm
}

restart_vm() {
  if vm_up; then
    colima stop || return "$STOP_FAILED"
  fi
  # shellcheck disable=SC2119 # no flags: a plain colima start
  start_vm
}

# compose_check NAME DIR NENV ENV... FILE...: checks the arguments of a
# Compose action again, the way ColimaBar checked them. The name has the
# letters, digits, "-" and "_" of Compose, and starts with a letter or digit.
# NENV (0 to 16) is the number of env files. 1 to 16 Compose files follow
# them. Each path is absolute. The folder and the files exist.
compose_check() {
  local name="$1" dir="$2" nenv="$3" f
  [ $# -ge 4 ] || { notify "Compose needs 1 to 16 files."; exit 1; }
  case "$nenv" in
    [0-9]|1[0-6]) ;;
    *) notify "Compose needs 0 to 16 env files."; exit 1 ;;
  esac
  shift 3
  [ $# -gt "$nenv" ] && [ $(($# - nenv)) -le 16 ] || { notify "Compose needs 1 to 16 files."; exit 1; }
  case "$name" in
    ""|[-_]*|*[!abcdefghijklmnopqrstuvwxyz0123456789_-]*)
      notify "Invalid Compose project name."; exit 1 ;;
  esac
  [ "${#name}" -le 63 ] || { notify "Invalid Compose project name."; exit 1; }
  case "$dir" in
    /*) ;;
    *) notify "Invalid folder for the Compose project $name."; exit 1 ;;
  esac
  [ -d "$dir" ] || { notify "The folder of the Compose project $name is missing."; exit 1; }
  for f in "$@"; do
    case "$f" in
      /*) ;;
      *) notify "Invalid Compose file for $name."; exit 1 ;;
    esac
    [ -f "$f" ] || { notify "A Compose file of $name is missing. The project folder moved or was deleted."; exit 1; }
  done
  docker compose version >/dev/null 2>&1 \
    || { notify "docker compose is missing. Open Doctor in ColimaBar."; exit 1; }
}

# compose_show: prints the saved output of docker compose and removes the
# file. A line of the output must not look like a notice, so a space comes
# before it. Cleanup calls it too, so a stop of the script keeps the output.
compose_show() {
  [ -n "$COMPOSE_OUT" ] || return 0
  local file="$COMPOSE_OUT"
  COMPOSE_OUT=""
  tail -n 1000 "$file" 2>/dev/null | sed 's/^COLIMABAR_NOTIFY:/ COLIMABAR_NOTIFY:/'
  rm -f "$file"
}

# compose_run VERB NAME DIR NENV ENV... FILE...: runs docker compose for the
# profile (DOCKER_HOST). VERB is pull, up or down. A plain down keeps the
# volumes and the images. The output goes to stdout only, never to ctl.log:
# it can show values of the project. Docker runs in the background, so a stop
# of this script (the time limit of ColimaBar) stops docker too.
compose_run() {
  local verb="$1" name="$2" dir="$3" nenv="$4" f rc
  shift 4
  local argv=(compose -p "$name" --project-directory "$dir")
  while [ "$nenv" -gt 0 ]; do argv+=(--env-file "$1"); shift; nenv=$((nenv - 1)); done
  for f in "$@"; do argv+=(-f "$f"); done
  case "$verb" in
    up) argv+=(up -d) ;;
    *) argv+=("$verb") ;;
  esac
  (umask 077 && mkdir -p "$STATE_DIR")
  COMPOSE_OUT="$STATE_DIR/compose-out.$$"
  (umask 077 && : >"$COMPOSE_OUT")
  docker "${argv[@]}" >"$COMPOSE_OUT" 2>&1 &
  CHILD=$!
  wait "$CHILD"
  rc=$?
  CHILD=""
  compose_show
  if [ "$rc" -ne 0 ]; then
    notify "Compose $verb failed for $name (exit $rc). Use Copy Last Output in the project menu to see the output."
    exit 1
  fi
}

case "$1" in
  start)
    lock_vm
    upgrade_confirm || exit 2
    with_busy "Starting $PROFILE" start_vm || { notify "Start of $NAMED failed - $SEE_LOG"; exit 1; } ;;
  stop)
    lock_vm
    with_busy "Stopping $PROFILE" colima stop || { notify "Stop of $NAMED failed - $SEE_LOG"; exit 1; } ;;
  restart)
    lock_vm
    upgrade_confirm || exit 2
    with_busy "Restarting" restart_vm || { notify "Restart of $NAMED failed - $SEE_LOG"; exit 1; } ;;

  # resources CPU MEM_GB. CPU is a whole number. MEM_GB is a whole or
  # decimal number of GiB, such as 2.5, as in Colima. Both must be 1 or
  # more. A stopped VM only gets the new values in colima.yaml, with no
  # dialog. They apply at the next start. This and rosetta and k8s read
  # COLIMABAR_EXPECT_RUNNING (see vm_state).
  resources)
    cpu="$2"; mem="$3"
    # The whole part of a decimal is 1 or more only for a value of 1 or more.
    # The length limits keep [ -lt ] away from numbers too big for it.
    mem_whole="${mem%%.*}"
    if ! is_num "$cpu" || ! is_decimal "$mem" || [ ${#cpu} -gt 4 ] || [ ${#mem_whole} -gt 6 ] \
      || [ "$cpu" -lt 1 ] || [ "$mem_whole" -lt 1 ]; then
      notify "Invalid CPU/memory for $NAMED: $cpu / $mem. Use at least 1 CPU and 1 GB of memory."
      exit 1
    fi
    lock_vm
    vm_state
    if [ "$VM_UP" = 1 ]; then
      upgrade_confirm || exit 2
      confirm "Restart the Colima VM of $NAMED with ${cpu} CPU / ${mem} GB RAM? $(running_count) running container(s) will stop." || exit 2
      set_key cpu "$cpu"
      set_key memory "$mem"
      with_busy "Applying ${cpu} CPU / ${mem} GB" restart_vm \
        || { notify "Failed to apply resources to $NAMED - $SEE_LOG"; exit 1; }
    else
      set_key cpu "$cpu"
      set_key memory "$mem"
    fi
    ;;

  # vm-config STAGED SHA: replaces colima.yaml with STAGED, a file that
  # ColimaBar wrote for the advanced VM settings. SHA is the SHA-256 of the
  # colima.yaml that ColimaBar edited. If colima.yaml is different now, the
  # script changes nothing. A copy of the old file stays in
  # colima.PROFILE.yaml.bak. A running VM restarts. If it does not start, the
  # old file goes back. A stopped VM only gets the new file. COLIMABAR_EXPECT_RUNNING
  # applies (see vm_state).
  vm-config)
    staged="$2"; sha="$3"
    # Only the file that ColimaBar stages for this profile.
    if [ "$staged" != "$STATE_DIR/colima.$PROFILE.yaml.new" ] || [ ! -f "$staged" ] || [ -L "$staged" ]; then
      notify "Invalid VM settings file for $NAMED. Nothing changed."
      exit 1
    fi
    STAGED="$staged"
    backup="$STATE_DIR/colima.$PROFILE.yaml.bak"
    lock_vm
    [ -f "$CONFIG" ] || { notify "$CONFIG not found."; exit 1; }
    vm_state
    changed_note="colima.yaml of $NAMED changed outside ColimaBar. Nothing changed. Try again."
    [ -n "$sha" ] && [ "$(file_sha "$CONFIG")" = "$sha" ] || { notify "$changed_note"; exit 1; }
    if [ "$VM_UP" = 1 ]; then
      upgrade_confirm || exit 2
      confirm "Apply the new VM settings to $NAMED? Colima will restart the VM and $(running_count) running container(s) will stop." || exit 2
      # The dialog can stay open for minutes.
      same_state 1 || state_changed
      [ "$(file_sha "$CONFIG")" = "$sha" ] || { notify "$changed_note"; exit 1; }
      cp -p "$CONFIG" "$backup" || { notify "Couldn't copy colima.yaml to $backup."; exit 1; }
      install_config "$staged" || { notify "Couldn't write colima.yaml of $NAMED. Nothing changed."; exit 1; }
      VM_BACKUP="$backup"
      INSTALLED=1
      with_busy "Applying VM settings" restart_vm || {
        rc=$?
        INSTALLED=""
        if install_config "$backup"; then
          # If the stop failed, the VM still runs with the old settings.
          if [ "$rc" = "$STOP_FAILED" ]; then
            notify "ColimaBar could not stop the VM of $NAMED, so nothing changed - $SEE_LOG."
          else
            notify "The VM of $NAMED did not start with the new settings - $SEE_LOG. ColimaBar put the old colima.yaml back. Start the VM to use it."
          fi
        else
          notify "The VM of $NAMED did not start with the new settings - $SEE_LOG. ColimaBar could not put the old colima.yaml back. A copy is in $backup."
        fi
        exit 1
      }
      INSTALLED=""
    else
      cp -p "$CONFIG" "$backup" || { notify "Couldn't copy colima.yaml to $backup."; exit 1; }
      install_config "$staged" || { notify "Couldn't write colima.yaml of $NAMED. Nothing changed."; exit 1; }
    fi
    ;;

  # rosetta on|off. A stopped VM only gets the new value in colima.yaml.
  rosetta)
    [ "$2" = on ] && val=true || val=false
    lock_vm
    vm_state
    if [ "$VM_UP" = 1 ]; then
      upgrade_confirm || exit 2
      confirm "Turn Rosetta (amd64 emulation) $2 for $NAMED? Colima will restart the VM and $(running_count) running container(s) will stop." || exit 2
      set_key rosetta "$val"
      with_busy "Rosetta $2" restart_vm || { notify "Rosetta change of $NAMED failed - $SEE_LOG"; exit 1; }
    else
      set_key rosetta "$val"
    fi
    ;;

  # k8s on|off. A stopped VM only gets the new value in colima.yaml. The
  # kubectl context does not exist before the first start with Kubernetes.
  # colima start switches to it.
  k8s)
    [ "$2" = on ] && val=true || val=false
    lock_vm
    vm_state
    if [ "$VM_UP" = 1 ]; then
      upgrade_confirm || exit 2
      mem_note=""
      # The note shows the value of colima.yaml, for example 2.5.
      mem_raw=$(yaml_value memory)
      gb=$(whole "$mem_raw")
      if [ "$2" = on ] && [ -n "$gb" ] && [ "$gb" -lt 4 ]; then
        mem_note=" The VM has $mem_raw GB of memory. Kubernetes uses about 0.5 to 1 GB of it."
      fi
      confirm "Turn Kubernetes (k3s) $2 for $NAMED? Colima will restart the VM and $(running_count) running container(s) will stop.$mem_note" || exit 2
      set_k8s "$val"
      with_busy "Kubernetes $2" restart_vm || { notify "Kubernetes change of $NAMED failed - $SEE_LOG"; exit 1; }
      # colima start also switches the context. This covers a Colima
      # version that does not.
      if [ "$2" = on ]; then
        kubectl config use-context "$KCTX" >/dev/null 2>&1 || true
      fi
    else
      set_k8s "$val"
    fi
    ;;

  # disk SIZE_GB (grow only). A stopped VM only gets the new size in
  # colima.yaml. Colima grows the disk at the next start.
  disk)
    case "$2" in *[!0123456789]*|"") notify "Invalid disk size: $2"; exit 1 ;; esac
    lock_vm
    no_start_in_progress
    if vm_up; then
      upgrade_confirm || exit 2
      confirm "Grow the Colima disk of $NAMED to $2 GB? A disk cannot shrink in place: to make it smaller later, all Docker data must be deleted. Colima will restart the VM and $(running_count) running container(s) will stop." || exit 2
      set_key disk "$2"
      with_busy "Growing disk to $2 GB" restart_vm || { notify "Disk resize of $NAMED failed - $SEE_LOG"; exit 1; }
    else
      confirm "Set the disk of $NAMED to $2 GB? Colima grows the disk at the next start. A disk cannot shrink in place: to make it smaller later, all Docker data must be deleted." || exit 2
      same_state 0 || state_changed
      set_key disk "$2"
    fi
    ;;

  # disk-shrink SIZE_GB: deletes the VM with all its data, then starts it
  # with a new, smaller disk. Disks cannot shrink in place. A stopped VM
  # starts once to create the disk, then stops again.
  disk-shrink)
    case "$2" in *[!0123456789]*|"") notify "Invalid disk size: $2"; exit 1 ;; esac
    size=$((10#$2))
    [ -f "$CONFIG" ] || { notify "$CONFIG not found."; exit 1; }
    cur=$(whole "$(yaml_value disk)")
    case "$cur" in *[!0123456789]*|"") notify "Couldn't read the disk size in colima.yaml."; exit 1 ;; esac
    if [ "$size" -lt "$MIN_DISK" ] || [ "$size" -ge "$cur" ]; then
      notify "Invalid disk size: $size GB. Use $MIN_DISK GB or more, and less than $cur GB."
      exit 1
    fi
    lock_vm
    k8s_note=""
    if tr -d '\r' <"$CONFIG" | sed -n '/^kubernetes:/,/^[a-z]/p' | grep -qE '^  enabled: true$'; then
      k8s_note=" The Kubernetes cluster and its data are also deleted."
    fi
    was_up=0
    restop=""
    after="Then Colima starts the VM again with an empty $size GB disk and the same settings."
    no_start_in_progress
    if vm_up; then
      was_up=1
    else
      restop=1
      after="Colima starts the VM once to create the new $size GB disk, then stops it again. The other settings stay the same."
    fi
    confirm "Delete all Docker data of $NAMED and shrink its disk from $cur GB to $size GB?

Colima deletes the VM and its disk. All containers, images, volumes and build cache are lost for good.$k8s_note

$after" || exit 2
    same_state "$was_up" || state_changed
    # Edit a copy first: if colima.yaml has no disk key, nothing is deleted.
    backup="$STATE_DIR/colima.$PROFILE.yaml.shrink"
    cp -p "$CONFIG" "$backup" || { notify "Couldn't copy colima.yaml to $backup."; exit 1; }
    set_key disk "$size" "$backup"
    FOLDER_NOTE=" A copy of colima.yaml is in $backup."
    with_busy "Shrinking disk to $size GB" shrink_disk "$backup" "$restop"
    rc=$?
    if [ "$rc" -eq "$RESTOP_FAILED" ]; then
      rm -f "$backup"
      notify "The disk of $NAMED is now $size GB, but the stop failed - $SEE_LOG"
      exit 1
    fi
    [ "$rc" -eq 0 ] \
      || { notify "Disk shrink of $NAMED failed - $SEE_LOG. A copy of colima.yaml is in $backup."; exit 1; }
    rm -f "$backup"
    ;;

  # stale-files: prints the pid files of Lima and Colima that they cannot use, one per
  # line: REASON<TAB>PATH<TAB>PID. It takes no lock and changes nothing.
  stale-files) stale_files ;;

  # repair: for a VM that does not start (a Lima pid file names a process
  # that is gone or that is not Lima, or the pid file of the Colima daemon).
  # Stops the VM by force, removes the stale pid files (see stale_files) and starts the VM.
  repair)
    lock_vm
    [ -f "$CONFIG" ] || { notify "Can't repair $NAMED. Its colima.yaml does not exist."; exit 1; }
    no_start_in_progress " If it hangs, stop it (Ctrl-C), then try again."
    list=""
    while IFS=$'\t' read -r reason path pid; do
      [ -n "$path" ] && list=$(printf '%s\n- %s (%s)' "$list" "$(short_path "$path")" "$reason")
    done <<<"$(stale_files)"
    [ -n "$list" ] || list=$(printf '\nNo stale pid file was found.')
    confirm "Repair $NAMED?

ColimaBar removes the pid files that name another process, stops the VM by force, removes the other stale pid files and starts the VM. Running containers stop. Disks, images and volumes stay.
$list" || exit 2
    with_busy "Repairing" repair_vm
    rc=$?
    # repair_vm has given the reason for this code.
    [ "$rc" -eq "$REMOVE_FAILED" ] && exit 1
    if [ "$rc" -eq "$STILL_RUNS" ]; then
      notify "The VM of $NAMED still runs. Nothing more was removed - $SEE_LOG"
      exit 1
    fi
    [ "$rc" -eq 0 ] || { notify "Repair of $NAMED failed - $SEE_LOG"; exit 1; }
    ;;

  copy-env)
    # ColimaBar's stable socket. While ColimaBar runs, it starts Colima on demand.
    # After ColimaBar quits, the path links to Colima's socket. It still reaches
    # Colima, but it does not start Colima.
    printf 'export DOCKER_HOST=unix://%s' "$HOME/.cache/colima-bar/docker.sock" | pbcopy ;;

  # Per-container actions: ctr-start|ctr-stop|ctr-restart|ctr-rm|ctr-logs|ctr-shell NAME
  # "--" ends the options, so a name that starts with "-" is not read as a flag.
  ctr-start)   docker start -- "$2" >/dev/null || { notify "Failed to start $2"; exit 1; } ;;
  # A clean stop first (up to 10 s), so the container can shut down properly.
  # docker stop does nothing to a container that is not running.
  ctr-rm)      confirm "Remove container $2? If it is running, it stops first (up to 10 seconds)." || exit 2
               { docker stop -- "$2" && docker rm -- "$2"; } >/dev/null || { notify "Failed to remove $2"; exit 1; } ;;
  ctr-stop)    docker stop -- "$2" >/dev/null || { notify "Failed to stop $2"; exit 1; } ;;
  ctr-restart) docker restart -- "$2" >/dev/null || { notify "Failed to restart $2"; exit 1; } ;;
  ctr-logs)    exec docker logs -f --tail 200 -- "$2" ;;
  ctr-shell)   exec docker exec -it -- "$2" sh -c 'command -v bash >/dev/null && exec bash || exec sh' ;;
  # Compose projects: compose-pull|compose-up|compose-down NAME DIR NENV ENV... FILE...
  # Not VM actions: no lock and no busy marker. Only down asks first.
  compose-pull) compose_check "${@:2}"; compose_run pull "${@:2}" ;;
  compose-up)   compose_check "${@:2}"; compose_run up "${@:2}" ;;
  compose-down)
    compose_check "${@:2}"
    confirm "Stop and remove the containers and networks of the Compose project $2 in $NAMED? Volumes and images stay." || exit 2
    compose_run down "${@:2}" ;;
  # Idle auto-stop from ColimaBar: no confirmation, just a notification.
  auto-stop)
    lock_vm quiet
    with_busy "Auto-stopping $PROFILE" colima stop || { notify "Auto-stop of $NAMED failed - $SEE_LOG"; exit 1; } ;;

  # profile-create CPU MEM_GB DISK_GB [RUNTIME]: creates the profile in
  # COLIMABAR_PROFILE and starts its VM. RUNTIME is docker (default) or
  # containerd. ColimaBar asked for the values in its form, so no dialog.
  profile-create)
    cpu="$2"; mem="$3"; disk="$4"; rt="${5:-docker}"
    new_name_ok "$PROFILE" || {
      notify "Invalid profile name: $PROFILE. Use lowercase letters, digits and single hyphens, 30 characters at most."
      exit 1
    }
    if ! is_num "$cpu" || ! is_num "$mem" || ! is_num "$disk" \
      || [ "$cpu" -lt 1 ] || [ "$mem" -lt 1 ] || [ "$disk" -lt "$MIN_DISK" ]; then
      notify "Invalid CPU/memory/disk for $NAMED: $cpu / $mem / $disk"
      exit 1
    fi
    case "$rt" in docker|containerd) ;; *) notify "Invalid runtime: $rt"; exit 1 ;; esac
    # The Mac file system ignores case, so this also finds "Work" for "work".
    if [ -e "$PROFILE_DIR" ]; then
      notify "Profile $PROFILE already exists."
      exit 1
    fi
    lock_vm
    with_busy "Creating $PROFILE" start_vm --cpu "$cpu" --memory "$mem" --disk "$disk" --runtime "$rt" \
      || { notify "Creating $NAMED failed - $SEE_LOG"; exit 1; }
    ;;

  # profile-delete: deletes the profile in COLIMABAR_PROFILE with its VM,
  # disk and folder. ColimaBar asked for the typed profile name before.
  profile-delete)
    # Colima maps "colima" to "default" and removes a "colima-" prefix.
    # Thus `colima delete --profile colima-work` deletes the profile work.
    case "$PROFILE" in
      colima|colima-*)
        notify "Can't delete $NAMED. Colima reads this name as a different profile."
        exit 1 ;;
    esac
    if ! profile_dir_exists; then
      notify "Can't delete $NAMED. Its folder $PROFILE_DIR does not exist."
      exit 1
    fi
    lock_vm
    msg="Delete $NAMED? Colima deletes its VM and disk. All containers, images, volumes and build cache of this profile are lost for good."
    if vm_up; then
      msg="$msg The VM runs now, and $(running_count) running container(s) will stop."
    fi
    if [ "$PROFILE" = default ]; then
      msg="$msg

'default' is the main Colima profile. A plain colima start creates it again with an empty disk."
    fi
    confirm "$msg" || exit 2
    with_busy "Deleting $PROFILE" colima delete --data --force \
      || { notify "Deleting $NAMED failed - $SEE_LOG"; exit 1; }
    ;;

  # Images and volumes: img-rm REF | img-pull REF | vol-rm NAME
  img-rm)
    confirm "Remove image $2?" || exit 2
    out=$(docker rmi -- "$2" 2>&1) || { notify "Remove failed: ${out##*: }"; exit 1; } ;;
  img-pull)
    # Not a VM action: no busy marker, so the dashboard stays usable.
    docker pull -q -- "$2" >/dev/null || { notify "Pull failed for $2"; exit 1; } ;;
  vol-rm)
    confirm "Remove volume $2? Data in it is lost for good." || exit 2
    out=$(docker volume rm -- "$2" 2>&1) || { notify "Remove failed: ${out##*: }"; exit 1; } ;;

  stop-all)
    n=$(running_count)
    [ "$n" -gt 0 ] || exit 0
    confirm "Stop all $n running container(s) of $NAMED?" || exit 2
    docker ps -q | xargs docker stop >/dev/null || { notify "Failed to stop some containers"; exit 1; }
    ;;

  # Cleanup: prune dangling|images|volumes|all
  prune)
    case "$2" in
      dangling) msg="Remove dangling images and build cache of $NAMED?"
                cmd() { docker image prune -f && docker builder prune -f; } ;;
      images)   msg="Remove ALL images of $NAMED not used by a container? They will need to be pulled again."
                cmd() { docker image prune -af; } ;;
      volumes)  msg="Remove ALL volumes of $NAMED not used by a container? Data in them is lost for good."
                cmd() { docker volume prune -af; } ;;
      all)      msg="Full cleanup of $NAMED: stopped containers, unused networks, all unused images and build cache? (Volumes are kept.)"
                cmd() { docker system prune -af; } ;;
      *) exit 1 ;;
    esac
    confirm "$msg" || exit 2
    cmd >/dev/null || { notify "Cleanup of $NAMED failed - $SEE_LOG"; exit 1; }
    ;;

  # exec skips shell functions, so pass the profile here.
  ssh)    colima_home; exec command colima ssh --profile "$PROFILE" ;;
  config) open -t "$CONFIG" ;;
  logs)
    # ColimaBar's action log (colima start/stop output) and Lima's host agent log.
    files=()
    for f in "$CTL_LOG" "$LIMA_LOG"; do [ -f "$f" ] && files+=("$f"); done
    if [ ${#files[@]} -eq 0 ] || ! open -a Console "${files[@]}"; then notify "No Colima logs yet."; fi ;;

  *)
    echo "usage: $0 {start|stop|restart|resources CPU MEM|rosetta on|off|k8s on|off|disk GB|vm-config STAGED SHA|disk-shrink GB|ctr-*|compose-pull|compose-up|compose-down NAME DIR NENV ENV... FILE...|img-rm|img-pull|vol-rm|stop-all|prune KIND|ssh|config|logs|copy-env|stale-files|repair|auto-stop MIN|profile-create CPU MEM DISK [RUNTIME]|profile-delete}" >&2
    echo "env: COLIMABAR_PROFILE selects the colima profile (default: default)" >&2
    echo "env: COLIMABAR_EXPECT_RUNNING=1|0 makes resources, rosetta, k8s and vm-config stop if the VM state differs" >&2
    echo "env: COLIMABAR_UPGRADE_NOTE and COLIMABAR_RELEASE_NOTES make start, restart and the config actions ask after an upgrade" >&2
    exit 1 ;;
esac
