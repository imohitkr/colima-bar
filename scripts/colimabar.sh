#!/bin/bash
# The `colimabar` command. build.sh puts it in
# ColimaBar.app/Contents/Resources/bin/colimabar, and Homebrew, install.sh
# and the user link to it. It runs the app binary in command line mode. A
# link to the binary itself does not work: the system finds the bundle
# from the path of the executable, and the app reads its settings from the
# bundle. So the wrapper finds the app through its own links, then starts
# the binary from inside the app.
set -u

# readlink -f follows every link, also a chain and a relative link.
self=$(/usr/bin/readlink -f "$0" 2>/dev/null) || {
  echo "colimabar: cannot find its own path: $0" >&2
  exit 1
}
# .../ColimaBar.app/Contents/Resources/bin/colimabar
app=$(cd "$(dirname "$self")/../../.." 2>/dev/null && pwd -P) || app=""
binary="$app/Contents/MacOS/ColimaBar"
if [ -z "$app" ] || [ ! -x "$binary" ]; then
  echo "colimabar: it must run from inside ColimaBar.app. It found no app around $self" >&2
  exit 1
fi
exec "$binary" --cli "$@"
