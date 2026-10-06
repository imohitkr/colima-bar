# Contributing to ColimaBar

Thank you for your help. This guide tells you how to build, test and change ColimaBar.

All contributors must follow the [Code of Conduct](CODE_OF_CONDUCT.md). To report a security problem, read [SECURITY.md](SECURITY.md). Do not open a public issue for it.

## Requirements

- A Mac with Apple silicon
- macOS 14 or later
- Swift 6.4. Use the Xcode Command Line Tools with Swift 6.4, or install Swift 6.4 with [swiftly](https://www.swift.org/install/macos/). You do not need Xcode. To check the version, run `swift --version`.
- [Colima](https://github.com/abiosoft/colima) and the docker CLI, for manual tests. To install them, run `brew install colima docker`.

## Build, run and test

| Command | What it does |
|---|---|
| `make build` | Builds `build/ColimaBar.app` with SwiftPM and signs it ad-hoc (`./build.sh`). |
| `make test` | Runs the test suite (`swift test`). |
| `make lint` | Checks the Swift format with `swift format lint --strict`, the shell scripts with ShellCheck and the workflows with actionlint. |
| `make fmt` | Formats the Swift code in place with `swift format`. |
| `make check` | Runs `make lint`, then `make test`. |
| `make install` | Builds the app, installs it in `~/Applications` and opens it (`./build.sh install`). |
| `make dmg` | Builds the app and the disk image `build/ColimaBar-<version>.dmg` (`./build.sh dmg`). |
| `make clean` | Removes `.build` and `build`. |

Run `make` with no target to list all targets. The Make targets call `./build.sh` and `swift`, so you can also run those commands directly.

`.swift-format` holds the format rules. `swift format` comes with the Swift toolchain. Run `make fmt` before you commit. CI fails if `make lint` reports a finding.

CI uses these lint tools: `swift format` from Swift 6.4.0 (the `swift:6.4.0` image), ShellCheck 0.11.0 and actionlint 1.7.12. `make lint` uses your local `shellcheck` and `actionlint` if they are installed (`brew install shellcheck actionlint`). If they are not installed, it runs the same pinned images as CI with docker. If docker does not work, it skips those checks. Colima shares only your home folder with its VM by default, so keep the repository in your home folder.

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

[ARCHITECTURE.md](ARCHITECTURE.md) describes the design and has a code map of each folder and its key types.

Each source file holds one type, or one type and its small private helpers. The file has the name of the type. An extension file has the name `Type+Topic.swift`.

## Coding conventions

- Use Swift 6.4 and SwiftPM, in the Swift 6 language mode. Do not add third-party dependencies.
- Use only Apple frameworks: AppKit, SwiftUI, Observation, UserNotifications and ServiceManagement.
- Draw graphs with SwiftUI `Shape` or `Path`. Do not use Swift Charts or `Canvas`, because they use a lot of graphics memory.
- Keep UI state in the `@Observable` `ColimaModel`. Assign a property only when its value changes. This keeps the popover still and the redraws small.
- Write tests with [Swift Testing](https://developer.apple.com/documentation/testing) (`@Suite`, `@Test`, `#expect`). Do not use XCTest.
- Keep logic in small static functions that tests can call without a VM.
- Do not make tests depend on exact timing. If a test must measure time, use a generous bound.
- Name each test file `<TypeOrFeature>Tests.swift`, with one file and one suite for each unit. Give the suite the same name as the file.
- Put shared fakes and helpers in `Tests/ColimaBarTests/TestSupport/`. Do not copy them into test files. Get each test socket path from `TestSocketPath.unique()`.
- If a test must wait for a condition, poll it with `waitUntil`. Do not use a fixed sleep before a check.
- Do not name files, suites or tests after review rounds or fixes. Name them after the behavior that they check.
- Put a `///` doc comment on each type and on each non-obvious function. Explain why the code does something, not only what it does.
- Keep inline comments short, for example `// retry on 503`.
- If you add or change a control, add or update its hover hint text in `Views/Shared/Help.swift`.
- If you change behavior that users see, update the user guide in `docs/`. Update `README.md` only if the summary changes.
- If you change the design, update `ARCHITECTURE.md`.

## Report a bug

Open a [bug report](https://github.com/imohitkr/colima-bar/issues/new?template=bug_report.yml). [Troubleshooting](docs/troubleshooting.md#report-a-bug) lists the information to include.

## Pull requests

1. Fork the repository and create a branch from `main`.
2. Keep each pull request small and about one change.
3. If you change logic, add or update tests.
4. Run `make check` and `make build` before you push.
5. Add a line under `[Unreleased]` in [CHANGELOG.md](CHANGELOG.md) for each change that users see.
6. Open the pull request. Fill in the template: What, Why and How tested.
7. If you change the UI, add screenshots. Use `--snapshot` to make them.

CI runs `swift format lint`, ShellCheck, actionlint, `swift test` and `./build.sh` on each pull request. The macOS jobs use Swift 6.4.0 from swift.org. CI must pass before a maintainer merges.

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
- Use one term for one concept. Use the terms of the docs: dashboard, auto-start, auto-stop, the installer, the disk image, the login item, profile, VM.
- Use plain words: "use", not "utilize"; "before", not "prior to".
- Do not use filler such as "basically", "simply" or "in order to".

You can use normal engineering words such as cache, retry and idempotent. Keep code, identifiers and command output exact.

## Releases

The maintainer makes each release:

1. The maintainer pushes a tag `vX.Y.Z` on `main`.
2. CI runs the tests and builds `ColimaBar.dmg` and `ColimaBar.zip`.
3. CI signs a build provenance attestation for both files.
4. CI publishes the GitHub release with generated notes.

Before the tag, the maintainer moves the `[Unreleased]` entries in `CHANGELOG.md` to a new version section.

Contributors do not need to change version numbers. The version comes from the tag.

## License

ColimaBar uses the [MIT license](LICENSE). When you contribute, you agree that your contribution uses the same license.
