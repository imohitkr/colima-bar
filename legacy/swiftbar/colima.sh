#!/bin/bash
# <xbar.title>Colima</xbar.title>
# <xbar.desc>Colima status, resources, containers, Rosetta and cleanup.</xbar.desc>
# <swiftbar.type>streamable</swiftbar.type>
# <swiftbar.hideRunInTerminal>true</swiftbar.hideRunInTerminal>
# <swiftbar.hideLastUpdated>true</swiftbar.hideLastUpdated>
[ -z "$COLIMA_BAR_BASH" ] && [ -x /opt/homebrew/bin/bash ] && COLIMA_BAR_BASH=1 exec /opt/homebrew/bin/bash "$0" "$@"
export PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export XDG_CONFIG_HOME="$HOME/.config"

CTL="$HOME/.local/bin/colima-ctl.sh"
CONFIG="$XDG_CONFIG_HOME/colima/default/colima.yaml"
BUSY="$HOME/.cache/colima-bar/busy"

PRESETS=("Light:2:4" "Standard:4:8" "Heavy:8:16")
CPU_OPTS=(2 4 6 8 10 12)
MEM_OPTS=(4 8 12 16 24 32)

act() { echo "$1 | bash=$CTL ${2:+param1=$2} ${3:+param2=$3} ${4:+param3=$4} terminal=false refresh=true $5"; }
term() { echo "$1 | bash=$CTL param1=$2 ${3:+param2=$3} terminal=true"; }

CACHE="$HOME/.cache/colima-bar"
mkdir -p "$CACHE"

# bg_cache NAME MAX_AGE_S cmd... -> refresh $CACHE/NAME in the background when
# older than MAX_AGE_S and no refresh is already in flight.
bg_cache() {
  local name="$1" age="$2"; shift 2
  local f="$CACHE/$name"
  [ -e "$f.lock" ] && return
  if [ -f "$f" ] && [ $(( $(date +%s) - $(stat -f %m "$f") )) -lt "$age" ]; then
    return
  fi
  touch "$f.lock"
  ( "$@" > "$f.tmp" 2>/dev/null && mv "$f.tmp" "$f"; rm -f "$f.lock" ) >/dev/null 2>&1 3<&- &
}

render() {
  if [ -f "$BUSY" ]; then
    echo ":hourglass: | sfcolor=#FF9800"
    echo "---"
    echo "$(cat "$BUSY")... | color=#FF9800"
    echo "---"
    echo "Refresh | refresh=true"
    return
  fi

  if ! colima status >/dev/null 2>&1; then
    echo ":shippingbox: | sfcolor=#9E9E9E"
    echo "---"
    echo "Stopped | color=#9E9E9E"
    echo "---"
    act "Start" start "" "" "sfimage=play.fill"
    echo "---"
    echo "Open colima.yaml | bash=$CTL param1=config terminal=false"
    echo "Open Colima log | bash=$CTL param1=logs terminal=false"
    echo "Refresh | refresh=true"
    return
  fi

  cfg() { sed -nE "s/^$1: (.*)/\1/p" "$CONFIG" | head -1; }
  info=$(colima list -j 2>/dev/null | head -1)
  cpus=$(sed -nE 's/.*"cpus":([0-9]+).*/\1/p' <<<"$info")
  mem=$(( $(sed -nE 's/.*"memory":([0-9]+).*/\1/p' <<<"$info") / 1073741824 ))
  disk=$(( $(sed -nE 's/.*"disk":([0-9]+).*/\1/p' <<<"$info") / 1073741824 ))
  rosetta=$(cfg rosetta)
  k8s=$(sed -nE '/^kubernetes:/,/^[a-z]/ s/^  enabled: (.*)/\1/p' "$CONFIG" | head -1)
  containers=$(docker ps --format '{{.Names}}|{{.Image}}|{{.Status}}|{{.Ports}}' 2>/dev/null)
  running=$( [ -n "$containers" ] && wc -l <<<"$containers" | tr -d ' ' || echo 0)
  stopped=$(docker ps -a --filter status=exited --filter status=created --format '{{.Names}}|{{.Image}}|{{.Status}}' 2>/dev/null)
  # Slow calls run in the background; render reads their last result.
  bg_cache stats 0 docker stats --no-stream --format '{{.Name}}|{{.CPUPerc}}|{{.MemUsage}}'
  bg_cache df 30 docker system df --format '{{.Type}}|{{.Size}}|{{.Reclaimable}}'
  stats=""
  [ "$running" -gt 0 ] && stats=$(cat "$CACHE/stats" 2>/dev/null)

  # Menu bar title
  if [ "$running" -gt 0 ]; then
    echo "$running | sfimage=shippingbox.fill sfcolor=#4CAF50"
  else
    echo ":shippingbox.fill: | sfcolor=#4CAF50"
  fi
  echo "---"
  echo "Running - ${cpus} CPU / ${mem} GB / ${disk} GB disk | color=#4CAF50"
  [ "$rosetta" = true ] && echo "Rosetta on (amd64 emulation) | size=11"
  [ "$k8s" = true ] && echo "Kubernetes (k3s) on - context: colima | size=11"
  echo "---"

  # Resources
  echo "Resources | sfimage=cpu"
  for p in "${PRESETS[@]}"; do
    IFS=: read -r name c m <<<"$p"
    chk=$( [ "$c" = "$cpus" ] && [ "$m" = "$mem" ] && echo "checked=true" )
    act "--$name  (${c} CPU / ${m} GB)" resources "$c" "$m" "$chk"
  done
  echo "-----"
  echo "--CPU"
  for c in "${CPU_OPTS[@]}"; do
    chk=$( [ "$c" = "$cpus" ] && echo "checked=true" )
    act "----$c CPU" resources "$c" "$mem" "$chk"
  done
  echo "--Memory"
  for m in "${MEM_OPTS[@]}"; do
    chk=$( [ "$m" = "$mem" ] && echo "checked=true" )
    act "----$m GB" resources "$cpus" "$m" "$chk"
  done
  echo "-----"
  if [ "$rosetta" = true ]; then
    act "--Rosetta (amd64)" rosetta off "" "checked=true"
  else
    act "--Rosetta (amd64)" rosetta on
  fi
  if [ "$k8s" = true ]; then
    act "--Kubernetes (k3s)" k8s off "" "checked=true"
  else
    act "--Kubernetes (k3s)" k8s on
  fi
  echo "-----"
  echo "--Grow disk (now ${disk} GB)"
  for d in 150 200 300; do
    [ "$d" -gt "$disk" ] && act "----$d GB" disk "$d"
  done
  echo "----Disks can only grow, not shrink | color=#9E9E9E size=11"

  # Containers
  echo "Containers ($running running) | sfimage=square.stack.3d.up"
  if [ "$running" -eq 0 ]; then
    echo "--No running containers | color=#9E9E9E"
  else
    while IFS='|' read -r name image status ports; do
      usage=$(grep "^$name|" <<<"$stats" | head -1 | cut -d'|' -f2- | sed 's/|/ · /')
      echo "--$name${usage:+   $usage} | sfimage=cube"
      echo "----$image | color=#9E9E9E size=11"
      echo "----$status | color=#9E9E9E size=11"
      echo "------"
      for port in $(grep -oE '(0\.0\.0\.0|127\.0\.0\.1|\[::\]):[0-9]+->' <<<"$ports" | grep -oE ':[0-9]+' | tr -d ':' | sort -un); do
        echo "----Open localhost:$port | href=http://localhost:$port sfimage=safari"
      done
      term "----Logs" ctr-logs "$name"
      term "----Shell" ctr-shell "$name"
      act "----Restart" ctr-restart "$name"
      act "----Stop" ctr-stop "$name"
    done <<<"$containers"
    echo "-----"
    act "--Stop all" stop-all
  fi
  if [ -n "$stopped" ]; then
    echo "-----"
    echo "--Stopped | color=#9E9E9E size=11"
    while IFS='|' read -r name image status; do
      echo "--$name | sfimage=cube.transparent color=#9E9E9E"
      echo "----$image | color=#9E9E9E size=11"
      echo "----$status | color=#9E9E9E size=11"
      echo "------"
      act "----Start" ctr-start "$name"
      term "----Logs" ctr-logs "$name"
      act "----Remove" ctr-rm "$name"
    done <<<"$stopped"
  fi

  # Cleanup
  echo "Disk & cleanup | sfimage=trash"
  cat "$CACHE/df" 2>/dev/null |
    while IFS='|' read -r type size recl; do
      echo "--$type: $size  (reclaimable $recl) | color=#9E9E9E size=12"
    done
  echo "-----"
  act "--Remove dangling images & build cache" prune dangling
  act "--Remove all unused images" prune images
  act "--Remove unused volumes" prune volumes
  act "--Full cleanup (keeps volumes)" prune all

  echo "---"
  act "Restart" restart "" "" "sfimage=arrow.clockwise"
  act "Stop" stop "" "" "sfimage=stop.fill"
  echo "---"
  term "SSH into VM" ssh
  echo "Copy DOCKER_HOST export | bash=$CTL param1=copy-env terminal=false"
  echo "Open colima.yaml | bash=$CTL param1=config terminal=false"
  echo "Open Colima log | bash=$CTL param1=logs terminal=false"
  echo "Refresh | refresh=true"
}

# Streamable: redraw immediately on any docker event (container start/stop/die,
# image pull, ...) and at least every TICK seconds for live CPU/RAM numbers.
TICK=2
rm -f "$CACHE"/*.lock

# Event stream feeds a FIFO held open read-write on fd 3, so reads never hit
# EOF; the docker events pid is tracked and restarted when it dies (VM stopped).
FIFO="$CACHE/events.$$"
rm -f "$FIFO"; mkfifo "$FIFO"
exec 3<>"$FIFO"
EPID=""
start_events() {
  docker events --filter type=container --filter type=image --filter type=volume \
    --format '{{.Type}}' >"$FIFO" 2>/dev/null 3<&- &
  EPID=$!
}
cleanup() { [ -n "$EPID" ] && kill "$EPID" 2>/dev/null; rm -f "$FIFO"; }
trap 'cleanup; exit 0' TERM INT HUP
trap cleanup EXIT
start_events

# Build the whole menu first and emit it in one write: printing "~~~" before a
# slow render makes SwiftBar flash its default title. Skip unchanged menus.
last=""
while true; do
  out=$(render)
  if [ "$out" != "$last" ]; then
    printf '~~~\n%s\n' "$out"
    last="$out"
  fi
  if read -r -t "$TICK" -u 3 _; then
    sleep 0.3                                 # let a burst of events settle
    while read -r -t 0.05 -u 3 _; do :; done  # drain it into one redraw
  fi
  kill -0 "$EPID" 2>/dev/null || start_events
done
