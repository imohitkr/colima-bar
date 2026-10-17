# Changelog

All notable changes to ColimaBar are in this file.

The format follows [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/). ColimaBar uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Before the first start after a Colima or Lima upgrade, ColimaBar asks first and offers the release notes. Doctor shows the change in a new Upgrade check. See [Upgrade warning](docs/usage.md#upgrade-warning).
- Doctor can save a diagnostics file and open a bug report with the versions filled in. **Save Diagnostics…** and **Report an Issue…** are at the bottom of the Doctor page. **Report an Issue…** is also in the right-click menu. The file is plain text, so you can read it first. It has no container data, and ColimaBar hides secrets, host names and your user name, but it can miss one. See [Save diagnostics and report an issue](docs/usage.md#save-diagnostics-and-report-an-issue). The debug flag `--diagnostics PATH` writes the file without the dialog.
- ColimaBar can install its own updates. For a copy that it can replace (the installer, the disk image, or a build in `/Applications` or `~/Applications`), the footer button is **Install *version*** and the right-click item is **Install ColimaBar *version*…**. After you confirm, ColimaBar downloads the release, checks the size, the SHA-256 digest, the build attestation (if `gh` is installed and logged in) and the signature, replaces its own app by rename, and restarts. If a VM action, a docker build, pull or push, an auto-start, Doctor or a diagnostics save runs at the click, ColimaBar says "ColimaBar cannot restart now". It waits for such work that starts later. If `gh` could run the attestation check at the confirmation but cannot run it later, ColimaBar stops. A failed or cancelled update leaves no copy in the Applications folder. If the old app cannot go back after a failed swap, ColimaBar says where it is. A Homebrew copy shows the `brew upgrade` command with **Copy Command** and **Run in Terminal**. Other copies open the release page. The first in-app update is from 0.9.0. See [Update](docs/install.md#update).
- The installer compares the SHA-256 digest of the download with the one that the GitHub API lists. It also checks the code identifier and the version of the app, and tells you when Homebrew also has ColimaBar.
- CI checks after each release that it is immutable, that the digest of each asset is the digest of the built file, and that the binary has no update test hook. `COLIMABAR_UPDATE_TEST=1 ./build.sh` makes a test build for the update. See [CONTRIBUTING.md](CONTRIBUTING.md#test-build-for-the-in-app-update).

### Changed

- The ColimaBar log no longer shows the names of containers, images, volumes and networks in the request lines of the proxy (for example `POST /containers/{name}/start`).

## [0.8.0] - 2026-10-16

### Added

- Doctor checks the docker setup of the selected profile: the tools, the docker context, the app routes, `DOCKER_HOST` in your shell files, the registry login, the docker plugins, the VM status, stale Lima files and the disk space. It offers a fix for most findings. Open it from the System tab or the right-click menu. If the profile is Broken or its last start failed, the stopped screen also shows a **Doctor…** button. See [Doctor](docs/usage.md#doctor).
- Repair gets a profile that Colima shows as Broken, or that does not start, running again. It removes a file whose PID belongs to another program before the force stop, so Colima and Lima never stop that program. If it cannot remove such a file, it stops nothing. It stops the VM by force, removes the pid files of Lima and of the Colima daemon whose process is gone, and starts the VM again. See [Repair](docs/usage.md#repair).

### Changed

- ColimaBar now also moves a launchd `DOCKER_HOST` or testcontainers `docker.host` that points to a Colima socket in `~/.colima` to the ColimaBar socket.

### Fixed

- ColimaBar no longer rewrites `~/.testcontainers.properties` when it cannot read it as UTF-8 text.
- The busy marker and the lock of a VM action hold the PID of the script. After a long sleep of the Mac, an action that still runs keeps its lock, and ColimaBar no longer shows it as finished. A marker or lock of a script that is gone ends at once.

## [0.7.1] - 2026-10-15

### Changed

- While auto-start is on, ColimaBar moves a manual `docker context use colima` back to `colimabar`. The move can take up to 15 seconds.
- When another profile starts, ColimaBar moves the docker CLI to `colimabar-PROFILE`. Before, it moved to `colimabar`, which pointed at the daemon of the selected profile.

### Fixed

- ColimaBar moves the docker CLI back to the `colimabar` context after Colima starts. Before, `colima start` switched it to `colima` and it stayed there. After `colima stop`, docker failed with `context "colima": context not found` and auto-start did not work. ColimaBar now also repairs this state.

## [0.7.0] - 2026-10-15

### Added

- After the Mac wakes from sleep, ColimaBar refreshes at once and checks that Docker answers in each running VM with the docker runtime. If Docker does not answer, it sends one notification with a **Restart** button. If the clock of a VM is more than 2 seconds off, ColimaBar waits 20 seconds for Lima to fix it. If the clock is still off, ColimaBar sets it to the time of the Mac. If that fails, it sends a notification with a **Restart** button. See [When the Mac sleeps](docs/usage.md#when-the-mac-sleeps).
- On battery, auto-stop stops an idle VM after 10 minutes at most. In Low Power Mode, it stops the VM after 5 minutes at most. A shorter time that you select stays. To turn this off, clear **Stop sooner on battery or in Low Power Mode**. Export and import include this setting. See [On battery and in Low Power Mode](docs/auto-stop.md#on-battery-and-in-low-power-mode).

### Changed

- On battery, in Low Power Mode or when the Mac is hot, ColimaBar checks the VM less often while the dashboard is closed.
- The README and the Install guide recommend Homebrew first.

### Fixed

- Auto-stop does not count the time that the Mac sleeps as idle time. Before, after a long sleep, the VM stopped seconds after the Mac woke.
- Auto-start does not fail when the Mac sleeps while it waits for Docker.

## [0.6.0] - 2026-10-08

### Added

- Change the settings of a stopped profile. The stopped screen now shows the VM resources and features from `colima.yaml`: CPU, memory, disk, Rosetta and Kubernetes. A change of CPU, memory, disk size, Rosetta or Kubernetes only edits `colima.yaml`. The VM stays stopped, and the new values apply at the next start. A bigger disk asks first. **Shrink…** of a stopped VM starts the VM once to create the new disk, then stops it again. See [Open the dashboard](docs/usage.md#open-the-dashboard).

### Changed

- The Rosetta switch is disabled when `vmType` in `colima.yaml` is not `vz`, unless Rosetta is on. Rosetta needs the `vz` VM type.
- When you turn on Kubernetes for a running VM with less than 4 GB of memory, the dialog shows the memory and says that Kubernetes uses about 0.5 to 1 GB of it.
- ColimaBar refuses a change of the VM resources, Rosetta, Kubernetes or the disk while a `colima start` or `colima restart` of the profile runs, for example in a terminal. It also refuses a change of the VM resources, Rosetta or Kubernetes when the VM started or stopped outside ColimaBar and the dashboard did not show it yet. Nothing changes, and a notification tells you to try again.

### Fixed

- A decimal memory in `colima.yaml`, such as `memory: 2.5`, shows as 2.5 GB, and a change of the CPU only keeps it. Colima reads the memory as GiB. The header, the live tiles and the profile list also show a decimal memory.
- ColimaBar finds the profile of a `colima start` in progress with flags before the name, for example `colima start --cpu 4 work`, `colima start -p=work` and `colima start colima-work`. `colima restart -f` also counts. For `restart`, `-f` means `--force`.
- **Start** and **Stop** in the profile menu now list the selected profile too. Before, with only one profile, both submenus were empty but still opened, so a click did nothing. An empty **Start**, **Stop** or **Delete Profile** submenu is now left out. The profile list shows the live state of the selected profile, and the action that runs for it.
- The popover closes when you click in another app. Before, after you opened ColimaBar from Spotlight, macOS could leave another app active, and the popover stayed open.

## [0.5.0] - 2026-10-07

### Added

- **Keep logs of removed containers that fail** on the System tab. This option is off by default. When it is on, ColimaBar keeps the newest 500 lines (at most 128 KB) of each container that `docker run --rm` started, in memory only. If the container fails, **View logs** on its alert shows these lines for 5 minutes. See [Saved logs](docs/usage.md#saved-logs).
- **Uninstall ColimaBar…** in the right-click menu. After you confirm, it runs the uninstall script of the app in iTerm, or in Terminal when iTerm is not installed.
- A Question issue form.
- **Export Settings…** and **Import Settings…** on the System tab. They save the ColimaBar settings to a JSON file and load them on a different Mac. Before an import applies anything, ColimaBar shows the changes. It skips invalid values and profiles that do not exist on the Mac. See [Export and import settings](docs/usage.md#export-and-import-settings).
- **Shrink…** next to the disk size on the System tab. Colima cannot shrink a disk in place. Thus this deletes the VM with all its containers, images, volumes and build cache, and starts it again with a smaller disk and the same settings. You must type the profile name to confirm. See [Shrink the disk](docs/usage.md#shrink-the-disk).
- A socket and a docker context for each profile with the docker runtime, for example `~/.cache/colima-bar/profiles/work.sock` and `colimabar-work`. A docker request to the socket of a stopped profile starts that profile. Use `docker --context colimabar-work ps`, or set `DOCKER_HOST` for one project. The ColimaBar socket still follows the selected profile. See [Profile sockets](docs/auto-start.md#profile-sockets).
- Auto-stop checks each running docker profile, not only the selected one. Each profile stops after its own idle time. See [Auto-stop](docs/auto-stop.md).
- The profile menu in the header now shows also when you have one profile. It starts and stops other profiles, creates a profile with **New Profile…** and deletes a profile with **Delete Profile** after a typed confirmation. **Delete Profile** refuses `colima`, names that start with `colima-`, and a profile without a folder, and a profile while an action runs for it. See [Profiles](docs/usage.md#profiles).
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
- The popover closes before a confirmation dialog opens. Before, the dialog of a cleanup, a remove or a VM setting could open behind the popover, for example over an app in full screen.
- Auto-stop does not stop the VM while an action that you started still runs. Before, it could stop the VM while a cleanup waited for you to click **OK**.
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

[Unreleased]: https://github.com/imohitkr/colima-bar/compare/v0.8.0...HEAD
[0.8.0]: https://github.com/imohitkr/colima-bar/compare/v0.7.1...v0.8.0
[0.7.1]: https://github.com/imohitkr/colima-bar/compare/v0.7.0...v0.7.1
[0.7.0]: https://github.com/imohitkr/colima-bar/compare/v0.6.0...v0.7.0
[0.6.0]: https://github.com/imohitkr/colima-bar/compare/v0.5.0...v0.6.0
[0.5.0]: https://github.com/imohitkr/colima-bar/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/imohitkr/colima-bar/compare/v0.3.1...v0.4.0
[0.3.1]: https://github.com/imohitkr/colima-bar/compare/v0.3.0...v0.3.1
[0.3.0]: https://github.com/imohitkr/colima-bar/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/imohitkr/colima-bar/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/imohitkr/colima-bar/releases/tag/v0.1.0
