#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
PREFIX="${PREFIX:-/usr/local}"
SOURCE_DIR="${1:-}"

if [[ -z "$SOURCE_DIR" ]]; then
  swift build -c release
  SOURCE_DIR="$ROOT/.build/release"
fi
SOURCE_DIR="$(cd "$SOURCE_DIR" && pwd)"
BIN_DIR="$PREFIX/bin"
LIBEXEC_DIR="$PREFIX/libexec/nyathing"

permission_check="$PREFIX"
while [[ ! -e "$permission_check" ]]; do
  permission_check="$(dirname "$permission_check")"
done
if [[ -w "$permission_check" ]]; then
  needs_sudo=false
else
  needs_sudo=true
fi

run_install() {
  if [[ "$needs_sudo" == true ]]; then
    sudo "$@"
  else
    "$@"
  fi
}

run_install mkdir -p "$BIN_DIR" "$LIBEXEC_DIR"
run_install install -m 755 "$SOURCE_DIR/nyathing" "$LIBEXEC_DIR/nyathing"
run_install rm -rf "$LIBEXEC_DIR/Nyathing_Nyathing.bundle"
run_install ditto "$SOURCE_DIR/Nyathing_Nyathing.bundle" \
  "$LIBEXEC_DIR/Nyathing_Nyathing.bundle"

wrapper="$BIN_DIR/nyathing"
wrapper_content='#!/bin/sh
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
exec "$SCRIPT_DIR/../libexec/nyathing/nyathing" "$@"
'
wrapper_tmp="$(mktemp)"
trap 'rm -f "$wrapper_tmp"' EXIT
printf '%s' "$wrapper_content" > "$wrapper_tmp"
run_install install -m 755 "$wrapper_tmp" "$wrapper"
echo "Installed nyathing in $BIN_DIR (resources in $LIBEXEC_DIR)."
