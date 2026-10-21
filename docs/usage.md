# Use ColimaBar

[Docs index](README.md)

ColimaBar shows the state of your Colima VM and its containers in the menu bar. Move the pointer over any control in the dashboard to see what it does.

## The menu bar icon

The icon shows the state of the selected [profile](#profiles):

- **Box outline**: Colima is stopped.
- **Filled box with a number**: Colima runs. The number counts the running containers.
- **Warning triangle**: Colima runs, and at least one container is unhealthy.
- **Hourglass**: an action runs, for example a start or a stop.

Left-click the icon to open the dashboard. Right-click or Control-click the icon to open [the right-click menu](#the-right-click-menu).

## Open the dashboard

Left-click the menu bar icon to open the dashboard. You can also press the [dashboard shortcut](#the-dashboard-shortcut). To keep it open in a resizable window, click the window button in the footer, or choose **Open Dashboard Window** in the right-click menu.

The tabs (Containers, Images, Volumes and System) and the live tiles show only while Colima runs. If Colima is stopped, the dashboard shows the stopped screen. It has a **Start Colima** button and the **Hide menu bar icon while Colima is stopped** checkbox. If Colima is not installed, the dashboard shows the command to install it.

Below the **Start Colima** button and the checkbox, the stopped screen shows the **VM resources** and **Features** of the selected profile, from its `colima.yaml`. You can change them while the VM is stopped:

- A preset, **Apply**, the Rosetta switch and the Kubernetes switch save to `colima.yaml` at once, with no dialog. The VM stays stopped, and the new values apply at the next start.
- Colima reads the memory as GiB, and it can be a decimal number such as `memory: 2.5`. If the memory is not one of the choices, the memory picker shows it as an extra choice, for example **2.5 GB**. A change of the CPU only keeps that memory.
- A bigger disk asks first. Colima grows the disk at the next start. A disk cannot shrink in place, so a grow is permanent.
- **Shrink…** deletes all Docker data. It starts the VM once to create the new disk, then stops it again. See [Shrink the disk](#shrink-the-disk).

**More VM settings…** opens the [VM settings](#vm-settings) page.

If the profile has no `colima.yaml`, the stopped screen tells you to start the profile once. Colima creates the file at the first start.

If `colima list` shows the profile as Broken, or the last start of the profile failed, the stopped screen shows an orange line with a **Doctor…** button. See [Doctor](#doctor).

ColimaBar refuses a change and sends a notification in these cases. Nothing changes. Try again later.

- You change the VM resources, Rosetta or Kubernetes, and the VM started or stopped outside ColimaBar, for example from a terminal. The dashboard did not show it yet.
- A `colima start` or `colima restart` of the profile runs, for example in a terminal. Wait until it ends. This also applies to a running VM.

## The dashboard

### Header and live usage

The header shows the VM state, its CPUs, memory, disk and architecture, and the start, stop and restart buttons. Next to the name "Colima", the profile menu shows the selected profile. See [Profiles](#profiles).

The live tiles show the total CPU and memory of all containers as a share of the VM, with 60-second graphs. A third tile counts running, stopped and unhealthy containers.

### Containers tab

- ColimaBar groups containers by Compose project. You can start, stop or restart a full project.
- Each container shows health badges, CPU, memory and `localhost` links for its ports.
- Click the name or the image of a container to open its [Inspect page](#inspect-a-container).
- A running container has logs, shell, restart and stop buttons. **Remove…** is in its ••• menu.
- A stopped container has logs, start and remove buttons.
- The shell opens in iTerm, or in Terminal when iTerm is not installed. If the container has no shell, the terminal tells you to use **Debug shell**.
- **Debug shell** is in the ••• menu of a running container and on its Inspect page. It opens a shell in a new container that shares the processes and the network of the container. Use it for an image that has no shell, for example a distroless image. The new container uses the image `busybox:latest`. On the first use, docker downloads the image. In the shell, `ps` shows the processes of the container, and its files are in `/proc/1/root`. The new container has the `SYS_PTRACE` capability and no other extra right. While it runs, it shows as a row named `colimabar-debug-` and the first 12 characters of the container ID. If you choose **Debug shell** again, you get a second shell in the same container. When you close the window, or when the container stops, the new container ends and docker removes it. To use another image, for example `nicolaka/netshoot`, run `defaults write com.imohitkr.ColimaBar debugShellImage nicolaka/netshoot`. A custom image must start a shell by default (`busybox` and `nicolaka/netshoot` do). The setting is not in the settings file. If the name is not valid, ColimaBar uses busybox and sends a notification.
- The ••• menu of a Compose project opens the project folder and runs docker compose. See [Compose projects](#compose-projects).
- The ••• menu of a container opens **Inspect…**. It also copies the name, ID, image or an exec command. It also opens ports. **Logs in Terminal** follows the logs in iTerm, or in Terminal when iTerm is not installed.
- You can filter the list and show running containers only.
- **Stop all** stops all running containers. ColimaBar asks first.
- An orange notice below the list shows a broken port forward or a VM that cannot resolve names. See [When the network changes](#when-the-network-changes).

### Log viewer

Each container gets a live log window. It has search, follow, timestamps, a stderr filter and copy. The window stays open when the container restarts.

If Docker removed the container, the window shows the lines that ColimaBar saved, if any. See [Saved logs](#saved-logs).

### Inspect a container

Click the name or the image of a container, or choose **Inspect…** in its ••• menu. The page replaces the tabs while the VM runs. **Done** (or the Escape key) closes it, and **Logs** opens the log window. The page reads the container again every 2 seconds. If the container is gone, the page says so. For a running container, **Debug shell** opens a [debug shell](#containers-tab).

The page has these sections: image (with the digest), state, health, command, environment, labels, networks, mounts, ports and resources. A limit of 0 shows as "No limit".

- **Hidden values.** ColimaBar hides the value of a variable or label with a secret name, such as `PASSWORD`, `TOKEN` or `API_KEY`. It also hides a value that looks like a token or a URL with a password. The value after a flag such as `--password` in the command is hidden too. Click the eye to show one value until you close the page. The copy button copies the full value, also when it is hidden.
- **Mounts.** If a bind mount comes from a folder that Colima shares from your Mac, **Open in Finder** shows that folder. A path that only exists in the VM shows "VM only".
- **Ports.** **Open in Browser** opens a web port on `localhost`. A port of a database or another service that is not web shows **Copy localhost:PORT** instead.

ColimaBar keeps these values in memory only while the page is open. It does not write them to the log, to notifications or to the diagnostics file.

### Compose projects

For a container that docker compose started, ColimaBar reads the project folder and the Compose files from its labels. The ••• menu in the header of the project has these items:

- **Open Project Folder**, **Open in VS Code** (only if Visual Studio Code is installed) and **Copy Project Path**.
- **Pull Images** runs `docker compose pull`. Running containers do not change.
- **Up (Detached)** runs `docker compose up -d`. It creates and starts the containers that changed or are missing.
- **Down…** runs `docker compose down`. ColimaBar asks first. It removes the containers and networks of the project. Volumes and images stay.
- **Copy Last Output** copies the last lines that docker compose printed. ColimaBar keeps them in memory only.

A spinner shows while docker compose runs for the project. If it fails, a notification gives the exit code. It shows no output, because the output can hold secrets. Use **Copy Last Output** to read it. After 15 minutes, ColimaBar stops docker compose and says so. The buttons are off if the docker CLI is missing, if the Compose files are gone (the folder moved or was deleted), and in a debug run. Doctor checks the docker CLI and the compose plugin (**Docker plugins**).

#### Mute a Compose project

To stop the banners of one project, click the bell icon in its header. You can also right-click the header and choose **Mute Alerts**. The bell then shows a slash. Click it again, or choose **Unmute Alerts**, to send banners again. The mute stops only the banner and the sound. The Containers tab still lists the alerts of the project. ColimaBar keeps the mute for each profile and project on this Mac. The settings file does not hold it. ColimaBar keeps up to 200 mutes.

### Images and Volumes tabs

These tabs show sizes and the items that containers use. You can pull the latest version of an image tag that you already have. You can also remove and prune images, remove unused volumes, and back up and restore volumes. See [Back up and restore volumes](#back-up-and-restore-volumes). ColimaBar asks before it deletes volume data.

#### Back up and restore volumes

ColimaBar saves the files of a volume to a tar archive on your Mac, and copies them back. The VM must run. One backup or restore runs at a time. A debug run does not back up or restore.

To back up one volume:

1. In the Volumes tab, click **•••** next to the volume. Choose **Back Up…**.
2. If running containers use the volume, ColimaBar names them. They can change files during the backup. For a database, stop the containers first. Click **Back Up** to go on.
3. Choose the name and the folder, then save. The default name is `VOLUME-yyyyMMdd-HHmmss.tar`.

The strip at the top of the tab shows the progress and a **Cancel** button. When you cancel, or when the backup fails, ColimaBar removes the incomplete file. The notification has the file name, not the path.

To back up all named volumes, click **•••** in the header of the tab and choose **Back Up All…**. Choose a folder. ColimaBar saves each volume to its own file. It never replaces a file that exists.

The backup file is a plain `.tar` file with the mode `0600`. It is not compressed. Its first entry is `.colimabar-volume.json`: the name, the driver and the labels of the volume. The files of the volume follow in the folder `v/`. You can read the file with `tar tf FILE`. ColimaBar needs no helper image from the internet: it builds a small image on your Mac and loads it into the VM. The helper container never starts, and ColimaBar removes it after each backup.

To restore a backup:

1. To restore into a volume that exists, click **•••** next to it and choose **Restore from Backup…**. To make a new volume, click **•••** in the header and choose **Restore to New Volume…**.
2. Choose the `.tar` file. ColimaBar reads the whole file first and changes nothing. It refuses a file that is not a complete tar archive, and a file with an unsafe entry (a path outside the volume, or a device). A gzip file is not accepted: run `gunzip` first.
3. For a new volume, enter a name. ColimaBar restores the labels of the file only if the new name is the same as the old name.

ColimaBar follows these rules for an existing volume:

| The volume | What ColimaBar does |
|---|---|
| Has no files | It restores the files into the volume. |
| Has files, and no container uses it | It asks. Click **Replace All Files** to delete the volume, create it again with its own labels and restore. The old files are lost for good. |
| Has files, and uses a driver option (a bind folder or NFS) | It refuses. ColimaBar cannot create such a volume again. Restore to a new volume. |
| Has files, and containers use it | It refuses and names the containers. Remove them first, or restore to a new volume. |

If a restore fails, see [A volume restore fails](troubleshooting.md#a-volume-restore-fails).

### System tab

- **VM resources**: Light, Standard and Heavy presets, or your own CPU and memory values. **Apply** restarts the VM.
- **Features**: Rosetta, Kubernetes (k3s) and the disk size. A change restarts the VM, and ColimaBar asks first. A disk grows in place and keeps your data. To make it smaller, use **Shrink…**. See [Shrink the disk](#shrink-the-disk).
- Rosetta needs the `vz` VM type. If `vmType` in `colima.yaml` is not `vz`, the Rosetta switch is disabled, unless Rosetta is on. A missing `vmType` counts as `vz`.
- **More VM settings…**: DNS, the port forwarder, the IP address, mounts, inotify and Docker registries. See [VM settings](#vm-settings).
- To change these settings while the VM is stopped, use the [stopped screen](#open-the-dashboard).
- **Disk usage**: the space that images, containers, volumes and the build cache use, with cleanup buttons. **Clean Up…** opens the cleanup page. See [Clean up disk space](#clean-up-disk-space). **Clean up dangling images and build cache weekly** runs the safe cleanup once a week.
- **Auto-start and auto-stop**: see [Auto-start](auto-start.md) and [Auto-stop](auto-stop.md). **Stop sooner on battery or in Low Power Mode** shortens the idle time. See [On battery and in Low Power Mode](auto-stop.md#on-battery-and-in-low-power-mode).
- **Hide menu bar icon while Colima is stopped**: see [Hide the icon](#hide-the-icon).
- **Domains**: the switch for container domains. See [Container domains](#container-domains).
- **Doctor**: the summary of the last Doctor run, and the **Open Doctor** button. See [Doctor](#doctor).
- **Profiles**: shown only when you have more than one profile.
- **App**: the daily update check, crash notifications, **Notify when a container is healthy again after an alert**, **Keep logs of removed containers that fail**, **Launch ColimaBar at login**, **Ask before a link starts, stops or restarts Colima** (see [Links](#links-url-scheme)), **Keyboard shortcut for the dashboard** (see [The dashboard shortcut](#the-dashboard-shortcut)), and **Export Settings…** and **Import Settings…**. See [Export and import settings](#export-and-import-settings).

### VM settings

**More VM settings…** opens a page for the settings of `colima.yaml` that the System tab does not show. It is on the System tab and on the stopped screen. The page replaces the tabs. **Done** closes it. ColimaBar keeps your edits until you click **Apply** or **Revert**.

- **DNS servers**: up to 3 IP addresses, separated by commas. Use them when names do not resolve, for example with a VPN. If the field is empty, the VM uses the DNS of your Mac.
- **Reachable IP address**: gives the VM an address that your Mac can reach. It needs the `vz` VM type. Colima cannot turn it off again. When the VM runs, the page shows the IP address and a button to copy it.
- **Port forwarder**: `ssh` forwards TCP only and is stable. `grpc` also forwards UDP and is experimental.
- **Mounts**: the Mac folders that the VM shares. Click **Add Folder…** to pick one. **Writable** lets containers change the files. The page knows three cases. If `colima.yaml` has no `mounts` key, or `mounts: null`, Colima mounts no folder, and the page says "No folders are mounted." The first folder that you add is then the only one. If `colima.yaml` has `mounts: []`, Colima mounts your home folder, writable. The first folder that you add then goes after `~`. Remove `~` if you do not want your home folder. If you remove the last folder of a list, ColimaBar writes `mounts: []`, and Colima mounts your home folder again. A folder must exist. Colima does not start if one folder path begins with another, for example `~` and `~/code`, so ColimaBar refuses that list. A folder name must have no line break or control character.
- **Send file changes to the VM (inotify)**: for tools that watch files. It is experimental.
- **Docker registries**: mirrors that Docker tries before Docker Hub (an http or https address with no user name, query or fragment), and insecure registries that Docker reaches without TLS. They need the `docker` runtime.
- **Set when the VM was created**: the VM type, the mount type and the architecture. Colima ignores a change of these values. To change them, delete the profile and create it again.

ColimaBar shows a problem in red and turns **Apply** off until you fix it. If the VM runs, **Apply** asks first, restarts the VM and stops the running containers. If the VM is stopped, **Apply** only writes `colima.yaml`. The VM stays stopped, and the settings apply at the next start.

ColimaBar changes only the lines that you changed in `colima.yaml`. It keeps your comments and the keys that it does not know. Before it writes, it saves a copy of the old file in `~/.cache/colima-bar/colima.PROFILE.yaml.bak`. If `colima.yaml` changed outside ColimaBar after the page read it, ColimaBar changes nothing. It shows the message "colima.yaml changed outside ColimaBar. ColimaBar reloaded it. Check your changes and click Apply again." and drops your edits. After a good **Apply**, the page shows the new file, so **Apply** and **Revert** are off again. If the VM does not start with the new settings, or the restart does not end (it stops, or it takes longer than 15 minutes), ColimaBar puts the old file back. See [The VM does not start after a VM settings change](troubleshooting.md#the-vm-does-not-start-after-a-vm-settings-change).

If a setting has a form that ColimaBar cannot edit (an anchor, or a list over several lines), the page shows it as read-only. Edit `colima.yaml` by hand then.

### Doctor

Doctor checks the setup of the selected profile and offers a fix for most findings. Doctor only reads: the checks do not start the VM and do not change anything. Doctor runs when you ask for it. It never runs by itself. The checks never send a notification. **Use colimabar**, **Set routes**, **Use osxkeychain** and **Add folder** send one with the result. **Repair…**, **Restart**, **Use ssh forwarder** and **Use the Mac's DNS** send one only if they fail. **Copy line** sends none.

To open Doctor, click **Open Doctor** on the System tab, click **Doctor…** on the stopped screen, or choose **Doctor…** in the right-click menu. The page runs the checks when it opens, unless the last report is less than 5 minutes old. **Run checks** runs them again. **Done** closes the page.

Each check has a status: OK (green), warning (orange), problem (red) or skipped. A check can have a button for a fix. After a fix, Doctor runs the checks again. **Copy line** is the exception: it only copies the line. In a debug run (see [CONTRIBUTING.md](../CONTRIBUTING.md#debug-flags)), the fix buttons are disabled.

| Check | What it looks at | Fix |
|---|---|---|
| Tools | colima, limactl and the docker CLI, with their versions. A missing colima or limactl is a problem. A missing docker CLI, or Lima before 2.1, is a warning. | None |
| Upgrade | Colima and Lima compared with the last good start of the profile. A new minor or major version, or an older version, is a warning. A patch change and a macOS change are OK, and the detail lists them. Skipped while no good start is recorded, while the Colima or Lima version is unknown, and while the record is incomplete. See [Upgrade warning](#upgrade-warning). | None. Back up important volumes and read the release notes. |
| Docker context | The current docker context. A context that does not exist is a problem. The `default` context and a `colima` context are a warning, because the docker CLI then skips auto-start. Another context, such as a remote one, is a warning with no fix. Skipped while auto-start is off. | **Use colimabar** |
| App routes | The launchd `DOCKER_HOST` and `docker.host` in `~/.testcontainers.properties`. A route that is not set, or that points to another daemon, is a warning. ColimaBar leaves a route to another daemon. Skipped while auto-start is off. | **Set routes**, only for a route that is not set, and only when the docker context is a ColimaBar context, `default`, a `colima` context or a context that does not exist |
| Shell DOCKER_HOST | `DOCKER_HOST` in the startup files of your login shell. Doctor reads the text of the files and runs nothing. A socket of Colima is a warning. A socket of Docker Desktop is a problem. For a full check, run `echo $DOCKER_HOST` in a new terminal. | **Copy line** copies the line for the ColimaBar socket. Paste it in place of the line in your file. |
| Registry login | The credential helpers in the docker config file. Doctor reads only the names, never the logins. A `credsStore` helper that is missing is a problem. | **Use osxkeychain**, if `docker-credential-osxkeychain` exists |
| Docker plugins | `docker-buildx` and `docker-compose` in the folders where docker looks. A broken link is a problem. A plugin that is only in `/opt/homebrew/lib/docker/cli-plugins` is a warning. | **Add folder** |
| VM status | The status of the profile in `colima list`. Broken is a problem. If `colima list` fails or times out, the check is a warning. | **Repair…** |
| Stale Lima files | The pid files of Lima and of the Colima daemon. A file that names another process, or has no PID, is a problem. A file whose process is gone is OK: Colima and Lima remove it at the next start. If the list fails, the check is skipped. | **Repair…** for a problem. None for a file whose process is gone. |
| Disk space | Free space in the VM (only while it runs) and on the Mac. The VM is a problem at 95% used or under 2 GB free, and a warning at 85% used. The Mac is a problem under 5 GB free and a warning under 20 GB. | None. Use the cleanup buttons on the System tab. |
| Port forwarding | The published TCP ports of the running containers (at most 32). Each port must answer on the Mac (`127.0.0.1`). A port that answers in the VM but not on the Mac is a problem. A port that answers nowhere is a warning: the app in the container may be down. Ports bound to other host addresses are not checked, and the detail counts them. The check sends no data. Skipped while the VM is stopped, for a runtime other than docker, with `portForwarder: none`, when Docker does not answer, when `colima ssh` fails, and when the VM gives no answer for some ports. | **Restart**. For the grpc port forwarder: **Use ssh forwarder**. |
| DNS in the VM | The VM and the Mac both look up `registry-1.docker.io`. If only the VM fails, it is a problem. With servers in `network.dns`, a VPN that sends some domains to its own DNS servers (split DNS) is a warning, because those servers do not know them. Skipped while the VM is stopped, and when the Mac cannot resolve the name either. | **Restart**. With servers in `network.dns`: **Use the Mac's DNS**. |

**Restart** restarts the VM. **Use ssh forwarder** sets `portForwarder: ssh` in `colima.yaml`, and **Use the Mac's DNS** removes the servers in `network.dns`. Both ask first, restart the VM and work like **Apply** in [VM settings](#vm-settings). **Use the Mac's DNS** does not copy the servers of the Mac, because they change with the network.

**Use osxkeychain** and **Add folder** change the docker config file (`~/.docker/config.json`, or `$DOCKER_CONFIG/config.json`). First ColimaBar saves a backup next to the file, named `config.json.colimabar-YYYYMMDD-HHMMSS`. The backup is private to you. If the file is a symlink, ColimaBar writes through it. ColimaBar changes only `credsStore` or `cliPluginsExtraDirs` and keeps all other keys. If the file is not valid JSON, or ColimaBar cannot read it, ColimaBar changes nothing.

#### Upgrade warning

A new version of Colima or Lima can change the VM disk. ColimaBar records the versions of Colima and Lima (and of macOS, for Doctor) at the last good start of each profile. A start is good when ColimaBar started the VM and the start succeeded.

Before a start that you begin in ColimaBar, it compares the versions with that record. A minor or major bump of Colima or Lima, or an older version, is a risky change. Then the popover closes and a dialog names the change. The dialog has three buttons:

- **Cancel**: nothing starts. The dialog comes again at the next start.
- **Release Notes**: ColimaBar opens the release page of each changed tool on GitHub and starts nothing. Opening the page counts as a cancel.
- **Continue**: the start goes on. When it succeeds, the new versions become the record.

The dialog shows for **Start**, **Restart**, and for a change of CPU, memory, Rosetta, Kubernetes or disk while the VM runs. It shows before the dialog of the change itself. **Repair…** and **Shrink…** do not show it: Doctor shows the change, and a shrink deletes the data anyway. A patch change and a macOS change show no dialog. Doctor lists them.

Auto-start never shows this dialog. If you cancel the dialog while a docker command waits, auto-start still starts the VM, and the notification below comes. If an auto-start succeeds after a risky change, ColimaBar sends one notification, for example "Auto-start started profile work with Colima 0.11.0 (before: 0.10.3)". A click on it opens the release notes. Then the new versions become the record.

When you install ColimaBar 0.9.0 or later, a running profile with no record gets one at the next `colima list`. Thus you get no warning at the first start. A profile that you delete loses its record. There is no setting to turn the warning off. It never blocks a start when ColimaBar cannot read a version. Then it writes the reason in the ColimaBar log, and it asks nothing.

To keep the data of a volume before you continue, see [ColimaBar warns about an upgrade](troubleshooting.md#colimabar-warns-about-an-upgrade).

#### Save diagnostics and report an issue

The bottom of the Doctor page has **Save Diagnostics…** and **Report an Issue…**. **Report an Issue…** is also in the right-click menu. Both ask where to save a text file named `ColimaBar-diagnostics-YYYYMMDD-HHMMSS.txt`. The Desktop is the first choice. After the save, ColimaBar shows the file in Finder. **Report an Issue…** then opens the bug report form in your browser, with the versions and the Doctor summary filled in. Drag the file into the **Diagnostics** box of the form. If you click Cancel, ColimaBar saves nothing. While ColimaBar saves the file, the buttons are disabled.

The file has:

- the versions of ColimaBar, macOS, Colima, Lima and docker, and the model and memory of the Mac
- the ColimaBar settings, the Colima and Lima folders, and the names of the folder variables that are set (not their values)
- the state of the profile, with the number of containers (no names, images, volumes or variables)
- the Doctor report, the good starts, the docker routes and the docker contexts
- the output of `colima list`, `colima status` and `limactl list`, and the version of the engine (`colima status` and the engine only while the VM runs; `limactl list` always runs)
- the values of the simple keys of `colima.yaml` (for example `cpu`, `memory` and `vmType`). For other keys, such as `env`, `provision` and `docker`, it shows only "set" or "empty".
- the last 24 hours of the ColimaBar log, the end of `ctl.log`, the end of the Lima host agent log and a short digest of the crash reports of ColimaBar

ColimaBar hides what it finds: private keys, tokens, passwords, host names, e-mail addresses, public IP addresses, MAC addresses, your user name, the name of your Mac, and your home folder (it shows `~`). ColimaBar can miss a secret. Open the file and read it before you share it. The file is private to you (mode 0600) and has at most 2 MB. Saving it only reads: it does not start the VM.

#### Repair

**Repair profile 'NAME'…** is at the bottom of the Doctor page. Use it when the VM does not start, or when Colima shows the profile as Broken. After a restart of the Mac, a pid file can name a process that now belongs to another program. Then `colima stop --force` would send SIGKILL (Lima) or SIGTERM (Colima) to that program, and Lima counts the profile as running.

Repair asks first. The dialog lists the files. If you click OK, ColimaBar does this under the lock of the profile:

1. It removes the pid files of the profile whose PID belongs to another process, or that have no PID. This comes first, so Colima and Lima never stop that process. If it cannot remove a file, it sends a notification and stops. It has stopped nothing then.
2. It stops the VM with `colima stop --force`. If this fails, Repair continues.
3. If a process of Lima still runs for the VM, Repair stops and sends a notification. It removes nothing more.
4. It removes the other stale pid files.
5. It starts the VM with `colima start`.

Repair removes only these regular files (never links) whose owner process is gone:

- `ha.pid`, `vz.pid`, `qemu.pid` and `krunkit.pid` in the Lima folder of the profile (`_lima/colima` for `default`, `_lima/colima-NAME` otherwise).
- `daemon/daemon.pid` in the Colima folder of the profile. The owner must be `colima daemon start`. `colima stop` and `colima start` send SIGTERM to the PID in this file without a check.
- `usernet_*.pid` in each folder of `_lima/_networks`, only when no Lima instance has a host agent that runs.

Repair never touches disks, `cidata.iso`, `*.yaml` files, logs or sockets. Your containers, images and volumes stay. Running containers stop. Repair refuses to run if the profile has no `colima.yaml`, while a `colima start` or `colima restart` of the profile runs, or while another action of the profile runs. ColimaBar writes each removed file to `~/.cache/colima-bar/ctl.log`.

### Clean up disk space

On the System tab, click **Clean Up…** in the **Disk usage** section. The page replaces the tabs. Click **Done** to go back. The page has these parts:

- **Disk image on the Mac**: the space that the disk image of the VM uses on your Mac, and its maximum size. See **Return Free Space** below.
- **Images**, **Unused volumes**, **Stopped containers** and **Build cache**: the largest items of each kind, with their sizes. Each section shows at most 10 rows (5 for the build cache), the largest first. A line below the rows gives the number and the size of the rest. Use the Images and Volumes tabs to see all items.
- **Container logs**: the size of the json log file of each container in the VM.

Click **Remove…** on a row to remove the item. ColimaBar asks first. An image that a container uses, and an image with more than one tag, have no button. Remove the container first, or remove the tags in the Images tab. A build cache entry has no button. Click **Remove Unused…** in the section header instead. It keeps the cache that a running build uses. The headers of the image and volume sections also have **Remove Unused…** and **Remove All…**. The image and volume buttons do the same as **Unused images** and **Unused volumes** on the System tab. **Remove Unused…** for the build cache has no button there.

**Empty…** empties the log file of one container. `docker logs` then shows only new lines. The page lists only the active file of the json-file log driver. The rotated files (`-json.log.1`) and other log drivers are not in the list.

**Return Free Space** runs `fstrim` in the VM. Removing items frees space in the VM, but the disk image on your Mac keeps its size. After the trim, macOS can take back the free blocks. The VM and the containers continue to run. When the run ends, a notification gives the size of the disk image before and after. The result depends on the VM type and on macOS. If the image stays the same size, see [The disk image does not get smaller](troubleshooting.md#the-disk-image-does-not-get-smaller).

The weekly cleanup is off by default. To turn it on, select **Clean up dangling images and build cache weekly** on the System tab. Then ColimaBar removes the dangling images and the unused build cache of the selected profile once a week. It runs only while the VM runs, no other action of the profile runs and no docker traffic is live. A build or a pull is live traffic, so the cleanup waits for it to end. It never starts the VM and never asks. The first run comes soon after you turn it on. The System tab shows the date of the last run. If a run fails, ColimaBar sends one notification and tries again after 6 hours. If the VM is busy, it tries again after 1 hour. A good run counts for a week. A debug run never runs it.

### Shrink the disk

> [!WARNING]
> Shrink deletes all Docker data of the profile: all containers, images, volumes and build cache. If Kubernetes is on, it also deletes the cluster and its data. You cannot undo this. Before you shrink, save the data that you want to keep. To keep volume data, [back up the volumes](#back-up-and-restore-volumes) first. The warning names the volumes, and the **Back Up Volumes…** button starts **Back Up All…**.

Colima cannot shrink a disk in place. Thus **Shrink…** deletes the VM and its disk, and starts the VM again with an empty, smaller disk. The other VM settings in `colima.yaml` stay: CPU, memory, runtime, architecture, VM type, mount type, Rosetta and Kubernetes.

To shrink the disk:

1. On the System tab or the stopped screen, click **Shrink…** next to the disk size. Select a size: 20, 40, 60 or 80 GB. The menu shows only the sizes that are smaller than the current disk.
2. Read the warning. It shows the data that the disk holds now, from the **Disk usage** section. If the VM is stopped, ColimaBar cannot show this data, and it tells you to start the VM and back up the volumes first. If the VM runs and has named volumes, the warning lists them. Click **Back Up Volumes…** to stop the shrink and back up the volumes. Then start the shrink again.
3. Type the profile name. Then click **Delete Data and Shrink**.
4. Colima asks one more time. Click **OK**.

ColimaBar then stops the VM, runs `colima delete --data --force`, puts back `colima.yaml` with the new `disk` value and runs `colima start`. The dashboard shows "Shrinking disk to N GB" until the VM runs again.

If the VM was stopped, Colima must start it once to create the new disk. Thus ColimaBar runs the same steps, and then runs `colima stop`. The dashboard shows "Shrinking disk to N GB" until the VM is stopped again. If this last stop fails, ColimaBar sends a notification. The new disk exists then, and the VM runs.

`colima delete` also removes `colima.yaml`. Thus ColimaBar first saves a copy as `~/.cache/colima-bar/colima.PROFILE.yaml.shrink`. If the shrink fails, the notification names this copy. See [A disk shrink fails](troubleshooting.md#a-disk-shrink-fails).

### Export and import settings

Use these buttons to copy your ColimaBar settings to a different Mac.

**Export Settings…** saves a JSON file. The default name is `ColimaBar-settings.json`. The file holds these settings: auto-start, auto-stop and its time, **Stop sooner on battery or in Low Power Mode**, **Hide menu bar icon while Colima is stopped**, crash notifications, recovery notifications, **Keep logs of removed containers that fail**, the daily update check, the selected profile, the login item, the weekly cleanup, the keyboard shortcut and container domains. It does not hold Colima settings such as CPU or memory, or internal ColimaBar data.

**Import Settings…** reads such a file. ColimaBar does this:

- It rejects a file that is not a ColimaBar settings file.
- It rejects a file with a newer format version. To read it, update ColimaBar.
- It skips a value of the wrong type or out of range. For example, the auto-stop time must be from 1 to 1440 minutes. It also skips a keyboard shortcut that the app cannot use, or that another app or macOS holds.
- An empty keyboard shortcut in the file removes the shortcut.
- It ignores unknown keys. A setting that is not in the file keeps its current value.
- It skips a profile that does not exist on this Mac. To create it, use **New Profile…** in the profile menu. See [Create a profile](#create-a-profile). Then import again.
- It shows the changes and asks before it applies them. Then it shows the applied and skipped settings.

The `hotKey` value is a text with these parts, joined with `+`:

- Modifiers: `control`, `option`, `shift` and `command`. Use each one at most once. The case does not matter.
- One key name: a letter, a digit, `F1` to `F20`, `space`, `return`, `tab`, `delete`, `forwarddelete`, `home`, `end`, `pageup`, `pagedown`, `left`, `right`, `up`, `down`, `minus`, `equal`, `leftbracket`, `rightbracket`, `backslash`, `semicolon`, `quote`, `comma`, `period`, `slash` or `grave`.

For example: `"hotKey": "control+option+command+C"`. The value `""` means no shortcut. The [rules for a shortcut](#the-dashboard-shortcut) apply: two of ⌘ ⌃ ⌥, or one of them with F1 to F20.

### Footer

From left to right, the footer has these controls:

- **Shell button**: a shell in the VM, in iTerm, or in Terminal when iTerm is not installed.
- **Copy button**: an `export DOCKER_HOST=…` line for the ColimaBar socket, copied to the clipboard.
- **Config button**: `colima.yaml` in your text editor.
- **Log button**: the Colima logs in Console.
- **Version**: the ColimaBar version. Click it to check for a new version. When a new version is available, a button appears next to it: **Install *version*** (ColimaBar installs it after you confirm), or **Update *version*** (for a Homebrew copy it shows the `brew` command, for other copies it says why it cannot install, then offers the release page). While ColimaBar installs, the button shows a progress bar with a cancel button, then **Checking…**, **Waiting…** (while a VM action, a docker build, pull or push, an auto-start, Doctor or a diagnostics save runs; the cancel button still works) and **Installing…** (you cannot cancel it). During an install, a click on the version shows "An update is in progress". See [Update](install.md#update).
- **Window, refresh and quit buttons**.

### Keyboard shortcuts

- ⌘R refreshes the data.
- ⌘F moves the focus to the filter field.

## The dashboard shortcut

A keyboard shortcut can open and close the dashboard from any app. It has no default. It needs no Accessibility or Input Monitoring permission.

To set it:

1. Open the System tab. In **App**, click **Record Shortcut**.
2. Press the keys of the shortcut, for example ⌃⌥⌘C.

To cancel, press Esc. To remove the shortcut, click the ✕ next to it.

Rules for a shortcut:

- Use two or more of ⌘, ⌃ and ⌥ with a letter, a digit, a sign, Space or another key. ⇧ does not count.
- Or use one of ⌘, ⌃ and ⌥ with a function key (F1 to F20).

What a press does:

- If the dashboard is closed, it opens. If the icon is hidden, the icon shows. If the icon is behind the camera housing or the menu bar is full, the dashboard opens as a window.
- If the popover is open, it closes.
- If the dashboard window is in front, it closes. If the window is behind other windows, it comes to the front.
- While a dialog is open, it does nothing.

When the dashboard opens, it takes the focus. Use ⌘F to filter, ⌘R to refresh and Esc to close the popover.

ColimaBar takes the shortcut for itself. If macOS or another app already uses the keys, the recorder shows why and keeps waiting for other keys:

- **macOS uses this shortcut.** Record a different one, or turn it off in System Settings > Keyboard > Keyboard Shortcuts.
- **Another app uses this shortcut.** Record a different one.

If ColimaBar cannot take the keys when it starts or after you record, the System tab shows an orange line. If nothing happens when you press the keys, see [The dashboard shortcut does nothing](troubleshooting.md#the-dashboard-shortcut-does-nothing).

A debug run does not record or use the shortcut. The row is disabled. The `colimabar` command never uses it.

## The right-click menu

Right-click or Control-click the menu bar icon for these menu items:

- **Start Colima**, or **Restart Colima** and **Stop Colima** when the VM runs
- **Open Dashboard Window**
- **Doctor…** (opens the dashboard on the [Doctor](#doctor) page)
- **Report an Issue…** (saves the [diagnostics file](#save-diagnostics-and-report-an-issue), then opens the bug report form). While the file is saved, the item is **Saving Diagnostics…** and is disabled.
- **Launch at Login**
- **Auto-start Colima on Demand**
- **Hide Icon While Colima Is Stopped**
- **ColimaBar *version*** (shows the version only)
- **Check for Updates…**. When an update is available, the item is **Install ColimaBar *version*…**, **Update ColimaBar *version* with Homebrew…** or **Download ColimaBar *version*…**. During an install, the menu shows the progress and **Cancel Update**. While ColimaBar installs, you cannot cancel.
- **Uninstall ColimaBar…** (see [Uninstall](uninstall.md))
- **Quit ColimaBar**

When you quit ColimaBar, Colima and your containers continue to run. Auto-start stops until you open ColimaBar again.

## When the Mac sleeps

When the Mac wakes from sleep, ColimaBar does these steps:

1. It opens its streams again and refreshes the dashboard at once.
2. For each running profile with the docker runtime, it asks the Colima socket if Docker answers. It tries for about 30 seconds. It skips a profile with a running action or auto-start.
3. If Docker does not answer, it sends one notification with a **Restart** button.
4. If Docker answers and the clock of the VM is more than 2 seconds off, it waits 20 seconds for Lima to fix it. If the clock is still off, ColimaBar sets it to the time of the Mac. If ColimaBar cannot set the clock, it sends a notification with a **Restart** button.
5. If Docker answers, ColimaBar waits 15 seconds for the network. Then it checks the published ports of the VM. If a port answers in the VM but not on the Mac, it checks again after 5 seconds. If the port still fails, ColimaBar sends a notification with a **Restart** button.

The **Restart** button restarts only a profile that still exists, has no running action and has a running VM. Else ColimaBar sends a short notice and does nothing. The check never starts a VM. Auto-stop does not count the sleep time. See [Auto-stop](auto-stop.md#when-the-mac-sleeps).

## When the network changes

ColimaBar watches the DNS setup of the Mac (the system network configuration). It needs no permission. A VPN that connects, or a move to another network, changes it. ColimaBar then waits 10 seconds for the change to end. After that, for each running profile with no running action, it looks up `registry-1.docker.io` in the VM and on the Mac.

- If the VM resolves the name, nothing happens.
- If neither resolves it, the network is down. ColimaBar does nothing.
- If only the VM fails, ColimaBar looks up again after 20 seconds. If it fails again, ColimaBar sends a notification with a **Restart** button, and the Containers tab shows a notice.

With empty `network.dns`, the VM asks the Mac, so it follows the VPN. A restart fixes a VM that lost this. With servers in `network.dns`, the VM asks only those servers. Then the notice has **Use the Mac's DNS**, which removes the servers and restarts the VM. With empty `network.dns`, the notice has **Restart**. In both cases the notice also has **Set DNS servers…**, which opens [VM settings](#vm-settings).

The dashboard also checks the published ports when it opens, if the last check is more than 5 minutes old. It shows the notice and sends no notification. **Check again** in the notice checks the ports and the DNS again. ColimaBar sends each kind of network notification for a profile at most one time in 60 minutes. A good result lets a new failure notify again. The checks run only while the VM runs. They never start it. A debug run does no check by itself and sends no notification.

## Hide the icon

This option is off by default. To turn it on, use one of these controls:

- **Hide menu bar icon while Colima is stopped** on the System tab.
- The same checkbox on the stopped screen. While Colima is stopped, this is the only place in the dashboard that has it.
- **Hide Icon While Colima Is Stopped** in the right-click menu.

When Colima is stopped, the icon leaves the menu bar. ColimaBar continues to run. If auto-start is on, a docker command still starts Colima. When Colima starts, the icon comes back.

The icon stays visible while an action runs, while the dashboard is open and while the VM of a different profile runs.

To show the icon while Colima is stopped, press the dashboard shortcut, open ColimaBar from Spotlight, or open the link `colimabar://open`. The icon and the dashboard appear. If the icon is behind the camera housing or the menu bar is full, the dashboard opens as a window. When you close the dashboard, the icon hides again. The first time the icon hides, ColimaBar sends a notification that tells you this.

## Notifications

ColimaBar sends few notifications. It sends one in these cases:

- A container exits with an error code, gets OOM-killed or becomes unhealthy. The notification has **View logs** and **Restart** buttons.
- A container keeps restarting (see below).
- A container is healthy again, if you turn on the option (see below).
- An action fails.
- Auto-start started a profile after a Colima or Lima upgrade. A click opens the release notes. See [Upgrade warning](#upgrade-warning).
- A Doctor fix of the docker context, the routes or the docker config file ends. The notification gives the result. The Doctor checks send none.
- An in-app update fails, or it installs but cannot restart ColimaBar. A click opens the release page. See [An update does not install](troubleshooting.md#an-update-does-not-install).
- A new version is available. ColimaBar sends one notification for each new version. After an in-app update, the new version sends one more notification with a link to the release notes. See [Update](install.md#update).
- The icon hides for the first time. This occurs only when [Hide the icon](#hide-the-icon) is on.
- ColimaBar refuses a link, or a link is not valid. If notifications are off, an alert window shows the text. See [A link does nothing](troubleshooting.md#a-link-does-nothing).
- After the Mac sleeps, Docker does not answer in a running VM, or the clock of the VM is more than 2 seconds off and ColimaBar could not set it. The notification has a **Restart** button. For one profile, ColimaBar sends each kind at most one time in 30 minutes. Exception: after Docker answers again, a new failure sends a new notification. See [When the Mac sleeps](#when-the-mac-sleeps).
- **Return Free Space** ends. The notification gives the size of the disk image before and after. See [Clean up disk space](#clean-up-disk-space).
- The weekly cleanup fails.
- A volume backup or restore ends or fails. The notification has the volume name and the file name, never the path. See [Back up and restore volumes](#back-up-and-restore-volumes).
- A docker compose command fails, or ColimaBar stops it after 15 minutes. The notification gives the exit code, not the output. See [Compose projects](#compose-projects).
- A published port answers in the VM but not on the Mac, or the VM cannot resolve host names while the Mac can. The notification has a **Restart** button. See [When the network changes](#when-the-network-changes).

ColimaBar sends no notification for a normal start or stop. These count as a normal stop and send no crash alert:

- Exit codes 130, 137 and 143 (SIGINT, SIGKILL and SIGTERM).
- Any exit in the 2 minutes after a stop signal (SIGHUP, SIGINT, SIGQUIT, SIGKILL or SIGTERM), and any exit in the 15 seconds after another signal. This includes a stop from a terminal or from Compose.
- Any exit while an action of the selected profile stops the containers (stop, restart, a change of VM settings or disk, or a repair), and in the 30 seconds after it. ColimaBar checks an unhealthy alert from this time again when the time ends.

ColimaBar also ignores testcontainers containers. For one container and one kind of failure, it sends at most one notification each 10 minutes.

A container that keeps restarting sends one alert: **Keeps restarting**. The first error exit sends a crash alert as usual. A second error exit sends none if the first one did. The third exit in 5 minutes sends the **Keeps restarting** alert. After that, the container sends no crash alerts until it runs 10 minutes without an exit, or until it becomes healthy. While a container is in a restart loop, ColimaBar sends no out-of-memory or unhealthy alert in the 5 minutes after its last exit. An out-of-memory alert right before the loop starts (after two exits in 5 minutes) is also silent, because the **Keeps restarting** alert follows. Every exit counts, even exit code 0 or 137. An exit in a stop window or during a VM action does not count.

The unhealthy alert waits up to 3 minutes after a start. If the container is healthy by then, ColimaBar sends nothing.

If ColimaBar shows no unhealthy banner (the project is muted, or the 10-minute limit applies), it shows no **Healthy again** banner either.

To stop the banners of one Compose project, see [Mute a Compose project](#mute-a-compose-project).

To get a notification when a container is healthy again after an unhealthy alert, turn on **Notify when a container is healthy again after an alert** on the System tab. It is off by default. It works only while crash notifications are on.

The Containers tab also lists recent alerts. If notifications are off for ColimaBar, the alerts show only there. To turn them on, click **Enable…**, or open **System Settings > Notifications > ColimaBar** and turn on **Allow Notifications**.

To stop the container alerts, clear **Notify when a container crashes, OOMs or turns unhealthy** on the System tab. Failed actions always send an alert.

### Saved logs

Docker removes a container that `docker run --rm` or `docker compose run --rm` started when it exits. Its logs go with it. Thus **View logs** on its crash alert finds nothing.

To keep these logs, turn on **Keep logs of removed containers that fail** on the System tab. This option is off by default. It works only while the crash alerts are on.

When the option is on, ColimaBar does this:

- When a container starts with auto-remove, ColimaBar reads its log stream. It keeps the newest 500 lines in memory. It never writes them to disk.
- If the container fails, ColimaBar keeps the lines for 5 minutes. A failure is the same as for the crash alert: an exit code other than 0, 130, 137 and 143, or an OOM kill.
- If the container stops normally, ColimaBar drops the lines at once.
- **View logs** on the alert, and the log button in the recent alerts list, open the saved lines. The log window shows **Saved from a removed container**. If the container still exists, the window shows its live logs.

The option has these limits:

- It applies only to containers that start after you turn it on.
- It applies only to the selected profile. When you switch the profile, ColimaBar drops the saved lines.
- Each container keeps at most 500 lines and 128 KB of raw log data.
- It keeps a buffer for at most 50 containers. In the worst case, this is about 6.4 MB.
- When 50 containers have a buffer, ColimaBar drops the saved lines that expire first. If no failed container has saved lines, a new container gets no buffer.
- ColimaBar parses the saved lines only when you open the log window.
- It ignores testcontainers containers, because they send no alert.

When you turn the option off, ColimaBar closes the log streams and drops all saved lines.

## Container domains

ColimaBar can open a container at a name such as `web.shop.localhost`, not at `localhost:49153`. The feature is off by default.

To turn it on, set **Open containers at .localhost names** on the System tab. A globe button then appears in each container row that has a name. A Compose project also gets a globe menu in its header. The ••• menu of a container lists its names and has **Copy Address**.

### How it works

ColimaBar runs a small web proxy on this Mac only. It listens on `127.0.0.1` and `::1`, never on the network. The proxy reads the `Host` header of a request and sends the request to the published port of the container. Your browser resolves every `.localhost` name to the Mac itself, so no DNS setup is needed.

The proxy never starts the VM. If the VM is stopped, the proxy answers with a page that says so. This stops a web page from starting your VM with a link to a `.localhost` name.

### Names

- A Compose service gets `SERVICE.PROJECT.localhost`, for example `web.shop.localhost`.
- A container that Compose did not start gets `NAME.localhost`.
- If a service has two or more containers, each one gets `SERVICE-N.PROJECT.localhost`, where N is the container number. The lowest number also gets the plain name.
- A subdomain goes to its parent. `api.web.shop.localhost` reaches `web.shop.localhost`.
- ColimaBar turns each name into a valid host name: lower case letters, digits and `-`. It changes `_`, `.` and spaces to `-`. It leaves out other characters. If it leaves out a non-ASCII character, or nothing is left, the container shows a warning. Use the label `dev.colimabar.domains` to set the name then.
- If two containers want one name, the order is: a name from a label, the derived name of a container, the plain name of the lowest replica, then the older container. The container that loses shows a warning icon in its row. Its hint names the owner. The hint also lists any other note about the names of the container.
- A name that is longer than 63 characters is cut. For a replica, ColimaBar cuts the service part, so that `SERVICE-N` still fits.

### The port

A container gets a name only if it publishes a TCP port on this Mac. ColimaBar picks the container port in this order:

1. The label `dev.colimabar.port`. The label `dev.orbstack.http-port` works too. If the container does not publish that port, it gets no name. If the label value is not a port, the container shows a warning, and ColimaBar picks the port with steps 2 and 3. The first of the two labels that is set decides.
2. The first published port from this list: 80, 8080, 3000, 8000, 5000, 5173, 4200, 8888, 443, 8443.
3. The lowest published port that is not a database or another known non-web port. Steps 2 and 3 skip a port that is published at a database port of the Mac, for example container port 80 at host port 5432.

The proxy connects to ports 443 and 8443 with TLS and accepts any certificate. Your browser still uses plain HTTP to the proxy. If a container publishes a port only on `::1` or only on `::`, the proxy connects to `::1`. Else it connects to `127.0.0.1`.

The proxy ignores a label port that is a database or another known non-web port, for example 5432, so that a web page cannot send HTTP to a database. The container shows a warning, and ColimaBar picks the port with steps 2 and 3.

### Labels

Set these labels on a container or in a Compose file:

```yaml
services:
  web:
    labels:
      dev.colimabar.port: "3000"
      dev.colimabar.domains: "admin.shop.localhost@8081, api.localhost"
```

- `dev.colimabar.port` picks the container port. A port that is not a web port is ignored (see above).
- `dev.colimabar.domains` adds names. Write a comma list of names. Add `@PORT` to send a name to another container port. The container must publish that port, else the name gets no route. A port that is not a web port is ignored. Each name must end in `.localhost` and use ASCII letters, digits and `-`. An entry that does not follow these rules, for example a name with `*`, is dropped, and the container shows a warning. The list has at most 16 names.
- `dev.colimabar.domains: "off"` gives the container no name.
- ColimaBar ignores the label `dev.orbstack.domains`.

### Port 80 and 8080

The proxy listens on port 80. If port 80 is busy, or a running container publishes it, the proxy listens on port 8080. The caption under the switch says so, and the links then have `:8080`. At the launch, ColimaBar tries port 80 twice, 1 second apart, before it takes 8080, because the old copy of the app may still be quitting.

If a container starts to publish the port of the proxy, the proxy moves to the other port. It moves at most once in 30 seconds. A move that the limit holds back happens when the 30 seconds end. A container whose port forward failed in the meantime may need a restart.

If the proxy listens on 8080, ColimaBar goes back to port 80 when port 80 is free and no container publishes it. It checks after a change of the containers and after a wake. If no port is free, the caption says so. ColimaBar tries again when the published ports of the containers change, after a wake, and from time to time: 5 seconds, 15 seconds and 60 seconds after the failure, then every 5 minutes. While the proxy listens on 8080, ColimaBar also checks port 80 about every 30 seconds. A link shows only while the proxy listens, so a link never points to another program on port 80.

### Error pages

- **404**: no running container of the selected profile has this name. The page lists the names that work. For a host that does not end in `.localhost`, the page shows no list.
- **502**: the name exists, but nothing answers on the published port. Check the logs of the container.
- **503**: the VM of the profile is not running, or the proxy has too many open connections.
- **502** also shows when a name points to the port of the proxy itself.
- **400**: the request is not valid HTTP/1.1 or HTTP/1.0 (this includes HTTP/2), has no `Host` header or two of them, or has a full address in the request line whose host differs from the `Host` header.
- **408**: the request head did not arrive in 10 seconds.
- **431**: the request head is larger than 64 KB.

### Limits

- The names work on the Mac only. They do not resolve inside containers or in the VM.
- Only the selected profile has names. When you switch the profile, the names change.
- The proxy speaks HTTP/1.1 and splices the bytes, so WebSockets and server-sent events work. It does not speak HTTP/2.
- The proxy reads the `Host` header of the first request on a connection only. Later requests on the same connection go to the same container, whatever their `Host`. A browser opens a new connection for each name, so this is rarely visible. A tool that reuses one connection for several names gets the container of the first name.
- The proxy has no idle timeout after the request head. An open connection stays until one side closes it.
- A debug run (screenshots) starts no proxy.
- Other users of this Mac can reach the proxy on the loopback address, as they can reach a published port.

## Profiles

Each Colima profile is a separate VM with its own containers, images and settings. The profile menu in the header shows the selected profile. Click it to see these items:

- **Show**: all profiles with their state. Select a profile to show it in the dashboard.
- **Start** and **Stop**: start or stop the VM of any profile, also the selected one. Each submenu lists only the profiles that it can act on now. If no profile qualifies, the menu leaves out that submenu.
- **New Profile…**: create a profile. See [Create a profile](#create-a-profile).
- **Delete Profile**: delete a profile with all its data. See [Delete a profile](#delete-a-profile).

While an action runs for a profile, the menu shows it next to the profile name, for example "work · starting…".

The dashboard and its actions apply to the selected profile. The ColimaBar socket follows the selected profile. Each docker profile also has its own socket and docker context, for example `colimabar-work`. See [Profile sockets](auto-start.md#profile-sockets). Auto-stop checks each running profile. See [Auto-stop](auto-stop.md).

If the selected profile no longer exists, ColimaBar switches to `default`.

### Create a profile

1. In the profile menu, choose **New Profile…**.
2. Type a name. Use lowercase letters, digits and single hyphens, up to 30 characters. Start and end with a letter or a digit. You cannot use `default`, `colima` or a name that starts with `colima-`. Colima maps `colima` to `default` and removes the `colima-` prefix.
3. Select the CPU, memory, disk and runtime. The form starts with the values of the selected profile. The runtime is docker by default. Only a docker profile gets auto-start, auto-stop, a profile socket and a docker context.
4. Click **Create**.

The form offers whole GB, so a profile with 2.5 GB starts the form at 2 GB. ColimaBar runs `colima start --profile NAME --cpu CPU --memory MEMORY --disk DISK --runtime RUNTIME`. The first start of a new profile can take some minutes. The dashboard keeps showing the selected profile.

### Delete a profile

> [!WARNING]
> Delete removes the VM of the profile, its disk and its folder with `colima.yaml`. All containers, images, volumes and build cache of the profile are lost. You cannot undo this.

1. If the profile is the selected profile and its VM runs, stop it first. The menu shows "(stop it first)" for it.
   While an action runs for a profile, **Delete Profile** does not show it. If an action starts while the confirmation is open, ColimaBar refuses the delete. Wait until the action ends, then try again.
2. In the profile menu, choose **Delete Profile**, then the profile. If an action runs for each profile, the menu leaves out **Delete Profile**.
3. Read the warning. Type the profile name. Then click **Delete Profile**.
4. Colima asks one more time. Click **OK**.

ColimaBar runs `colima delete --profile NAME --data --force`. Then it removes the socket of the profile and its `colimabar-NAME` context. If you deleted the selected profile, ColimaBar switches to `default`.

You can delete a different profile while its VM runs. Colima stops it first.

You can also delete `default`. The warning then tells you that a plain `colima start` creates it again with an empty disk. If you delete the selected `default` profile, ColimaBar switches to a different profile, if you have one.

## Command line

The `colimabar` command works in Terminal and in scripts. It is a part of the app, so it always has the version of ColimaBar. Homebrew links it. The installer links it into `~/.local/bin` or `~/bin`. For other installs, see [Use the command in your PATH](install.md#use-the-command-in-your-path).

```sh
colimabar status
colimabar start --profile work
colimabar doctor --json
```

| Command | What it does |
|---|---|
| `colimabar status` | Shows the profile, the VM, the action that runs, auto-start, auto-stop, the socket, the docker context and the app. |
| `colimabar start` | Starts the VM. It returns when Docker is ready. |
| `colimabar stop` | Stops the VM. |
| `colimabar restart` | Stops and starts the VM. It returns when Docker is ready. |
| `colimabar open` | Opens the dashboard. It starts ColimaBar if it does not run. |
| `colimabar doctor` | Runs the [Doctor](#doctor) checks and prints the report. |
| `colimabar diagnostics [PATH]` | Writes the [diagnostics file](#save-diagnostics-and-report-an-issue). `PATH` is a file or a folder. The default is the current folder. The command never overwrites a file. It prints the path of the file. Read the file before you share it. |
| `colimabar version` | Shows the version. |
| `colimabar help` | Shows the commands. |

`status`, `start`, `stop`, `restart`, `doctor` and `diagnostics` take `--profile NAME` (or `-p NAME`). Without it, the command uses the profile that ColimaBar shows. `status` and `doctor` take `--json`.

Rules:

- `status`, `doctor` and `diagnostics` never start the VM. ColimaBar does not need to run. Without ColimaBar, `status` cannot tell when auto-stop stops the VM.
- `start`, `stop` and `restart` use the same script as the app. They ask no question, and they do not show the [upgrade warning](#upgrade-warning). They never create a VM. If the profile is not in `colima list`, the command fails. This is true for every profile but `default`.
- If another action of the profile runs, the command waits until it ends, for 15 minutes at most. `start` on a running VM and `stop` on a stopped VM do nothing and exit with 0.
- The command uses the `COLIMA_HOME` of your shell, as `colima` does.
- The output has no names or counts of containers, images, volumes or networks.

Exit codes:

| Code | Meaning |
|---|---|
| 0 | Done. For `doctor`: no problem. A warning is not a problem. |
| 1 | Failed, or Doctor found a problem. Also: the profile is missing, Colima is not installed, or Docker is not ready after a start. |
| 2 | Usage error. |
| 3 | Not done: another VM action holds the lock of the profile. |
| 130 | You stopped the command with Control-C. SIGTERM gives 143. |

For `start`, `stop` and `restart`, the log of the script is `~/.cache/colima-bar/ctl.log`. If a command fails, run `colimabar doctor`.

### JSON

`status --json` and `doctor --json` write JSON with the key `schemaVersion` (now 1). Every key is always there. A key has the value `null` when it has no value. A new key does not change the version. If a key is renamed or removed, or its type changes, the version goes up. The text output can change at any time, so scripts must read the JSON.

`status --json` has these keys:

- `version`, `profile`, `selectedInApp`
- `vm`: `state`, `colimaStatus`, `action`, `runtime`, `arch`, `cpus`, `memoryGiB`, `diskGiB`. `state` is `running`, `stopped`, `broken`, `missing`, `notInstalled` or `unknown`.
- `autoStart`
- `autoStop`: `enabled`, `idleMinutes`, `stopsAt` (a date in UTC, or `null`), `minutesLeft`. The times come from ColimaBar, so they are `null` while it does not run.
- `socket`: `path` and `kind`. `kind` is `proxy` (the proxy of ColimaBar), `link` (a link to the socket of Colima), `stale`, `missing` or `other`. The path is the stable socket if ColimaBar shows the profile, else the socket of the profile.
- `dockerContext`
- `app`: `running` and `version`

`status` exits with 0 if Colima lists the profile, and with 1 if it does not.

`doctor --json` has `schemaVersion`, `version`, `profile`, `problems`, `warnings` and `checks`. Each check has `id`, `title`, `status` (`ok`, `warning`, `problem` or `skipped`), `detail` and `fix`. `fix` is the name of the fix that the Doctor page offers (for example `useColimabar`), or `null`. The command makes no fix.

Examples:

- A shell prompt (starship): `[custom.colima]` with `command = "colimabar status --json | jq -r .vm.state"`, `when = "command -v colimabar"` and `shell = ["bash", "--noprofile", "--norc"]`. Starship has no `interval` for a custom module. It runs the command at each prompt, and it stops the command after `command_timeout` (500 ms by default). The call takes about 0.2 s. If the prompt shows no state, raise `command_timeout`.
- A script that waits for Docker: `colimabar start && docker ps`.
- A check in a script: `colimabar doctor --json | jq -e '.problems == 0'`.
- Raycast: make a Script Command that runs `colimabar status`. A Script Command has a short `PATH`, so use the full path, for example `/opt/homebrew/bin/colimabar` or `/Applications/ColimaBar.app/Contents/Resources/bin/colimabar`. Or use the [links](#links-url-scheme).

## Links (URL scheme)

Apps, scripts and web pages can open `colimabar://` links. A link can open the dashboard, or start, stop or restart a VM.

| Link | Action |
|---|---|
| `colimabar://open` | Open the dashboard. |
| `colimabar://doctor` | Open the dashboard on the Doctor page. |
| `colimabar://start` | Start the VM. |
| `colimabar://stop` | Stop the VM. |
| `colimabar://restart` | Restart the VM. |

`start`, `stop` and `restart` take one parameter: `profile=NAME`. Example: `colimabar://start?profile=work`. Without it, a link uses the selected profile. No other parameter works.

Rules:

- The scheme and the route are not case sensitive. The profile name is.
- A link never creates a VM. If the profile is not in `colima list`, ColimaBar sends a notification and does nothing. This is also true for `default`.
- ColimaBar does nothing if the VM already has the state that the link wants. For example, `start` on a running VM.
- ColimaBar refuses a link while the profile has a running action, while Colima is not installed, while ColimaBar cannot read the profiles, and while ColimaBar restarts for an update. It sends one notification. If notifications are off for ColimaBar, an alert window shows the text.
- `restart` on a stopped VM does nothing and sends a notification. Use `start`.
- ColimaBar asks before a link starts, stops or restarts a VM. To stop the question, tick **Do not ask again for links**, or turn off **Ask before a link starts, stops or restarts Colima** on the System tab. The setting is not in the settings file, because a file must not turn off a safety question.
- Links that open the dashboard or Doctor never ask.
- A link never gives data back to the caller, and never saves a file.
- A debug run ignores all links.

Examples:

- Terminal: `open -g 'colimabar://start?profile=work'`
- Raycast: make a Quicklink with the link `colimabar://stop`.
- Alfred: make a Custom Search with the link `colimabar://start?profile={query}`.
- Shortcuts: use the action **Open URLs** with the link.

macOS learns the scheme when ColimaBar runs from an Applications folder. If a link does nothing, see [A link does nothing](troubleshooting.md#a-link-does-nothing).

## The login item

The first time you open ColimaBar from an Applications folder, it turns on the login item. ColimaBar then starts when you log in. If it crashes, it starts again immediately. Only one copy runs at a time.

To turn the login item off or on, use **Launch at Login** in the right-click menu or **Launch ColimaBar at login** on the System tab.
