#!/bin/bash
set -euo pipefail

prefix="${PREFIX:-/usr/local}"
bin_dir="$prefix/bin"
cli_path="$bin_dir/nyathing"
libexec_dir="$prefix/libexec/nyathing"
legacy_app_path="/Applications/Nyathing.app"
launch_agent="$HOME/Library/LaunchAgents/com.nyathing.Nyathing.plist"

launchctl bootout "gui/$(id -u)" "$launch_agent" 2>/dev/null || true

# Stop Nyathing before removing its executable and resources.
/usr/bin/pkill -TERM -x nyathing 2>/dev/null || true
for _ in {1..5}; do
  if ! /usr/bin/pgrep -x nyathing >/dev/null 2>&1; then break; fi
  /bin/sleep 1
done
/usr/bin/pkill -KILL -x nyathing 2>/dev/null || true

remove_path() {
  local path="$1" parent="$(dirname "$1")"
  [[ -e "$path" || -L "$path" ]] || return 0
  while [[ ! -e "$parent" ]]; do parent="$(dirname "$parent")"; done
  if [[ -w "$parent" ]]; then
    /bin/rm -rf -- "$path"
  else
    sudo /bin/rm -rf -- "$path"
  fi
}

remove_path "$cli_path"
remove_path "$libexec_dir"
remove_path "$legacy_app_path"
remove_path "$launch_agent"

if [[ -e "$cli_path" || -L "$cli_path" || -e "$libexec_dir" \
  || -e "$legacy_app_path" || -e "$launch_agent" ]]; then
  echo "Nyathing uninstall failed: some installed files remain." >&2
  exit 1
fi

echo "Nyathing was removed. User configuration and state were kept."
