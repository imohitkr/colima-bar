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

Left-click the menu bar icon to open the dashboard. To keep it open in a resizable window, click the window button in the footer, or choose **Open Dashboard Window** in the right-click menu.

The tabs (Containers, Images, Volumes and System) and the live tiles show only while Colima runs. If Colima is stopped, the dashboard shows the stopped screen. It has a **Start Colima** button and the **Hide menu bar icon while Colima is stopped** checkbox. If Colima is not installed, the dashboard shows the command to install it.

Below the **Start Colima** button and the checkbox, the stopped screen shows the **VM resources** and **Features** of the selected profile, from its `colima.yaml`. You can change them while the VM is stopped:

- A preset, **Apply**, the Rosetta switch and the Kubernetes switch save to `colima.yaml` at once, with no dialog. The VM stays stopped, and the new values apply at the next start.
- Colima reads the memory as GiB, and it can be a decimal number such as `memory: 2.5`. If the memory is not one of the choices, the memory picker shows it as an extra choice, for example **2.5 GB**. A change of the CPU only keeps that memory.
- A bigger disk asks first. Colima grows the disk at the next start. A disk cannot shrink in place, so a grow is permanent.
- **Shrink…** deletes all Docker data. It starts the VM once to create the new disk, then stops it again. See [Shrink the disk](#shrink-the-disk).

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
- A running container has logs, shell, restart and stop buttons. **Remove…** is in its ••• menu.
- A stopped container has logs, start and remove buttons.
- The shell opens in iTerm, or in Terminal when iTerm is not installed.
- The ••• menu copies the name, ID, image or an exec command. It also opens ports. **Logs in Terminal** follows the logs in iTerm, or in Terminal when iTerm is not installed.
- You can filter the list and show running containers only.
- **Stop all** stops all running containers. ColimaBar asks first.

### Log viewer

Each container gets a live log window. It has search, follow, timestamps, a stderr filter and copy. The window stays open when the container restarts.

If Docker removed the container, the window shows the lines that ColimaBar saved, if any. See [Saved logs](#saved-logs).

### Images and Volumes tabs

These tabs show sizes and the items that containers use. You can pull the latest version of an image tag that you already have. You can also remove and prune images, and remove unused volumes. ColimaBar asks before it deletes volume data.

### System tab

- **VM resources**: Light, Standard and Heavy presets, or your own CPU and memory values. **Apply** restarts the VM.
- **Features**: Rosetta, Kubernetes (k3s) and the disk size. A change restarts the VM, and ColimaBar asks first. A disk grows in place and keeps your data. To make it smaller, use **Shrink…**. See [Shrink the disk](#shrink-the-disk).
- Rosetta needs the `vz` VM type. If `vmType` in `colima.yaml` is not `vz`, the Rosetta switch is disabled, unless Rosetta is on. A missing `vmType` counts as `vz`.
- To change these settings while the VM is stopped, use the [stopped screen](#open-the-dashboard).
- **Disk usage**: the space that images, containers, volumes and the build cache use, with cleanup buttons.
- **Auto-start and auto-stop**: see [Auto-start](auto-start.md) and [Auto-stop](auto-stop.md). **Stop sooner on battery or in Low Power Mode** shortens the idle time. See [On battery and in Low Power Mode](auto-stop.md#on-battery-and-in-low-power-mode).
- **Hide menu bar icon while Colima is stopped**: see [Hide the icon](#hide-the-icon).
- **Doctor**: the summary of the last Doctor run, and the **Open Doctor** button. See [Doctor](#doctor).
- **Profiles**: shown only when you have more than one profile.
- **App**: the daily update check, crash notifications, **Keep logs of removed containers that fail**, **Launch ColimaBar at login**, and **Export Settings…** and **Import Settings…**. See [Export and import settings](#export-and-import-settings).

### Doctor

Doctor checks the setup of the selected profile and offers a fix for most findings. Doctor only reads: the checks do not start the VM and do not change anything. Doctor runs when you ask for it. It never runs by itself. The checks never send a notification. **Use colimabar**, **Set routes**, **Use osxkeychain** and **Add folder** send one with the result. **Repair…** sends one only if it fails. **Copy line** sends none.

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

### Shrink the disk

> [!WARNING]
> Shrink deletes all Docker data of the profile: all containers, images, volumes and build cache. If Kubernetes is on, it also deletes the cluster and its data. You cannot undo this. Before you shrink, save the data that you want to keep, for example with `docker save` or a volume backup.

Colima cannot shrink a disk in place. Thus **Shrink…** deletes the VM and its disk, and starts the VM again with an empty, smaller disk. The other VM settings in `colima.yaml` stay: CPU, memory, runtime, architecture, VM type, mount type, Rosetta and Kubernetes.

To shrink the disk:

1. On the System tab or the stopped screen, click **Shrink…** next to the disk size. Select a size: 20, 40, 60 or 80 GB. The menu shows only the sizes that are smaller than the current disk.
2. Read the warning. It shows the data that the disk holds now, from the **Disk usage** section. If the VM is stopped, ColimaBar cannot show this data.
3. Type the profile name. Then click **Delete Data and Shrink**.
4. Colima asks one more time. Click **OK**.

ColimaBar then stops the VM, runs `colima delete --data --force`, puts back `colima.yaml` with the new `disk` value and runs `colima start`. The dashboard shows "Shrinking disk to N GB" until the VM runs again.

If the VM was stopped, Colima must start it once to create the new disk. Thus ColimaBar runs the same steps, and then runs `colima stop`. The dashboard shows "Shrinking disk to N GB" until the VM is stopped again. If this last stop fails, ColimaBar sends a notification. The new disk exists then, and the VM runs.

`colima delete` also removes `colima.yaml`. Thus ColimaBar first saves a copy as `~/.cache/colima-bar/colima.PROFILE.yaml.shrink`. If the shrink fails, the notification names this copy. See [A disk shrink fails](troubleshooting.md#a-disk-shrink-fails).

### Export and import settings

Use these buttons to copy your ColimaBar settings to a different Mac.

**Export Settings…** saves a JSON file. The default name is `ColimaBar-settings.json`. The file holds these settings: auto-start, auto-stop and its time, **Stop sooner on battery or in Low Power Mode**, **Hide menu bar icon while Colima is stopped**, crash notifications, **Keep logs of removed containers that fail**, the daily update check, the selected profile and the login item. It does not hold Colima settings such as CPU or memory, or internal ColimaBar data.

**Import Settings…** reads such a file. ColimaBar does this:

- It rejects a file that is not a ColimaBar settings file.
- It rejects a file with a newer format version. To read it, update ColimaBar.
- It skips a value of the wrong type or out of range. For example, the auto-stop time must be from 1 to 1440 minutes.
- It ignores unknown keys. A setting that is not in the file keeps its current value.
- It skips a profile that does not exist on this Mac. To create it, use **New Profile…** in the profile menu. See [Create a profile](#create-a-profile). Then import again.
- It shows the changes and asks before it applies them. Then it shows the applied and skipped settings.

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

The **Restart** button restarts only a profile that still exists, has no running action and has a running VM. Else ColimaBar sends a short notice and does nothing. The check never starts a VM. Auto-stop does not count the sleep time. See [Auto-stop](auto-stop.md#when-the-mac-sleeps).

## Hide the icon

This option is off by default. To turn it on, use one of these controls:

- **Hide menu bar icon while Colima is stopped** on the System tab.
- The same checkbox on the stopped screen. While Colima is stopped, this is the only place in the dashboard that has it.
- **Hide Icon While Colima Is Stopped** in the right-click menu.

When Colima is stopped, the icon leaves the menu bar. ColimaBar continues to run. If auto-start is on, a docker command still starts Colima. When Colima starts, the icon comes back.

The icon stays visible while an action runs, while the dashboard is open and while the VM of a different profile runs.

To show the icon while Colima is stopped, open ColimaBar from Spotlight. The icon and the dashboard appear. When you close the dashboard, the icon hides again. The first time the icon hides, ColimaBar sends a notification that tells you this.

## Notifications

ColimaBar sends few notifications. It sends one in these cases:

- A container exits with an error code, gets OOM-killed or becomes unhealthy. The notification has **View logs** and **Restart** buttons.
- An action fails.
- Auto-start started a profile after a Colima or Lima upgrade. A click opens the release notes. See [Upgrade warning](#upgrade-warning).
- A Doctor fix of the docker context, the routes or the docker config file ends. The notification gives the result. The Doctor checks send none.
- An in-app update fails, or it installs but cannot restart ColimaBar. A click opens the release page. See [An update does not install](troubleshooting.md#an-update-does-not-install).
- A new version is available. ColimaBar sends one notification for each new version. After an in-app update, the new version sends one more notification with a link to the release notes. See [Update](install.md#update).
- The icon hides for the first time. This occurs only when [Hide the icon](#hide-the-icon) is on.
- After the Mac sleeps, Docker does not answer in a running VM, or the clock of the VM is more than 2 seconds off and ColimaBar could not set it. The notification has a **Restart** button. For one profile, ColimaBar sends each kind at most one time in 30 minutes. Exception: after Docker answers again, a new failure sends a new notification. See [When the Mac sleeps](#when-the-mac-sleeps).

ColimaBar sends no notification for a normal start or stop. Exit codes 130, 137 and 143 (SIGINT, SIGKILL and SIGTERM) count as a normal stop, so they send no crash alert. ColimaBar also ignores testcontainers containers. For one container and one kind of failure, it sends at most one notification each 10 minutes.

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

## The login item

The first time you open ColimaBar from an Applications folder, it turns on the login item. ColimaBar then starts when you log in. If it crashes, it starts again immediately. Only one copy runs at a time.

To turn the login item off or on, use **Launch at Login** in the right-click menu or **Launch ColimaBar at login** on the System tab.
