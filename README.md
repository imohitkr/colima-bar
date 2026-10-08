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
- **Quiet**: ColimaBar uses almost no CPU. It sends few notifications: when something fails, one for each new version, and one the first time the icon hides.

> [!NOTE]
> ColimaBar is an independent community project. It is not part of [Colima](https://github.com/abiosoft/colima), and the Colima maintainers do not support it. Report ColimaBar problems in the [ColimaBar issue tracker](https://github.com/imohitkr/colima-bar/issues).

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

## Install

You need a Mac with Apple silicon, macOS 14 or later, and [Colima](https://github.com/abiosoft/colima) (`brew install colima docker`).

**Homebrew (recommended).** Run this command in Terminal:

```sh
brew install --cask imohitkr/tap/colima-bar
```

Apple does not notarize ColimaBar, so macOS blocks the first launch. To allow it, open **System Settings > Privacy & Security** and click **Open Anyway**.

**The installer.** Run this command in Terminal. macOS does not block this download.

```sh
curl -fsSL https://raw.githubusercontent.com/imohitkr/colima-bar/main/scripts/install.sh | bash
```

**The disk image.** Download [ColimaBar.dmg](https://github.com/imohitkr/colima-bar/releases/latest/download/ColimaBar.dmg) and drag ColimaBar into Applications. Allow the first launch as described for Homebrew above.

The [Install guide](docs/install.md) has the full steps, the download check and the build from source.

### After you install

The docker CLI needs no setup. ColimaBar starts at login and switches docker to its context `colimabar`.

If your `~/.zshrc` sets `DOCKER_HOST`, replace that line with the [shell snippet](docs/auto-start.md#shell-setup). Otherwise your terminal bypasses auto-start.

## Use

- Left-click the menu bar icon to open the dashboard. Move the pointer over a control to see what it does.
- Right-click or Control-click the icon to start, stop or restart Colima, change options, check for updates, uninstall or quit.

The [Usage guide](docs/usage.md) describes the icon, each tab and each menu item.

## Update

If you use Homebrew, run `brew upgrade --cask colima-bar`. If you used the installer, run it again. ColimaBar checks for a new version each day and shows an **Update** button in the dashboard when one is available.

## Uninstall

Right-click the menu bar icon and choose **Uninstall ColimaBar…**. Colima, your containers and your images stay.

- If the icon is hidden, open ColimaBar from Spotlight first.
- If your version does not have the menu item, [run the uninstall script manually](docs/uninstall.md#run-the-script-manually).
- If you installed with Homebrew, run `brew uninstall --cask colima-bar` after you uninstall. Do not run it first: Homebrew cannot restore your docker settings.

The [Uninstall guide](docs/uninstall.md) lists what the script removes.

## Documentation

The [user guides](docs/README.md) describe how to install, use, troubleshoot and uninstall ColimaBar.

## Contributing

Bug reports, ideas and pull requests are welcome. Read [CONTRIBUTING.md](CONTRIBUTING.md) and follow the [Code of Conduct](CODE_OF_CONDUCT.md). [ARCHITECTURE.md](ARCHITECTURE.md) explains how ColimaBar works. [CHANGELOG.md](CHANGELOG.md) lists the changes in each release.

To report a security problem, follow [SECURITY.md](SECURITY.md).

## Support

To get help, read [SUPPORT.md](SUPPORT.md).

ColimaBar is free and open source. If it saves you time, you can support its development through [GitHub Sponsors](https://github.com/sponsors/imohitkr).

## License

[MIT](LICENSE)
