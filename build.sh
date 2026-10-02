#!/bin/bash
# Builds ColimaBar.app with swiftc (Command Line Tools are enough, no Xcode).
#   ./build.sh            build into ./build/ColimaBar.app
#   ./build.sh install    also install the app to ~/Applications and
#                         scripts/colima-ctl.sh to ~/.local/bin, then relaunch
set -euo pipefail
cd "$(dirname "$0")"

APP=build/ColimaBar.app
BIN="$APP/Contents/MacOS/ColimaBar"
VERSION=$(git describe --tags --always 2>/dev/null || echo dev)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -parse-as-library -swift-version 5 \
  -target arm64-apple-macos14.0 \
  -o "$BIN" Sources/ColimaBar/*.swift

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.imohitkr.ColimaBar</string>
  <key>CFBundleName</key><string>ColimaBar</string>
  <key>CFBundleDisplayName</key><string>ColimaBar</string>
  <key>CFBundleExecutable</key><string>ColimaBar</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
EOF

# Ad-hoc signature: required for SMAppService (launch at login) to accept it.
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
