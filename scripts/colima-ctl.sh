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
LIMA_LOG="$LIMA_DIR/$([ "$PROFILE" = default ] && echo colima || echo "colima-$PROFILE")/ha.stderr.log"

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

# lock_vm -> takes this profile's lock for a VM action (confirm dialog
# included), so two starts/restarts can't run at once. A lock older than 30
# minutes is left over from a killed script and is taken over.
# lock_vm [quiet] -> "quiet" skips the notice (timer-driven auto-stop).
HOLD_LOCK=""
lock_vm() {
  (umask 077 && mkdir -p "$STATE_DIR")  # private: 0700
  if ! mkdir "$LOCK" 2>/dev/null; then
    # Take over a stale lock atomically: only one script wins the mv.
    if [ -n "$(find "$LOCK" -maxdepth 0 -mmin +30 2>/dev/null)" ] \
      && mv "$LOCK" "$LOCK.stale.$$" 2>/dev/null; then
      # Another script may have taken over first and made a fresh lock that
      # we just moved. If so, give it back.
      if [ -z "$(find "$LOCK.stale.$$" -maxdepth 0 -mmin +30 2>/dev/null)" ]; then
        [ -e "$LOCK" ] || mv "$LOCK.stale.$$" "$LOCK" 2>/dev/null
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
}

# Clean up on any exit, and stop the running action when ColimaBar times
# us out. Bash runs a trap only after a foreground child exits, so long
# actions run in the background and we `wait` for them (wait is interruptible).
WROTE_BUSY=""
CHILD=""
cleanup() {
  if [ -e "$FOLDER_CHANGED" ]; then
    rm -f "$FOLDER_CHANGED"
    notify "The Colima folder changed during the action of $NAMED. Try again.$FOLDER_NOTE"
  fi
  [ -n "$WROTE_BUSY" ] && rm -f "$BUSY"
  [ -n "$HOLD_LOCK" ] && rmdir "$LOCK" 2>/dev/null
  return 0
}
on_term() {
  if [ -n "$CHILD" ]; then
    pkill -TERM -P "$CHILD" 2>/dev/null
    kill -TERM "$CHILD" 2>/dev/null
  fi
  exit 143
}
trap cleanup EXIT
trap on_term TERM INT

# with_busy "label" cmd... -> writes the busy marker ColimaBar watches.
with_busy() {
  local label="$1"; shift
  (umask 077 && mkdir -p "$STATE_DIR")  # private: 0700
  echo "$label" > "$BUSY"
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

# The smallest disk that disk-shrink accepts, in GB.
MIN_DISK=10

# The exit code of shrink_disk when the new disk exists but the last stop
# failed. The caller tells the user.
RESTOP_FAILED=3

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
  colima start || return 1
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
  notify "A start of $NAMED runs now. Try again when it ends."
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

restart_vm() {
  if vm_up; then
    colima stop || return 1
  fi
  colima start
}

case "$1" in
  start)
    lock_vm
    with_busy "Starting $PROFILE" colima start || { notify "Start of $NAMED failed - $SEE_LOG"; exit 1; } ;;
  stop)
    lock_vm
    with_busy "Stopping $PROFILE" colima stop || { notify "Stop of $NAMED failed - $SEE_LOG"; exit 1; } ;;
  restart)
    lock_vm
    with_busy "Restarting" restart_vm || { notify "Restart of $NAMED failed - $SEE_LOG"; exit 1; } ;;

  # resources CPU MEM_GB. CPU is a whole number. MEM_GB is a whole or
  # decimal number of GiB, such as 2.5, as in Colima. Both must be 1 or
  # more. A stopped VM only gets the new values in colima.yaml, with no
  # dialog. They apply at the next start. This and rosetta and k8s read
  # COLIMABAR_EXPECT_RUNNING (see vm_state).
  resources)
    cpu="$2"; mem="$3"
    # The whole part of a decimal is 1 or more only for a value of 1 or more.
    if ! is_num "$cpu" || ! is_decimal "$mem" || [ "$cpu" -lt 1 ] || [ "${mem%%.*}" -lt 1 ]; then
      notify "Invalid CPU/memory for $NAMED: $cpu / $mem. Use at least 1 CPU and 1 GB of memory."
      exit 1
    fi
    lock_vm
    vm_state
    if [ "$VM_UP" = 1 ]; then
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

  # rosetta on|off. A stopped VM only gets the new value in colima.yaml.
  rosetta)
    [ "$2" = on ] && val=true || val=false
    lock_vm
    vm_state
    if [ "$VM_UP" = 1 ]; then
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
    with_busy "Creating $PROFILE" colima start --cpu "$cpu" --memory "$mem" --disk "$disk" --runtime "$rt" \
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
    echo "usage: $0 {start|stop|restart|resources CPU MEM|rosetta on|off|k8s on|off|disk GB|disk-shrink GB|ctr-*|img-rm|img-pull|vol-rm|stop-all|prune KIND|ssh|config|logs|copy-env|auto-stop MIN|profile-create CPU MEM DISK [RUNTIME]|profile-delete}" >&2
    echo "env: COLIMABAR_PROFILE selects the colima profile (default: default)" >&2
    echo "env: COLIMABAR_EXPECT_RUNNING=1|0 makes resources, rosetta and k8s stop if the VM state differs" >&2
    exit 1 ;;
esac
