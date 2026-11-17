# Nyathing

A native macOS menu bar animation player, built with Swift and AppKit.

## Step 4: Local client API manual check

Build and launch from the repository root:

```sh
swift build
swift run nyathing
```

The app creates a Unix socket at `$XDG_RUNTIME_DIR/nyathing.sock` when
`XDG_RUNTIME_DIR` is set; otherwise it uses `$TMPDIR/nyathing-<uid>.sock`.
Only the current user can access it. Connect with any Unix-socket client and send
one JSON object per line. The server returns one JSON object per command.

This Python example starts an animation, keeps it alive, and stops it using one
connection. If `missing_36x36.png` is not installed, the built-in ghost animation
is used instead.

```sh
python3 - <<'PY'
import json
import os
import socket
import tempfile

runtime_dir = os.environ.get("XDG_RUNTIME_DIR")
socket_path = os.path.join(
    runtime_dir or os.environ.get("TMPDIR", tempfile.gettempdir()),
    "nyathing.sock" if runtime_dir else f"nyathing-{os.getuid()}.sock",
)
with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
    client.connect(socket_path)
    stream = client.makefile("rwb")

    def command(value):
        stream.write(json.dumps(value).encode() + b"\n")
        stream.flush()
        response = json.loads(stream.readline())
        print(response)
        return response

    activity_id = command({"command": "start", "animation": "missing_36x36.png"})["activity_id"]
    command({"command": "keepalive", "activity_id": activity_id})
    command({"command": "stop", "activity_id": activity_id})
PY
```

Check that start returns an activity ID, keepalive and stop return `{"ok":true}`,
and stopping removes the activity's status item. Start the same animation from
multiple clients and confirm the shared status item shows an activity count;
start different animations and confirm they receive separate status items.

To check timeout behavior, start an activity and do not send another keepalive.
After the configured `activity_timeout_seconds` (5 seconds by default), verify
the activity ends and the main status item displays the warning count and
explosion effect. Explicit stop must not increase the count. The count remains
after the explosion ends and can be reset from the main menu. When the explosion
asset is missing or invalid, the warning state should still appear.

The keepalive interval expected of clients is `keepalive_interval_seconds`
(5 seconds by default); timeout is configured by `activity_timeout_seconds` in
`$XDG_CONFIG_HOME/nyathing/config.toml`, or `~/.config/nyathing/config.toml` when
`XDG_CONFIG_HOME` is unset. The sibling `animations/` directory contains
animation assets. The app creates a populated configuration and seeds
`ghost_36x36.png` on first launch.

Configuration template:

```toml
# Seconds between client keepalive messages; must be greater than zero.
keepalive_interval_seconds = 5
# Seconds without a keepalive before an activity expires; must be greater than zero.
activity_timeout_seconds = 5
# Whether to prepare a user LaunchAgent plist for manual installation.
auto_start = false
# Animation filename in the sibling animations directory.
default_animation = "ghost_36x36.png"
```

The main menu also provides About, Quit, Reset Disconnected Count, Reload
Configuration and Animations, and Open Configuration. Reload clears active
animations and the warning count. Status-item placement is managed by macOS and
visibility may be limited when the menu bar is crowded.

## Step 5: Auto-start and error-handling manual check

Set `auto_start = true` in the configuration and launch Nyathing. The app writes
`com.nyathing.Nyathing.plist` beside `config.toml`; it does not install or manage
the LaunchAgent. Inspect `ProgramArguments` and make sure it points to the
executable at its final, stable location. If you relocate the executable, launch
the app again to regenerate the plist. Copy the prepared file to
`~/Library/LaunchAgents/com.nyathing.Nyathing.plist`, then load it manually:

```sh
mkdir -p ~/Library/LaunchAgents
cp "$XDG_CONFIG_HOME/nyathing/com.nyathing.Nyathing.plist" \
  ~/Library/LaunchAgents/com.nyathing.Nyathing.plist
launchctl bootstrap "gui/$(id -u)" \
  ~/Library/LaunchAgents/com.nyathing.Nyathing.plist
```

If `XDG_CONFIG_HOME` is unset, use `~/.config/nyathing/` as the source directory.
Confirm that Nyathing starts at the next login. To stop and remove the manually
installed agent, run:

```sh
launchctl bootout "gui/$(id -u)" \
  ~/Library/LaunchAgents/com.nyathing.Nyathing.plist
rm ~/Library/LaunchAgents/com.nyathing.Nyathing.plist
```

Set `auto_start = false` to stop preparing/updating the plist; Nyathing does not
unload or remove an already installed agent.

To check socket safety, first run one instance and confirm a second instance
reports that the socket is already active without removing it. For a stale owned
socket, quit Nyathing, leave its socket path behind, and launch again; it should
recover the socket. For an unsafe path, create a regular file at the socket path
in a controlled temporary runtime directory and launch Nyathing with
`XDG_RUNTIME_DIR` set to that directory; it must refuse to remove the file.

Startup errors are written to `$XDG_STATE_HOME/nyathing/nyathing.log`, or
`~/.local/state/nyathing/nyathing.log` when `XDG_STATE_HOME` is unset. Check that
an invalid configuration or socket startup failure displays an error dialog
with the full log path and an **Open Full Log** button. The app remains available
where startup can continue safely; configuration/API startup failures are
reported and leave the local API unavailable until configuration is corrected
and reloaded. The log directory and file are restricted to the current user.
