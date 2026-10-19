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

- **The ColimaBar socket and the profile sockets.** ColimaBar listens on the ColimaBar socket (`~/.cache/colima-bar/docker.sock`). It also listens on one profile socket for each docker profile (`~/.cache/colima-bar/profiles/PROFILE.sock`). Each socket has mode `0600`. Each socket folder has mode `0700`. Only your macOS user can connect. A way for another local user to connect is a vulnerability.
- **The `colimabar` command.** It runs as your user. `status`, `doctor` and `diagnostics` only read, and `diagnostics` never overwrites a file. `--profile` must pass `ProfileName.isValid` and reaches `colima-ctl.sh` only through the environment. The app writes `~/.cache/colima-bar/app-status.json` with mode `0600`. A way to make the command change a setting, create a VM, or run something other than `colima-ctl.sh` is a vulnerability.
- **Docker daemon access.** Access to a socket of the Docker daemon is equal to root access inside the VM. The ColimaBar socket and each profile socket give the same access as the Colima socket of their profile, and no more. Any process that runs as your user can already use the Colima socket. Thus this access alone is not a vulnerability.
- **Docker routes.** ColimaBar sets these routes:
  - `DOCKER_HOST` with `launchctl setenv`.
  - `TESTCONTAINERS_DOCKER_SOCKET_OVERRIDE=/var/run/docker.sock` with `launchctl setenv`. All apps that you open from the Dock or Finder get it.
  - The docker context `colimabar`, and one docker context `colimabar-PROFILE` for each profile socket. ColimaBar changes only the `colimabar-PROFILE` contexts whose description starts with "ColimaBar".
  - `docker.host` in `~/.testcontainers.properties`.
  - The optional `/var/run/docker.sock` symlink, only after you click **Link (admin)**.

  If ColimaBar changes a route that points to a different daemon, report it.
- **`colima-ctl.sh`.** The app bundle contains this script. It runs VM actions and changes `colima.yaml`. Injection through a profile name or a setting is a vulnerability.
- **`colimabar://` links.** Any app or web page can open a link. A link can only open the dashboard or Doctor, or start, stop or restart an existing VM. It never returns data, writes a file or opens a panel. Its only parameter is a profile name that must pass `ProfileName.isValid` and be in `colima list`. While **Ask before a link starts, stops or restarts Colima** is on, ColimaBar asks first. The setting is not in the settings file. A link that runs a command, reads data, creates a VM, or skips the question while the setting is on is a vulnerability.
- **Import Settings…** reads a JSON file that you choose. A setting from such a file that changes behavior beyond its documented values is a vulnerability.
- **Code signing.** ColimaBar has an ad-hoc signature. Apple does not notarize it. The signature only shows that the app is not damaged. It does not show who built it.
- **Download integrity.** GitHub Actions signs a build provenance attestation for each release file. To check a download, follow [Verify a download](docs/install.md#verify-a-download). If a release file fails this check, report it.
- **In-app update.** After you confirm, ColimaBar downloads `ColimaBar.zip` of the exact release tag from github.com (it never uses `latest` or a URL from the API). It follows redirects only to https hosts of GitHub (`github.com`, `release-assets.githubusercontent.com`, `objects.githubusercontent.com`). It accepts only an immutable release, and it compares the size and the SHA-256 digest of the file with the values of the GitHub API. If `gh` 2.68 or later is installed and logged in, it also runs `gh attestation verify` with the flags of the installer. The dialog says if `gh` cannot run the check. Only then does the update go on with the digest check. If the dialog promised the check and `gh` cannot run it later, the update stops. It unpacks the zip into a private folder, and accepts only one entry, `ColimaBar.app`, with a valid signature, the code identifier `com.imohitkr.ColimaBar`, the version of the release and a newer version than the running one. It replaces the bundle by rename only, and restarts. The trust rests on TLS and GitHub. The digest catches damage, a cut-off download and a changed copy on the CDN. It does not catch a hijacked GitHub account or a changed CI workflow. Immutable releases keep the files of a tag. The attestation (when `gh` runs) shows that `ci.yml` of this repository built the file from the tag on a GitHub-hosted runner. The ad-hoc signature shows integrity only. Homebrew is stronger: the cask holds the SHA-256 in a separate repository, and the tap checks the attestation. A way to make ColimaBar install a file that fails one of these checks is a vulnerability. A test build with the update test hook is not a release: report a release binary that contains the hook (the string `COLIMABAR_UPDATE_BASE`).

Problems in Colima, Lima or Docker are out of scope. Report them to those projects.
