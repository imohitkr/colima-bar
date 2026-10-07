# Auto-start

[Docs index](README.md)

Auto-start is on by default. All docker clients use the ColimaBar socket (`~/.cache/colima-bar/docker.sock`). While Colima is stopped, the first real docker request to this socket starts the VM. The request then continues. A cold `docker run` takes about 15 seconds.

The ColimaBar socket starts the VM of the selected [profile](usage.md#profiles). Each docker profile also has its own socket, which starts that profile. See [Profile sockets](#profile-sockets).

A ping (`/_ping`) does not start the VM. ColimaBar answers it, so idle pollers do not start the VM. ColimaBar can answer a ping only after it reached the Docker daemon one time. Thus on a fresh install, the first ping can start the VM. To learn how the socket works, read [ARCHITECTURE.md](../ARCHITECTURE.md#auto-start-proxy).

To turn auto-start off or on, use **Start Colima when something uses docker** on the System tab, or **Auto-start Colima on Demand** in the right-click menu. The System tab shows only while Colima runs. While Colima is stopped, use the right-click menu.

## Shell setup

The docker CLI needs no shell setup, because it uses the docker context. Add this snippet to your `~/.zshrc` in these cases:

- Your `~/.zshrc` already sets `DOCKER_HOST`. Replace that line with the snippet. Otherwise `docker` bypasses auto-start.
- You use scripts or tools that read only `DOCKER_HOST` and not the docker context.

```sh
if [ -e "$HOME/.cache/colima-bar/docker.sock" ]; then
  export DOCKER_HOST="unix://$HOME/.cache/colima-bar/docker.sock"
else
  export DOCKER_HOST="unix://$HOME/.config/colima/default/docker.sock"
fi
```

The snippet uses the Colima socket if the ColimaBar socket is missing. For a single `export DOCKER_HOST=…` line, click the copy button in the dashboard footer.

## Profile sockets

Each Colima profile with the docker runtime has its own socket and docker context:

| Profile | Socket | Docker context |
|---|---|---|
| `default` | `~/.cache/colima-bar/profiles/default.sock` | `colimabar-default` |
| `work` | `~/.cache/colima-bar/profiles/work.sock` | `colimabar-work` |

A profile socket works like the ColimaBar socket, but it always uses its own profile. It does not follow the profile that you select in the dashboard. A real docker request to the socket of a stopped profile starts that profile, and only that profile. A ping does not start it.

To use one profile from the docker CLI, give its context:

```sh
docker --context colimabar-work ps
```

To use one profile for a project, set `DOCKER_HOST` for that project only, for example in its `.envrc` file:

```sh
export DOCKER_HOST="unix://$HOME/.cache/colima-bar/profiles/work.sock"
```

ColimaBar creates the socket and the context when a profile appears, and removes them when the profile goes away. It changes only the contexts that it created. Their description starts with "ColimaBar". If a context with the name `colimabar-NAME` already exists and ColimaBar did not create it, ColimaBar leaves it alone.

The `colimabar` context and the other [routes](#how-docker-clients-reach-colima) still use the ColimaBar socket. ColimaBar does not change them for the profile sockets.

ColimaBar skips a profile if the socket path would be longer than 99 bytes. A unix socket path holds at most 103 bytes, and ColimaBar needs 4 bytes for a temporary name. With a home folder of normal length, a name of up to about 45 characters fits. ColimaBar writes the skipped name to its log.

A profile with the containerd runtime has no Docker daemon. Thus it gets no socket and no context.

## IDEs

Restart any IDE that was open when ColimaBar ran for the first time. The IDE reads the launchd `DOCKER_HOST` only when it starts.

## The /var/run/docker.sock link

Some tools only look at `/var/run/docker.sock`, for example the Python docker SDK without `DOCKER_HOST`. For these tools, click **Link (admin)** on the System tab. ColimaBar asks for your admin password one time. Then it creates `/var/run/docker.sock` as a symlink to the ColimaBar socket.

ColimaBar does not replace a real socket at that path, for example the socket of Docker Desktop.

## When ColimaBar quits

When ColimaBar quits, the ColimaBar socket becomes a symlink to the Colima socket of the selected profile. Each profile socket becomes a symlink to the Colima socket of its profile. All clients continue to work, but auto-start stops. Colima and your containers continue to run.

You do not need to change the routes back. When ColimaBar starts again, auto-start starts again.

If you turn off auto-start, the ColimaBar socket and the profile sockets also become symlinks to the Colima sockets.

## When auto-start does not start the VM

Auto-start does not start the VM in these cases:

- The profile uses the containerd runtime. This runtime has no Docker daemon.
- The profile is not `default`, and you deleted it. ColimaBar sends the notification "Profile NAME doesn't exist, so it wasn't started."

If the start fails, the docker client gets an error. See [Auto-start fails](troubleshooting.md#auto-start-fails).

## How docker clients reach Colima

ColimaBar sets a route for each kind of docker client. All routes use the ColimaBar socket. The [profile sockets](#profile-sockets) are extra, and only the clients that you point at them use them.

<p align="center">
  <img src="assets/docker-routes.svg" width="900" alt="Each docker client reaches the ColimaBar socket through its own route. While ColimaBar runs, the socket is the proxy. When ColimaBar quits, it is a symlink to the Colima socket.">
</p>

| Client | Route |
|---|---|
| docker CLI | The docker context `colimabar`. The docker CLI uses it when `DOCKER_HOST` is not set. Most GUIs and other tools that read docker contexts also use it. |
| IDEs and Dock apps | `DOCKER_HOST`, set with `launchctl setenv`. Apps that you open from the Dock or Finder get it, for example IDE test runners. |
| testcontainers | `docker.host` in `~/.testcontainers.properties`. |
| Scripts and shells | The [shell snippet](#shell-setup) in your `~/.zshrc`, for tools that read only `DOCKER_HOST`. |
| Tools that use /var/run | An optional symlink. See [The /var/run/docker.sock link](#the-varrundockersock-link). |

ColimaBar sets these routes when it starts. It sets them again each time the VM starts, because `colima start` switches the docker context back to `colima`. The System tab shows a check mark next to each route that is set.

With the launchd `DOCKER_HOST`, ColimaBar also sets `TESTCONTAINERS_DOCKER_SOCKET_OVERRIDE=/var/run/docker.sock` with `launchctl setenv`. testcontainers mounts this path into its Ryuk container, and the path exists inside the VM. This setting applies to all apps that you open from the Dock or Finder.

ColimaBar does not change a route that points to a different daemon, for example a remote docker context or a custom testcontainers `docker.host`.
