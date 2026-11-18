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

BUILD_DIR="$ROOT/.build/pkg"
APP_DIR="$BUILD_DIR/Nyathing.app"
CONTENTS="$APP_DIR/Contents"
RESOURCES="$CONTENTS/Resources"
PAYLOAD="$BUILD_DIR/payload"
PACKAGE_DIR="$BUILD_DIR/package-scripts"
OUTPUT_DIR="$ROOT/out"
OUTPUT="$OUTPUT_DIR/Nyathing.pkg"

swift build -c release
rm -rf "$BUILD_DIR" "$OUTPUT"
mkdir -p "$CONTENTS/MacOS" "$RESOURCES" "$PAYLOAD/Applications" "$PACKAGE_DIR" "$OUTPUT_DIR"
cp .build/release/nyathing "$CONTENTS/MacOS/nyathing"
cp -R .build/release/Nyathing_Nyathing.bundle "$RESOURCES/"
ICONSET="$BUILD_DIR/Nyathing.iconset"
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

cp -R "$APP_DIR" "$PAYLOAD/Applications/"
cp Scripts/pkg-preinstall "$PACKAGE_DIR/preinstall"
cp Scripts/pkg-postinstall "$PACKAGE_DIR/postinstall"
chmod 755 "$PACKAGE_DIR/preinstall" "$PACKAGE_DIR/postinstall"
pkgbuild \
  --root "$PAYLOAD" \
  --identifier com.nyathing.Nyathing.pkg \
  --version "$VERSION" \
  --install-location / \
  --scripts "$PACKAGE_DIR" \
  "$OUTPUT"

echo "Created $OUTPUT"
