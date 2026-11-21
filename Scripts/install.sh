#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PREFIX="${PREFIX:-/usr/local}"
if [[ "$PREFIX" != /* || "$PREFIX" == / || "$PREFIX" == "$HOME" \
  || "/$PREFIX/" == */../* ]]; then
  echo "Refusing unsafe PREFIX: $PREFIX" >&2
  exit 1
fi
SOURCE_DIR="${1:-}"

if [[ -z "$SOURCE_DIR" ]]; then
  if [[ -f "$SCRIPT_DIR/nyathing" && -d "$SCRIPT_DIR/Nyathing_Nyathing.bundle" ]]; then
    SOURCE_DIR="$SCRIPT_DIR"
  else
    cd "$ROOT"
    swift build -c release
    SOURCE_DIR="$ROOT/.build/release"
  fi
  SOURCE_DIR="$(cd "$SOURCE_DIR" && pwd -P)"
fi
[[ -d "$SOURCE_DIR" && ! -L "$SOURCE_DIR" ]] || {
  echo "Invalid install source directory: $SOURCE_DIR" >&2; exit 1;
}
SOURCE_DIR="$(cd "$SOURCE_DIR" && pwd -P)"
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
bundle_path="$LIBEXEC_DIR/Nyathing_Nyathing.bundle"
if [[ -e "$bundle_path" || -L "$bundle_path" ]]; then
  [[ ! -L "$bundle_path" && "$bundle_path" == "$PREFIX/libexec/nyathing/Nyathing_Nyathing.bundle" ]] || {
    echo "Refusing to remove unexpected bundle path: $bundle_path" >&2; exit 1;
  }
  run_install rm -rf -- "$bundle_path"
fi
run_install ditto "$SOURCE_DIR/Nyathing_Nyathing.bundle" \
  "$LIBEXEC_DIR/Nyathing_Nyathing.bundle"

wrapper="$BIN_DIR/nyathing"
wrapper_content='#!/bin/sh
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
exec "$SCRIPT_DIR/../libexec/nyathing/nyathing" "$@"
'
wrapper_tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/nyathing-install.XXXXXX")"
wrapper_tmp="$wrapper_tmp_dir/wrapper"
cleanup() {
  case "$wrapper_tmp_dir" in
    "${TMPDIR:-/tmp}"/nyathing-install.*) rm -rf -- "$wrapper_tmp_dir" ;;
    *) echo "Refusing to remove unexpected temporary path: $wrapper_tmp_dir" >&2; exit 1 ;;
  esac
}
trap cleanup EXIT
printf '%s' "$wrapper_content" > "$wrapper_tmp"
run_install install -m 755 "$wrapper_tmp" "$wrapper"
echo "Installed nyathing in $BIN_DIR (resources in $LIBEXEC_DIR)."
