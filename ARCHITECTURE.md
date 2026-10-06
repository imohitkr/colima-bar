# Architecture

This document describes the high-level design of ColimaBar. Read it before you make a large change. For build, test and pull request steps, read [CONTRIBUTING.md](CONTRIBUTING.md). For the user guides, read [docs/](docs/README.md).

## Bird's-eye view

ColimaBar is a menu bar app for [Colima](https://github.com/abiosoft/colima). It does three jobs:

1. **The dashboard.** It shows the VM and its containers, and runs actions on them.
2. **Auto-start.** It runs a proxy on a stable unix socket. All docker clients use that socket. While the VM is down, the first real docker request starts Colima.
3. **Auto-stop.** It can stop the VM after an idle time.

ColimaBar is one native process. It uses Swift 6.4, SwiftPM and Apple frameworks only (AppKit, SwiftUI, Observation, UserNotifications, ServiceManagement). It has no third-party dependencies. It runs on Apple silicon with macOS 14 or later.

ColimaBar gets its data from three sources:

- **The Docker Engine API on the unix socket** of the selected profile. The docker CLI and Portainer use the same transport. `/events` streams changes. `/containers/{id}/stats?stream=1` streams samples for each container, but only while a dashboard is on screen. `docker stats --no-stream` blocks for about 2 seconds on each call, and the stream does not.
- **The `colima` CLI.** Colima has no API. Thus ColimaBar reads VM data from `colima list -j`, and the driver and mount type from `colima status -j`.
- **`scripts/colima-ctl.sh`.** The app bundle contains this script. VM actions, actions that ask for confirmation and changes to `colima.yaml` go through it. Container start, stop and restart calls go directly to the API.

<p align="center">
  <img src="docs/assets/architecture-overview.svg" width="900" alt="Docker clients connect to SocketProxy, which splices to the Colima Docker socket. ColimaModel drives the proxy wake, DockerAPI, Shell, Routing and the Views.">
</p>

## Code map

Sources live in `Sources/ColimaBar/`, in one folder per area. Each file holds one type, or one type and its small private helpers. The file has the name of the type. An extension file has the name `Type+Topic.swift`. Tests in `Tests/ColimaBarTests/` use the same folders.

### `App/`

`AppDelegate` owns the menu bar icon, the popover, the dashboard window, the right-click menu (`showMenu()`) and the debug flags. It also makes sure that only one instance runs. `AppDelegate+Relaunch` restarts the app after an update replaced its bundle. `MainMenu` adds the Edit and Window menus. `Snapshot` renders the debug screenshots.

### `Model/`

`ColimaModel` is the `@Observable` single source of truth for the dashboard, auto-start and auto-stop. It runs the heartbeat, starts the VM for the proxy (`wakeForProxy()`) and checks for idle time (`checkIdle()`).

- `ColimaModel+Rules`: static rules, for example when to hide the icon and how often the heartbeat runs.
- `ColimaModel+Events`: which `/events` messages cause which refresh.
- `ColimaModel+StartDetection`: finds a `colima start` that already runs, so ColimaBar does not start a second one.
- `CtlAction`: the actions of `colima-ctl.sh`.
- `DFGate`: allows one `/system/df` call at a time.
- `LatestOnly`: drops results of overlapping calls that arrive out of order.
- `Models`, `VMState`, `IdleMinutes`: row types, the VM state and the auto-stop times.

### `Docker/`

`DockerAPI` is a small Docker Engine API client over the unix socket. `DockerJSON` holds the JSON wire types.

### `Proxy/`

`SocketProxy` is the auto-start proxy. `SocketProxy+HTTP` parses just enough HTTP to answer pings and to classify requests. `UnixSocket` has the socket helpers.

### `System/`

- `Paths`: all file paths.
- `Shell`: runs `colima`, `colima-ctl.sh` and other tools, and opens iTerm or Terminal.
- `Routing`: sets and checks the docker routes.
- `LoginItem`: the login item.
- `Notifier` and `AlertThrottle`: notifications and their rate limit.
- `Updater`, `Version`, `ReleaseLink`: the daily release check.
- `Defaults`: `UserDefaults` access.
- `ColimaDirWatcher`: watches the Colima folders.
- `FileLimit`: raises the open file limit.

### `Logs/`

The log windows. `LogStore` holds the live state for one container. `LogDemuxer` splits the stdout and stderr frames of Docker. `LogFilter`, `LogBuffer`, `LogTrim` and `LogTail` filter and limit the lines. `LogView` and `LogWindows` show them.

### `Views/`

The dashboard UI. `Dashboard/` has the frame, header, live tiles, footer and the stopped screen. `Containers/` and `System/` hold those tabs. `ImagesTab.swift` and `VolumesTab.swift` are the other tabs. `Shared/` has the hover hints (`Hint.swift`), all hint text (`Help.swift`) and small shared views.

### `Support/`

Small helpers with no app state: `Parse` (for example `colima.yaml` lookup), byte formatting and bounded concurrency.

### Other files

| Path | Contents |
|---|---|
| `scripts/colima-ctl.sh` | VM actions, confirm dialogs and `colima.yaml` changes. The app bundle contains it. |
| `scripts/install.sh` | The installer. |
| `scripts/uninstall.sh` | The uninstall script. The app bundle contains it. |
| `scripts/make-icon.swift` | Draws `Resources/AppIcon.icns`. |
| `scripts/dmg-readme.txt` | The "Read Me First" file in the disk image. |
| `build.sh` | Builds the app bundle and the disk image. |
| `Makefile` | Shortcuts for build, test, lint and format. |
| `.swift-format` | The `swift format` rules. |
| `Tests/ColimaBarTests/` | Swift Testing tests, in the same folders as the sources. `TestSupport/` has the shared fakes and helpers. |
| `.github/workflows/ci.yml` | CI and the release job. |
| `.github/actions/setup-swift/` | Installs the Swift.org toolchain with swiftly for the macOS CI jobs. |
| `legacy/` | The old SwiftBar plugin. The app does not use it. |

## Cross-cutting concerns

### Auto-start proxy

All docker clients use one stable path: `~/.cache/colima-bar/docker.sock` (`Paths.proxySocket`). `Routing` points each client at it:

<p align="center">
  <img src="docs/assets/docker-routes.svg" width="900" alt="Each docker client reaches the stable socket through its own route. While ColimaBar runs, the socket is the proxy. When ColimaBar quits, it is a symlink to the Colima socket.">
</p>

| Client | Route |
|---|---|
| docker CLI and tools that read contexts | The docker context `colimabar`. ColimaBar switches to it only from `default` or a `colima*` context. |
| Apps opened from the Dock or Finder | `launchctl setenv DOCKER_HOST`. ColimaBar also sets `TESTCONTAINERS_DOCKER_SOCKET_OVERRIDE=/var/run/docker.sock` for Ryuk. |
| testcontainers | `docker.host` in `~/.testcontainers.properties`. The write follows a symlink and keeps the file mode. |
| Tools that only try `/var/run/docker.sock` | An optional symlink that needs an admin password (`Routing.linkVarRun()`). |

`Routing` never changes a route that points to a different daemon.

The proxy upstream is the socket of the selected profile. While the VM is up, the proxy splices bytes in both directions. While the VM is down, it does this:

<p align="center">
  <img src="docs/assets/auto-start-sequence.svg" width="900" alt="Sequence: the proxy answers a ping itself. A real request calls wakeForProxy, which runs colima start and readiness probes. Then the proxy splices the waiting request on the same connection.">
</p>


- It answers `GET` and `HEAD /_ping` itself, so idle pollers do not start the VM.
- For the first real request, it calls `wakeForProxy()`. Requests that arrive during a wake wait for the same wake.
- `wakeForProxy()` waits for `colima start` to exit. Then it waits for several successful `/images/json` probes in a row. An open socket does not mean that Docker is ready.
- After the wake, the request continues on the same connection.

On quit, or when auto-start is off, `SocketProxy.stop()` replaces the path with a symlink to the Colima socket. It creates the link before it closes the listener, so a client never sees a missing socket.

### VM state

The heartbeat runs each second while a dashboard is open or an action runs. Otherwise it runs each 5 seconds. It pings the Docker socket each 3 seconds while a dashboard is open, and each 10 seconds otherwise.

ColimaBar runs `colima list -j` only in these cases:

- A ping shows that the VM went up or down.
- `ColimaDirWatcher` sees a change in `~/.config/colima`, a profile folder or a Lima instance folder.
- The dashboard opens and the last list is more than 1 minute old.
- The last list is more than 5 minutes old (1 minute when the state is not running or stopped).

### Actions and `colima-ctl.sh`

ColimaBar sends the selected profile in `COLIMABAR_PROFILE`. The script takes a lock for each profile and writes a busy marker while a VM action runs. Its stderr goes to `~/.cache/colima-bar/ctl.log`.

The exit codes are fixed. 0 means done. 1 means failed, and the script already notified the user. 2 means cancelled, or another VM action holds the lock. ColimaBar shows nothing for 2.

### Auto-stop

`checkIdle()` starts the idle time when no container runs and the proxy has no active transfers. A transfer is a connection whose latest request is a build, pull, push, load, save, commit or BuildKit session (`SocketProxy.isWork`). Before it stops the VM, it gets a fresh container list. If that fails, it does not stop.

### Login item

The login item is a plain LaunchAgent plist with the label `com.imohitkr.ColimaBar.login` in `~/Library/LaunchAgents`. It has `KeepAlive` for a failed exit, so launchd restarts ColimaBar after a crash. A normal quit is respected.

ColimaBar does not use `SMAppService`. launchd ties an `SMAppService` agent to the code signature, and each ad-hoc build has a new signature. `LoginItem.migrate()` removes the old agent one time.

### Notifications

Notifications go out only for failures: a container exits with an error, gets OOM-killed or becomes unhealthy, or an action fails. Containers with the label `org.testcontainers=true` do not send alerts. `AlertThrottle` allows one banner for each container and alert kind each 10 minutes. The dashboard keeps a list of recent alerts, so nothing is lost when notifications are off.

### Update check

`Updater` asks the GitHub releases API one time each day. It builds the release link from the tag and accepts only release pages of this repository.

### Performance and limits

When the dashboard is closed, the app idles at about 0% CPU. These limits keep memory and file use low:

| Limit | Value | Where |
|---|---|---|
| Open file limit | 8192 (launchd starts apps with 256) | `FileLimit`, login item plist |
| Lines in a log window | 20,000 lines and 32 MB of text | `LogLimits` |
| Rendered log lines | the newest 2,000; copy and filter use all lines | `LogTail` |
| Proxy request head | 64 KB, then HTTP 431 | `SocketProxy.maxHead` |
| Proxy copy buffer | 16 KB for each direction | `SocketProxy.bufferSize` |
| Idle client while the VM is down | closed after 5 minutes | `SocketProxy.idleTimeout` |
| `ctl.log` | starts again after 1 MB | `Shell` |

Live stats stream only while a dashboard is on screen. `/system/df` runs only for the tabs that show it. Graphs use SwiftUI `Shape`, not Swift Charts, because Swift Charts uses a lot of graphics memory.

### Debug runs

`--snapshot`, `--popover` and `--notify-test` start a debug run. A debug run does not change the proxy socket, the docker routes or the login item. Thus it can run next to the installed app. [CONTRIBUTING.md](CONTRIBUTING.md#debug-flags) lists the flags.

## Invariants

[AGENTS.md](AGENTS.md#invariants) has the full list. The most important rules are these:

- The popover has a fixed size. `ColimaModel` assigns a property only when its value changes.
- The proxy socket path does not change. The socket has mode `0600`, and its folder has mode `0700`.
- Docker clients must keep working without ColimaBar. On quit, the socket path becomes a symlink to the Colima socket.
- No request goes to the daemon before the readiness gate after a wake passes.
- A debug run never changes the proxy socket, the docker routes or the login item.

## Testing

Tests use Swift Testing. Logic lives in small static functions, so tests can call it without a VM. `Tests/ColimaBarTests/TestSupport/` has shared fakes, for example `FakeDaemon`. Automated runs never start or stop the user's Colima VM.
