# ColimaBar documentation

These guides are for people who use ColimaBar. For a short overview, read the [project README](../README.md).

| Page | Contents |
|---|---|
| [Install](install.md) | Requirements, Homebrew, the installer, the disk image, download checks, the build from source, the `colimabar` command in your PATH, updates, the in-app update and what it checks. |
| [Use](usage.md) | The menu bar icon, the stopped screen and its VM settings, the dashboard tabs, the Inspect page, Compose projects, image updates (the badges, Pull All, Check Now, Update and Recreate), image scan (Trivy or Grype), container domains (HTTPS and the custom suffix), the debug shell, volume backup and restore, disk cleanup and Return Free Space, the VM settings page (DNS, port forwarder, IP address, mounts, registries, the VM type and mount type), disk shrink, settings export and import, Doctor and the upgrade warning, Repair and the diagnostics file, the right-click menu, the docker and kubectl context switchers, keyboard shortcuts, the dashboard shortcut, notifications (restart loops, planned stops, muted projects), system sleep, network changes and the port and DNS checks, saved logs, profiles, the command line, `colimabar://` links and Shortcuts recipes. |
| [Auto-start](auto-start.md) | The ColimaBar socket, the profile sockets, the shell snippet, what happens when ColimaBar quits, and the docker routes. |
| [Auto-stop](auto-stop.md) | Stop the VM after an idle time, what counts as activity, system sleep, and a shorter idle time on battery and in Low Power Mode. |
| [Uninstall](uninstall.md) | The menu item, the uninstall script, what it removes (also the `colimabar` command links) and what stays. |
| [Troubleshooting](troubleshooting.md) | Run Doctor first, an upgrade warning, where the logs are, common problems such as a Broken profile and Repair, a container that has no shell, a volume restore that fails, a disk image that does not get smaller, cleanup that cannot read the logs, a VM that does not start after a VM settings change, domains that show 502 or use another port, a custom suffix that does not resolve, names that do not resolve, image update badges that do not show, an image scan that fails, published ports that stop answering, DNS that fails after a VPN change, ColimaBar is gone after the macOS prompt, an update that does not install, a link or the dashboard shortcut that does nothing, and how to report a bug. |
| [Roadmap](roadmap.md) | Features that are planned. They have no target version yet. |

Contributors: read [ARCHITECTURE.md](../ARCHITECTURE.md) for the design and [CONTRIBUTING.md](../CONTRIBUTING.md) to build and test.
