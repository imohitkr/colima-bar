# Auto-start

[Docs index](README.md)

Auto-start is on by default. While Colima is stopped, the first real docker request starts the VM. The request then continues. A cold `docker run` takes about 15 seconds.

To turn auto-start off or on, use **Start Colima when something uses docker** on the System tab, or **Auto-start Colima on Demand** in the right-click menu.

## How docker clients reach Colima

All docker clients use one stable socket path: `~/.cache/colima-bar/docker.sock`. When ColimaBar starts, it sets these routes to that path:

<p align="center">
  <img src="assets/docker-routes.svg" width="900" alt="Each docker client reaches the stable socket through its own route. While ColimaBar runs, the socket is the proxy. When ColimaBar quits, it is a symlink to the Colima socket.">
</p>

| Client | Route |
|---|---|
| Terminal `docker` | The docker context `colimabar`. The docker CLI uses it when `DOCKER_HOST` is not set. |
| Other tools that read docker contexts, and most GUIs | The docker context `colimabar`. |
| IDE test runners and apps that you open from the Dock or Finder | `DOCKER_HOST`, set with `launchctl setenv`. |
| testcontainers (Java, Go) | `docker.host` in `~/.testcontainers.properties`. |
| Scripts and shells that read only `DOCKER_HOST` | The [shell snippet](#shell-setup) in your `~/.zshrc`. |
| Tools that only try `/var/run/docker.sock` | An optional symlink. To create it, click **Link (admin)** on the System tab. |

The System tab shows a check mark next to each route that is set.

ColimaBar does not change a route that points to a different daemon, for example a remote docker context or a custom testcontainers `docker.host`.

The stable socket reaches the selected [profile](usage.md#profiles). Auto-start starts the VM of that profile.

## What the socket does

While ColimaBar runs, the stable socket is a proxy:

- If the VM is up, the proxy copies all bytes to and from the Colima socket. Thus attach, exec, builds and log streams work.
- If the VM is down, the proxy answers the docker `/_ping` check itself. Thus idle pollers do not start the VM. The first real request starts Colima. When Docker is ready, the request continues on the same connection.

## When ColimaBar quits

When ColimaBar quits, the stable socket becomes a symlink to the Colima socket. All clients continue to work, but auto-start stops. Colima and your containers continue to run.

You do not need to change the routes back. When ColimaBar starts again, auto-start starts again.

If you turn off auto-start, the stable socket also becomes a symlink to the Colima socket.

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

The snippet uses the Colima socket if the stable path is missing. For a single `export DOCKER_HOST=…` line, click the copy button in the dashboard footer.

## IDEs

Restart any IDE that was open when ColimaBar ran for the first time. The IDE reads the launchd `DOCKER_HOST` only when it starts.

## The /var/run/docker.sock link

Some tools only look at `/var/run/docker.sock`, for example the Python docker SDK without `DOCKER_HOST`. For these tools, click **Link (admin)** on the System tab. ColimaBar asks for your admin password one time. Then it creates `/var/run/docker.sock` as a symlink to the stable socket.

ColimaBar does not replace a real socket at that path, for example the socket of Docker Desktop.
