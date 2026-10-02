# ColimaBar

A native macOS menu bar dashboard for [Colima](https://github.com/abiosoft/colima) that also **starts Colima on demand**: run `docker`, a test suite or an IDE test with the VM stopped, and it boots and carries on. A cold `docker run` takes about 8 s.

Left-click opens a live dashboard. Right-click opens quick actions (start/stop, window, auto-start, launch at login, quit). Hover over anything for an explanation.

## Features

- **Auto-start on demand**: every docker client goes through ColimaBar's socket, which boots Colima when a real request arrives (see below)
- **Auto-stop when idle** (opt-in): stop the VM after 15/30/60 min with no running containers
- **Live usage**: aggregate container CPU and memory as a share of the VM, with 60-second sparklines
- **Containers**: grouped by Compose project (start/stop/restart a whole project), health badges, per-container CPU/mem, `localhost` port links, restart/stop/start/remove, shell, filter, "running only"
- **Log viewer**: live per-container logs in their own window, with search, follow, timestamps, a stderr filter and copy. They survive container restarts. Or follow them in iTerm.
- **Images** and **Volumes**: sizes, in-use and unused, pull, remove, prune
- **VM settings**: CPU/memory presets, Rosetta, Kubernetes (k3s), grow disk, SSH, open `colima.yaml` and the log
- **Alerts, failures only**: a container exits non-zero, is OOM-killed or turns unhealthy, with **View logs** and **Restart** buttons; or an action fails. Nothing for routine start/stop.
- **Profiles**: if you have more than one Colima profile, a picker appears; otherwise it stays hidden
- Starts at login and relaunches itself if it ever crashes. Single instance. ⌘R refresh, ⌘F filter.

## Auto-start: how docker clients reach Colima

Everything points at one stable path, `~/.cache/colima-bar/docker.sock`:

| Client | Route |
|---|---|
| Terminal `docker`, scripts | `DOCKER_HOST` in `~/.zshrc` (falls back to Colima's socket if the path is missing) |
| IDE test runners and apps launched from the Dock | `launchctl setenv DOCKER_HOST`, set at login |
| Tools that read docker contexts | context `colimabar` |
| testcontainers (Java, Go) | `docker.host` in `~/.testcontainers.properties` |
| Tools that only try `/var/run/docker.sock` | optional symlink, from the **Link (admin)** button in the System tab |

While ColimaBar runs, that path is a proxy:
- If the VM is up, the proxy splices bytes to Colima's socket, so attach, exec, builds and log streams all work.
- If the VM is down, the proxy answers docker's preflight `/_ping` itself, so idle pollers don't boot the VM. The first real request starts Colima and continues on the same connection.

When ColimaBar quits, the path becomes a **symlink to Colima's socket**, so every client keeps working, just without auto-start. The routes never need switching back.

Your `~/.zshrc` should contain:

```sh
if [ -e "$HOME/.cache/colima-bar/docker.sock" ]; then
  export DOCKER_HOST="unix://$HOME/.cache/colima-bar/docker.sock"
else
  export DOCKER_HOST="unix://$HOME/.config/colima/default/docker.sock"
fi
```

An IDE that was already open when ColimaBar first ran must be restarted to pick up the launchd `DOCKER_HOST`.

## How it works

- Container data comes from the **Docker Engine API on the unix socket**, the same transport Portainer and the docker CLI use. `/events` streams changes, and `/containers/{id}/stats?stream=1` pushes per-container samples, but only while the dashboard is open. `docker stats --no-stream` blocks ~2 s per call; the stream doesn't.
- Colima has no API of its own, so VM facts come from `colima list -j` / `colima status -j`. These run only when a socket `/_ping` says the VM went up or down, and otherwise once a minute.
- Actions that need a confirmation or edit `colima.yaml` go through `scripts/colima-ctl.sh` (installed to `~/.local/bin`, profile chosen through `COLIMABAR_PROFILE`). Container lifecycle calls go straight to the API.
- With the dashboard closed, the app idles at ~0% CPU.
- Diagnostics: `log stream --predicate 'subsystem == "com.imohitkr.ColimaBar"'`

## Build, test, install

Command Line Tools are enough; Xcode isn't needed. Requires macOS 14+.

```sh
./build.sh test       # swift-testing suite (parsing, log demux, proxy end to end)
./build.sh            # build/ColimaBar.app
./build.sh install    # install to ~/Applications, install colima-ctl.sh, relaunch
```

CI (`.github/workflows/ci.yml`) runs the tests and builds the app on pushes to `main` and on PRs. Pushing a `v*` tag also publishes a zipped `.app` as a GitHub release:

```sh
git tag v1.0.0 && git push origin v1.0.0
```

The app is ad-hoc signed. A downloaded release zip is quarantined, so clear that once with `xattr -dr com.apple.quarantine ~/Applications/ColimaBar.app`.

Debug: `ColimaBar.app/Contents/MacOS/ColimaBar --snapshot out.png [Containers|Images|Volumes|System]` renders the dashboard to a PNG and quits (`COLIMABAR_SNAPSHOT_HEIGHT`, `COLIMABAR_HINT` and `COLIMABAR_LOGS=<container>` adjust it). `--popover [out.png]` does the same for the popover.

## Uninstall

```sh
scripts/uninstall.sh
```

This quits the app, removes the login agent, switches the docker context back to `colima`, clears the launchd `DOCKER_HOST` and the testcontainers `docker.host`, removes the `/var/run/docker.sock` link if ColimaBar made it, and deletes the app.

## Roadmap

- kubectl context / namespace switcher
- Global hotkey
- Docker context switcher for remote daemons
