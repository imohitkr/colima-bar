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
curl -fsSL https://raw.githubusercontent.com/imohitkr/colima-bar/main/scripts/install.sh | COLIMABAR_VERSION=v0.6.0 bash
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
- It shows an **Update** button in the dashboard footer. The button opens the release page.

If you use Homebrew, run `brew upgrade --cask colima-bar`.

If you use [the installer](#the-installer), run it again. The installer quits ColimaBar, replaces the app in the same folder and opens it again.

If you use the disk image, download it again and replace the app in Applications.

To check now, click the version in the dashboard footer, or choose **Check for Updates…** in the right-click menu. To turn off the daily check, clear **Check for new versions daily** on the System tab.
