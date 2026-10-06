# AGENTS.md

This file guides AI coding agents that work on this repository. Human contributors read [CONTRIBUTING.md](CONTRIBUTING.md).

## Overview

ColimaBar is a native macOS menu bar app for [Colima](https://github.com/abiosoft/colima). It shows the VM and its containers in a dashboard.
Its proxy socket starts the VM when the first real docker request arrives (auto-start). It can stop an idle VM (auto-stop).
It uses Swift 5.10 and SwiftPM with Command Line Tools only. It runs on Apple silicon with macOS 14 or later. It has no third-party dependencies.

## Commands

| Command | Use |
|---|---|
| `make build` | Build `build/ColimaBar.app`. |
| `make test` | Run the tests. |
| `timeout 300 swift test` | Run the tests with a time limit. On macOS, `timeout` comes from GNU coreutils and can be named `gtimeout`. |
| `make lint` | Check the Swift format (`.swift-format`) and, if ShellCheck is installed, the shell scripts. |
| `make fmt` | Format the Swift code in place. |
| `make check` | Run `make lint`, then `make test`. |
| `make dmg` | Build the disk image. |
| `make install` | Run it only when the user asks. It quits and replaces the installed app. |

Run `make fmt` and `make lint` before you commit. CI fails on any lint finding.

For screenshots, use a debug run: `build/ColimaBar.app/Contents/MacOS/ColimaBar --snapshot PATH [TAB]`. A debug run does not touch the proxy socket, the docker routes or the login item. CONTRIBUTING.md lists all debug flags.

## Layout

Sources live in `Sources/ColimaBar/`, in one folder per area. Each file holds one type, or one type and its small private helpers. The file has the name of the type. An extension file has the name `Type+Topic.swift`.

- `App/`: the app delegate with the menu bar icon, popover, dashboard window and debug flags (`AppDelegate.swift`). Other files hold the restart after an update (`AppDelegate+Relaunch.swift`), the main menu and the debug snapshots.
- `Model/`: the `@Observable` model with auto-start wake and auto-stop (`ColimaModel.swift`). Its static rules are in `ColimaModel+Rules.swift`, `ColimaModel+Events.swift` and `ColimaModel+StartDetection.swift`. The folder also has the row types (`Models.swift`), `DFGate`, `LatestOnly`, `VMState` and `IdleMinutes`.
- `Docker/`: the Docker Engine API client over the unix socket (`DockerAPI.swift`) and the JSON wire types (`DockerJSON.swift`).
- `Proxy/`: the auto-start proxy (`SocketProxy.swift`), its HTTP parsers (`SocketProxy+HTTP.swift`) and the unix socket helpers (`UnixSocket.swift`).
- `System/`: paths, the process runner, docker routes, the login item, notifications, the release check, `UserDefaults` access, the Colima directory watcher and the open file limit.
- `Logs/`: log windows: the line parsers, the filter, the buffer, `LogStore`, `LogView` and `LogWindows`.
- `Views/`: the dashboard UI. `Dashboard/` has the frame, header, footer and live tiles. `Containers/` and `System/` have those tabs. `ImagesTab.swift` and `VolumesTab.swift` are the other tabs. `Shared/` has the hover hints (`Hint.swift`), the hint text (`Help.swift`) and small shared views.
- `Support/`: small helpers with no app state: `Parse`, byte formatting and bounded concurrency.
- `Tests/ColimaBarTests/`: Swift Testing tests, in the same folders as the sources. `TestSupport/` has the shared fakes and helpers.
- `scripts/`: `colima-ctl.sh`, the installer, the uninstall script, the icon generator.

## Invariants

Do not break these rules.

- **Fixed popover size.** The popover is 480 x 640 points (`AppDelegate.popoverSize`). In `ColimaModel`, assign a property only when its value changes. Otherwise the popover jitters and SwiftUI redraws too much.
- **Proxy socket.** The path is `~/.cache/colima-bar/docker.sock` (`Paths.proxySocket`). The socket has mode `0600`. The directory has mode `0700`. Do not change the path or relax the modes.
- **Quit behavior.** On quit, or when auto-start is off, the socket path becomes a symlink to the Colima socket (`SocketProxy.stop()`). Docker clients must keep working without ColimaBar.
- **`colima-ctl.sh`.** The app bundle contains it in `Contents/Resources`. Exit code 0 means done. Exit code 1 means failed (the script already notified the user). Exit code 2 means cancelled, or another VM action holds the lock. ColimaBar shows nothing for 2.
- **Login item.** It is a plain LaunchAgent plist with the label `com.imohitkr.ColimaBar.login` in `~/Library/LaunchAgents`. Do not use `SMAppService`. launchd ties an `SMAppService` agent to the code signature, and each ad-hoc build has a new signature. `LoginItem.migrate()` removes the old `SMAppService` agent.
- **Log `since`.** The Docker logs `since` parameter must be UNIX seconds with nine digits of nanoseconds (`sec.nanos`). See `LogStore.sinceParam`.
- **Readiness gate after a wake.** An open socket does not mean Docker is ready. `wakeForProxy()` waits for `colima start` to exit, then for several successful `/images/json` probes in a row. While a wake runs, `connectIfAwake()` returns `.down`, so no request is spliced before the gate passes.
- **Debug runs.** `--snapshot`, `--popover` and `--notify-test` set `AppDelegate.isDebugRun`. A debug run must not change the proxy socket, the docker routes or the login item.

## Tests

- Use Swift Testing (`@Suite`, `@Test`, `#expect`). Do not use XCTest.
- Name each test file `<TypeOrFeature>Tests.swift`, with one file and one suite for each unit. Give the suite the same name as the file.
- Put shared fakes and helpers in `Tests/ColimaBarTests/TestSupport/`, for example `FakeDaemon`, `BusyUpstream`, `waitUntil` and `TestSocketPath`. Do not copy them into test files.
- Get each test socket path from `TestSocketPath.unique()`. Suites run in parallel, so a fixed path can collide.
- If a test must wait for a condition, poll it with `waitUntil`. Do not use a fixed sleep before a check.
- Do not name files, suites or tests after review rounds or fixes. Name them after the behavior that they check.
- If you change logic, add or update tests.
- Do not write tests that depend on exact timing. If a test must measure time, use a generous bound.
- Do not start or stop the user's Colima VM in automated runs.
- Do not quit or kill the installed ColimaBar in automated runs.

## Writing style

Use a light form of ASD-STE100 for docs, comments, hints, notifications, error messages and commit messages:

- Write one idea per sentence. Keep instructions to about 20 words.
- Use the active voice and the imperative for instructions.
- Put conditions before commands.
- Use one term for one concept. Use the README terms: dashboard, auto-start, auto-stop, the installer, the disk image, profile, VM.
- Use plain words. Do not use filler.
- Keep code, identifiers and command output exact.

If you add or change a control, update its hint text in `Views/Shared/Help.swift`. If you change behavior that users see, update `README.md`.

## Commits and pull requests

- Write the commit subject in the imperative mood, for example "Fix the log viewer scroll". In the body, explain why.
- Keep each pull request small and about one change. Fill in the pull request template.
- Do not add AI attribution anywhere. This includes `Co-Authored-By` trailers for an AI, "Generated with" lines and similar notes in code, docs, commits or pull requests.
