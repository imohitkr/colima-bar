# Changelog

All notable changes to ColimaBar are in this file.

The format follows [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/). ColimaBar uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Image update check (off by default). On the System tab, turn on **Check registries for newer images daily**. A blue **update** badge shows a container whose tag has a newer image in the registry. An orange **recreate** badge shows a container that runs an older image than the one that you pulled. **Pull New Image**, **Pull All** and **Update and Recreate** for a Compose project pull the new images. ColimaBar checks each image once a day and at most 3 Docker Hub images in one run, to keep inside the rate limit of Docker Hub. See [Image updates](docs/usage.md#image-updates).

## [0.15.0] - 2026-10-23

### Added

- Change the VM type and mount type of a profile with a guided recreate. On the "More VM settings" page, pick the VM type (`vz` or `qemu`) and the mount type (`virtiofs`, `sshfs` or `9p`), then click **Change and Recreate…**. ColimaBar can back up the volumes and save the images first, deletes and creates the VM again (Colima keeps its Docker data disk), and restores what is missing. See [Change the VM type or mount type](docs/usage.md#change-the-vm-type-or-mount-type).
- Pick the VM type and mount type for a new profile.

### Changed

- ColimaBar now needs macOS 15 or later. Version 0.14.1 is the last version for macOS 14. The in-app update and the Homebrew notice skip a release that needs a newer macOS than the one that runs, and say why.
- The TLS identities of HTTPS for container domains now exist in memory only. ColimaBar no longer makes a temporary keychain file, and it deletes the leftover files of older versions at launch.

## [0.14.1] - 2026-10-23

### Changed

- The in-app update skips a release that needs a newer macOS than the one that runs, and says why. It also refuses a downloaded app that needs a newer macOS. ColimaBar 0.15.0 needs macOS 15, so on macOS 14 ColimaBar stays on 0.14.1.

## [0.14.0] - 2026-10-22

### Added

- Container domains (off by default). On the System tab, turn on **Open containers at .localhost names**. Containers then open at names like `web.shop.localhost`. ColimaBar runs a proxy on port 80 of this Mac only, or on 8080 when 80 is busy. Labels pick the port or add names. See [Container domains](docs/usage.md#container-domains).
- HTTPS for container domains (off by default). On the System tab, turn on **Use HTTPS with a local certificate authority**. ColimaBar makes a certificate authority that can sign only websites under `.localhost` and your custom suffix, and macOS asks for your password one time to trust it. The links then use `https://`, on port 443 or 8443. Turning HTTPS off removes the certificate authority. **Show Certificate** shows the file for Node.js and other tools. The uninstall script removes the certificate authority too. See [HTTPS](docs/usage.md#https).
- Custom suffix for container domains, for example `web.shop.colima.internal` (off by default). On the System tab, turn on **Also use a custom suffix**. ColimaBar runs a small DNS server on this Mac and adds `/etc/resolver/SUFFIX`, and macOS asks for an administrator password to add it and to remove it. Only `test` and one or two names before `.test`, `.internal` or `.home.arpa` are allowed. ColimaBar never changes a resolver file that another tool owns. With HTTPS on, a new suffix replaces the certificate authority. The uninstall script removes the resolver file. See [Custom suffix](docs/usage.md#custom-suffix).

## [0.13.0] - 2026-10-21

### Added

- Restart-loop alert. A container that exits 3 times in 5 minutes sends one "keeps restarting" notification. It then sends no crash alerts until it runs 10 minutes without an exit, or becomes healthy. In a loop, out-of-memory and unhealthy alerts are silent for 5 minutes after the last exit.
- **Mute alerts** for a Compose project with the bell icon in its header, or right-click the header. The banner stops. The dashboard still lists the alerts.
- Optional notification when a container is healthy again (off by default). The settings file has it.
- Cleanup page. On the System tab, click **Clean Up…** in **Disk usage**. The page lists the largest images, unused volumes, stopped containers, build cache entries and container log files, each with its size. Remove an item, or empty a log, with one click. ColimaBar asks first. See [Clean up disk space](docs/usage.md#clean-up-disk-space).
- **Return Free Space** runs fstrim in the VM, so the disk image on the Mac gets smaller. The notification gives the size before and after.
- Weekly cleanup (off by default). It removes dangling images and unused build cache of the selected profile while the VM runs and no other action runs. It waits while docker traffic is live, so it never removes an image that a build or a pull is about to use. It never starts the VM. A failed run tries again after 6 hours. The settings file has it.

### Changed

- No crash or unhealthy alert for a container that you, Compose or ColimaBar stop or restart, or while a VM-wide action runs. An unhealthy alert in this time is checked again after it. The unhealthy alert waits up to 3 minutes after a start.

## [0.12.0] - 2026-10-19

### Added

- Inspect page. Click the name or the image of a container, or choose **Inspect…** in its ••• menu. The page shows the image and digest, state, health, command, environment, labels, networks, mounts, ports and limits. It hides values with secret names or secret shapes until you click the eye. A bind mount from your Mac opens in Finder, and a web port opens in your browser. See [Inspect a container](docs/usage.md#inspect-a-container).
- Compose project menu. The ••• menu in the header of a project opens the project folder (also in Visual Studio Code) and runs **Pull Images**, **Up (Detached)** and **Down…** with docker compose. **Down…** asks first and keeps volumes and images. See [Compose projects](docs/usage.md#compose-projects).
- Debug shell for containers that have no shell, for example distroless images. In the ••• menu of a running container, choose **Debug shell**. See [Containers tab](docs/usage.md#containers-tab) and [A container has no shell](docs/troubleshooting.md#a-container-has-no-shell). It uses `busybox:latest`. The hidden setting `debugShellImage` changes the image.
- Volume backup and restore. In the Volumes tab, click **•••** > **Back Up…** or **Restore from Backup…**. The header menu has **Restore to New Volume…** and **Back Up All…**. ColimaBar saves a plain `.tar` file with the mode `0600`, shows the progress and removes an incomplete file. It checks a file before it restores, refuses an unsafe archive and asks before it replaces a volume that has files. The Shrink dialog offers to back up the volumes first. See [Back up and restore volumes](docs/usage.md#back-up-and-restore-volumes).

### Changed

- The diagnostics file hides more secrets: the values of keys such as `passphrase` and `connection_string`, and URL passwords with an empty user name or a `/` in them.
- **Shell** tells you to use **Debug shell** if the container has no shell.

### Fixed

- ColimaBar could quit when a docker client or Docker closed a socket connection first. A write then raised SIGPIPE. Now the write fails and ColimaBar continues.

## [0.11.0] - 2026-10-19

### Added

- More VM settings: DNS servers, the port forwarder, a reachable IP address, mounts, inotify and Docker registries. Click **More VM settings…** on the System tab or the stopped screen. ColimaBar keeps a copy of the old `colima.yaml`. It puts the copy back if the VM does not start with the new settings or the restart does not end. It refuses to write if `colima.yaml` changed outside ColimaBar. See [VM settings](docs/usage.md#vm-settings).
- Port forwarding check. ColimaBar finds published ports that answer in the VM but not on the Mac, for example after a sleep or a network change. It tells you in the Containers tab, in a notification and in Doctor, with a **Restart** button. A grpc port forwarder also gets **Use ssh forwarder**. See [Published ports stop answering](docs/troubleshooting.md#published-ports-stop-answering).
- DNS check. ColimaBar finds a VM that cannot resolve host names while the Mac can, for example after a VPN change. It tells you in the Containers tab, in a notification and in Doctor. With servers in `network.dns`, **Use the Mac's DNS** clears them. Doctor warns when a VPN uses split DNS and `network.dns` is set. See [DNS fails in the VM after a VPN change](docs/troubleshooting.md#dns-fails-in-the-vm-after-a-vpn-change).

### Changed

- Doctor has two new checks, **Port forwarding** and **DNS in the VM**. `colimabar doctor --json` shows them as `portForwarding` and `vmDNS`. `schemaVersion` stays 1.

## [0.10.0] - 2026-10-19

### Added

- A keyboard shortcut can open and close the dashboard from any app. On the System tab, in **App**, click **Record Shortcut**, then press the keys, for example ⌃⌥⌘C. It has no default and needs no Accessibility or Input Monitoring permission. Settings export and import include it. See [The dashboard shortcut](docs/usage.md#the-dashboard-shortcut).
- A `colimabar` command for Terminal and scripts. `colimabar status` shows the VM, auto-start, auto-stop and the socket. `colimabar start`, `stop` and `restart` run the VM actions. `start` and `restart` wait until Docker is ready. `colimabar open` opens the dashboard. `colimabar doctor` runs the Doctor checks, and `colimabar diagnostics` writes the diagnostics file. `status` and `doctor` have `--json` for scripts. `status`, `doctor` and `diagnostics` never start the VM, and ColimaBar does not need to run. Homebrew links the command. The installer links it into `~/.local/bin` or `~/bin` if that folder is in your `PATH`. The uninstall script removes these links. See [Command line](docs/usage.md#command-line).
- ColimaBar opens `colimabar://` links: `open`, `doctor`, `start`, `stop` and `restart`. The last three take `profile=NAME`. Use them from Raycast, Alfred, Shortcuts or a script. ColimaBar asks before a link starts, stops or restarts a VM. The System tab setting **Ask before a link starts, stops or restarts Colima** turns the question off. A link never gives data back, and never creates a VM. If ColimaBar refuses a link, it sends a notification. See [Links](docs/usage.md#links-url-scheme).

### Changed

- The update also checks that the new app has the `colimabar` command.
- The diagnostics file shows if the keyboard shortcut is active, and "(command line)" when `colimabar diagnostics` wrote it.
- The install docs warn that **Move to Bin** in the "ColimaBar" Not Opened prompt deletes ColimaBar, and tell you to click **Done**. A new troubleshooting entry tells you how to get ColimaBar back. See [ColimaBar is gone after the macOS prompt](docs/troubleshooting.md#colimabar-is-gone-after-the-macos-prompt).

### Fixed

- The dashboard did not show when the icon was behind the camera housing or when the menu bar was full. It now opens as a window.

## [0.9.0] - 2026-10-17

### Added

- Before the first start after a Colima or Lima upgrade, ColimaBar asks first and offers the release notes. Doctor shows the change in a new Upgrade check. See [Upgrade warning](docs/usage.md#upgrade-warning).
- Doctor can save a diagnostics file and open a bug report with the versions filled in. **Save Diagnostics…** and **Report an Issue…** are at the bottom of the Doctor page. **Report an Issue…** is also in the right-click menu. The file is plain text, so you can read it first. It has no container data, and ColimaBar hides secrets, host names and your user name, but it can miss one. See [Save diagnostics and report an issue](docs/usage.md#save-diagnostics-and-report-an-issue). The debug flag `--diagnostics PATH` writes the file without the dialog.
- ColimaBar can install its own updates. For a copy that it can replace (the installer, the disk image, or a build in `/Applications` or `~/Applications`), the footer button is **Install *version*** and the right-click item is **Install ColimaBar *version*…**. After you confirm, ColimaBar downloads the release, checks the size, the SHA-256 digest, the build attestation (if `gh` is installed and logged in) and the signature, replaces its own app by rename, and restarts. If a VM action, a docker build, pull or push, an auto-start, Doctor or a diagnostics save runs at the click, ColimaBar says "ColimaBar cannot restart now". It waits for such work that starts later. If `gh` could run the attestation check at the confirmation but cannot run it later, ColimaBar stops. A failed or cancelled update leaves no copy in the Applications folder. If the old app cannot go back after a failed swap, ColimaBar says where it is. A Homebrew copy shows the `brew upgrade` command with **Copy Command** and **Run in Terminal**. Other copies say why ColimaBar cannot install, then offer the release page. The first in-app update is from 0.9.0. See [Update](docs/install.md#update).
- The installer compares the SHA-256 digest of the download with the one that the GitHub API lists. It also checks the code identifier and the version of the app, and tells you when Homebrew also has ColimaBar.

### Changed

- CI checks that each release is immutable and that the SHA-256 digest that GitHub lists for each file is the digest of the built file.
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

[Unreleased]: https://github.com/imohitkr/colima-bar/compare/v0.15.0...HEAD
[0.15.0]: https://github.com/imohitkr/colima-bar/compare/v0.14.1...v0.15.0
[0.14.1]: https://github.com/imohitkr/colima-bar/compare/v0.14.0...v0.14.1
[0.14.0]: https://github.com/imohitkr/colima-bar/compare/v0.13.0...v0.14.0
[0.13.0]: https://github.com/imohitkr/colima-bar/compare/v0.12.0...v0.13.0
[0.12.0]: https://github.com/imohitkr/colima-bar/compare/v0.11.0...v0.12.0
[0.11.0]: https://github.com/imohitkr/colima-bar/compare/v0.10.0...v0.11.0
[0.10.0]: https://github.com/imohitkr/colima-bar/compare/v0.9.0...v0.10.0
[0.9.0]: https://github.com/imohitkr/colima-bar/compare/v0.8.0...v0.9.0
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
