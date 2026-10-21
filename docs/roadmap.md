# Roadmap

[Docs index](README.md)

These milestones are planned next. Each milestone gets its own release. Features that need an extra tool, such as kubectl, mkcert, Trivy or Grype, are off by default and appear only when the tool is installed.

## Housekeeping (0.13.0)

- **Cleanup advisor**: see the largest images, unused volumes, build cache, stopped containers and container logs, and remove them. Give free disk space back to the Mac (fstrim). Optionally prune dangling images and build cache once a week.
- **Better container alerts**: one notification for a container that keeps restarting, no alert during a planned restart, mute a Compose project, and an optional notification when a container becomes healthy again.

## Container domains (0.14.0)

- Open containers at names like `web.shop.colima.local`, with HTTPS from a local certificate authority. ColimaBar asks for an administrator password once to add the resolver, and it can remove everything again.

## VM recreate (0.15.0)

- Change the VM type and the mount type in the app. Colima fixes them when it creates the VM, so ColimaBar backs up the volumes (and optionally the images), recreates the VM and restores them.

## Images and contexts (0.16.0)

- **Image update check**: find containers whose image tag has a newer version in the registry, and pull it. This contacts registries, so it is off by default.
- **Context switchers**: switch the docker context, and the kubectl context and namespace.

## Integrations (0.17.0)

- **Shortcuts actions** to start, stop and restart the VM and to read its status.
- **Image scan**: scan an image for known vulnerabilities with Trivy or Grype, when one is installed.

## Later

These features have no target version and no fixed order.

- A build history view.
- VM snapshots.

To suggest a feature, open a [feature request](https://github.com/imohitkr/colima-bar/issues/new?template=feature_request.yml).
