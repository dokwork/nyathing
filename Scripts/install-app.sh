#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH="/Applications/Nyathing.app"
BUILD_DIR="$ROOT/.build/source-install"
STAGED_APP="$BUILD_DIR/Nyathing.app"

if [[ -e "$APP_PATH" || -L "$APP_PATH" ]]; then
  read -r -p "Replace existing $APP_PATH? [y/N] " answer
  case "$answer" in
    y|Y|yes|Yes|YES) ;;
    *) echo "Installation cancelled."; exit 0 ;;
  esac
fi

cd "$ROOT"
swift build -c release
rm -rf "$BUILD_DIR"
mkdir -p "$STAGED_APP/Contents/MacOS" "$STAGED_APP/Contents/Resources"
cp .build/release/nyathing "$STAGED_APP/Contents/MacOS/nyathing"
cp -R .build/release/Nyathing_Nyathing.bundle "$STAGED_APP/Contents/Resources/"
ICONSET="$BUILD_DIR/Nyathing.iconset"
swift Scripts/make-app-icon.swift assets/nyathing.png "$ICONSET"
iconutil -c icns "$ICONSET" -o "$STAGED_APP/Contents/Resources/Nyathing.icns"
cat > "$STAGED_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>nyathing</string>
    <key>CFBundleIdentifier</key>
    <string>com.nyathing.Nyathing</string>
    <key>CFBundleIconFile</key>
    <string>Nyathing</string>
    <key>CFBundleName</key>
    <string>Nyathing</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>12.0</string>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
PLIST

sudo /bin/rm -rf -- "$APP_PATH"
sudo /usr/bin/ditto "$STAGED_APP" "$APP_PATH"
echo "Installed Nyathing.app in /Applications."
