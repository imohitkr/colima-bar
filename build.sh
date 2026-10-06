#!/bin/bash
# Builds ColimaBar.app with SwiftPM (Command Line Tools are enough, no Xcode).
#   ./build.sh            build into ./build/ColimaBar.app
#   ./build.sh test       run the test suite
#   ./build.sh install    build, then install the app to ~/Applications and
#                         scripts/colima-ctl.sh to ~/.local/bin, and relaunch
set -euo pipefail
cd "$(dirname "$0")"

if [ "${1:-}" = test ]; then
  exec swift test
fi

APP=build/ColimaBar.app
ID=com.imohitkr.ColimaBar
VERSION=$(git describe --tags --always --dirty 2>/dev/null || echo dev)
VERSION=${VERSION#v}

swift build -c release --product ColimaBar
BIN=$(swift build -c release --show-bin-path)/ColimaBar

mkdir -p Resources
[ -f Resources/AppIcon.icns ] || swift scripts/make-icon.swift Resources/AppIcon.icns

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Library/LaunchAgents"
cp "$BIN" "$APP/Contents/MacOS/ColimaBar"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>${ID}</string>
  <key>CFBundleName</key><string>ColimaBar</string>
  <key>CFBundleDisplayName</key><string>ColimaBar</string>
  <key>CFBundleExecutable</key><string>ColimaBar</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
EOF

# Legacy SMAppService agent plist (v0.2.0 and earlier). ColimaBar no longer
# registers it; it stays in the bundle only so SMAppService can find and
# unregister an old registration (LoginItem.migrate).
cat > "$APP/Contents/Library/LaunchAgents/${ID}.agent.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>${ID}.agent</string>
  <key>BundleProgram</key><string>Contents/MacOS/ColimaBar</string>
  <key>RunAtLoad</key><false/>
</dict>
</plist>
EOF

# Ad-hoc signature: required for notifications.
codesign --force --sign - "$APP" >/dev/null
echo "built $APP ($VERSION)"

if [ "${1:-}" = install ]; then
  mkdir -p ~/Applications ~/.local/bin
  install -m 755 scripts/colima-ctl.sh ~/.local/bin/colima-ctl.sh
  osascript -e 'quit app "ColimaBar"' >/dev/null 2>&1 && sleep 1 || true
  rm -rf ~/Applications/ColimaBar.app
  cp -R "$APP" ~/Applications/
  open ~/Applications/ColimaBar.app
  echo "installed ~/Applications/ColimaBar.app and ~/.local/bin/colima-ctl.sh"
fi
