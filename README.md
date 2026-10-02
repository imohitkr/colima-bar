# ColimaBar

A native macOS menu bar dashboard for [Colima](https://github.com/abiosoft/colima).
Left-click opens a live dashboard popover. Right-click opens a quick menu (start/stop, window, launch at login, quit).

It replaces an earlier SwiftBar plugin (kept in `legacy/swiftbar/`). SwiftBar rebuilds the whole menu on every update, so the menu jittered while you were reading it. ColimaBar updates only the values that change, so nothing moves while it's open.

## Features

- **VM**: status, start/stop/restart, CPU/memory presets and pickers, Rosetta and Kubernetes (k3s) toggles, grow disk, SSH, copy `DOCKER_HOST`, open `colima.yaml` / log
- **Live usage**: aggregate container CPU and memory as a share of the VM, with 60-second sparklines
- **Containers**: grouped by Compose project (start/stop/restart a whole project), health badges, per-container CPU/mem, `localhost` port links, logs, shell, restart, stop/start, remove, copy name/ID/exec command, filter and "running only"
- **Images**: size, age, in-use badge, pull, remove, prune dangling/unused
- **Volumes**: size, compose project, which are unused, remove, prune
- **Disk usage**: images / containers / volumes / build cache with reclaimable space, and cleanup actions
- **Notifications**: a container exits non-zero, is OOM-killed or turns unhealthy
- **Detached window**: the same dashboard in a resizable window
- Shortcuts: ⌘R refresh, ⌘F filter

## How it works

- Container data comes from the **Docker Engine API on Colima's unix socket** (`~/.config/colima/default/docker.sock`), the same transport Portainer and the docker CLI use. There's no process spawn per refresh.
  - `GET /events` streams changes, so the list updates as soon as anything happens.
  - `GET /containers/{id}/stats?stream=1` pushes one sample per second per container, but only while the dashboard is on screen. `docker stats --no-stream` blocks for about 2 s per call; the stream doesn't.
- Colima has no API of its own, so VM facts come from `colima list -j` / `colima status -j`. These run only when a socket `/_ping` says the VM went up or down, and otherwise once a minute.
- Actions that need a confirmation or edit `colima.yaml` go through `scripts/colima-ctl.sh` (installed to `~/.local/bin`). Plain container lifecycle calls go straight to the API.
- With the popover closed, the app idles at ~0% CPU.

## Build and install

Command Line Tools are enough; Xcode isn't needed. Requires macOS 14+.

```sh
./build.sh            # build/ColimaBar.app
./build.sh install    # install to ~/Applications, install colima-ctl.sh, relaunch
```

The first launch from `~/Applications` registers ColimaBar as a login item. You can turn it off from the System tab or the right-click menu.

Logs, shell and SSH open in iTerm (Terminal.app if iTerm is not installed).

Debug: `ColimaBar.app/Contents/MacOS/ColimaBar --snapshot out.png [Containers|Images|Volumes|System]` renders the dashboard to a PNG and quits.

## Roadmap

- Multiple Colima profiles
- kubectl context / namespace switcher
- Inline log tail with search
- Docker context switcher
- Global hotkey
- Auto-stop the VM when idle
