# Roadmap

[Docs index](README.md)

These milestones are planned next. Each milestone gets its own release. Features that need an extra tool, such as kubectl, mkcert, Trivy or Grype, are off by default and appear only when the tool is installed.

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
- mkcert support for container domains. mkcert has a root that is not limited to a few names, so ColimaBar does not sign with it.
- VM snapshots.

To suggest a feature, open a [feature request](https://github.com/imohitkr/colima-bar/issues/new?template=feature_request.yml).
