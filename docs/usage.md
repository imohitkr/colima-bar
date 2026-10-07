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

## The dashboard

### Header and live usage

The header shows the VM state, its CPUs, memory, disk and architecture, and the start, stop and restart buttons.

The live tiles show the total CPU and memory of all containers as a share of the VM, with 60-second graphs. A third tile counts running, stopped and unhealthy containers.

### Containers tab

- ColimaBar groups containers by Compose project. You can start, stop or restart a full project.
- Each container shows health badges, CPU, memory and `localhost` links for its ports.
- A running container has logs, shell, restart and stop buttons. **Remove…** is in its ••• menu.
- A stopped container has logs, start and remove buttons.
- The shell opens in iTerm, or in Terminal when iTerm is not installed.
- The ••• menu copies the name, ID, image or an exec command. It also opens ports and follows the logs in iTerm, or in Terminal when iTerm is not installed.
- You can filter the list and show running containers only.
- **Stop all** stops all running containers. ColimaBar asks first.

### Log viewer

Each container gets a live log window. It has search, follow, timestamps, a stderr filter and copy. The window stays open when the container restarts.

If Docker removed the container, the window shows the lines that ColimaBar saved, if any. See [Saved logs](#saved-logs).

### Images and Volumes tabs

These tabs show sizes and the items that containers use. You can pull the latest version of an image tag that you already have. You can also remove and prune images, and remove unused volumes. ColimaBar asks before it deletes volume data.

### System tab

- **VM resources**: Light, Standard and Heavy presets, or your own CPU and memory values. **Apply** restarts the VM.
- **Features**: Rosetta, Kubernetes (k3s) and disk growth. A disk can grow but cannot shrink.
- **Disk usage**: the space that images, containers, volumes and the build cache use, with cleanup buttons.
- **Auto-start and auto-stop**: see [Auto-start](auto-start.md) and [Auto-stop](auto-stop.md).
- **Hide menu bar icon while Colima is stopped**: see [Hide the icon](#hide-the-icon).
- **Profiles**: shown only when you have more than one profile.
- **App**: the daily update check, crash notifications, **Keep logs of removed containers that fail** and **Launch ColimaBar at login**.

### Footer

From left to right, the footer has these controls:

- **Shell button**: a shell in the VM, in iTerm, or in Terminal when iTerm is not installed.
- **Copy button**: an `export DOCKER_HOST=…` line for the ColimaBar socket, copied to the clipboard.
- **Config button**: `colima.yaml` in your text editor.
- **Log button**: the Colima logs in Console.
- **Version**: the ColimaBar version. Click it to check for a new version. An **Update** button appears next to it when a new version is available.
- **Window, refresh and quit buttons**.

### Keyboard shortcuts

- ⌘R refreshes the data.
- ⌘F moves the focus to the filter field.

## The right-click menu

Right-click or Control-click the menu bar icon for these menu items:

- **Start Colima**, or **Restart Colima** and **Stop Colima** when the VM runs
- **Open Dashboard Window**
- **Launch at Login**
- **Auto-start Colima on Demand**
- **Hide Icon While Colima Is Stopped**
- **ColimaBar *version*** (shows the version only)
- **Check for Updates…**, or **Download ColimaBar *version*…** when an update is available
- **Uninstall ColimaBar…** (see [Uninstall](uninstall.md))
- **Quit ColimaBar**

When you quit ColimaBar, Colima and your containers continue to run. Auto-start stops until you open ColimaBar again.

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
- A new version is available. ColimaBar sends one notification for each new version. See [Update](install.md#update).
- The icon hides for the first time. This occurs only when [Hide the icon](#hide-the-icon) is on.

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
- It keeps lines for at most 50 containers and 25 MB of text. When the limit is reached, ColimaBar drops the oldest saved lines first. If no lines are saved, a new container gets no buffer.
- It ignores testcontainers containers, because they send no alert.

When you turn the option off, ColimaBar closes the log streams and drops all saved lines.

## Profiles

If you have more than one Colima profile, a profile picker appears in the header. With one profile, the picker stays hidden. To create a profile, run `colima start --profile NAME`.

The dashboard, all actions, auto-start and auto-stop apply to the selected profile only. If the selected profile no longer exists, ColimaBar switches to `default`.

## The login item

The first time you open ColimaBar from an Applications folder, it turns on the login item. ColimaBar then starts when you log in. If it crashes, it starts again immediately. Only one copy runs at a time.

To turn the login item off or on, use **Launch at Login** in the right-click menu or **Launch ColimaBar at login** on the System tab.
