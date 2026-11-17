# Nyathing

Nyathing is a native macOS menu bar animation player for macOS 12 and later. It
plays horizontal PNG sprite sheets and exposes a local Unix-socket API so other
programs can control animations independently of their own lifecycle.

## Build and run

Requires macOS 12+ and Swift 5.9 or later. From the repository root:

```sh
swift build
swift run nyathing
```

Run the automated tests with `swift test`. The app is an accessory/menu bar app;
launch it in a logged-in desktop session. Quit it from its menu or terminate its
process from a terminal.

## Install

Build the unsigned installer package with:

```sh
Scripts/build-pkg.sh
```

The script builds a release `.app` bundle and creates
`dist/Nyathing-1.0.0.pkg`. Open the package and follow the Installer prompts to
install `Nyathing.app` in `/Applications`. Launch it from Finder. The installer
is currently unsigned and not notarized; macOS may require the user to approve
opening it. Signing and notarization are not included in this build process.

Future download: [Nyathing package releases](https://github.com/OWNER/REPOSITORY/releases)

## Configuration and animations

On first launch, Nyathing creates its configuration directory and seeds a
sample ghost animation:

- Configuration: `$XDG_CONFIG_HOME/nyathing/config.toml`, or
  `~/.config/nyathing/config.toml` when `XDG_CONFIG_HOME` is unset.
- Animation directory: `animations/` beside `config.toml`.

The complete initial configuration is:

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

All settings are required. Durations are numeric seconds and must be positive.
`default_animation` must name a valid animation file in `animations/`.

Animation files are single horizontal PNG sprite sheets. Supported frame sizes
are 36x36 and 54x36 pixels; image height must equal the frame height and image
width must be a positive multiple of it. Name files with the frame size suffix,
for example `nyan_54x36.png`. The app validates assets on startup and reload;
invalid assets are ignored and logged. Playback runs at 10 frames per second.

Use **Reload Configuration and Animations** in the menu after changing
configuration or animation files. Reload clears active client activities and
the disconnected-client count.

## Local client API

The API uses a current-user Unix domain socket and newline-delimited JSON (one
JSON object and one response per line). The socket path is
`$XDG_RUNTIME_DIR/nyathing.sock` when `XDG_RUNTIME_DIR` is set, otherwise
`$TMPDIR/nyathing-<uid>.sock`. Requests support multiple commands per connection
and multiple simultaneous connections. Socket permissions and peer credentials
restrict access to the current user.

Commands:

- `{"command":"start","animation":"nyan_54x36.png"}` starts an activity and
  returns `{"ok":true,"activity_id":"…"}`. An unavailable animation uses the
  built-in ghost animation.
- `{"command":"keepalive","activity_id":"…"}` refreshes an activity.
- `{"command":"stop","activity_id":"…"}` ends it explicitly.

Keepalive and stop success responses are `{"ok":true}`. Invalid requests and
unknown activity IDs return `{"ok":false,"error":"…"}`. Clients should send
keepalives at `keepalive_interval_seconds`; an activity expires after
`activity_timeout_seconds` without one. Expiration increments the main menu-bar
warning count and plays `explosion_36x36.png` when available. Explicit stop does
not increment the count. The menu can reset the count.

A minimal Python example:

```python
import json
import os
import socket
import tempfile

runtime = os.environ.get("XDG_RUNTIME_DIR")
path = os.path.join(runtime or os.environ.get("TMPDIR", tempfile.gettempdir()),
                    "nyathing.sock" if runtime else f"nyathing-{os.getuid()}.sock")
with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
    client.connect(path)
    stream = client.makefile("rwb")
    def command(value):
        stream.write(json.dumps(value).encode() + b"\n")
        stream.flush()
        return json.loads(stream.readline())
    activity = command({"command": "start", "animation": "nyan_54x36.png"})["activity_id"]
    command({"command": "keepalive", "activity_id": activity})
    command({"command": "stop", "activity_id": activity})
```

## Optional login launch

Set `auto_start = true` and launch Nyathing. It prepares
`com.nyathing.Nyathing.plist` beside the configuration; it does not install or
manage the LaunchAgent. Install and load it manually:

```sh
mkdir -p ~/Library/LaunchAgents
cp "${XDG_CONFIG_HOME:-$HOME/.config}/nyathing/com.nyathing.Nyathing.plist" \
  ~/Library/LaunchAgents/com.nyathing.Nyathing.plist
launchctl bootstrap "gui/$(id -u)" ~/Library/LaunchAgents/com.nyathing.Nyathing.plist
```

To unload and remove the manually installed agent:

```sh
launchctl bootout "gui/$(id -u)" ~/Library/LaunchAgents/com.nyathing.Nyathing.plist
rm ~/Library/LaunchAgents/com.nyathing.Nyathing.plist
```

The plist uses the app executable's current path. If Nyathing is moved,
regenerate the plist by launching it again with `auto_start = true`.

## Troubleshooting

Startup and runtime diagnostics are written to
`$XDG_STATE_HOME/nyathing/nyathing.log`, or
`~/.local/state/nyathing/nyathing.log` when `XDG_STATE_HOME` is unset. Startup
errors show an alert with an **Open Full Log** button. If the socket path is
already in use, quit the existing instance before launching another. Invalid
configuration or animation files are reported in the log; correct them and
reload.
