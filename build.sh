#!/bin/bash
# Builds GearVRMouse.app (menu-bar agent) into ./build
set -euo pipefail
cd "$(dirname "$0")"

APP=build/GearVRMouse.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"

swiftc -O -o "$APP/Contents/MacOS/GearVRMouse" Sources/main.swift

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>local.gearvrmouse</string>
  <key>CFBundleName</key><string>GearVRMouse</string>
  <key>CFBundleExecutable</key><string>GearVRMouse</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>12.0</string>
  <key>LSUIElement</key><true/>
  <key>NSBluetoothAlwaysUsageDescription</key><string>Connects to the Gear VR controller to use it as a mouse.</string>
</dict>
</plist>
PLIST

# Sign with a stable identity so macOS keeps the Accessibility grant across rebuilds
# (ad-hoc signatures change every build). Override with SIGN_ID=..., falls back to ad-hoc.
SIGN_ID="${SIGN_ID:-$(security find-identity -v -p codesigning | grep -m1 "Apple Development" | awk '{print $2}')}"
codesign --force --sign "${SIGN_ID:--}" "$APP"
echo "Built $APP"
