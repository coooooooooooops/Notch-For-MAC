#!/bin/bash
# Builds a universal (Apple Silicon + Intel) NOTCH.app and installs it to /Applications.
# Needs Xcode Command Line Tools:  xcode-select --install
set -e
cd "$(dirname "$0")"
APP=NOTCH.app
# The updater passes the release tag as NOTCH_VERSION; a normal build uses the VERSION file.
VERSION="${NOTCH_VERSION:-$(tr -d '[:space:]' < VERSION 2>/dev/null || true)}"
[ -n "$VERSION" ] || VERSION=1.0
rm -rf "$APP" .arm .x86
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -target arm64-apple-macos13.0  main.swift Extras.swift Lab.swift Updater.swift ControlCentre.swift AI.swift Apps.swift Features.swift Weather.swift Notes.swift ClipImages.swift Hotkeys.swift -o .arm
swiftc -O -target x86_64-apple-macos13.0 main.swift Extras.swift Lab.swift Updater.swift ControlCentre.swift AI.swift Apps.swift Features.swift Weather.swift Notes.swift ClipImages.swift Hotkeys.swift -o .x86
lipo -create .arm .x86 -output "$APP/Contents/MacOS/NOTCH"
rm -f .arm .x86

if [ -f icon.png ]; then
  mkdir -p AppIcon.iconset
  for s in 16 32 128 256 512; do
    sips -z $s $s icon.png --out AppIcon.iconset/icon_${s}x${s}.png >/dev/null
    sips -z $((s*2)) $((s*2)) icon.png --out AppIcon.iconset/icon_${s}x${s}@2x.png >/dev/null
  done
  iconutil -c icns AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
  rm -rf AppIcon.iconset
fi

# packed resource file (unpacked and served to a tab from inside the app)
if [ -f ui-cache.dat ]; then
  cp ui-cache.dat "$APP/Contents/Resources/ui-cache.dat"
else
  echo "WARNING: no 'ui-cache.dat' next to build.sh - one tab will show an error."
fi

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>NOTCH</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleIdentifier</key><string>com.coops.notch</string>
<key>CFBundleName</key><string>NOTCH</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>__VERSION__</string>
<key>CFBundleVersion</key><string>__VERSION__</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>NSAppleEventsUsageDescription</key><string>NOTCH reads and controls Music and Spotify playback.</string>
<key>NSDownloadsFolderUsageDescription</key><string>Show download progress in the notch.</string>
<key>NSBluetoothAlwaysUsageDescription</key><string>Connect and disconnect your Bluetooth devices from the notch.</string>
<key>NSCameraUsageDescription</key><string>Camera mirror and photos in the notch.</string>
<key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
<key>NSCalendarsUsageDescription</key><string>Show your events in the notch.</string>
<key>NSCalendarsFullAccessUsageDescription</key><string>Show your events in the notch.</string>
<key>NSRemindersUsageDescription</key><string>Show your reminders in the notch.</string>
<key>NSRemindersFullAccessUsageDescription</key><string>Show your reminders in the notch.</string>
</dict></plist>
EOF

sed -i '' "s/__VERSION__/$VERSION/g" "$APP/Contents/Info.plist"

xattr -cr "$APP" || true
codesign --force --deep --sign - "$APP"
rm -rf dmg NOTCH.dmg && mkdir dmg && cp -R "$APP" dmg/ && ln -s /Applications dmg/Applications
hdiutil create -volname NOTCH -srcfolder dmg -ov -format UDZO NOTCH.dmg >/dev/null && rm -rf dmg
echo "Made NOTCH.dmg (drag-to-install)."

pkill -x NOTCH 2>/dev/null || true
rm -rf "/Applications/$APP"
cp -R "$APP" /Applications/
open "/Applications/$APP"
echo "Installed. Look for the icon in your menu bar (Launch at Login / Quit live there)."
