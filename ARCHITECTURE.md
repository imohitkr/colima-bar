# Architecture

This document describes the high-level design of ColimaBar. Read it before you make a large change. For build, test and pull request steps, read [CONTRIBUTING.md](CONTRIBUTING.md). For the user guides, read [docs/](docs/README.md).

## Bird's-eye view

ColimaBar is a menu bar app for [Colima](https://github.com/abiosoft/colima). It does three jobs:

1. **The dashboard.** It shows the VM and its containers, and runs actions on them.
2. **Auto-start.** It runs a proxy on a unix socket, the stable socket. All docker clients use that socket. While the VM is down, the first real docker request starts Colima. Each docker profile also has its own proxy socket, the profile socket, which starts that profile.
3. **Auto-stop.** It can stop the VM of each running profile after an idle time.

ColimaBar is one native process. It uses Swift 6.4, SwiftPM and Apple frameworks only (AppKit, SwiftUI, Observation, UserNotifications, ServiceManagement, IOKit; `notify` is part of libSystem). It has no third-party dependencies. It runs on Apple silicon with macOS 14 or later.

ColimaBar gets its data from three sources:

- **The Docker Engine API on the unix socket** of the selected profile. For auto-stop and for starts, the model also calls the sockets of the other running profiles. The docker CLI and Portainer use the same transport. `/events` streams changes. `/containers/{id}/stats?stream=1` streams samples for each container, but only while a dashboard is on screen. `docker stats --no-stream` blocks for about 2 seconds on each call, and the stream does not.
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

`ColimaModel` is the `@Observable` single source of truth for the dashboard, auto-start and auto-stop. It runs the heartbeat, starts the VM of a profile for a proxy (`wakeForProxy(profile:)`), checks for idle time (`checkIdle()` for the selected profile, `checkOtherProfilesIdle()` for the others) and runs the profile actions (`createProfile`, `deleteProfile`, `startProfile`, `stopProfile`).

- `ColimaModel+Rules`: static rules, for example when to hide the icon and how often the heartbeat runs.
- `ColimaModel+Events`: which `/events` messages cause which refresh, and which ones go to `RemovedLogKeeper`.
- `ColimaModel+StartDetection`: finds a `colima start` that already runs, so ColimaBar does not start a second one.
- `ColimaModel+Settings`: reads the user settings for an export, and applies imported settings through the normal setters.
- `SettingsTransfer`: the settings file format (JSON with a format name and a version), its checks and the import plan.
- `DiskShrink`: the rules and the warning text for a smaller disk.
- `VMConfig`: the VM settings in the `colima.yaml` of the selected profile (`ColimaModel.config`), and the values that the settings show (`VMConfig.shown`). For a stopped VM, `colima list` shows the values of the last start, not the file. Memory is a decimal number of GiB, as in Colima: `memory: 2.5` is 2.5 GiB. CPU and disk are whole numbers.
- `AutoStopRule`: the idle rule for one profile (it uses `SuspendingClock`), the idle time for the power state (`limit`), the stop time and which other profiles auto-stop checks.
- `AfterSleepCheck`: which profiles the check after a system sleep covers, its ping delays and its notification texts.
- `ClockDrift`: measures the clock of a VM against the Mac, and builds the command that fixes it.
- `ProfileName`: the name rules of `colima-ctl.sh`, and the stricter rules for a new profile.
- `NewProfileForm`: the values and checks of the New Profile form.
- `ProfileDelete`: when a delete is refused, its warning text and the profile to select after it.
- `CtlAction`: the actions of `colima-ctl.sh`.
- Doctor, see [Doctor](#doctor): `DoctorCheck` (the nine checks), `DoctorResult` (a status, a detail and an optional `DoctorFix`), `DoctorFix`, `DoctorInputs` (everything the checks read), `DoctorRules` and `DoctorRules+Docker` (the pure rules: inputs in, results out), `DoctorReport` (the results of one run, its summary and its plain text), `ColimaModel+Doctor` (`runDoctor()`, `applyFix(_:)`, `repairProfile()`, `currentDoctorReport`, `doctorHint`). The parsers and rules have their own types: `ToolVersions`, `ShellStartupScan`, `DockerConfig`, `StaleLimaFile`, `DiskSpace`.
- `BusyMarker`: reads the busy marker (label and owner PID) and decides if it is stale.
- `DFGate`: allows one `/system/df` call at a time.
- `LatestOnly`: drops results of overlapping calls that arrive out of order.
- `Models`, `VMState`, `IdleMinutes`: row types, the VM state and the auto-stop times.

### `Docker/`

`DockerAPI` is a small Docker Engine API client over the unix socket. `DockerJSON` holds the JSON wire types.

### `Proxy/`

`SocketProxy` is the auto-start proxy. `SocketProxy+HTTP` parses just enough HTTP to answer pings and to classify requests. `ProfileProxies` owns one `SocketProxy` for each docker profile. `ProfileSocket` derives and checks the path of a profile socket. `UnixSocket` has the socket helpers.

### `System/`

- `Paths`: all file paths. `colimaDir` and `limaDir` find the Colima folder and Lima's folder with the rule in [Actions and `colima-ctl.sh`](#actions-and-colima-ctlsh). The model checks both folders again on each status refresh and each heartbeat tick.
- `Shell`: runs `colima`, `colima-ctl.sh` and other tools, and opens iTerm or Terminal.
- `Routing`: sets and checks the docker routes. `Routing.useOwnContext()` is the Doctor fix **Use colimabar**.
- `DoctorProbe`: all the I/O of Doctor (tool versions, `docker context ls`, the shell files, the docker config file, plugin folders, `colima-ctl.sh stale-files`, `df`). It reads only.
- `DockerConfigFile`: edits the docker config file for a Doctor fix: a private backup `config.json.colimabar-YYYYMMDD-HHMMSS`, then a write through a symlink.
- `ProcessProbe`: the start time of a process by PID (`sysctl`), for the busy marker.
- `ProfileContexts`: creates, updates and removes the `colimabar-PROFILE` docker contexts.
- `LoginItem`: the login item.
- `Notifier` and `AlertThrottle`: notifications and their rate limit.
- `SystemPowerObserver`: reports system sleep and the end of it. It also reports changes of the power state: the charger (`notify_register_dispatch` with `kIOPSNotifyPowerSource`), Low Power Mode and the thermal state. It is the only place that subscribes to power events.
- `PowerState`: on battery, Low Power Mode and a hot Mac, and the heartbeat saving that follows (`PowerState.Saving`). `read()` is the only part that calls IOKit and `ProcessInfo`.
- `Updater`, `Version`, `ReleaseLink`: the daily release check.
- `Defaults`: `UserDefaults` access.
- `ColimaDirWatcher`: watches the Colima folder, Lima's folder and their subfolders. Lima's folder can be outside the Colima folder (`LIMA_HOME`).
- `FileLimit`: raises the open file limit.

### `Logs/`

The log windows. `LogStore` holds the live state for one container. If the container is gone, it shows the lines that `RemovedLogKeeper` saved. `LogDemuxer` splits the stdout and stderr frames of Docker. `LogLine` is one line with its time, text and stream. `LogTime` parses the Docker timestamps fast, off the main thread. `LogFilter`, `LogBuffer`, `LogTrim` and `LogTail` filter and limit the lines. `LogLimits` holds the limits and timings of a log window. `LogView` and `LogWindows` show the lines. `RemovedLogKeeper` keeps the newest lines of auto-remove containers (`docker run --rm`) while the option is on, and keeps them for 5 minutes after a failure. `RemovedLogRing` is the buffer of one container: the stream thread stores the raw log bytes in it. ColimaBar parses them only when a log window opens.

### `Views/`

The dashboard UI. `Dashboard/` has the frame, header, live tiles, footer and the stopped screen. It also has `ViewState`, the UI state that survives when the popover closes (tab, filter, collapsed groups), and `Sparkline`, the `Shape` that draws the 60-second graphs. `Containers/` and `System/` hold those tabs. `Dashboard/` also has `NewProfileAlert` (the New Profile form) and `DeleteProfileAlert` (the typed confirmation before a profile delete). `System/` also has `VMSettingsSection` (the VM resources and features, on the System tab for a running VM and on the stopped screen for a stopped VM), `SettingsFilePanel` (the export and import panels) and `ShrinkDiskAlert` (the typed confirmation before a disk shrink). `ImagesTab.swift` and `VolumesTab.swift` are the other tabs. `Doctor/` has `DoctorView` (the Doctor page) and `DoctorRow` (one check). `Shared/` has the hover hints (`Hint.swift`), all hint text (`Help.swift`), `TypedNameWatcher` (turns on a destructive button when the typed text matches) and small shared views.

### `Support/`

Small helpers with no app state: `Parse` (for example `colima.yaml` lookup), byte formatting, bounded concurrency and `SymlinkWrite` (writes to the target of a symlink and keeps the mode; `Routing` and `DockerConfigFile` use it). `Logger+ColimaBar` creates loggers in the unified log subsystem `com.imohitkr.ColimaBar`.

### Other files

| Path | Contents |
|---|---|
| `scripts/colima-ctl.sh` | VM actions, confirm dialogs, `colima.yaml` changes, `stale-files` and `repair`. The app bundle contains it. |
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

## Cross-cutting concerns

### Auto-start proxy

All docker clients use the stable socket (`~/.cache/colima-bar/docker.sock`, `Paths.proxySocket`). Its path never changes, and it follows the selected profile. The user guides call it "the ColimaBar socket". This document calls it "the stable socket". "The proxy sockets" means the stable socket and all profile sockets. `Routing` points each client at the stable socket:

<p align="center">
  <img src="docs/assets/docker-routes.svg" width="900" alt="Each docker client reaches the ColimaBar socket through its own route. While ColimaBar runs, the socket is the proxy. When ColimaBar quits, it is a symlink to the Colima socket.">
</p>

| Client | Route |
|---|---|
| docker CLI and tools that read contexts | The docker context `colimabar`. ColimaBar switches to it from `default` or a `colima*` context at launch, whatever the auto-start setting. While auto-start is on, it also moves a `colima` or `colima-PROFILE` context back at any time. |
| IDEs and Dock apps | `launchctl setenv DOCKER_HOST`. ColimaBar also sets `TESTCONTAINERS_DOCKER_SOCKET_OVERRIDE=/var/run/docker.sock` for Ryuk. Both apply to all apps that launchd starts in the session. |
| testcontainers | `docker.host` in `~/.testcontainers.properties`. The write follows a symlink and keeps the file mode. |
| Tools that only try `/var/run/docker.sock` | An optional symlink that needs an admin password (`Routing.linkVarRun()`). |

`Routing.apply(selected:)` runs when the app starts. Colima switches the docker context on `start` and deletes it on `stop`. Thus `ColimaModel.checkDockerContext()` runs `Routing.restoreContext(selected:)`. It runs only while auto-start is on. The triggers are:

- Each VM action that was not cancelled.
- The end of a wake.
- A profile start or stop that `refreshStatus()` sees.
- A change of the mtime of the docker config file (`Routing.configStamp()`, one `stat` for each tick, through a symlink).
- Auto-start turning on.
- A retry 60 seconds after a failed check, at most three times in a row.

When a ColimaBar context is current, the check also sets the launchd and testcontainers routes. It reads `currentContext` from the config file, because `docker context show` fails when the context is missing. `Routing.contextTarget` decides the move. `Routing` never changes a route that points to a different daemon.

The upstream of the stable socket is the Colima socket of the selected profile. While the VM is up, the proxy splices bytes in both directions. While the VM is down, it does this:

<p align="center">
  <img src="docs/assets/auto-start-sequence.svg" width="900" alt="Sequence: the proxy answers a ping itself. A real request calls wakeForProxy, which runs colima start and readiness probes. Then the proxy splices the waiting request on the same connection.">
</p>

- It answers `GET` and `HEAD /_ping` itself, so idle pollers do not start the VM. It needs the daemon API version for this answer. `ColimaModel` stores the version from the last real ping in `UserDefaults`. Until the first one, a ping counts as a real request.
- For the first real request, it calls `wakeForProxy()`. Requests that arrive during a wake wait for the same wake.
- `wakeForProxy()` waits for `colima start` to exit. Then it waits for several successful `/images/json` probes in a row. An open socket does not mean that the Docker daemon is ready.
- After the wake, the request continues on the same connection. If the wake fails, the proxy answers HTTP 503 with a JSON `message`.
- `wakeForProxy()` does not start a deleted non-default profile, or a profile with a runtime other than docker.

On quit, or when auto-start is off, `SocketProxy.stop()` replaces the path with a symlink to the Colima socket. It creates the link before it closes the listener, so a client never sees a missing socket.

The listener is a GCD read source on a non-blocking fd. When a client waits, the event handler accepts all waiting clients and starts one thread for each connection. There is no accept thread for each proxy. Only the cancel handler of the source closes the fd. GCD runs it after the last event handler returns. Thus the system cannot give the same fd number to a new listener while an accept can still run on the old one.

### Profile sockets

`ProfileProxies` runs one more `SocketProxy` for each profile with the docker runtime in the last `colima list`. The socket is `~/.cache/colima-bar/profiles/PROFILE.sock` (`Paths.profileSocket`). Its upstream is the Colima socket of that profile. It changes only when the Colima folder moves (`ProfileProxies.refreshUpstreams()`). A real request to it calls `wakeForProxy(profile:)` for that profile only. The readiness gate and the refusals are the same as for the stable socket.

- `ProfileSocket.path` returns nil for an invalid name, or when the path is longer than 99 bytes: sun_path holds 103 bytes, and `UnixSocket.listen` binds at `PATH.tmp` first. ColimaBar logs the skipped name once.
- `refreshStatus()` calls `syncProfiles()` after each `colima list`. It creates the proxies of new profiles, removes the proxies of gone profiles and deletes old files in the folder. It keeps the proxy of a profile while its busy marker exists, because a disk shrink deletes the profile for a short time. An empty list changes nothing. A debug run changes nothing.
- `ProfileContexts` keeps one docker context `colimabar-PROFILE` for each proxy. It changes only contexts whose description starts with "ColimaBar". It runs the docker CLI only when the wanted set changes. The `colimabar` context, the launchd `DOCKER_HOST` and the testcontainers route still point at the stable socket.
- `wakeForProxy(profile:)` runs one wake at a time for each profile. The stable socket and the profile socket of the selected profile can ask for the same wake.
- `colima start` of any profile switches the docker context to `colima-PROFILE`. `Routing.restoreContext` moves a non-selected profile to `colimabar-PROFILE`, which has the same daemon and auto-start.
- Each proxy holds one listening fd and one GCD read source. It has no accept thread. Thus the idle cost grows by one fd for each profile.

On quit, or when auto-start is off, each profile socket becomes a symlink to the Colima socket of its profile.

### VM state

The heartbeat runs each second while a dashboard is open or an action runs. Otherwise its steps depend on the power state (`PowerState.saving`, `ColimaModel.tickInterval`, `pingInterval` and `staleAfter`). The model uses `.off` while a dashboard is open or an action runs.

| Saving | Tick | Ping | `colima list` (running or stopped) |
|---|---|---|---|
| Dashboard open | 1 s | 3 s | 5 min |
| Action runs, dashboard closed | 1 s | 10 s | 5 min |
| `.off` (charger) | 5 s | 10 s | 5 min |
| `.battery` | 10 s | 20 s | 10 min |
| `.strong` (Low Power Mode, or thermal state serious or critical) | 15 s | 30 s | 15 min |

Each ping time is a whole number of ticks. A VM in another state refreshes after 60 seconds. The proxies and the folder watcher do not depend on the tick. Auto-start and auto-stop read the busy marker directly, so auto-start is not slower. The hourglass for an action from outside the app follows the tick: in Low Power Mode with the dashboard closed, it can lag by up to about 22 seconds.

ColimaBar runs `colima list -j` only in these cases:

- A ping shows that the VM went up or down.
- `ColimaDirWatcher` sees a change in the Colima folder (`Paths.colimaDir`), a profile folder, Lima's folder (`Paths.limaDir`) or a Lima instance folder.
- The dashboard opens and the last list is more than 1 minute old.
- The last list is older than the time in the table above (5, 10 or 15 minutes; 1 minute when the state is not running or stopped).

The model reads the `colima.yaml` of the selected profile after each `colima list` that succeeds, each time the dashboard opens, and after a config edit of a stopped VM.

### Actions and `colima-ctl.sh`

ColimaBar sends the profile in `COLIMABAR_PROFILE`: the selected profile, or the profile of a profile menu action. The script takes a lock for each profile and writes a busy marker while a VM action runs. Its stderr goes to `~/.cache/colima-bar/ctl.log`. Each VM dialog of the script names the profile, for example "Grow the Colima disk of profile 'work' to 150 GB?".

`with_busy` runs the action in an extra subshell, `( "$@" ) &`. Without it, bash 3.2 (the `/bin/bash` of macOS) can run the first `command colima` of the action with `exec`. Then the action ends after that call. For example, `restart_vm` stops the VM but does not start it again. A test with stub tools (`ColimaCtlScriptTests`) checks this.

`profile-create CPU MEM DISK [RUNTIME]` runs `colima start` with these values for a new profile. It checks the name with the same rules as `ProfileName.problem`. `profile-delete` refuses the name `colima` and names that start with `colima-`, because Colima reads them as a different profile: it maps `colima` to `default` and removes the `colima-` prefix. It also refuses a profile without a folder. Then it asks once more and runs `colima delete --data --force`. The app shows a typed confirmation before it.

ColimaBar (`Paths.colimaDir`), the script and `uninstall.sh` find the Colima folder with the same rule as Colima. They use the first match:

1. `COLIMA_HOME`, if it is set and the folder exists.
2. `~/.colima`, if it exists.
3. `~/.config/colima`, if it exists.
4. `$XDG_CONFIG_HOME/colima`, if `XDG_CONFIG_HOME` is set.
5. `~/.colima`, the default of Colima.

Lima's folder (`Paths.limaDir`) is `LIMA_HOME` if it is set, else `_lima` in the Colima folder. ColimaBar runs each `colima` command, `colima-ctl.sh` and each Terminal command with `COLIMA_HOME` set to the Colima folder, so Colima uses the same folder. It creates the folder first, because Colima skips a `COLIMA_HOME` that does not exist. Before it creates the folder, the app and `colima-ctl.sh` check the rules again. They create the folder only if the rules still pick it and colima is installed. If the rules now pick a different folder, the script stops the action. A new empty `~/.colima` would otherwise hide `~/.config/colima` from then on. The app reads `COLIMA_HOME`, `LIMA_HOME` and `XDG_CONFIG_HOME` from its launchd environment, not from the shell. The model checks the folders again on each status refresh and each heartbeat tick, so a change needs no restart.

The name checks of the script list each allowed character, not a range such as `[a-z]`. Thus they match only ASCII in every locale.

`resources`, `rosetta`, `k8s` and `disk` restart a running VM after a dialog. For a stopped VM, they only change `colima.yaml`, and the values apply at the next start (`CtlAction.editsConfigWhenStopped`). They write no busy marker then, so the app shows "Saving" until the script ends. `resources`, `rosetta` and `k8s` show no dialog for a stopped VM. `disk` still asks, because the grow becomes permanent at the next start. If the VM starts or stops while that dialog is open, the script changes nothing and exits with 1. `k8s on` for a stopped VM does not switch the kubectl context. `colima start` switches to it.

`resources CPU MEM` takes a whole number of CPUs and a whole or decimal number of GiB for memory, such as 2.5. Both must be 1 or more. The memory picker of the app shows a value that is not a preset, such as 2.5 GB, as an extra choice. Thus a change of the CPU only sends the same memory again (`ByteFormat.gibText`). A value below 1 GB starts the pick at 1 GB, because the script refuses less. Colima gives Lima the memory in whole MiB, so `ByteFormat.gib(bytes:)` rounds to 2 decimals. While the VM runs, the settings show the value of `colima.yaml` if it differs from the live value by less than 0.006 GiB. The MiB cut and the rounding together stay below that (`VMConfig.shown`).

`run()` sends the VM state that it used for `showsDialog(running:)` in `COLIMABAR_EXPECT_RUNNING` (1 or 0), for each action whose dialog depends on the state (`CtlAction.checksExpectedState`: `resources`, `rosetta` and `k8s`). If the VM is in the other state, for example because it started outside the app, the script changes nothing and exits with 1 (`vm_state`). Thus no dialog opens behind the popover. After a config edit of a stopped VM, `execute` reads `colima.yaml` again before "Saving" ends.

While a `colima start` or `colima restart` for the profile runs (`start_in_progress`), the script refuses `disk`, `disk-shrink`, and `resources`, `rosetta` and `k8s`, before any dialog. It exits with 1. A restart would run a second `colima start` during it, and a shrink would delete the VM while it starts. During a start, `colima status` still fails. Thus while a dialog is open, a start that begins counts as a running VM (`same_state`).

`start_in_progress` uses the same rule as `ColimaModel.isStartInProgress`. The profile is the value of `--profile` or `-p` (also `--profile=NAME` and `-p=NAME`). Else it is the first word after `start` or `restart` that is not a flag and not the value of a flag, such as the `4` of `--cpu 4` (`ColimaModel.startValueFlags`). Else it is `default`. Colima reads `colima` as `default` and removes a `colima-` prefix. `colima start -f` does not count: it is a foreground supervisor. For `colima restart`, `-f` means `--force`, and it counts.

The script reads values of `colima.yaml` in the same forms as `VMConfig.parse`: with CRLF line ends, inline comments and quotes. The script runs `colima status` in a subshell. If the Colima folder changed, the main shell exits after the subshell, without the redirect, so the notice of `cleanup` reaches the app.

A disk cannot shrink in place. `disk-shrink N` saves a copy of `colima.yaml` with `disk: N`, then runs `colima stop`, `colima delete --data --force`, puts the copy back and runs `colima start`. `colima delete` removes the profile folder with `colima.yaml`, so the copy keeps the other VM settings. Colima creates the new disk only at a start. Thus for a stopped VM, the script runs `colima stop` at the end. The busy marker covers the full run. That start switches the docker context, so the model checks the context after the shrink like after any VM action. While the busy marker exists, the model does not switch away from a profile that `colima list` no longer shows, and auto-start waits.

The script puts its PID in the lock (`lock.PROFILE/pid`, written through a temporary file and `mv`) and in line 2 of the busy marker (line 1 is the label). A leftover is stale when `ps` shows that its owner is gone, or that the PID belongs to a process that started after the file was written (`owner_check`, with `ps -o command=` and `ps -o etime=`). If the PID cannot be read, the lock follows the 30-minute rule. A lock folder with no PID file, left by an owner that is ending, is removed, not given back. Age alone does not free a lock whose owner runs, so a long sleep of the Mac cannot free the lock of an action that still runs. A lock or marker with no PID (older versions) keeps the old rule: 30 and 20 minutes. `ColimaModel` reads the marker with `BusyMarker` and `ProcessProbe` and removes a stale one.

`stale-files` prints the pid files of Lima and of the Colima daemon that they cannot use, as `reason<TAB>path<TAB>pid` lines (`gone`, `reused`, `invalid`). It takes no lock, writes no busy marker and runs no `colima` command. `repair` is the action behind Doctor's **Repair**: see [Doctor](#doctor).

The exit codes are fixed. 0 means done. 1 means failed, and the script already notified the user. 2 means cancelled, or another VM action holds the lock. ColimaBar shows nothing for 2.

### Doctor

Doctor checks the setup of the selected profile. It runs only on request: the **Run checks** button, or the Doctor page when it opens and the last report is more than 5 minutes old (`DoctorReport.staleAfter`). It never runs from the heartbeat. The checks never send a notification. **Use colimabar**, **Set routes**, **Use osxkeychain** and **Add folder** send one with the result. **Repair…** sends one only if it fails. **Copy line** sends none. One run at a time (`isDoctorRunning`). A profile switch drops the result of a run in progress (`generation`). A request during a run (`isDoctorRunQueued`) makes the run start once more, so the new profile gets its report. A probe that fails gives a skipped or warning result, never an OK: a failed `colima list` (`refreshStatus()` returns false), a failed `stale-files`, a failed `df`, a tool that does not run, a file that cannot be read.

- **Design.** `DoctorProbe` reads the system (the only I/O), `ColimaModel.collectDoctor()` fills `DoctorInputs`, and `DoctorRules.evaluate` gives one `DoctorResult` for each `DoctorCheck`. The independent probes run in parallel (`async let`) and each has a time-out of 5 to 15 seconds. No probe starts the VM: it uses `docker --version` (not `docker version`), `docker context ls` and, only while the VM runs, `colima ssh -- df -Pk`.
- **Context and routes** reuse the code of the docker context check: the current context comes from `Routing.currentContext()` (the config file), the list from `Routing.existingContexts`, the routes from `Routing.status()`. The fixes call `Routing.useOwnContext()` and `Routing.apply`.
- **Shell.** `ShellStartupScan` reads the text of the startup files of the login shell. It runs no user code, so a new terminal can still differ.
- **Registry login.** `DockerConfig` reads helper names only. It never reads `auths`.
- **Fixes.** **Use colimabar**, **Set routes**, **Copy line** (`CtlAction.copyEnv`), **Use osxkeychain**, **Add folder** and **Repair…**. Each fix except **Copy line** runs the checks again. The two docker config fixes go through `DockerConfigFile.edit`.
- **Repair.** `colima-ctl.sh repair` takes the lock, refuses without a `colima.yaml` and while a start runs, and asks first. Then it runs under the busy marker "Repairing": (1) remove the pid files whose PID was reused or is not a number, before the force stop, so Lima never sends SIGKILL, and Colima never sends SIGTERM, to that process. If a file stays, notify and stop before the force stop; (2) `colima stop --force`, whose failure is logged; (3) if a Lima process of the VM still runs, fail and remove nothing more; (4) remove the other stale pid files; (5) `colima start`. The script decides and deletes in one process, under the lock. Only regular files (never links) are removed: `ha.pid`, `vz.pid`, `qemu.pid` and `krunkit.pid` of the instance of the profile, and `usernet_NAME.pid` of a network when no instance has a live host agent, and `PROFILE/daemon/daemon.pid` of the Colima folder (the owner must be `colima daemon`; `colima stop` and `colima start` run `pkill -F` on this file with no owner check). It never touches disks, `cidata.iso`, `*.yaml`, logs or sockets. `CtlAction.repair` is a VM action, so the model checks the docker context after it like after any VM action.
- **UI.** `ViewState.showDoctor` makes `DashboardView` show `DoctorView` between the header and the hint bar. The page scrolls inside the fixed popover size. Entry points: the System tab, the stopped screen (only when `colima list` shows the profile Broken or its last start failed, `ColimaModel.doctorHint`) and the right-click menu.
- **Debug runs.** A debug run may run the checks (they only read). It makes no fix and no repair: the buttons are disabled and `applyFix` and `repairProfile` check `isDebug`. `COLIMABAR_DOCTOR=1` with `--snapshot` opens the Doctor page.
- **Later features.** `DoctorProbe.tools()` and `DoctorProbe.versions()` stand alone, so an upgrade guard can compare the versions of the last good start. `DoctorReport.text(home:version:)` is plain text for a diagnostics bundle: it shows the home folder as `~` and holds no secrets.

### Auto-stop

`AutoStopRule.evaluate` holds the idle rule for one profile. A profile is idle when no container runs, no `colima-ctl.sh` action that ColimaBar started runs (`blocksAutoStop`) and its proxies have no active transfers. A transfer is a connection whose latest request is a build, pull, push, load, save, commit or BuildKit session (`SocketProxy.isWork`). Each profile has its own idle time. The timeout setting is the same for all.

- `checkIdle()` checks the selected profile at each tick. It counts the transfers of the stable socket and of the profile socket of the selected profile. Before it stops the VM, it gets a fresh container list. If that fails, it does not stop. While that check runs, `checkIdle()` does nothing. After the list, it reads the limit again and stops only if the idle time (`AutoStopRule.stillDue`) is still over.
- `checkOtherProfilesIdle()` checks each other running docker profile (`AutoStopRule.otherProfiles`). A transfer or a busy marker resets its idle time at each tick. Each 30 seconds (`AutoStopRule.otherCheckInterval`), it gets a fresh container list from the socket of the profile. A failed list does not count as idle. When the idle time is over, it runs `auto-stop` for that profile.
- The idle time uses `SuspendingClock`, which stops while the Mac sleeps, as the VM does. Thus the sleep time never counts, and a dark wake needs no event. The idle time does not restart after a sleep: on a laptop that sleeps often, it would never stop the VM. `idleSince` is the wall time for display. `autoStopAt` is the stop time (`AutoStopRule.stopTime`). It moves later by the sleep time.
- `AutoStopRule.limit` gives the idle time for the power state: at most 10 minutes on battery and at most 5 minutes in Low Power Mode, while `autoStopSooner` is on. A shorter user time stays. The thermal state does not change it. `checkIdle()` and `checkOtherProfilesIdle()` read the limit at each check. A power change keeps the idle start, so the stop time moves at once. A change of the `autoStopSooner` setting restarts the idle time, as a change of the minutes does.
- `checkIdle()` and `checkOtherProfilesIdle()` do nothing in a debug run.

### System sleep

The word for the Mac sleeping is "system sleep". The word "wake" means auto-start in this code (`wakeForProxy`). Only `NSWorkspace.didWakeNotification` uses it for the Mac.

`SystemPowerObserver` calls `systemSleepBegan()`, `systemSleepEnded()` and `powerChanged(_:)` of the model. The model creates it in a normal run only.

- `systemSleepBegan()` and `systemSleepEnded()` cancel the check that runs. The newest check wins.
- `recoverAfterSleep()` opens the `/events` stream again (it can hang after a sleep without an error), opens the stat streams again if a dashboard is on screen, and runs `refreshAll()`.
- `checkAfterSleep(_:)` runs for each profile in `AfterSleepCheck.profiles`: running, docker runtime, valid name, no busy marker, no action in flight and no auto-start. The profiles run in parallel. It waits 0, 1, 2, 4 and 8 seconds before each ping. Each ping has a 3-second time-out, so the check ends within about 30 seconds. Before each try and each notification, it stops quietly if the task is cancelled, an action or a start began, or the VM stopped. If no ping answers, it refreshes the status, and if the VM still runs, it sends one notification with a **Restart** button. An `AlertThrottle` of 30 minutes, keyed by kind and profile, stops repeats. A ping that answers resets the no-answer key, so a new failure after a recovery notifies again.
- `syncClock(_:_:)` runs when Docker answers. It measures with `ClockDrift.sample` (`GET /info`, the middle of the request time). A fix is needed when the offset minus the uncertainty is more than 2 seconds. Then it waits 20 seconds for Lima (Lima 2.1 and later set the guest clock every 10 seconds) and measures again. If the clock is still off, it runs `colima ssh --profile P -- sudo -n date -s ±N.NNNsec` through `Shell.run`, with stderr in the output for the log. A set of profiles with a clock fix in flight stops a second fix for the same profile. GNU date applies the amount to the guest clock when it runs, so ssh adds no error. It is not a `colima-ctl.sh` action. It sends a notification only if the last measurement still needs a fix.
- `restartFromAlert(_:)` handles the **Restart** button. It checks, in order: the profile exists (`colima.yaml`, except for `default`, and the profile list), no action runs for it, and its VM runs. It restarts only then. Else it posts a short notice, so `colima start` never makes a new VM or starts a VM that the user stopped. `ColimaModel.alertRestart` holds the rule.
- The check uses the Colima sockets, never the proxy sockets, so it never starts a VM.
- The readiness gate of `performWake` uses `SuspendingClock` for its deadline, so a sleep during the gate does not use up the time.

### Login item

The login item is a plain LaunchAgent plist with the label `com.imohitkr.ColimaBar.login` in `~/Library/LaunchAgents`. It has `KeepAlive` for a failed exit, so launchd restarts ColimaBar after a crash. A normal quit is respected.

ColimaBar does not use `SMAppService`. launchd ties an `SMAppService` agent to the code signature, and each ad-hoc build has a new signature. `LoginItem.migrate()` removes the old agent one time.

### Notifications

Notifications go out for failures: a container exits with an error, gets OOM-killed or becomes unhealthy, or an action fails. Exit codes 0, 130, 137 and 143 are a normal stop (`ColimaModel.ignoredExitCodes`). Containers with the label `org.testcontainers=true` do not send alerts. Two other notifications go out once: one for each new version, and one the first time the icon hides. `AlertThrottle` allows one banner for each container and alert kind each 10 minutes. The checks after a system sleep send a notification with a **Restart** button (category `PROFILE`) when Docker does not answer or the clock fix fails. A click on its banner does nothing. The dashboard keeps a list of recent alerts, so nothing is lost when notifications are off.

**Saved logs.** Docker removes an auto-remove container (`docker run --rm`) and its logs right after it dies. While the option is on (`Defaults.Key.keepRemovedLogs`, off by default) and crash alerts are on, `RemovedLogKeeper` does this for the selected profile:

1. On a `start` event, it inspects the container. If `HostConfig.AutoRemove` is true, it opens one log stream (`follow=1`, `tail=100`).
2. The stream thread stores the raw log bytes in a `RemovedLogRing`, at most 500 lines and 128 KB for each container. Nothing parses them yet. The main actor does no work for each line.
3. On `die` with a crash exit code (`ColimaModel.isCrashExit`, the same rule as the alert) or after `oom`, it keeps the lines for 5 minutes. A clean exit, or a `destroy` without a failure, drops them. It closes the stream at most 2 seconds after `die`.
4. "View logs" calls `ColimaModel.openLogs`. `LogStore` inspects the container. If the daemon answers 404, ColimaBar parses the saved bytes, and the window shows the lines with the status "Saved from a removed container" and does not reconnect. Otherwise it shows live logs.

The buffers are not observed. The model publishes only `savedLogIDs`, the set of kept containers, for the alerts list. A profile switch, or turning the option off, drops all buffers.

### Update check

`Updater` asks the GitHub releases API one time each day. It builds the release link from the tag and accepts only release pages of this repository.

### Performance and limits

When the dashboard is closed, the app idles at about 0% CPU. These limits keep memory and file use low:

| Limit | Value | Where |
|---|---|---|
| Open file limit | 8192 (launchd starts apps with 256) | `FileLimit`, login item plist |
| Lines in a log window | 20,000 lines and 32 MB of text | `LogLimits` |
| Rendered log lines | the newest 2,000; copy and filter use all lines | `LogTail` |
| Saved logs of removed containers | 500 lines and 128 KB of raw log data for each container, 50 containers (about 6.4 MB), 5 minutes after a failure | `RemovedLogKeeper` |
| Proxy request head | 64 KB, then HTTP 431 | `SocketProxy.maxHead` |
| Proxy copy buffer | 16 KB for each direction | `SocketProxy.bufferSize` |
| Idle client while the VM is down | closed after 5 minutes | `SocketProxy.idleTimeout` |
| `ctl.log` | starts again after 1 MB | `Shell` |

Live stats stream only while a dashboard is on screen. Saved-log streams open only while the option is on, one for each running auto-remove container. `/system/df` runs only for the tabs that show it. Graphs use SwiftUI `Shape`, not Swift Charts, because Swift Charts uses a lot of graphics memory.

### Debug runs

`--snapshot`, `--popover` and `--notify-test` start a debug run. A debug run does not change the proxy sockets, the docker routes and contexts or the login item. It also skips system sleep, power changes and auto-stop. It runs the Doctor checks (they only read), but makes no Doctor fix. Thus it can run next to the installed app. [CONTRIBUTING.md](CONTRIBUTING.md#debug-flags) lists the flags.

## Invariants

Do not break these rules.

- **Fixed popover size.** The popover is 480 x 640 points (`AppDelegate.popoverSize`). In `ColimaModel`, assign a property only when its value changes. Otherwise the popover jitters and SwiftUI redraws too much.
- **No dialog behind the popover.** Call `model.dismissPopover()` before an alert or a file panel opens from the popover. A `colima-ctl.sh` action that asks with a dialog has `CtlAction.showsDialog(running:)`, and `run()` closes the popover for it. Some actions ask only while the VM runs. A test checks the list for a running VM against the script.
- **Proxy sockets.** The stable socket is `~/.cache/colima-bar/docker.sock` (`Paths.proxySocket`). The profile sockets are `~/.cache/colima-bar/profiles/PROFILE.sock` (`Paths.profileSocket`). Each socket has mode `0600`. Their folders have mode `0700`. Do not change the paths or relax the modes.
- **Quit behavior.** On quit, or when auto-start is off, the stable socket path becomes a symlink to the Colima socket of the selected profile, and each profile socket path a symlink to the Colima socket of its profile (`SocketProxy.stop()`). Docker clients must keep working without ColimaBar.
- **Docker contexts.** ColimaBar creates, updates and removes only the `colimabar` context and the `colimabar-PROFILE` contexts whose description starts with "ColimaBar". It never changes other contexts.
- **`colima-ctl.sh`.** The app bundle contains it in `Contents/Resources`. Exit code 0 means done. Exit code 1 means failed (the script already notified the user). Exit code 2 means cancelled, or another VM action holds the lock. ColimaBar shows nothing for 2.
- **Login item.** It is a plain LaunchAgent plist with the label `com.imohitkr.ColimaBar.login` in `~/Library/LaunchAgents`. Do not use `SMAppService`. launchd ties an `SMAppService` agent to the code signature, and each ad-hoc build has a new signature. `LoginItem.migrate()` removes the old `SMAppService` agent.
- **Log `since`.** The Docker logs `since` parameter must be UNIX seconds with nine digits of nanoseconds (`sec.nanos`). See `LogStore.sinceParam`.
- **Readiness gate after a wake.** An open socket does not mean that the Docker daemon is ready. `wakeForProxy()` waits for `colima start` to exit, then for several successful `/images/json` probes in a row. During a wake of profile P, every proxy whose upstream is P holds its requests until the shared wake ends (`SocketProxy.holdForWake`, set by `syncWakeHolds()`). These are the stable socket when P is selected, and the profile socket of P. While a wake runs, `connectIfAwake()` returns `.down`, so no request is spliced before the gate passes.
- **Debug runs.** `--snapshot`, `--popover` and `--notify-test` set `AppDelegate.isDebugRun`. A debug run must not change the proxy sockets, the docker routes and contexts or the login item. It does not observe system sleep or power changes, it does not auto-stop a VM, and it makes no Doctor fix or repair.

## Testing

Tests use Swift Testing. Logic lives in small static functions, so tests can call it without a VM. `Tests/ColimaBarTests/TestSupport/` has shared fakes, for example `FakeDaemon`. Automated runs never start or stop the user's Colima VM.

`Tests/ColimaBarTests/Scripts/` tests the scripts in `scripts/`. `ScriptSandbox` runs a copy of a script in a temporary HOME, with stub `osascript`, `colima`, `docker`, `kubectl`, `pgrep` and `ps` first on its PATH. The stub `ps` answers `-o command=` and `-o etime=` for a PID from a table (`stubProcesses`), so the owner checks of the lock, the busy marker and the pid files of Lima run without real processes. Thus no dialog reaches the screen, and no VM or docker context changes. The uninstall tests source only the helper functions of `uninstall.sh`.
