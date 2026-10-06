# Contributing to ColimaBar

Thank you for your help. This guide tells you how to build, test and change ColimaBar.

All contributors must follow the [Code of Conduct](CODE_OF_CONDUCT.md). To report a security problem, read [SECURITY.md](SECURITY.md). Do not open a public issue for it.

## Requirements

- A Mac with Apple silicon
- macOS 14 or later
- The Xcode Command Line Tools. You do not need Xcode.
- [Colima](https://github.com/abiosoft/colima) and the docker CLI, for manual tests. To install them, run `brew install colima docker`.

## Build, run and test

| Command | What it does |
|---|---|
| `make build` | Builds `build/ColimaBar.app` with SwiftPM and signs it ad-hoc (`./build.sh`). |
| `make test` | Runs the test suite (`swift test`). |
| `make lint` | Checks the Swift format with `swift format lint --strict`. If `shellcheck` is installed, it also checks the shell scripts. |
| `make fmt` | Formats the Swift code in place with `swift format`. |
| `make check` | Runs `make lint`, then `make test`. |
| `make install` | Builds the app, installs it in `~/Applications` and opens it (`./build.sh install`). |
| `make dmg` | Builds the app and the disk image `build/ColimaBar-<version>.dmg` (`./build.sh dmg`). |
| `make clean` | Removes `.build` and `build`. |

Run `make` with no target to list all targets. The Make targets call `./build.sh` and `swift`, so you can also run those commands directly.

`.swift-format` holds the format rules. `swift format` comes with the Swift toolchain in the Command Line Tools. Run `make fmt` before you commit. CI fails if `make lint` reports a finding. To check the shell scripts locally, install ShellCheck with `brew install shellcheck`.

`make install` quits the running ColimaBar and replaces it. Use it when you want to test the full app with the login item and auto-start.

The version comes from `git describe --tags`. Without a tag, the version is the commit hash.

### Debug flags

The app reads these flags at launch. A run with `--snapshot`, `--popover` or `--notify-test` is a debug run. A debug run does not touch the proxy socket, the docker routes or the login item. Thus it can run next to the installed app.

| Flag | What it does |
|---|---|
| `--snapshot PATH [TAB]` | Opens the dashboard window, renders it to a PNG at `PATH`, then quits. `TAB` is `Containers`, `Images`, `Volumes` or `System`. |
| `--popover [PATH]` | Opens the dashboard popover at launch. With `PATH`, it renders the popover to a PNG, then quits. |
| `--notify-test` | Sends a test notification, then quits. |
| `--window` | Opens the dashboard window at launch. |

`--snapshot` also reads these environment variables:

- `COLIMABAR_HINT`: text for the hint bar.
- `COLIMABAR_LOGS`: a container name. The PNG then shows the log viewer for that container.
- `COLIMABAR_SNAPSHOT_HEIGHT`: the window height in points.
- `COLIMABAR_SNAPSHOT_DELAY`: seconds to wait before the snapshot (default 6). Use 65 to fill the sparklines.

Example:

```sh
./build.sh
build/ColimaBar.app/Contents/MacOS/ColimaBar --snapshot /tmp/system.png System
```

## Project layout

| Path | Contents |
|---|---|
| `Sources/ColimaBar/App.swift` | App delegate: menu bar icon, popover, dashboard window, right-click menu and debug flags. |
| `Sources/ColimaBar/ColimaModel.swift` | The `@Observable` model. It is the single source of truth for the dashboard, auto-start and auto-stop. |
| `Sources/ColimaBar/DashboardView.swift` | Dashboard frame: header, live tiles, tab picker, profile picker and footer. |
| `Sources/ColimaBar/Tabs.swift` | The Containers, Images, Volumes and System tabs. |
| `Sources/ColimaBar/LogViewer.swift` | Log windows: stream demuxing, the log buffer, search and filters. |
| `Sources/ColimaBar/DockerAPI.swift` | A small Docker Engine API client over the unix socket. |
| `Sources/ColimaBar/SocketProxy.swift` | The auto-start proxy on `~/.cache/colima-bar/docker.sock`, and unix socket helpers. |
| `Sources/ColimaBar/Routing.swift` | Docker routes (`DOCKER_HOST`, docker context, testcontainers) and the login item. |
| `Sources/ColimaBar/Shell.swift` | File paths, and the runner for `colima` and `colima-ctl.sh`. |
| `Sources/ColimaBar/Models.swift` | Data types, JSON decoding and parsers. |
| `Sources/ColimaBar/Notifier.swift` | Native notifications and alert throttling. |
| `Sources/ColimaBar/Hints.swift` | The hover hint text for each control (`Help`) and the hint bar. |
| `Sources/ColimaBar/Updater.swift` | The daily check for a new release. |
| `Tests/ColimaBarTests/` | Unit tests (Swift Testing). |
| `scripts/colima-ctl.sh` | VM actions, confirm dialogs and `colima.yaml` changes. The app bundle contains it. |
| `scripts/install.sh` | The installer. |
| `scripts/uninstall.sh` | The uninstall script. The app bundle contains it. |
| `scripts/make-icon.swift` | Draws `Resources/AppIcon.icns`. |
| `scripts/dmg-readme.txt` | The "Read Me First" file in the disk image. |
| `build.sh` | Builds the app bundle, the disk image and the tests. |
| `Makefile` | Shortcuts for build, test, lint and format. |
| `.swift-format` | The `swift format` rules. |
| `.github/workflows/ci.yml` | CI and the release job. |
| `legacy/` | The old SwiftBar plugin. The app does not use it. |

## Coding conventions

- Use Swift 5.10 and SwiftPM. Do not add third-party dependencies.
- Use only Apple frameworks: AppKit, SwiftUI, Observation, UserNotifications and ServiceManagement.
- Draw graphs with SwiftUI `Shape` or `Path`. Do not use Swift Charts or `Canvas`, because they use a lot of graphics memory.
- Keep UI state in the `@Observable` `ColimaModel`. Assign a property only when its value changes. This keeps the popover still and the redraws small.
- Write tests with [Swift Testing](https://developer.apple.com/documentation/testing) (`@Suite`, `@Test`, `#expect`). Do not use XCTest.
- Keep logic in small static functions that tests can call without a VM.
- Do not make tests depend on exact timing. If a test must measure time, use a generous bound.
- Put a `///` doc comment on each type and on each non-obvious function. Explain why the code does something, not only what it does.
- Keep inline comments short, for example `// retry on 503`.
- If you add or change a control, add or update its hover hint in `Hints.swift`.
- If you change behavior that users see, update `README.md`.

## Report a bug

Open a [bug report](https://github.com/imohitkr/colima-bar/issues/new/choose). Include this information:

- The macOS version.
- The ColimaBar version. The dashboard footer and the right-click menu show it.
- The output of `colima version`.
- The runtime and the profile, if it is not `default`.
- The steps that cause the problem, what you expected and what happened.
- The relevant lines from `~/.cache/colima-bar/ctl.log`. This file contains the output of VM actions.

Remove secrets, tokens and private host names from logs before you post them.

## Pull requests

1. Fork the repository and create a branch from `main`.
2. Keep each pull request small and about one change.
3. If you change logic, add or update tests.
4. Run `make check` and `make build` before you push.
5. Open the pull request. Fill in the template: What, Why and How tested.
6. If you change the UI, add screenshots. Use `--snapshot` to make them.

CI runs `swift format lint`, ShellCheck, `swift test` and `./build.sh` on each pull request. CI must pass before a maintainer merges.

## Commit messages

- Write the subject in the imperative mood, for example "Add a profile picker".
- Keep the subject short, at about 50 to 70 characters. Do not end it with a period.
- In the body, explain why you made the change. The diff shows what changed.

## Writing style

Use a light form of [ASD-STE100 Simplified Technical English](https://www.asd-ste100.org/) for docs, code comments, commit messages, hints, notifications and error messages. A reader whose first language is not English must not misread the text.

- Write one idea per sentence. Keep instructions to about 20 words.
- Use the active voice with a clear subject.
- Use the imperative for instructions: "Run `make check` before you push."
- Put conditions before commands: "If the VM is stopped, start it."
- Use one term for one concept. Use the README terms: dashboard, auto-start, auto-stop, the installer, the disk image, profile, VM.
- Use plain words: "use", not "utilize"; "before", not "prior to".
- Do not use filler such as "basically", "simply" or "in order to".

You can use normal engineering words such as cache, retry and idempotent. Keep code, identifiers and command output exact.

## Releases

The maintainer makes each release:

1. The maintainer pushes a tag `vX.Y.Z` on `main`.
2. CI runs the tests and builds `ColimaBar.dmg` and `ColimaBar.zip`.
3. CI signs a build provenance attestation for both files.
4. CI publishes the GitHub release with generated notes.

Contributors do not need to change version numbers. The version comes from the tag.

## License

ColimaBar uses the [MIT license](LICENSE). When you contribute, you agree that your contribution uses the same license.
