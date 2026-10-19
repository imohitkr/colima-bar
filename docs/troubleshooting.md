# Troubleshooting

[Docs index](README.md)

This page lists the ColimaBar logs, fixes for common problems and the steps to report a bug.

## Run Doctor first

For many problems, open [Doctor](usage.md#doctor): click **Doctor…** in the right-click menu. Doctor checks the tools, the docker context, the routes, the shell, the registry login, the docker plugins, the Colima and Lima upgrade, the VM status, the stale Lima files and the disk space. It offers a fix for most findings. Doctor only reads, so it is safe to run at any time.

## ColimaBar warns about an upgrade

Colima or Lima has a new minor or major version, or an older version, since the last good start of the profile. A new version can change the VM disk. See [Upgrade warning](usage.md#upgrade-warning).

1. Click **Release Notes**. Read the notes of Colima and Lima. ColimaBar starts nothing.
2. Back up the data that you need.
   - If the VM runs (Restart or a change of settings), copy a volume to a file. Run this in a folder in your home folder: `docker run --rm -v VOLUME:/data -v "$PWD":/backup alpine tar czf /backup/VOLUME.tgz -C /data .`
   - If the VM is stopped, do not start it with `colima start`. That start is the risk that the dialog guards against. Copy the [Colima folder](#colimabar-uses-the-wrong-colima-folder) while the VM is stopped. On APFS, this makes a fast clone: `cp -cR ~/.colima ~/colima-backup`. Use your own Colima folder in place of `~/.colima`.
3. Start the VM again in ColimaBar and click **Continue**.

If you cancel, the dialog comes again at the next start. If the start fails after the upgrade, Doctor shows the change in the Upgrade row: the new version is the likely cause. To go back, install the old version from the release page of Colima or Lima on GitHub, and restore the backup if needed.

## Logs

| Log | Contents |
|---|---|
| `~/.cache/colima-bar/ctl.log` | The output of VM actions, for example `colima start` and `colima stop`. ColimaBar starts a new file when it passes 1 MB. |
| `_lima/colima/ha.stderr.log` in your [Colima folder](#colimabar-uses-the-wrong-colima-folder) | The Lima host agent log of the `default` profile. If `LIMA_HOME` is set, the log is `colima/ha.stderr.log` in `LIMA_HOME`. For a different profile, the folder is `colima-PROFILE`. |
| The macOS unified log | The messages of ColimaBar itself. |

To open the first two logs in Console, click the log button in the dashboard footer.

To show the ColimaBar messages of the last hour, run this command:

```sh
log show --info --last 1h --predicate 'subsystem == "com.imohitkr.ColimaBar"'
```

## An action fails

If a VM action fails, ColimaBar sends a notification. Open `~/.cache/colima-bar/ctl.log` to see the output of Colima.

If the notification says "Colima profile NAME didn't become ready", open the Lima log from the dashboard footer.

## A disk shrink fails

A disk shrink runs `colima stop`, `colima delete --data --force` and `colima start`. For a stopped VM, it skips the first `colima stop` and runs `colima stop` at the end. If a step fails, ColimaBar sends a notification. Open `~/.cache/colima-bar/ctl.log` to see the output of Colima.

If the notification says that the stop failed, the new disk exists and the VM runs. Click **Stop** in the profile menu, or run `colima stop -p PROFILE`.

`colima delete` removes `colima.yaml`. ColimaBar saves a copy with the new disk size in `~/.cache/colima-bar/colima.PROFILE.yaml.shrink` before it deletes anything. If the delete failed, or `colima start` failed after the delete, do these steps:

1. If `PROFILE/colima.yaml` does not exist in your [Colima folder](#colimabar-uses-the-wrong-colima-folder), copy the saved file to that path.
2. Run `colima start --profile PROFILE`.

The containers, images and volumes are gone after the delete. You cannot get them back.

## Auto-start fails

If auto-start cannot start the VM, the docker client gets HTTP status 503 with this message:

```text
ColimaBar could not start Colima. Check the Colima log or start it from the menu bar.
```

After `colima start` exits, ColimaBar waits up to 60 seconds for the Docker daemon to become ready. Then it stops and sends the notification "Colima profile NAME didn't become ready. Check the Colima log."

To fix it, do these steps:

1. Open `~/.cache/colima-bar/ctl.log` and the Lima log. Look for the error.
2. Start Colima from the right-click menu, or run `colima start`.
3. Run the docker command again.

Auto-start also does nothing for some profiles. See [When auto-start does not start the VM](auto-start.md#when-auto-start-does-not-start-the-vm).

## Problems after the Mac sleeps

After the Mac wakes, ColimaBar checks each running VM. See [When the Mac sleeps](usage.md#when-the-mac-sleeps). If Docker does not answer, or ColimaBar cannot set the clock of the VM, you get a notification.

To fix it, do these steps:

1. Click **Restart** in the notification, or restart the VM from the dashboard.
2. If the clock of the VM is wrong, compare the clocks. On the Mac, run `date -u` and `colima ssh --profile PROFILE -- date -u`.
3. If the clock is often wrong, update Colima and Lima. Lima 2.1 and later set the clock of the VM every 10 seconds.

## docker cannot connect after you quit ColimaBar

When ColimaBar quits, auto-start stops. The ColimaBar socket then points directly to Colima. If the VM is stopped, docker cannot connect.

To fix it, do one of these steps:

- Open ColimaBar again. Auto-start then starts the VM on the next docker command.
- Run `colima start`.

## Colima hangs or does not start

If `colima start` hangs or fails, and `colima list` shows the profile as Broken, a pid file of Lima can be stale. Open Doctor and click **Repair profile 'NAME'…**. See [Repair](usage.md#repair) for the steps.

Repair refuses while a `colima start` runs. If `colima start` hangs, stop it first (Ctrl-C). Then click **Repair profile 'NAME'…**.

To check by hand, look at the pid files (`ha.pid`, `vz.pid`, `qemu.pid`, `krunkit.pid`) in the Lima folder of the profile, `~/.colima/_lima/colima` for `default`. Look also at `~/.colima/PROFILE/daemon/daemon.pid` (`~/.colima/default/daemon/daemon.pid` for `default`). For each file, run `ps -p PID`. If the process is not Lima (or `colima daemon` for the daemon file), or does not exist, remove the file. Do this before you run `colima stop --force`. Else Lima sends SIGKILL, and Colima sends SIGTERM, to that process.

## docker says context not found

docker shows `context "colima": context not found`, or `colima-PROFILE` for a profile that is not `default`. `colima stop` deleted the context, but the docker config still names it.

To fix it, click **Use colimabar** in [Doctor](usage.md#doctor), or run `docker context use colimabar`, then `docker ps`. While auto-start is on, ColimaBar repairs this itself within 15 seconds.

## docker does not start Colima

1. Make sure that ColimaBar runs and that auto-start is on. Look at **Auto-start Colima on Demand** in the right-click menu.
2. Start Colima, then open the System tab. Each route to the ColimaBar socket shows a check mark when it is set. The System tab shows only while Colima runs.
3. In your terminal, run `echo $DOCKER_HOST`. If it shows a different socket, replace that line in your `~/.zshrc` with the [shell snippet](auto-start.md#shell-setup).
4. Run `docker context show`. It must show `colimabar`, or `colimabar-PROFILE` for a profile that is not selected. ColimaBar does not change a context that points to a different daemon.
5. If an IDE test cannot connect, restart the IDE. An IDE reads the launchd `DOCKER_HOST` only when it starts.

## ColimaBar uses the wrong Colima folder

ColimaBar finds the Colima folder like Colima does. It uses the first match:

1. `COLIMA_HOME`, if it is set and the folder exists.
2. `~/.colima`, if it exists.
3. `~/.config/colima`, if it exists.
4. `$XDG_CONFIG_HOME/colima`, if `XDG_CONFIG_HOME` is set.
5. `~/.colima`.

Lima's folder is `LIMA_HOME` if it is set, else `_lima` in the Colima folder. ColimaBar checks the folders again while it runs. If you create or move a folder, you do not have to restart ColimaBar.

ColimaBar reads `COLIMA_HOME`, `LIMA_HOME` and `XDG_CONFIG_HOME` from its launchd environment, not from `~/.zshrc`. If you set one of them in your shell, do these steps:

1. Run `launchctl setenv NAME VALUE` with the same value, for example `launchctl setenv COLIMA_HOME "$HOME/colima-home"`.
2. Quit ColimaBar and open it again.

`launchctl setenv` lasts until you log out. To keep the value after a restart of the Mac, run the command again after each login.

## macOS blocks the first launch

Apple does not notarize ColimaBar. macOS shows "ColimaBar" Not Opened. Click **Done**, not **Move to Bin**. Then follow the [Open Anyway steps](install.md#the-disk-image), or remove the quarantine flag:

```sh
xattr -dr com.apple.quarantine /Applications/ColimaBar.app
```

With Homebrew, this occurs after each install and upgrade. As an alternative, use [the installer](install.md#the-installer). macOS does not block its download.

The prompt can also come when you do not open ColimaBar yourself: at login, the login item starts ColimaBar. After a `brew upgrade`, remove the quarantine flag before you log out, or click **Done** at the next login.

## ColimaBar is gone after the macOS prompt

If you clicked **Move to Bin**, macOS deleted `/Applications/ColimaBar.app`. Your settings and the login item stay. To install ColimaBar again:

- **Homebrew.** Homebrew still lists the cask, so use `reinstall`, then remove the quarantine flag:

  ```sh
  brew reinstall --cask colima-bar
  xattr -dr com.apple.quarantine /Applications/ColimaBar.app
  open /Applications/ColimaBar.app
  ```

- **Disk image or installer.** Install ColimaBar again as described in [install.md](install.md). The installer download has no quarantine flag.

If docker cannot connect while ColimaBar is gone, see [docker cannot connect after you quit ColimaBar](#docker-cannot-connect-after-you-quit-colimabar).

## An update does not install

ColimaBar tells you why in a notification. A failed update leaves the old app in place.

- **The download does not match the size or the SHA-256 digest.** The download was damaged or changed. Click the notification and download the update from the release page.
- **gh attestation verify failed.** The file does not match a build of this repository. Do not use it. Report it as described in [SECURITY.md](../SECURITY.md).
- **The signature or the version of the app is wrong.** ColimaBar installs only an app with the code identifier `com.imohitkr.ColimaBar` and the version of the release.
- **macOS blocked the change to the app folder.** Since macOS 13, App Management can stop an app from changing another app. Open System Settings > Privacy & Security > App Management and turn on ColimaBar. Or install the update with [the installer](install.md#the-installer).
- **A VM action, a docker build, pull or push, an auto-start, Doctor or a diagnostics save did not end in time.** Try again when the work ends.
- **ColimaBar could not run the build attestation check.** The confirmation dialog promised the check, but `gh` could not run it (no network, a time-out or a login problem). Nothing changed. Try again later.
- **There is not enough free disk space.** The update needs the size of the download plus about 200 MB (up to about 250 MB) in `~/.cache/colima-bar`.
- **ColimaBar could not put the old version back.** This is rare: the swap failed, and the old app could not go back to its place. The notification gives the path of the old app. Quit ColimaBar. Move that app to `/Applications/ColimaBar.app` (or to the folder of the app that you use). Until you move it, ColimaBar keeps that folder and does not delete it. If you cannot find the app, use [the installer](install.md#the-installer).
- **The new version is installed, but ColimaBar did not restart.** Quit ColimaBar and open it again.

After a failed check or a failed swap, the button opens the release page until you start ColimaBar again. ColimaBar installs nothing in a debug run, and from a copy that is not in `/Applications` or `~/Applications`.

To go back to an older version, run the installer with that version. See [Install a specific release](install.md#install-a-specific-release).

## ColimaBar does not start when you log in

- ColimaBar turns on the login item only when you open it from an Applications folder. A copy that runs from the disk image or from Downloads does not turn it on.
- Make sure that **Launch at Login** in the right-click menu has a check mark.
- If the System tab shows "Waiting for your approval in System Settings > Login Items", click **Open**. Then turn on ColimaBar in the list.

## The menu bar icon is missing

If **Hide Icon While Colima Is Stopped** is on, the icon hides while Colima is stopped. To show it, open ColimaBar from Spotlight. See [Hide the icon](usage.md#hide-the-icon).

If the icon is behind the camera housing or the menu bar is full, ColimaBar opens the dashboard as a window. Hold Command and drag other icons away, or quit an app with a menu bar icon.

## A link does nothing

1. Make sure that ColimaBar runs. If ColimaBar runs as a debug run (`--snapshot`, `--popover` …), it ignores links. Quit it and open ColimaBar normally.
2. Look for a notification. ColimaBar says why it refused the link. If notifications are off for ColimaBar, an alert window shows the text instead.
3. If a question appears, answer it. A link that starts, stops or restarts a VM asks while **Ask before a link starts, stops or restarts Colima** is on.
4. If the link has a profile, make sure that `colima list` shows it. A link never creates a VM.
5. If macOS opens another app or none, register ColimaBar again: `/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/ColimaBar.app` (or `~/Applications/ColimaBar.app`). Then try again.

See [Links](usage.md#links-url-scheme).

## The dashboard shortcut does nothing

1. Open the System tab. Look at the row **Keyboard shortcut for the dashboard**. An orange line says why the shortcut does not work.
2. If the line says that another app uses the shortcut, close that app or record a different shortcut.
3. If the line says that macOS uses the shortcut, record a different one. Or turn the macOS shortcut off in System Settings > Keyboard > Keyboard Shortcuts.
4. If the row shows no orange line, click the ✕ and record the shortcut again.
5. If ColimaBar runs as a debug run (`--snapshot`, `--popover` …), it does not use the shortcut. Quit it and open ColimaBar normally.
6. After an update, the old copy can hold the keys for a few seconds. ColimaBar tries again after 1 and 3 seconds.

See [The dashboard shortcut](usage.md#the-dashboard-shortcut).

## Report a bug

Open [Doctor](usage.md#doctor) and click **Report an Issue…** (the right-click menu has it too). ColimaBar then saves a [diagnostics file](usage.md#save-diagnostics-and-report-an-issue) and opens the bug report form with the versions filled in. Drag the file into the **Diagnostics** box.

The file has the versions, the settings, the Doctor report, the output of `colima list` and `limactl list`, the logs and a digest of crash reports. It has no container names, images, volumes or environment variables. ColimaBar hides secrets, host names, your user name and your home folder, but it can miss one. Open the file and read it before you attach it.

To report without the file, open a [bug report](https://github.com/imohitkr/colima-bar/issues/new?template=bug_report.yml). Include this information:

- The macOS version.
- The ColimaBar version. The dashboard footer and the right-click menu show it.
- The output of `colima version`.
- The runtime and the profile, if the profile is not `default`.
- The steps that cause the problem, what you expected and what happened.
- The relevant lines from `~/.cache/colima-bar/ctl.log`. This file contains the output of VM actions.

Remove secrets, tokens and private host names from logs before you post them.

To ask a question, open a [question](https://github.com/imohitkr/colima-bar/issues/new?template=question.yml). To report a security problem, do not open an issue. Follow [SECURITY.md](../SECURITY.md).
