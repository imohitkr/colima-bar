# Changelog

All notable changes to ColimaBar are in this file.

The format follows [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/). ColimaBar uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **Keep logs of removed containers that fail** on the System tab. This option is off by default. When it is on, ColimaBar keeps the newest 500 lines (at most 128 KB) of each container that `docker run --rm` started, in memory only. If the container fails, **View logs** on its alert shows these lines for 5 minutes. See [Saved logs](docs/usage.md#saved-logs).
- **Uninstall ColimaBar…** in the right-click menu. After you confirm, it runs the uninstall script of the app in iTerm, or in Terminal when iTerm is not installed.
- A Question issue form.
- **Export Settings…** and **Import Settings…** on the System tab. They save the ColimaBar settings to a JSON file and load them on a different Mac. Before an import applies anything, ColimaBar shows the changes. It skips invalid values and profiles that do not exist on the Mac. See [Export and import settings](docs/usage.md#export-and-import-settings).
- **Shrink…** next to the disk size on the System tab. Colima cannot shrink a disk in place. Thus this deletes the VM with all its containers, images, volumes and build cache, and starts it again with a smaller disk and the same settings. You must type the profile name to confirm. See [Shrink the disk](docs/usage.md#shrink-the-disk).
- A socket and a docker context for each profile with the docker runtime, for example `~/.cache/colima-bar/profiles/work.sock` and `colimabar-work`. A docker request to the socket of a stopped profile starts that profile. Use `docker --context colimabar-work ps`, or set `DOCKER_HOST` for one project. The ColimaBar socket still follows the selected profile. See [Profile sockets](docs/auto-start.md#profile-sockets).
- Auto-stop checks each running docker profile, not only the selected one. Each profile stops after its own idle time. See [Auto-stop](docs/auto-stop.md).
- The profile menu in the header now shows also when you have one profile. It starts and stops other profiles, creates a profile with **New Profile…** and deletes a profile with **Delete Profile** after a typed confirmation. **Delete Profile** refuses `colima`, names that start with `colima-`, and a profile without a folder. See [Profiles](docs/usage.md#profiles).
- Install with Homebrew: `brew install --cask imohitkr/tap/colima-bar`. The cask is in the new [imohitkr/homebrew-tap](https://github.com/imohitkr/homebrew-tap) repository. A workflow in the tap verifies the attestation of each new release before it updates the cask.

### Changed

- The VM dialogs and the failure notifications name the profile, for example "Grow the Colima disk of profile 'work' to 150 GB?".
- The ••• menu item **Logs in iTerm** is now **Logs in Terminal**.
- The uninstall script also removes the `colimabar-PROFILE` contexts whose description starts with "ColimaBar". It links each profile socket to the Colima socket of its profile.
- The docs have a new structure. The README is short. The user guides are in `docs/`. `ARCHITECTURE.md` describes the design, and `SUPPORT.md` tells you how to get help.

### Removed

- The old SwiftBar plugin (`legacy/swiftbar`).

### Fixed

- Restart, **Apply** of VM resources, Rosetta, Kubernetes and a disk grow always restart a running VM. Before, they could report success and leave the VM unchanged: the bash of macOS ended `restart_vm` early, after `colima status`. A disk shrink of a running VM could also stop at this step.
- ColimaBar, `colima-ctl.sh` and the uninstall script find the Colima folder like Colima does (`COLIMA_HOME`, `~/.colima`, `~/.config/colima`, `$XDG_CONFIG_HOME/colima`). They use `LIMA_HOME` for Lima's folder if it is set. Before, they always used `~/.config/colima`. Thus with `~/.colima`, the dashboard, auto-start and the VM settings used the wrong folder. See [Colima folder](docs/troubleshooting.md#colimabar-uses-the-wrong-colima-folder).
- In some locales, the profile name check of `colima-ctl.sh` accepted non-ASCII letters.
- The installer no longer stops when `gh` 2.49 to 2.67 is installed. It needs `gh` 2.68 or later to verify the download. With an older `gh`, it prints a notice and continues.
- ColimaBar now finds iTerm in `~/Applications`. Before, it used Terminal.
- CI no longer fails on timing benchmarks. They run only with `make perf`.
- Test builds with the Command Line Tools no longer fail now and then with "plugin for module 'TestingMacros' not found".

## [0.4.0] - 2026-10-06

### Added

- The installer: a one-line `curl` command installs or updates ColimaBar from the latest release.
- The disk image `ColimaBar.dmg`, with a "Read Me First" file.
- A build provenance attestation for `ColimaBar.dmg` and `ColimaBar.zip`. The installer verifies it when `gh` can.
- The dashboard footer shows the version. Click it to check for a new version.
- The app contains the uninstall script.
- A contributing guide, a code of conduct, a security policy and a GitHub Sponsors link.
- A note that ColimaBar is not part of the Colima project.

### Changed

- The app contains `colima-ctl.sh`. A downloaded app no longer needs a separate install step.
- ColimaBar watches the Colima folders instead of running `colima list` each minute. This lowers the idle cost.
- Lower memory use. An open dashboard uses about 23 MB instead of 164 MB. A log window renders only the newest 2,000 lines.
- Faster log viewer: parsing runs off the main thread, and filtering is faster.
- ColimaBar raises its open file limit to 8192.

### Fixed

- A downloaded app could not start or stop Colima, because `colima-ctl.sh` was missing.
- Auto-stop now counts a pull or push that follows a ping on the same connection.
- The log viewer tries again when Docker is unreachable. It no longer reports the container as removed.
- The log viewer keeps characters that are split across two reads.
- Opening the app again after an update runs the new version.
- testcontainers `docker.host` lines with spaces or a colon are read correctly.
- **Remove** works on running containers.
- The uninstall script edits `~/.testcontainers.properties` through a symlink.

### Security

- The proxy limits request heads to 64 KB and does not log query strings.
- CI uses a read-only token by default and pins actions to commit SHAs.
- The scripts reject profile names that start with a dot.

## [0.3.1] - 2026-10-06

### Fixed

- If you open ColimaBar from Spotlight while the icon is hidden, the icon hides again when the dashboard closes.

## [0.3.0] - 2026-10-06

### Added

- Auto-stop times: 5, 15, 30 or 60 minutes, or a custom time.
- A daily check for a new release, with one notification for each version, an **Update** button in the footer and **Check for Updates…** in the right-click menu.
- **Hide Icon While Colima Is Stopped** in the right-click menu and on the stopped screen.
- Edit and Window menus, so copy, paste and close shortcuts work.

### Changed

- The login item is a LaunchAgent in `~/Library/LaunchAgents`. ColimaBar moves older login items one time.
- Auto-stop counts docker builds, pulls and pushes as activity. It confirms with a fresh container list before it stops the VM.
- VM actions write their output to `~/.cache/colima-bar/ctl.log`.

### Fixed

- A cold `docker run` through auto-start failed with "Unavailable: error reading from server: EOF". The proxy now waits until Docker is ready.
- ColimaBar did not start at login after an update.
- The dashboard stayed busy after **Stop**.
- A failed `colima list` no longer shows the VM as stopped.
- A deleted profile falls back to `default`.
- The log viewer keeps the lines that a container writes while it restarts.

## [0.2.0] - 2026-10-06

### Added

- An option to hide the menu bar icon while Colima is stopped, on the System tab.

## [0.1.0] - 2026-10-05

### Added

- First release: a native menu bar dashboard for Colima.
- Auto-start: a proxy socket starts Colima on the first real docker request.
- Containers grouped by Compose project, with health, ports, CPU and memory.
- A live log viewer.
- Notifications for failures only.
- A hover hint for each control.

[Unreleased]: https://github.com/imohitkr/colima-bar/compare/v0.4.0...HEAD
[0.4.0]: https://github.com/imohitkr/colima-bar/compare/v0.3.1...v0.4.0
[0.3.1]: https://github.com/imohitkr/colima-bar/compare/v0.3.0...v0.3.1
[0.3.0]: https://github.com/imohitkr/colima-bar/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/imohitkr/colima-bar/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/imohitkr/colima-bar/releases/tag/v0.1.0
