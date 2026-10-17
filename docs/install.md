# Install ColimaBar

[Docs index](README.md)

This page tells you how to install, verify, build and update ColimaBar.

## Requirements

- A Mac with Apple silicon
- macOS 14 or later
- [Colima](https://github.com/abiosoft/colima). To install it, run `brew install colima docker`.

## Homebrew (recommended)

Run this command in Terminal:

```sh
brew install --cask imohitkr/tap/colima-bar
```

The cask comes from the [imohitkr/homebrew-tap](https://github.com/imohitkr/homebrew-tap) repository. Homebrew installs ColimaBar in `/Applications`. A workflow in the tap verifies the attestation of each new release before it updates the cask. See [Verify a download](#verify-a-download).

Apple does not notarize ColimaBar. Thus macOS blocks the first launch after you install or upgrade ColimaBar. To allow it, do the steps in [The disk image](#the-disk-image), or remove the quarantine flag:

```sh
xattr -dr com.apple.quarantine /Applications/ColimaBar.app
```

To upgrade, run `brew upgrade --cask colima-bar`.

`brew uninstall` cannot restore your docker settings. To uninstall, do these steps in this order:

1. Choose **Uninstall ColimaBar…** in the right-click menu. If your version does not have this menu item, run `/Applications/ColimaBar.app/Contents/Resources/uninstall.sh`. See [Uninstall ColimaBar](uninstall.md).
2. Run `brew uninstall --cask colima-bar`.

## The installer

Run this command in Terminal:

```sh
curl -fsSL https://raw.githubusercontent.com/imohitkr/colima-bar/main/scripts/install.sh | bash
```

The installer does these steps:

1. It checks that the Mac has Apple silicon and macOS 14 or later.
2. It downloads `ColimaBar.zip` from the latest release.
3. It verifies the download, if it can. See [Verify a download](#verify-a-download).
4. It quits a running ColimaBar.
5. It installs ColimaBar in `/Applications`. If it cannot write to `/Applications`, it uses `~/Applications`. If ColimaBar is already installed, it replaces that copy in the same folder and removes a copy in the other folder.
6. It opens ColimaBar.

macOS does not show the "Apple could not verify" prompt for this download. If Colima is not installed, the installer tells you how to install it.

### Install a specific release

Set `COLIMABAR_VERSION` to the release tag. The installer supports v0.4.0 and later.

```sh
curl -fsSL https://raw.githubusercontent.com/imohitkr/colima-bar/main/scripts/install.sh | COLIMABAR_VERSION=v0.8.0 bash
```

## The disk image

1. Download [ColimaBar.dmg](https://github.com/imohitkr/colima-bar/releases/latest/download/ColimaBar.dmg).
2. Open the disk image.
3. Drag ColimaBar into Applications.

Apple does not notarize ColimaBar. Thus the first launch shows "Apple could not verify ColimaBar". Do these steps one time:

1. Click **Done**.
2. Open **System Settings > Privacy & Security**.
3. Scroll down. Next to "ColimaBar was blocked", click **Open Anyway**.
4. Enter your password, then click **Open Anyway** again.

As an alternative, remove the quarantine flag in Terminal, then open ColimaBar:

```sh
xattr -dr com.apple.quarantine /Applications/ColimaBar.app
```

## Verify a download

GitHub Actions builds each release. It signs a build provenance attestation for `ColimaBar.dmg` and `ColimaBar.zip`. The installer uses [ColimaBar.zip](https://github.com/imohitkr/colima-bar/releases/latest/download/ColimaBar.zip).

The app has an ad-hoc code signature. This signature only shows that the app is not damaged. It does not show who built it.

### What the installer checks

If the [GitHub CLI](https://cli.github.com) (`gh`) 2.68 or later is installed and logged in to github.com, the installer verifies the download before it installs it. The check makes sure that the release workflow of this repository built the file from the release tag.

- If the check fails, the installer stops.
- The installer also compares the SHA-256 digest of the download with the digest that the GitHub API lists for the release file. It stops if they differ. If the API does not answer, it tells you and continues. It then checks the signature (with the code identifier of ColimaBar) and the version of the app.
- If `gh` cannot do the check, the installer tells you that it did not verify the download. Then it continues. This occurs when `gh` is missing, older than 2.68 or not logged in.

To stop in that second case too, set `COLIMABAR_REQUIRE_VERIFY=1`:

```sh
curl -fsSL https://raw.githubusercontent.com/imohitkr/colima-bar/main/scripts/install.sh | COLIMABAR_REQUIRE_VERIFY=1 bash
```

### Check a file yourself

To check that a file comes from the release workflow of this repository, run this command in the folder of the file:

```sh
gh attestation verify ColimaBar.dmg --repo imohitkr/colima-bar
```

For the zip file, use `ColimaBar.zip` in place of `ColimaBar.dmg`. You cannot verify releases from before v0.4.0 this way, because they have no attestation. If a release file fails this check, report it as described in [SECURITY.md](../SECURITY.md).

## Build from source

You need Swift 6.4. Use the Xcode Command Line Tools with Swift 6.4, or Swift 6.4 from [swiftly](https://www.swift.org/install/macos/).

```sh
git clone https://github.com/imohitkr/colima-bar && cd colima-bar
make install    # builds, installs to ~/Applications and opens the app
make dmg        # builds build/ColimaBar-<version>.dmg
```

To list all targets, run `make` with no target. The Make targets call `./build.sh`, so `./build.sh install` and `./build.sh dmg` also work. [CONTRIBUTING.md](../CONTRIBUTING.md) has the other targets.

## After you install

ColimaBar turns on its login item the first time you open it from an Applications folder. See [The login item](usage.md#the-login-item).

The docker CLI needs no setup. If your `~/.zshrc` sets `DOCKER_HOST`, replace that line with the [shell snippet](auto-start.md#shell-setup).

## Update

ColimaBar checks GitHub for a new release one time each day. When a new version is available, ColimaBar does two things:

- It sends one notification for that version.
- It shows a button in the dashboard footer. The button depends on how you installed ColimaBar.

| How you installed ColimaBar | The button | What a click does |
|---|---|---|
| The installer, the disk image, or a build in `/Applications` or `~/Applications` that you can write to | **Install *version*** | ColimaBar asks first. Then it downloads the release, checks it, replaces itself and restarts. See [Install an update in the app](#install-an-update-in-the-app). |
| Homebrew | **Update *version*** | ColimaBar shows `brew upgrade --cask colima-bar && open -a ColimaBar`. You can copy it or run it in Terminal. |
| A copy that runs from a disk image or Downloads, a read-only disk, a folder that you cannot write to, or a development build | **Update *version*** | The release page opens. Download the update there. |

To check now, click the version in the dashboard footer, or choose **Check for Updates…** in the right-click menu. To turn off the daily check, clear **Check for new versions daily** on the System tab. ColimaBar never installs an update without your click.

The first in-app update is from version 0.9.0 to the next release. If you use an older version, update it one time with the installer, Homebrew or the disk image.

### Install an update in the app

When you click **Install**, ColimaBar asks for a confirmation. Click **Install and Restart**.

1. ColimaBar downloads `ColimaBar.zip` of that exact release from GitHub. The footer shows the progress. Click the cancel button to stop.
2. ColimaBar checks the download. See [What the update checks](#what-the-update-checks). If a check fails, ColimaBar changes nothing and tells you why. The button then opens the release page until you start ColimaBar again.
3. If a VM action, a docker build, pull or push, an auto-start, Doctor or a diagnostics save runs when you click, ColimaBar does not start and says "ColimaBar cannot restart now". If such work starts after your click, ColimaBar waits for up to 2 minutes (the footer shows **Waiting…**). Then it does not install and tells you.
4. ColimaBar replaces its own app and restarts. For about 2 seconds, a docker command does not start a stopped VM. Open connections, for example `docker logs -f`, close. Running containers continue.
5. The new version shows one notification with a link to the release notes.

ColimaBar keeps the old app in `~/.cache/colima-bar/update/previous` until the new version starts. A failed or cancelled update leaves no copy in the Applications folder. If the old app cannot go back after a failed swap, ColimaBar tells you where it is. See [the troubleshooting page](troubleshooting.md#an-update-does-not-install). To go back to an older version, run the installer with `COLIMABAR_VERSION`. See [Install a specific release](#install-a-specific-release).

### What the update checks

- The release is immutable, and the size and SHA-256 digest of `ColimaBar.zip` come from the GitHub API. ColimaBar compares them with the file that it downloaded.
- If `gh` 2.68 or later is installed and logged in, ColimaBar runs the same `gh attestation verify` check as [the installer](#what-the-installer-checks). If the check fails, ColimaBar stops. If `gh` cannot run it when you confirm, the dialog says so, and the update goes on with the digest check. If `gh` could run it then but cannot run it later (for example, no network or a time-out), ColimaBar stops and keeps the **Install** button. Click it again later.
- The zip must hold only `ColimaBar.app`. The app must have a valid signature with the code identifier `com.imohitkr.ColimaBar`, the version of the release, a newer version than the running one, and `colima-ctl.sh`.

These checks rest on TLS and GitHub. The digest shows that the file is whole and is the file that GitHub stores. Immutable releases keep the files of a tag. Only the attestation shows that the release workflow of this repository built the file. The ad-hoc signature shows integrity, not the author. Homebrew is stronger: the cask holds the SHA-256 in a separate repository, and the tap checks the attestation. See [SECURITY.md](../SECURITY.md).

### Update with the installer, Homebrew or the disk image

If you use Homebrew, run `brew upgrade --cask colima-bar`.

If you use [the installer](#the-installer), run it again. The installer quits ColimaBar, replaces the app in the same folder and opens it again. It also compares the SHA-256 digest of the download with the one that GitHub lists.

If you use the disk image, download it again and replace the app in Applications.
