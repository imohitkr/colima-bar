<p align="center">
  <img src="docs/screenshots/icon.png" width="112" alt="ColimaBar icon">
</p>

<h1 align="center">ColimaBar</h1>

<p align="center">
  A native macOS menu bar dashboard for <a href="https://github.com/abiosoft/colima">Colima</a> that <b>starts the VM on demand</b>.
</p>

<p align="center">
  <a href="https://github.com/imohitkr/colima-bar/actions/workflows/ci.yml"><img src="https://github.com/imohitkr/colima-bar/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-black?logo=apple" alt="macOS 14+">
  <img src="https://img.shields.io/badge/Apple%20silicon-only-black?logo=apple" alt="Apple silicon only">
  <img src="https://img.shields.io/badge/Swift-6.4-F05138?logo=swift&logoColor=white" alt="Swift 6.4">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue" alt="MIT license"></a>
  <a href="https://github.com/sponsors/imohitkr"><img src="https://img.shields.io/badge/sponsor-%E2%99%A5-ea4aaa?logo=githubsponsors&logoColor=white" alt="Sponsor"></a>
</p>

<p align="center">
  <img src="docs/screenshots/containers.png" width="480" alt="Dashboard: containers grouped by Compose project, with health, ports, CPU and memory">
</p>

- **Auto-start**: run `docker`, a test suite or an IDE test while Colima is stopped. ColimaBar starts the VM, and the command continues.
- **Live dashboard**: see containers by Compose project, with health, ports, CPU, memory and logs. Images, volumes and VM settings are one click away.
- **Auto-stop**: ColimaBar can stop the VM when it is idle.
- **Quiet**: ColimaBar uses almost no CPU. It sends a notification only when something fails.

> [!NOTE]
> ColimaBar is an independent community project. It is not part of [Colima](https://github.com/abiosoft/colima), and the Colima maintainers do not support it. Report ColimaBar problems [here](https://github.com/imohitkr/colima-bar/issues).

## Install

You need a Mac with Apple silicon, macOS 14 or later, and [Colima](https://github.com/abiosoft/colima) (`brew install colima docker`).

**The installer (recommended).** Run this command in Terminal:

```sh
curl -fsSL https://raw.githubusercontent.com/imohitkr/colima-bar/main/scripts/install.sh | bash
```

**The disk image.** Download [ColimaBar.dmg](https://github.com/imohitkr/colima-bar/releases/latest/download/ColimaBar.dmg) and drag ColimaBar into Applications. Apple does not notarize ColimaBar, so macOS blocks the first launch. To allow it, open **System Settings > Privacy & Security** and click **Open Anyway**.

[docs/install.md](docs/install.md) has the full steps, the download check and the build from source.

### After you install

The docker CLI needs no setup. ColimaBar starts at login and switches docker to its context `colimabar`.

If your `~/.zshrc` sets `DOCKER_HOST`, replace that line with the [shell snippet](docs/auto-start.md#shell-setup). Otherwise your terminal bypasses auto-start.

## Use

- Left-click the menu bar icon to open the dashboard. Move the pointer over a control to see what it does.
- Right-click the icon to start, stop or restart Colima, change options, check for updates, uninstall or quit.

[docs/usage.md](docs/usage.md) describes each tab and menu item.

## Screenshots

<table>
  <tr>
    <td width="50%"><img src="docs/screenshots/images.png" alt="Images tab: sizes, in-use badges, prune"></td>
    <td width="50%"><img src="docs/screenshots/system.png" alt="System tab: VM resources, features, disk usage, auto-start, auto-stop presets, hide icon, update check"></td>
  </tr>
  <tr>
    <td align="center"><b>Images</b>: sizes, images in use, prune</td>
    <td align="center"><b>System</b>: VM size, Rosetta, k3s, disk, auto-start and auto-stop</td>
  </tr>
  <tr>
    <td colspan="2"><img src="docs/screenshots/logs.png" alt="Log viewer with search, follow, timestamps and highlighted stderr"></td>
  </tr>
  <tr>
    <td colspan="2" align="center"><b>Log viewer</b>: live follow, search, timestamps and highlighted stderr</td>
  </tr>
</table>

## Update

Run the installer again. ColimaBar checks for a new version each day and shows an **Update** button in the dashboard when one is available.

## Uninstall

Right-click the menu bar icon and choose **Uninstall ColimaBar…**. Colima, your containers and your images stay. For details, read [docs/uninstall.md](docs/uninstall.md).

## Documentation

- [Install](docs/install.md): the installer, the disk image, download checks and the build from source
- [Use](docs/usage.md): the dashboard, the right-click menu, notifications and profiles
- [Auto-start](docs/auto-start.md): how docker clients reach Colima, and the shell snippet
- [Auto-stop](docs/auto-stop.md): stop the VM when it is idle
- [Uninstall](docs/uninstall.md): what the uninstall script removes and what stays
- [Troubleshooting](docs/troubleshooting.md): logs and common problems
- [Roadmap](docs/roadmap.md): planned features

## Contributing

Bug reports, ideas and pull requests are welcome. Read [CONTRIBUTING.md](CONTRIBUTING.md) and follow the [Code of Conduct](CODE_OF_CONDUCT.md). [ARCHITECTURE.md](ARCHITECTURE.md) explains how ColimaBar works. [CHANGELOG.md](CHANGELOG.md) lists the changes in each release.

To report a security problem, follow [SECURITY.md](SECURITY.md).

## Support

To get help, read [SUPPORT.md](SUPPORT.md).

ColimaBar is free and open source. If it saves you time, you can support its development through [GitHub Sponsors](https://github.com/sponsors/imohitkr).

## License

[MIT](LICENSE)
