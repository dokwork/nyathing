#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [[ -z "${VERSION:-}" ]]; then
  VERSION="$(git describe --tags --exact-match HEAD 2>/dev/null || true)"
  VERSION="${VERSION#v}"
fi
if [[ ! "$VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
  echo "Set VERSION to a SemVer value like 1.2.3, or build from a vX.Y.Z tag." >&2
  exit 1
fi

APP_NAME="Nyathing.app"
APP_DIR="$ROOT/.build/dmg/$APP_NAME"
CONTENTS="$APP_DIR/Contents"
RESOURCES="$CONTENTS/Resources"
STAGE="$ROOT/.build/dmg-staging"
DIST="$ROOT/dist"

swift build -c release
rm -rf "$APP_DIR" "$STAGE" "$DIST"
mkdir -p "$CONTENTS/MacOS" "$RESOURCES" "$STAGE" "$DIST"
cp .build/release/nyathing "$CONTENTS/MacOS/nyathing"
cp -R .build/release/Nyathing_Nyathing.bundle "$RESOURCES/"
ICONSET="$ROOT/.build/dmg/Nyathing.iconset"
swift Scripts/make-app-icon.swift assets/nyathing.png "$ICONSET"
iconutil -c icns "$ICONSET" -o "$RESOURCES/Nyathing.icns"
cat > "$CONTENTS/Info.plist" <<PLIST
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
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>Nyathing</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$VERSION</string>
    <key>LSMinimumSystemVersion</key>
    <string>12.0</string>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP_DIR"
codesign --verify --deep --strict --verbose=2 "$APP_DIR"

cp -R "$APP_DIR" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create \
  -volname "Nyathing" \
  -srcfolder "$STAGE" \
  -ov \
  -format UDZO \
  "$DIST/nyathing-$VERSION.dmg"

echo "Created $DIST/nyathing-$VERSION.dmg"
