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

Below the Start button, the stopped screen shows the **VM resources** and **Features** of the selected profile, from its `colima.yaml`. You can change them while the VM is stopped. The VM stays stopped, and the new values apply at the next start:

- A preset, **Apply**, the Rosetta switch and the Kubernetes switch save to `colima.yaml` at once, with no dialog.
- A bigger disk asks first. Colima grows the disk at the next start. A disk cannot shrink in place, so a grow is permanent.
- **Shrink…** works as on the System tab. See [Shrink the disk](#shrink-the-disk).

If the profile has no `colima.yaml`, the stopped screen tells you to start the profile once. Colima creates the file at the first start.

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
- Rosetta needs the `vz` VM type. If `vmType` in `colima.yaml` is `qemu`, the Rosetta switch is disabled.
- To change these settings while the VM is stopped, use the [stopped screen](#open-the-dashboard).
- **Disk usage**: the space that images, containers, volumes and the build cache use, with cleanup buttons.
- **Auto-start and auto-stop**: see [Auto-start](auto-start.md) and [Auto-stop](auto-stop.md).
- **Hide menu bar icon while Colima is stopped**: see [Hide the icon](#hide-the-icon).
- **Profiles**: shown only when you have more than one profile.
- **App**: the daily update check, crash notifications, **Keep logs of removed containers that fail**, **Launch ColimaBar at login**, and **Export Settings…** and **Import Settings…**. See [Export and import settings](#export-and-import-settings).

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

**Export Settings…** saves a JSON file. The default name is `ColimaBar-settings.json`. The file holds these settings: auto-start, auto-stop and its time, **Hide menu bar icon while Colima is stopped**, crash notifications, **Keep logs of removed containers that fail**, the daily update check, the selected profile and the login item. It does not hold Colima settings such as CPU or memory, or internal ColimaBar data.

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

While an action runs for a different profile, the menu shows it next to the profile name, for example "work · starting…".

The dashboard and its actions apply to the selected profile. The ColimaBar socket follows the selected profile. Each docker profile also has its own socket and docker context, for example `colimabar-work`. See [Profile sockets](auto-start.md#profile-sockets). Auto-stop checks each running profile. See [Auto-stop](auto-stop.md).

If the selected profile no longer exists, ColimaBar switches to `default`.

### Create a profile

1. In the profile menu, choose **New Profile…**.
2. Type a name. Use lowercase letters, digits and single hyphens, up to 30 characters. Start and end with a letter or a digit. You cannot use `default`, `colima` or a name that starts with `colima-`. Colima maps `colima` to `default` and removes the `colima-` prefix.
3. Select the CPU, memory, disk and runtime. The form starts with the values of the selected profile. The runtime is docker by default. Only a docker profile gets auto-start, auto-stop, a profile socket and a docker context.
4. Click **Create**.

ColimaBar runs `colima start --profile NAME --cpu CPU --memory MEMORY --disk DISK --runtime RUNTIME`. The first start of a new profile can take some minutes. The dashboard keeps showing the selected profile.

### Delete a profile

> [!WARNING]
> Delete removes the VM of the profile, its disk and its folder with `colima.yaml`. All containers, images, volumes and build cache of the profile are lost. You cannot undo this.

1. If the profile is the selected profile and its VM runs, stop it first. The menu shows "(stop it first)" for it.
   While an action runs for a profile, **Delete Profile** does not show it. If an action starts while the confirmation is open, ColimaBar refuses the delete. Wait until the action ends, then try again.
2. In the profile menu, choose **Delete Profile**, then the profile.
3. Read the warning. Type the profile name. Then click **Delete Profile**.
4. Colima asks one more time. Click **OK**.

ColimaBar runs `colima delete --profile NAME --data --force`. Then it removes the socket of the profile and its `colimabar-NAME` context. If you deleted the selected profile, ColimaBar switches to `default`.

You can delete a different profile while its VM runs. Colima stops it first.

You can also delete `default`. The warning then tells you that a plain `colima start` creates it again with an empty disk. If you delete the selected `default` profile, ColimaBar switches to a different profile, if you have one.

## The login item

The first time you open ColimaBar from an Applications folder, it turns on the login item. ColimaBar then starts when you log in. If it crashes, it starts again immediately. Only one copy runs at a time.

To turn the login item off or on, use **Launch at Login** in the right-click menu or **Launch ColimaBar at login** on the System tab.
