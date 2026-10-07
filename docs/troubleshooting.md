# Troubleshooting

[Docs index](README.md)

This page lists the ColimaBar logs, fixes for common problems and the steps to report a bug.

## Logs

| Log | Contents |
|---|---|
| `~/.cache/colima-bar/ctl.log` | The output of VM actions, for example `colima start` and `colima stop`. ColimaBar starts a new file when it passes 1 MB. |
| `~/.config/colima/_lima/colima/ha.stderr.log` | The Lima host agent log of the `default` profile. For a different profile, the folder is `colima-PROFILE`. |
| The macOS unified log | The messages of ColimaBar itself. |

To open the first two logs in Console, click the log button in the dashboard footer.

To show the ColimaBar messages of the last hour, run this command:

```sh
log show --info --last 1h --predicate 'subsystem == "com.imohitkr.ColimaBar"'
```

## An action fails

If a VM action fails, ColimaBar sends a notification. Open `~/.cache/colima-bar/ctl.log` to see the output of Colima.

If the notification says "Colima didn't become ready", open the Lima log from the dashboard footer.

## A disk shrink fails

A disk shrink runs `colima stop`, `colima delete --data` and `colima start`. If a step fails, ColimaBar sends a notification. Open `~/.cache/colima-bar/ctl.log` to see the output of Colima.

`colima delete` removes `colima.yaml`. ColimaBar saves a copy with the new disk size in `~/.cache/colima-bar/colima.PROFILE.yaml.shrink` before it deletes anything. If the delete failed, or `colima start` failed after the delete, do these steps:

1. If `~/.config/colima/PROFILE/colima.yaml` does not exist, copy the saved file to that path.
2. Run `colima start --profile PROFILE`.

The containers, images and volumes are gone after the delete. You cannot get them back.

## Auto-start fails

If auto-start cannot start the VM, the docker client gets HTTP status 503 with this message:

```text
ColimaBar could not start Colima. Check the Colima log or start it from the menu bar.
```

After `colima start` exits, ColimaBar waits up to 60 seconds for the Docker daemon to become ready. Then it stops and sends the notification "Colima didn't become ready. Check the Colima log."

To fix it, do these steps:

1. Open `~/.cache/colima-bar/ctl.log` and the Lima log. Look for the error.
2. Start Colima from the right-click menu, or run `colima start`.
3. Run the docker command again.

Auto-start also does nothing for some profiles. See [When auto-start does not start the VM](auto-start.md#when-auto-start-does-not-start-the-vm).

## docker cannot connect after you quit ColimaBar

When ColimaBar quits, auto-start stops. The ColimaBar socket then points directly to Colima. If the VM is stopped, docker cannot connect.

To fix it, do one of these steps:

- Open ColimaBar again. Auto-start then starts the VM on the next docker command.
- Run `colima start`.

## docker does not start Colima

1. Make sure that ColimaBar runs and that auto-start is on. Look at **Auto-start Colima on Demand** in the right-click menu.
2. Start Colima, then open the System tab. Each route to the ColimaBar socket shows a check mark when it is set. The System tab shows only while Colima runs.
3. In your terminal, run `echo $DOCKER_HOST`. If it shows a different socket, replace that line in your `~/.zshrc` with the [shell snippet](auto-start.md#shell-setup).
4. Run `docker context show`. It must show `colimabar`. ColimaBar does not change a context that points to a different daemon.
5. If an IDE test cannot connect, restart the IDE. An IDE reads the launchd `DOCKER_HOST` only when it starts.

## macOS blocks the first launch

Apple does not notarize ColimaBar. If you use the disk image, follow the [Open Anyway steps](install.md#the-disk-image). As an alternative, use [the installer](install.md#the-installer-recommended). macOS does not block its download.

## ColimaBar does not start when you log in

- ColimaBar turns on the login item only when you open it from an Applications folder. A copy that runs from the disk image or from Downloads does not turn it on.
- Make sure that **Launch at Login** in the right-click menu has a check mark.
- If the System tab shows "Waiting for your approval in System Settings > Login Items", click **Open**. Then turn on ColimaBar in the list.

## The menu bar icon is missing

If **Hide Icon While Colima Is Stopped** is on, the icon hides while Colima is stopped. To show it, open ColimaBar from Spotlight. See [Hide the icon](usage.md#hide-the-icon).

## Report a bug

Open a [bug report](https://github.com/imohitkr/colima-bar/issues/new?template=bug_report.yml). Include this information:

- The macOS version.
- The ColimaBar version. The dashboard footer and the right-click menu show it.
- The output of `colima version`.
- The runtime and the profile, if the profile is not `default`.
- The steps that cause the problem, what you expected and what happened.
- The relevant lines from `~/.cache/colima-bar/ctl.log`. This file contains the output of VM actions.

Remove secrets, tokens and private host names from logs before you post them.

To ask a question, open a [question](https://github.com/imohitkr/colima-bar/issues/new?template=question.yml). To report a security problem, do not open an issue. Follow [SECURITY.md](../SECURITY.md).
