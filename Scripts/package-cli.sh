#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [[ "$(uname -m)" != "arm64" ]]; then
  echo "The macOS arm64 archive must be built on an arm64 runner." >&2
  exit 1
fi

swift build -c release
BUILD_DIR="$ROOT/.build"
OUT_DIR="$ROOT/out"
mkdir -p "$BUILD_DIR" "$OUT_DIR"
BUILD_DIR="$(cd "$BUILD_DIR" && pwd -P)"
OUT_DIR="$(cd "$OUT_DIR" && pwd -P)"
STAGING="$(mktemp -d "$BUILD_DIR/nyathing-cli.XXXXXX")"
OUTPUT_DIR="$OUT_DIR/nyathing-macos-arm64"
OUTPUT="$OUT_DIR/nyathing-macos-arm64.tar.gz"
cleanup() {
  trap - EXIT
  case "$STAGING" in
    "$BUILD_DIR"/nyathing-cli.*) rm -rf -- "$STAGING" ;;
    *) echo "Refusing to remove unexpected staging path: $STAGING" >&2; exit 1 ;;
  esac
}
trap cleanup EXIT
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
if [[ -e "$OUTPUT_DIR" || -L "$OUTPUT_DIR" ]]; then
  [[ ! -L "$OUTPUT_DIR" && "$OUTPUT_DIR" == "$OUT_DIR/nyathing-macos-arm64" ]] || {
    echo "Refusing to replace unexpected output path: $OUTPUT_DIR" >&2; exit 1;
  }
  rm -rf -- "$OUTPUT_DIR"
fi
cp -R "$STAGING" "$OUTPUT_DIR"
if [[ -e "$OUTPUT" || -L "$OUTPUT" ]]; then
  [[ ! -d "$OUTPUT" && "$OUTPUT" == "$OUT_DIR/nyathing-macos-arm64.tar.gz" ]] || {
    echo "Refusing to replace unexpected archive path: $OUTPUT" >&2; exit 1;
  }
  rm -f -- "$OUTPUT"
fi
tar -czf "$OUTPUT" -C "$STAGING" .
echo "Created $OUTPUT"
