#!/bin/bash
# Action backend for ColimaBar. Pins
# XDG_CONFIG_HOME so it always targets the same VM as an interactive `colima`.
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export XDG_CONFIG_HOME="$HOME/.config"

# Profile to act on: ColimaBar passes the selected one in COLIMABAR_PROFILE.
PROFILE="${COLIMABAR_PROFILE:-default}"
# A leading "." would allow "." and "..", which point outside the profile folder.
case "$PROFILE" in
  *[!A-Za-z0-9._-]*|.*|"") echo "invalid profile name: $PROFILE" >&2; exit 1 ;;
esac
CONFIG="$XDG_CONFIG_HOME/colima/$PROFILE/colima.yaml"
SOCK="$XDG_CONFIG_HOME/colima/$PROFILE/docker.sock"
export DOCKER_HOST="unix://$SOCK"
# kubectl context Colima creates: "colima" for default, "colima-NAME" otherwise.
KCTX=$([ "$PROFILE" = default ] && echo colima || echo "colima-$PROFILE")
LIMA_LOG="$XDG_CONFIG_HOME/colima/_lima/$([ "$PROFILE" = default ] && echo colima || echo "colima-$PROFILE")/ha.stderr.log"

# Every colima call targets the selected profile.
colima() { command colima "$@" --profile "$PROFILE"; }
STATE_DIR="$HOME/.cache/colima-bar"
BUSY="$STATE_DIR/busy.$PROFILE"
LOCK="$STATE_DIR/lock.$PROFILE"
CTL_LOG="$STATE_DIR/ctl.log"
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
  mkdir -p -m 700 "$STATE_DIR"
  if ! mkdir "$LOCK" 2>/dev/null; then
    # Take over a stale lock atomically: only one script wins the mv.
    if [ -n "$(find "$LOCK" -maxdepth 0 -mmin +30 2>/dev/null)" ] \
      && mv "$LOCK" "$LOCK.stale.$$" 2>/dev/null; then
      # Another script may have taken over first and made a fresh lock that
      # we just moved. If so, give it back.
      if [ -z "$(find "$LOCK.stale.$$" -maxdepth 0 -mmin +30 2>/dev/null)" ]; then
        [ -e "$LOCK" ] || mv "$LOCK.stale.$$" "$LOCK" 2>/dev/null
        rm -rf "$LOCK.stale.$$"
        [ "${1:-}" = quiet ] || notify "Another Colima action is still running for $PROFILE."
        exit 2
      fi
      rm -rf "$LOCK.stale.$$"
      mkdir "$LOCK" 2>/dev/null || exit 2
    else
      [ "${1:-}" = quiet ] || notify "Another Colima action is still running for $PROFILE."
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
  mkdir -p -m 700 "$STATE_DIR"
  echo "$label" > "$BUSY"
  WROTE_BUSY=1
  "$@" &
  CHILD=$!
  wait "$CHILD"
  local rc=$?
  CHILD=""
  rm -f "$BUSY"
  WROTE_BUSY=""
  return $rc
}

running_count() {
  docker ps -q 2>/dev/null | wc -l | tr -d ' '
}

# set_key KEY VALUE -> sets a top-level key in colima.yaml and checks it took.
set_key() {
  [ -f "$CONFIG" ] || { notify "$CONFIG not found."; exit 1; }
  sed -i '' -E "s/^$1: .*/$1: $2/" "$CONFIG"
  grep -qE "^$1: $2\$" "$CONFIG" || { notify "Couldn't set $1 in colima.yaml (key not found)."; exit 1; }
}

restart_vm() {
  if colima status >/dev/null 2>&1; then
    colima stop || return 1
  fi
  colima start
}

case "$1" in
  start)
    lock_vm
    with_busy "Starting $PROFILE" colima start || { notify "Start failed - $SEE_LOG"; exit 1; } ;;
  stop)
    lock_vm
    with_busy "Stopping $PROFILE" colima stop || { notify "Stop failed - $SEE_LOG"; exit 1; } ;;
  restart)
    lock_vm
    with_busy "Restarting" restart_vm || { notify "Restart failed - $SEE_LOG"; exit 1; } ;;

  # resources CPU MEM_GB
  resources)
    cpu="$2"; mem="$3"
    case "$cpu$mem" in *[!0-9]*|"") notify "Invalid CPU/memory: $cpu / $mem"; exit 1 ;; esac
    lock_vm
    msg="Restart Colima with ${cpu} CPU / ${mem} GB RAM?"
    if colima status >/dev/null 2>&1; then
      msg="$msg $(running_count) running container(s) will stop."
    fi
    confirm "$msg" || exit 2
    set_key cpu "$cpu"
    set_key memory "$mem"
    with_busy "Applying ${cpu} CPU / ${mem} GB" restart_vm \
      || { notify "Failed to apply resources - $SEE_LOG"; exit 1; }
    ;;

  # rosetta on|off
  rosetta)
    [ "$2" = on ] && val=true || val=false
    lock_vm
    confirm "Turn Rosetta (amd64 emulation) $2? Colima will restart and $(running_count) running container(s) will stop." || exit 2
    set_key rosetta "$val"
    with_busy "Rosetta $2" restart_vm || { notify "Rosetta change failed - $SEE_LOG"; exit 1; }
    ;;

  # k8s on|off
  k8s)
    [ "$2" = on ] && val=true || val=false
    lock_vm
    confirm "Turn Kubernetes (k3s) $2? Colima will restart and $(running_count) running container(s) will stop." || exit 2
    [ -f "$CONFIG" ] || { notify "$CONFIG not found."; exit 1; }
    sed -i '' -E "/^kubernetes:/,/^[a-z]/ s/^  enabled: .*/  enabled: $val/" "$CONFIG"
    sed -n '/^kubernetes:/,/^[a-z]/p' "$CONFIG" | grep -qE "^  enabled: $val\$" \
      || { notify "Couldn't set kubernetes.enabled in colima.yaml."; exit 1; }
    with_busy "Kubernetes $2" restart_vm || { notify "Kubernetes change failed - $SEE_LOG"; exit 1; }
    if [ "$2" = on ]; then
      kubectl config use-context "$KCTX" >/dev/null 2>&1 || true
    fi
    ;;

  # disk SIZE_GB (grow only)
  disk)
    case "$2" in *[!0-9]*|"") notify "Invalid disk size: $2"; exit 1 ;; esac
    lock_vm
    confirm "Grow the Colima disk to $2 GB? Disks cannot be shrunk later. Colima will restart and $(running_count) running container(s) will stop." || exit 2
    set_key disk "$2"
    with_busy "Growing disk to $2 GB" restart_vm || { notify "Disk resize failed - $SEE_LOG"; exit 1; }
    ;;

  copy-env)
    # ColimaBar's stable socket: auto-starts Colima, works even when ColimaBar is quit.
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
    with_busy "Auto-stopping $PROFILE" colima stop || { notify "Auto-stop of $PROFILE failed - $SEE_LOG"; exit 1; } ;;

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
    confirm "Stop all $n running container(s)?" || exit 2
    docker ps -q | xargs docker stop >/dev/null || { notify "Failed to stop some containers"; exit 1; }
    ;;

  # Cleanup: prune dangling|images|volumes|all
  prune)
    case "$2" in
      dangling) msg="Remove dangling images and build cache?"
                cmd() { docker image prune -f && docker builder prune -f; } ;;
      images)   msg="Remove ALL images not used by a container? They will need to be pulled again."
                cmd() { docker image prune -af; } ;;
      volumes)  msg="Remove ALL volumes not used by a container? Data in them is lost for good."
                cmd() { docker volume prune -af; } ;;
      all)      msg="Full cleanup: stopped containers, unused networks, all unused images and build cache? (Volumes are kept.)"
                cmd() { docker system prune -af; } ;;
      *) exit 1 ;;
    esac
    confirm "$msg" || exit 2
    cmd >/dev/null || { notify "Cleanup failed - $SEE_LOG"; exit 1; }
    ;;

  # exec skips shell functions, so pass the profile here.
  ssh)    exec command colima ssh --profile "$PROFILE" ;;
  config) open -t "$CONFIG" ;;
  logs)
    # ColimaBar's action log (colima start/stop output) and Lima's host agent log.
    files=()
    for f in "$CTL_LOG" "$LIMA_LOG"; do [ -f "$f" ] && files+=("$f"); done
    [ ${#files[@]} -gt 0 ] && open -a Console "${files[@]}" || notify "No Colima logs yet." ;;

  *)
    echo "usage: $0 {start|stop|restart|resources CPU MEM|rosetta on|off|k8s on|off|disk GB|ctr-*|img-rm|img-pull|vol-rm|stop-all|prune KIND|ssh|config|logs|copy-env|auto-stop MIN}" >&2
    echo "env: COLIMABAR_PROFILE selects the colima profile (default: default)" >&2
    exit 1 ;;
esac
