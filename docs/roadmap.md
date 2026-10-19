# Roadmap

[Docs index](README.md)

These features are planned. They have no target version yet. The milestones are in the order that we plan to build them.

## 1. VM configuration

- Change the VM type and the mount type in the app. Colima fixes them when it creates the VM, so this needs a delete and create flow.
- Detect published ports that stop working and DNS that fails after a VPN change, with a fix.

## 2. Containers

- Inspect a container: environment with secrets hidden, labels, networks, mounts and restart count. Open the Compose project folder, and pull, start or stop the project.
- A debug shell for containers that have no shell, for example distroless images.
- Back up a volume to a file and restore it.

## Later

- A kubectl context and namespace switcher.
- A docker context switcher for remote daemons.

To suggest a feature, open a [feature request](https://github.com/imohitkr/colima-bar/issues/new?template=feature_request.yml).
