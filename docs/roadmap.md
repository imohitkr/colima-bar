# Roadmap

[Docs index](README.md)

These features are planned. They have no target version yet. The milestones are in the order that we plan to build them.

## 1. Automation

- A `colimabar://` URL scheme to start, stop and open the dashboard from Raycast, Alfred or Shortcuts.
- A `colimabar` command for the terminal, for example `colimabar status --json`.
- A global hotkey.

## 2. VM configuration

- Change more Colima settings in the app: DNS, the port forwarder, the VM network address, mounts, the VM type and registry mirrors.
- Detect published ports that stop working and DNS that fails after a VPN change, with a fix.

## 3. Containers

- Inspect a container: environment with secrets hidden, labels, networks, mounts and restart count. Open the Compose project folder, and pull, start or stop the project.
- A debug shell for containers that have no shell, for example distroless images.
- Back up a volume to a file and restore it.

## Later

- A kubectl context and namespace switcher.
- A docker context switcher for remote daemons.

To suggest a feature, open a [feature request](https://github.com/imohitkr/colima-bar/issues/new?template=feature_request.yml).
