#!/bin/bash
# Action backend for ColimaBar. Pins
# XDG_CONFIG_HOME so it always targets the same VM as an interactive `colima`.
export PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export XDG_CONFIG_HOME="$HOME/.config"

# Profile to act on: ColimaBar passes the selected one in COLIMABAR_PROFILE.
PROFILE="${COLIMABAR_PROFILE:-default}"
CONFIG="$XDG_CONFIG_HOME/colima/$PROFILE/colima.yaml"
SOCK="$XDG_CONFIG_HOME/colima/$PROFILE/docker.sock"
export DOCKER_HOST="unix://$SOCK"
# kubectl context Colima creates: "colima" for default, "colima-NAME" otherwise.
KCTX=$([ "$PROFILE" = default ] && echo colima || echo "colima-$PROFILE")

# Every colima call targets the selected profile.
colima() { command colima "$@" --profile "$PROFILE"; }
BUSY="$HOME/.cache/colima-bar/busy"

# Failures only. Run by ColimaBar, the message goes back to the app (native
# alert with ColimaBar's icon); run by hand, it falls back to osascript.
notify() {
  if [ -n "${COLIMABAR_APP:-}" ]; then
    echo "COLIMABAR_NOTIFY:$1"
  else
    osascript -e "display notification \"$1\" with title \"Colima\"" >/dev/null 2>&1
  fi
}

# confirm "message" -> exit status 0 only if the user clicked OK.
confirm() {
  osascript -e "display dialog \"$1\" with title \"Colima\" buttons {\"Cancel\", \"OK\"} default button \"OK\" cancel button \"Cancel\" with icon caution" >/dev/null 2>&1
}

# with_busy "label" cmd... -> writes the busy marker ColimaBar watches.
with_busy() {
  local label="$1"; shift
  mkdir -p "$(dirname "$BUSY")"
  echo "$label" > "$BUSY"
  "$@"
  local rc=$?
  rm -f "$BUSY"
  return $rc
}

running_count() {
  docker ps -q 2>/dev/null | wc -l | tr -d ' '
}

set_key() {
  sed -i '' -E "s/^$1: .*/$1: $2/" "$CONFIG"
}

restart_vm() {
  if colima status >/dev/null 2>&1; then
    colima stop
  fi
  colima start
}

case "$1" in
  start)
    with_busy "Starting $PROFILE" colima start || notify "Start failed - see /tmp/colima.err.log" ;;
  stop)
    with_busy "Stopping $PROFILE" colima stop || notify "Stop failed - see /tmp/colima.err.log" ;;
  restart)
    with_busy "Restarting" restart_vm || notify "Restart failed - see /tmp/colima.err.log" ;;

  # resources CPU MEM_GB
  resources)
    cpu="$2"; mem="$3"
    msg="Restart Colima with ${cpu} CPU / ${mem} GB RAM?"
    if colima status >/dev/null 2>&1; then
      msg="$msg $(running_count) running container(s) will stop."
    fi
    confirm "$msg" || exit 0
    set_key cpu "$cpu"
    set_key memory "$mem"
    with_busy "Applying ${cpu} CPU / ${mem} GB" restart_vm \
      || notify "Failed to apply resources - see /tmp/colima.err.log"
    ;;

  # rosetta on|off
  rosetta)
    [ "$2" = on ] && val=true || val=false
    confirm "Turn Rosetta (amd64 emulation) $2? Colima will restart and $(running_count) running container(s) will stop." || exit 0
    set_key rosetta "$val"
    with_busy "Rosetta $2" restart_vm || notify "Rosetta change failed"
    ;;

  # k8s on|off
  k8s)
    [ "$2" = on ] && val=true || val=false
    confirm "Turn Kubernetes (k3s) $2? Colima will restart and $(running_count) running container(s) will stop." || exit 0
    sed -i '' -E "/^kubernetes:/,/^[a-z]/ s/^  enabled: .*/  enabled: $val/" "$CONFIG"
    with_busy "Kubernetes $2" restart_vm || { notify "Kubernetes change failed"; exit 1; }
    [ "$2" = on ] && kubectl config use-context "$KCTX" >/dev/null 2>&1
    ;;

  # disk SIZE_GB (grow only)
  disk)
    confirm "Grow the Colima disk to $2 GB? Disks cannot be shrunk later. Colima will restart and $(running_count) running container(s) will stop." || exit 0
    set_key disk "$2"
    with_busy "Growing disk to $2 GB" restart_vm || notify "Disk resize failed"
    ;;

  copy-env)
    # ColimaBar's stable socket: auto-starts Colima, works even when ColimaBar is quit.
    printf 'export DOCKER_HOST=unix://%s' "$HOME/.cache/colima-bar/docker.sock" | pbcopy ;;

  # Per-container actions: ctr-start|ctr-stop|ctr-restart|ctr-rm|ctr-logs|ctr-shell NAME
  ctr-start)   docker start "$2" >/dev/null || notify "Failed to start $2" ;;
  ctr-rm)      confirm "Remove container $2?" && { docker rm "$2" >/dev/null || notify "Failed to remove $2"; } ;;
  ctr-stop)    docker stop "$2" >/dev/null || notify "Failed to stop $2" ;;
  ctr-restart) docker restart "$2" >/dev/null || notify "Failed to restart $2" ;;
  ctr-logs)    exec docker logs -f --tail 200 "$2" ;;
  ctr-shell)   exec docker exec -it "$2" sh -c 'command -v bash >/dev/null && exec bash || exec sh' ;;
  # Idle auto-stop from ColimaBar: no confirmation, just a notification.
  auto-stop)
    with_busy "Auto-stopping $PROFILE" colima stop || notify "Auto-stop of $PROFILE failed" ;;

  # Images and volumes: img-rm REF | img-pull REF | vol-rm NAME
  img-rm)
    confirm "Remove image $2?" || exit 0
    out=$(docker rmi "$2" 2>&1) || notify "Remove failed: ${out##*: }" ;;
  img-pull)
    with_busy "Pulling $2" docker pull -q "$2" >/dev/null || notify "Pull failed for $2" ;;
  vol-rm)
    confirm "Remove volume $2? Data in it is lost for good." || exit 0
    out=$(docker volume rm "$2" 2>&1) || notify "Remove failed: ${out##*: }" ;;

  stop-all)
    n=$(running_count)
    [ "$n" -gt 0 ] || exit 0
    confirm "Stop all $n running container(s)?" || exit 0
    docker stop $(docker ps -q) >/dev/null || notify "Failed to stop some containers"
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
    confirm "$msg" || exit 0
    with_busy "Cleaning up" cmd >/dev/null 2>&1 || notify "Cleanup failed"
    ;;

  ssh)    exec colima ssh ;;
  config) open -t "$CONFIG" ;;
  logs)   open -a Console /tmp/colima.err.log ;;

  *)
    echo "usage: $0 {start|stop|restart|resources CPU MEM|rosetta on|off|k8s on|off|disk GB|ctr-*|img-rm|img-pull|vol-rm|stop-all|prune KIND|ssh|config|logs|copy-env|auto-stop MIN}" >&2
    echo "env: COLIMABAR_PROFILE selects the colima profile (default: default)" >&2
    exit 1 ;;
esac
