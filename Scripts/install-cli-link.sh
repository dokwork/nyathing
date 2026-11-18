#!/bin/bash
set -euo pipefail

APP_EXECUTABLE="/Applications/Nyathing.app/Contents/MacOS/nyathing"
CLI_PATH="/usr/local/bin/nyathing"

if [[ ! -x "$APP_EXECUTABLE" ]]; then
  echo "Install Nyathing.app in /Applications before creating the CLI link." >&2
  exit 1
fi
if [[ -e "$CLI_PATH" || -L "$CLI_PATH" ]]; then
  if [[ -d "$CLI_PATH" && ! -L "$CLI_PATH" ]]; then
    echo "Cannot replace $CLI_PATH because it is a directory." >&2
    exit 1
  fi
  read -r -p "Replace existing $CLI_PATH? [y/N] " answer
  case "$answer" in
    y|Y|yes|Yes|YES) sudo /bin/rm -f -- "$CLI_PATH" ;;
    *) echo "Installation cancelled."; exit 0 ;;
  esac
fi

sudo /bin/mkdir -p /usr/local/bin
sudo /bin/ln -s "$APP_EXECUTABLE" "$CLI_PATH"
echo "Created CLI link at $CLI_PATH."
