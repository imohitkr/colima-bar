<p align="center">
  <img src="docs/screenshots/icon.png" width="112" alt="ColimaBar icon">
</p>

<h1 align="center">ColimaBar</h1>

<p align="center">
  A native macOS menu bar dashboard for <a href="https://github.com/abiosoft/colima">Colima</a> that <b>starts the VM on demand</b>.<br>
  Run <code>docker</code>, a test suite or an IDE test with Colima stopped; it boots and carries on.
</p>

<p align="center">
  <a href="https://github.com/imohitkr/colima-bar/actions/workflows/ci.yml"><img src="https://github.com/imohitkr/colima-bar/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-black?logo=apple" alt="macOS 14+">
  <img src="https://img.shields.io/badge/Swift-5.10-F05138?logo=swift&logoColor=white" alt="Swift 5.10">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue" alt="MIT license"></a>
</p>

<p align="center">
  <img src="docs/screenshots/containers.png" width="480" alt="Dashboard: containers grouped by Compose project, with health, ports, CPU and memory">
</p>

- **Zero-thought Docker**: every client (terminal, IDE, testcontainers) goes through one socket that boots Colima on the first real request. A cold `docker run` takes about 8 s.
- **Live dashboard**: containers grouped by Compose project, health, ports, per-container CPU and memory, logs, images, volumes and VM settings in one popover.
- **Quiet by default**: idles at ~0% CPU, can stop the VM when idle, and only notifies you when something actually breaks.

Left-click the menu bar icon for the dashboard. Right-click for quick actions (start/stop, window, auto-start, launch at login, quit). Hover over anything for an explanation.

## Screenshots

<table>
  <tr>
    <td width="50%"><img src="docs/screenshots/images.png" alt="Images tab: sizes, in-use badges, prune"></td>
    <td width="50%"><img src="docs/screenshots/system.png" alt="System tab: VM resources, features, disk usage, auto-start and auto-stop"></td>
  </tr>
  <tr>
    <td align="center"><b>Images</b>: sizes, what's in use, one-click prune</td>
    <td align="center"><b>System</b>: VM presets, Rosetta, k3s, disk, auto-start and auto-stop</td>
  </tr>
  <tr>
    <td colspan="2"><img src="docs/screenshots/logs.png" alt="Log viewer with search, follow, timestamps and highlighted stderr"></td>
  </tr>
  <tr>
    <td colspan="2" align="center"><b>Log viewer</b>: live follow, search, timestamps, stderr highlighted; survives container restarts</td>
  </tr>
</table>

## Quick start

```sh
git clone https://github.com/imohitkr/colima-bar && cd colima-bar
./build.sh install    # builds, installs to ~/Applications and launches
```

Needs macOS 14+, [Colima](https://github.com/abiosoft/colima) and the Xcode Command Line Tools. Then add the [`DOCKER_HOST` snippet](#auto-start-how-docker-clients-reach-colima) to your `~/.zshrc`. Or grab a prebuilt zip from the [releases page](https://github.com/imohitkr/colima-bar/releases) (clear quarantine once, see below).

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
git tag v0.2.0 && git push origin v0.2.0
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

## License

[MIT](LICENSE)
