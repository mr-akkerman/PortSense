#!/bin/zsh
# Release build of PortSense: universal binary, Developer ID signature,
# notarized app, styled DMG, notarized and stapled DMG.
#
# Requirements: a "Developer ID Application" certificate in the keychain and,
# for notarization, a notarytool keychain profile:
#   xcrun notarytool store-credentials <profile> --apple-id <id> --team-id <team>
#
# Usage:  VERSION=1.2 NOTARY_PROFILE=<profile> ./scripts/release.sh
#         NOTARIZE=0 ./scripts/release.sh        # skip notarization
#
# Local overrides (IDENTITY, NOTARY_PROFILE, BUNDLE_ID, COPYRIGHT) can live in
# scripts/local.env, which is not committed.
set -euo pipefail
cd "${0:A:h}/.."
[[ -f scripts/local.env ]] && source scripts/local.env

VERSION=${VERSION:-1.0}
BUILD=${BUILD:-$(date +%Y%m%d%H%M)}
BUNDLE_ID=${BUNDLE_ID:-com.example.portsense}
COPYRIGHT=${COPYRIGHT:-"© $(date +%Y) PortSense contributors"}
NOTARIZE=${NOTARIZE:-1}
NOTARY_PROFILE=${NOTARY_PROFILE:-}
IDENTITY=${IDENTITY:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' | head -1)}
[[ -n "$IDENTITY" ]] || { echo "No Developer ID Application certificate found; set IDENTITY."; exit 1; }
[[ $NOTARIZE == 0 || -n "$NOTARY_PROFILE" ]] || { echo "Set NOTARY_PROFILE or run with NOTARIZE=0."; exit 1; }

OUT=build/release
APP="$OUT/PortSense.app"
DMG="$OUT/PortSense-$VERSION.dmg"
VOL="PortSense"

rm -rf "$OUT"; mkdir -p "$OUT" "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "▸ Building (arm64 + x86_64)"
for arch in arm64 x86_64; do
  swiftc -O -parse-as-library -target $arch-apple-macos14.0 -o "$OUT/PortSense-$arch" Sources/*.swift
done
lipo -create "$OUT/PortSense-arm64" "$OUT/PortSense-x86_64" -output "$APP/Contents/MacOS/PortSense"

echo "▸ Icon"
ICONSET="$OUT/AppIcon.iconset"; mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s assets/icon_1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) assets/icon_1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>PortSense</string>
  <key>CFBundleDisplayName</key><string>PortSense</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>PortSense</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key><array><string>en</string><string>ru</string></array>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSUIElement</key><true/>
  <key>NSHumanReadableCopyright</key><string>$COPYRIGHT</string>
</dict>
</plist>
PLIST

echo "▸ Signing the app (hardened runtime)"
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
codesign --verify --strict --deep "$APP"

notarize() {  # $1 — file to submit (zip or dmg)
  xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait --timeout 30m | tee "$OUT/notary.log"
  grep -q "status: Accepted" "$OUT/notary.log" || {
    id=$(awk '/^  id:/{print $2; exit}' "$OUT/notary.log")
    [[ -n "$id" ]] && xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE"
    echo "✗ Notarization failed"; exit 1; }
}

if [[ $NOTARIZE == 1 ]]; then
  echo "▸ Notarizing the app"
  ditto -c -k --keepParent "$APP" "$OUT/app.zip"
  notarize "$OUT/app.zip"
  xcrun stapler staple "$APP"
fi

echo "▸ DMG"
STAGE="$OUT/dmg"; mkdir -p "$STAGE/.background"
ditto "$APP" "$STAGE/PortSense.app"
ln -s /Applications "$STAGE/Applications"
sips -z 400 660 assets/dmg_background.png --out "$OUT/bg.png" >/dev/null
cp assets/dmg_background.png "$OUT/bg@2x.png"
tiffutil -cathidpicheck "$OUT/bg.png" "$OUT/bg@2x.png" -out "$STAGE/.background/background.tiff" >/dev/null

hdiutil detach "/Volumes/$VOL" -quiet 2>/dev/null || true
hdiutil create -quiet -srcfolder "$STAGE" -volname "$VOL" -fs HFS+ -format UDRW -ov "$OUT/rw.dmg"
DEV=$(hdiutil attach -readwrite -noverify -noautoopen "$OUT/rw.dmg" | awk '/Apple_HFS/{print $1}')
cp "$APP/Contents/Resources/AppIcon.icns" "/Volumes/$VOL/.VolumeIcon.icns"
SetFile -a C "/Volumes/$VOL" 2>/dev/null || true

osascript <<OSA
tell application "Finder"
  tell disk "$VOL"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 860, 548}
    set opts to the icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 128
    set text size of opts to 13
    set background picture of opts to file ".background:background.tiff"
    set position of item "PortSense.app" of container window to {180, 200}
    set position of item "Applications" of container window to {480, 200}
    update without registering applications
    delay 1
    close
  end tell
end tell
OSA
sync
hdiutil detach "$DEV" -quiet
hdiutil convert "$OUT/rw.dmg" -quiet -format UDZO -imagekey zlib-level=9 -o "$DMG"
rm -f "$OUT/rw.dmg"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"

if [[ $NOTARIZE == 1 ]]; then
  echo "▸ Notarizing the DMG"
  notarize "$DMG"
  xcrun stapler staple "$DMG"
  spctl -a -t open --context context:primary-signature -vv "$DMG"
fi

echo "✓ Done: ${DMG:A}"
