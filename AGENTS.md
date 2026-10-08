# AGENTS.md

This file guides AI coding agents that work on this repository. Human contributors read [CONTRIBUTING.md](CONTRIBUTING.md).

## Overview

ColimaBar is a native macOS menu bar app for [Colima](https://github.com/abiosoft/colima). It shows the VM and its containers in a dashboard.
Its proxy socket (`~/.cache/colima-bar/docker.sock`) starts the VM when the first real docker request arrives (auto-start). It can stop an idle VM (auto-stop).
It uses Swift 6.4 and SwiftPM, in the Swift 6 language mode, with Command Line Tools only. It runs on Apple silicon with macOS 14 or later. It has no third-party dependencies.

## Commands

| Command | Use |
|---|---|
| `make build` | Build `build/ColimaBar.app`. |
| `make test` | Run the tests. |
| `make perf` | Run the tests and the timing benchmarks. |
| `timeout 300 swift test` | Run the tests with a time limit. On macOS, `timeout` comes from GNU coreutils and can be named `gtimeout`. |
| `make lint` | Check the Swift format (`.swift-format`), the shell scripts (ShellCheck 0.11.0) and the workflows (actionlint 1.7.12). If ShellCheck or actionlint is not installed, it uses docker. If docker does not work, it skips that check. |
| `make fmt` | Format the Swift code in place. |
| `make check` | Run `make lint`, then `make test`. |
| `make dmg` | Build the disk image. |
| `make install` | Run it only when the user asks. It quits and replaces the installed app. |

Run `make fmt` and `make lint` before you commit. CI fails on any lint finding.

For screenshots, use a debug run: `build/ColimaBar.app/Contents/MacOS/ColimaBar --snapshot PATH [TAB]`. A debug run does not touch the proxy sockets, the docker routes and contexts or the login item. CONTRIBUTING.md lists all debug flags.

## Layout

[ARCHITECTURE.md](ARCHITECTURE.md) has the code map of `Sources/ColimaBar/` and the main data flows. Read it before a large change.

Each file holds one type, or one type and its small private helpers. The file has the name of the type. An extension file has the name `Type+Topic.swift`. Tests in `Tests/ColimaBarTests/` use the same folders as the sources.

User guides live in `docs/`. `README.md` is a short summary for users.

## Invariants

Do not break the rules in [ARCHITECTURE.md](ARCHITECTURE.md#invariants). In short: a fixed popover size, fixed proxy socket paths and modes, working clients after quit, only ColimaBar's own docker contexts, fixed `colima-ctl.sh` exit codes, a plain LaunchAgent login item, the log `since` format, the readiness gate after a wake, and debug runs that change nothing.

## Tests

- Use Swift Testing (`@Suite`, `@Test`, `#expect`). Do not use XCTest.
- Name each test file `<TypeOrFeature>Tests.swift`, with one file and one suite for each unit. Give the suite the same name as the file.
- Put shared fakes and helpers in `Tests/ColimaBarTests/TestSupport/`, for example `FakeDaemon`, `BusyUpstream`, `waitUntil` and `TestSocketPath`. Do not copy them into test files.
- Get each test socket path from `TestSocketPath.unique()`. Suites run in parallel, so a fixed path can collide.
- If a test must wait for a condition, poll it with `waitUntil`. Do not use a fixed sleep before a check.
- Do not block a Swift concurrency thread in a test, for example in a socket read, a process wait or a semaphore wait. Suites run in parallel, so a blocked test can stall async code in another test, such as the Task that runs a wake. Make the test `async`. Run each blocking call through `onOwnThread`, or through a helper that uses it, such as `roundTrip` or `ScriptSandbox.bash`. Poll with `await waitUntil`.
- Do not name files, suites or tests after review rounds or fixes. Name them after the behavior that they check.
- If you change logic, add or update tests.
- Do not write tests that depend on exact timing. Put wall-clock bounds only in a benchmark test marked `@Test(.benchmark)`. CI does not run benchmarks; run them with `make perf`.
- Do not start or stop the user's Colima VM in automated runs.
- Do not quit or kill the installed ColimaBar in automated runs.

## Writing style

Use a light form of ASD-STE100 for docs, comments, hints, notifications, error messages and commit messages:

- Write one idea per sentence. Keep instructions to about 20 words.
- Use the active voice and the imperative for instructions.
- Put conditions before commands.
- Use one term for one concept. Use the terms of the docs: dashboard, auto-start, auto-stop, the installer, the disk image, the login item, profile, VM.
- Use plain words. Do not use filler.
- Keep code, identifiers and command output exact.

If you add or change a control, update its hint text in `Views/Shared/Help.swift`. If you change behavior that users see, update the user guide in `docs/`, and `README.md` if the summary changes. If you change the design, update `ARCHITECTURE.md`.

## Releases

- Collect features before a release. Do not tag each merge.
- After every change, run at least one round of review agents and fix the findings.
- Before a tag, review the docs against the code and fix anything out of date.
- Never move or delete a tag that has a release. Releases are immutable; publish the next patch version instead.

## Commits and pull requests

- Write the commit subject in the imperative mood, for example "Fix the log viewer scroll". In the body, explain why.
- Keep each pull request small and about one change. Fill in the pull request template.
- Add a line under `[Unreleased]` in `CHANGELOG.md` for each change that users see.
- Do not add AI attribution anywhere. This includes `Co-Authored-By` trailers for an AI, "Generated with" lines and similar notes in code, docs, commits or pull requests.
