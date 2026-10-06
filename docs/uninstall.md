# Uninstall ColimaBar

[Docs index](README.md)

## Use the menu item

1. Right-click the menu bar icon.
2. Choose **Uninstall ColimaBar…**.
3. Click **Uninstall** to confirm.

ColimaBar opens iTerm, or Terminal if iTerm is not installed, and runs its uninstall script. If the script asks for your password, it is to remove the `/var/run/docker.sock` link.

## Run the script manually

The app contains the uninstall script. Run it in Terminal:

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
2. It switches the docker context back to `colima` and removes the `colimabar` context.
3. It clears the launchd `DOCKER_HOST` and the testcontainers `docker.host` that ColimaBar set.
4. It removes the `/var/run/docker.sock` symlink if it points to ColimaBar. This step asks for your password.
5. It deletes the app, the ColimaBar cache (`~/.cache/colima-bar`) and the ColimaBar settings.
6. It makes the stable socket path a symlink to the Colima socket of the `default` profile.

## What stays

- Colima, your VMs, containers, images and volumes.
- The stable socket path, as a symlink to the Colima socket. Thus a `DOCKER_HOST` line in your `~/.zshrc` continues to work. You can remove that line or keep it.
