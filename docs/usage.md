# Use ColimaBar

[Docs index](README.md)

ColimaBar shows the state of your Colima VM and its containers in the menu bar. Move the pointer over any control in the dashboard to see what it does.

## Open the dashboard

Left-click the menu bar icon to open the dashboard. To keep it open in a resizable window, click the window button in the footer, or choose **Open Dashboard Window** in the right-click menu.

If Colima is stopped, the dashboard shows a **Start Colima** button. If Colima is not installed, it shows the command to install it.

## The dashboard

### Header and live usage

The header shows the VM state, its CPUs, memory, disk and architecture, and the start, stop and restart buttons.

The live tiles show the total CPU and memory of all containers as a share of the VM, with 60-second graphs. A third tile counts running, stopped and unhealthy containers.

### Containers tab

- ColimaBar groups containers by Compose project. You can start, stop or restart a full project.
- Each container shows health badges, CPU, memory and `localhost` links for its ports.
- Each container has restart, stop, start, remove, logs and shell buttons. The shell opens in iTerm.
- The ••• menu copies the name, ID, image or an exec command. It also opens ports and follows the logs in iTerm.
- You can filter the list and show running containers only.
- **Stop all** stops all running containers. ColimaBar asks first.

### Log viewer

Each container gets a live log window. It has search, follow, timestamps, a stderr filter and copy. The window stays open when the container restarts.

### Images and Volumes tabs

These tabs show sizes and the items that containers use. You can pull, remove and prune images, and remove unused volumes. ColimaBar asks before it deletes volume data.

### System tab

- **VM resources**: Light, Standard and Heavy presets, or your own CPU and memory values. **Apply** restarts the VM.
- **Features**: Rosetta, Kubernetes (k3s) and disk growth. A disk can grow but cannot shrink.
- **Disk usage**: the space that images, containers, volumes and the build cache use, with cleanup buttons.
- **Auto-start and auto-stop**: see [Auto-start](auto-start.md) and [Auto-stop](auto-stop.md).
- **Hide menu bar icon while Colima is stopped**: see [Hide the icon](#hide-the-icon).
- **Profiles**: shown only when you have more than one profile.
- **App**: the daily update check, crash notifications and **Launch ColimaBar at login**.

### Footer

From left to right, the footer has these controls:

- Open a shell in the VM, in iTerm.
- Copy an `export DOCKER_HOST=…` line for the ColimaBar socket.
- Open `colima.yaml` in your text editor.
- Open the Colima logs in Console.
- The ColimaBar version. Click it to check for a new version. An **Update** button appears next to it when a new version is available.
- Open the dashboard window, refresh and quit.

### Keyboard shortcuts

- ⌘R refreshes the data.
- ⌘F moves the focus to the filter field.

## The right-click menu

Right-click the menu bar icon for these menu items:

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

This option is off by default. To turn it on, select **Hide menu bar icon while Colima is stopped** on the System tab, or **Hide Icon While Colima Is Stopped** in the right-click menu.

When Colima is stopped, the icon leaves the menu bar. ColimaBar continues to run. If auto-start is on, a docker command still starts Colima. When Colima starts, the icon comes back.

The icon stays visible while an action runs, while the dashboard is open and while the VM of a different profile runs.

To show the icon while Colima is stopped, open ColimaBar from Spotlight. The icon and the dashboard appear. When you close the dashboard, the icon hides again. The first time the icon hides, ColimaBar sends a notification that tells you this.

## Notifications

ColimaBar sends a notification only when something fails:

- A container exits with an error code, gets OOM-killed or becomes unhealthy. The notification has **View logs** and **Restart** buttons.
- An action fails.

ColimaBar ignores testcontainers containers. It sends no notification for a normal start or stop. For one container and one kind of failure, it sends at most one notification each 10 minutes.

The Containers tab also lists recent alerts. If notifications are off for ColimaBar, the alerts show only there. To turn them on, click **Enable…**, or open **System Settings > Notifications > ColimaBar** and turn on **Allow Notifications**.

To stop the container alerts, clear **Notify when a container crashes, OOMs or turns unhealthy** on the System tab. Failed actions always send an alert.

ColimaBar also sends one notification for each new version. See [Update](install.md#update).

## Profiles

If you have more than one Colima profile, a profile picker appears in the header. With one profile, the picker stays hidden. To create a profile, run `colima start --profile NAME`.

The dashboard, all actions and auto-start apply to the selected profile. If the selected profile no longer exists, ColimaBar switches to `default`.

## The login item

The first time you open ColimaBar from an Applications folder, it turns on the login item. ColimaBar then starts when you log in. If it crashes, it starts again immediately. Only one copy runs at a time.

To turn the login item off or on, use **Launch at Login** in the right-click menu or **Launch ColimaBar at login** on the System tab.
