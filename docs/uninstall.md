# Uninstall ColimaBar

[Docs index](README.md)

This page tells you how to remove ColimaBar, and what stays on your Mac.

## Use the menu item

1. Right-click the menu bar icon. If the icon is hidden, open ColimaBar from Spotlight first.
2. Choose **Uninstall ColimaBar…**.
3. Click **Uninstall** to confirm.

ColimaBar runs its uninstall script in iTerm, or in Terminal when iTerm is not installed. The script asks for your password only to remove the `/var/run/docker.sock` link.

## Run the script manually

Use these steps if your version of ColimaBar does not have the menu item. The app contains the uninstall script. Run it in Terminal:

```sh
/Applications/ColimaBar.app/Contents/Resources/uninstall.sh
```

If you installed ColimaBar in `~/Applications`, use this path:

```sh
~/Applications/ColimaBar.app/Contents/Resources/uninstall.sh
```

From a clone of the repository, run `scripts/uninstall.sh`. It does the same steps.

## What the script removes

The script does these steps:

1. It quits ColimaBar and removes the login item. If ColimaBar does not quit, the script stops and asks you to quit ColimaBar from its menu. Then run the script again.
2. If the current docker context is `colimabar` or a `colimabar-PROFILE` context, it switches to the `colima` context. If there is no `colima` context, it switches to `default`. Then it removes the `colimabar` context and every `colimabar-PROFILE` context.
3. It clears the launchd `DOCKER_HOST` and the testcontainers `docker.host` that ColimaBar set. It also clears the launchd `TESTCONTAINERS_DOCKER_SOCKET_OVERRIDE`.
4. It removes the `/var/run/docker.sock` symlink if it points to the ColimaBar socket. This step asks for your password.
5. It deletes the app, the ColimaBar cache (`~/.cache/colima-bar`) and the ColimaBar settings.
6. It creates `~/.cache/colima-bar/docker.sock` again, as a symlink to the Colima socket of the `default` profile.
7. It creates each profile socket in `~/.cache/colima-bar/profiles` again, as a symlink to the Colima socket of its profile.

## What stays

- Colima, your VMs, containers, images and volumes.
- The ColimaBar socket path, as a symlink to the Colima socket. Thus a `DOCKER_HOST` line in your `~/.zshrc` continues to work. You can remove that line or keep it.
- The profile socket paths, as symlinks to the Colima socket of each profile. Thus a project that sets `DOCKER_HOST` to a profile socket continues to work. The script links these paths instead of removing them for this reason. To remove them, delete `~/.cache/colima-bar`.
