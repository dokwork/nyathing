#!/bin/bash
set -euo pipefail

app_path="/Applications/Nyathing.app"
cli_path="/usr/local/bin/nyathing"
launch_agent="$HOME/Library/LaunchAgents/com.nyathing.Nyathing.plist"
config_dir="${XDG_CONFIG_HOME:-$HOME/.config}/nyathing"
state_dir="${XDG_STATE_HOME:-$HOME/.local/state}/nyathing"

launchctl bootout "gui/$(id -u)" "$launch_agent" 2>/dev/null || true

# Stop Nyathing before removing its app bundle and executable.
/usr/bin/pkill -TERM -x nyathing 2>/dev/null || true
for _ in {1..5}; do
  if ! /usr/bin/pgrep -x nyathing >/dev/null 2>&1; then break; fi
  /bin/sleep 1
done
/usr/bin/pkill -KILL -x nyathing 2>/dev/null || true

sudo /bin/rm -rf -- \
  "$app_path" \
  "$cli_path" \
  "$launch_agent" \
  "$config_dir" \
  "$state_dir"

if [[ -e "$app_path" || -L "$app_path" || -e "$cli_path" || -L "$cli_path" \
  || -e "$launch_agent" || -e "$config_dir" || -e "$state_dir" ]]; then
  echo "Nyathing uninstall failed: some app files or user data remain." >&2
  exit 1
fi

echo "Nyathing and its user data were removed."
