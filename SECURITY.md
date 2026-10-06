# Security policy

## Supported versions

Only the [latest release](https://github.com/imohitkr/colima-bar/releases/latest) gets security fixes. If you use an older version, update before you report a problem.

## Report a vulnerability

Do not open a public issue, discussion or pull request for a vulnerability.

Report it privately through GitHub:

1. Open the [Security tab](https://github.com/imohitkr/colima-bar/security) of this repository.
2. Click **Report a vulnerability**.
3. Fill in the form and submit it.

Include this information:

- The ColimaBar version and the macOS version.
- The output of `colima version`.
- What an attacker can do, and what access the attacker needs first.
- Steps to reproduce the problem, or a proof of concept.
- Relevant lines from `~/.cache/colima-bar/ctl.log`. Remove secrets before you send them.

## What to expect

- The maintainer acknowledges the report within one week.
- This is a volunteer project. There is no fixed time for a fix.
- The maintainer keeps you informed and tells you before the fix is public.
- If you agree, the security advisory credits you for the report.

## Scope

These notes describe how ColimaBar works. They help you decide if a problem is a vulnerability.

- **The proxy socket.** ColimaBar listens on `~/.cache/colima-bar/docker.sock`. The socket has mode `0600`. Its directory has mode `0700`. Only your macOS user can connect. A way for another local user to connect is a vulnerability.
- **The docker socket.** Access to the docker socket is equal to root access inside the VM. The proxy gives the same access as the Colima socket, and no more. Any process that runs as your user can already use the Colima socket. Thus this access alone is not a vulnerability.
- **Docker routes.** ColimaBar writes `DOCKER_HOST` with `launchctl setenv`, creates the docker context `colimabar` and sets `docker.host` in `~/.testcontainers.properties`. If ColimaBar changes a route that points to a different daemon, report it.
- **`colima-ctl.sh`.** The app bundle contains this script. It runs VM actions and changes `colima.yaml`. Injection through a profile name or a setting is a vulnerability.
- **Code signing.** ColimaBar has an ad-hoc signature. Apple does not notarize it. The signature only shows that the app is not damaged. It does not show who built it.
- **Download integrity.** GitHub Actions signs a build provenance attestation for each release file. To check a download, run this command in the folder of the file:

  ```sh
  gh attestation verify ColimaBar.zip --repo imohitkr/colima-bar
  ```

  Use `ColimaBar.dmg` in place of `ColimaBar.zip` for the disk image. If a release file fails this check, report it.

Problems in Colima, Lima or Docker are out of scope. Report them to those projects.
