# Roadmap

[Docs index](README.md)

These features are planned. Only the next version has a target.

## v0.5.0

- **Keep logs of removed containers that fail.** This option is off by default. When it is on, ColimaBar keeps the logs of auto-removed containers that fail. Auto-removed containers come from `docker run --rm`, `docker compose run --rm` and testcontainers.
- **Export and import settings.** Save the ColimaBar settings to a file, and load them on a different Mac.
- **Install with Homebrew.** Run `brew install --cask imohitkr/tap/colima-bar`, and update with `brew upgrade`.

## Later

- A kubectl context and namespace switcher.
- A global hotkey.
- A docker context switcher for remote daemons.

To suggest a feature, open a [feature request](https://github.com/imohitkr/colima-bar/issues/new?template=feature_request.yml).
