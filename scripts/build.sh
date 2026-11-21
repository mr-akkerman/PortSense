#!/bin/zsh
# Development build: compiles PortSense.app, signs it ad hoc and installs it to ~/Applications.
# Launch at login is tied to that path, so the app should always run from there.
set -e
cd "${0:A:h}/.."

APP=build/dev/PortSense.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

swiftc -O -parse-as-library -o "$APP/Contents/MacOS/PortSense" Sources/*.swift

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>PortSense</string>
  <key>CFBundleIdentifier</key><string>local.portsense</string>
  <key>CFBundleExecutable</key><string>PortSense</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>dev</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"

DEST="$HOME/Applications/PortSense.app"
mkdir -p "$HOME/Applications"
pkill -x PortSense || true
rm -rf "$DEST"
ditto "$APP" "$DEST"
echo "Installed: $DEST"
echo "Run: open \"$DEST\""
