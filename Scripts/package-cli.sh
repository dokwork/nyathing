#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [[ "$(uname -m)" != "arm64" ]]; then
  echo "The macOS arm64 archive must be built on an arm64 runner." >&2
  exit 1
fi

swift build -c release
STAGING="$ROOT/.build/cli-archive"
OUTPUT_DIR="$ROOT/out/nyathing-macos-arm64"
OUTPUT="$ROOT/out/nyathing-macos-arm64.tar.gz"
rm -rf "$STAGING"
mkdir -p "$STAGING"
cp .build/release/nyathing "$STAGING/nyathing"
cp -R .build/release/Nyathing_Nyathing.bundle "$STAGING/Nyathing_Nyathing.bundle"
cp Scripts/install-cli.sh "$STAGING/install-cli.sh"
cp Scripts/force-uninstall.sh "$STAGING/uninstall.sh"
cat > "$STAGING/install.sh" <<'INSTALLER'
#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PREFIX="${PREFIX:-/usr/local}" bash "$SCRIPT_DIR/install-cli.sh" "$SCRIPT_DIR"
INSTALLER
chmod 755 "$STAGING/install.sh" "$STAGING/install-cli.sh" "$STAGING/uninstall.sh"
mkdir -p "$ROOT/out"
rm -rf "$OUTPUT_DIR"
cp -R "$STAGING" "$OUTPUT_DIR"
rm -f "$OUTPUT"
tar -czf "$OUTPUT" -C "$STAGING" .
echo "Created $OUTPUT"
