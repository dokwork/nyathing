# Nyathing

![nyathings.png](assets/nyathings.png)

Nyathing brings background processes to life with playful animations in the
macOS menu bar. Clients start an animation when work begins and stop it when the
task is done.

## Install

Download `nyathing-X.Y.Z.pkg` from the repository's **Releases** page. Open the
downloaded package and follow the Installer prompts to install `Nyathing.app` in
`/Applications`. Packages are unsigned and not notarized; macOS may require you
to approve opening them.

## Build and run

Requires macOS 12+ and Swift 5.9 or later.
From the repository root:

```sh
swift build
swift run nyathing
```

## Protocol

Nyathing exposes a local API over a Unix domain stream socket. The socket path is
`$XDG_RUNTIME_DIR/nyathing.sock` when `XDG_RUNTIME_DIR` is set; otherwise it is
`$TMPDIR/nyathing-<uid>.sock` (usually `/tmp`). The socket is restricted to the
current user, and the server checks the connecting process's user ID.

Exchange UTF-8 JSON Lines: send one JSON object followed by a newline (`\n`);
Nyathing returns one JSON object followed by a newline for each request. A
connection can carry multiple request/response pairs, and multiple clients may
connect at the same time. Request lines are limited to 1 MiB.

Commands:

- Start an activity: `{"command":"start","animation":"nyan_54x36.png"}`
  returns `{"ok":true,"activity_id":"…"}`. The animation is identified by
  its filename. If it is unavailable or invalid, Nyathing uses the built-in
  ghost animation.
- Refresh a running activity: `{"command":"keepalive","activity_id":"…"}`
  returns `{"ok":true}` and resets its expiration timer.
- End an activity: `{"command":"stop","activity_id":"…"}` returns
  `{"ok":true}` and does not count as a disconnect.

Errors return `{"ok":false,"error":"…"}`. This includes malformed requests,
unknown commands, and unknown activity IDs. Send keepalives periodically; the
activity expires after `activity_timeout_seconds` without one. Expiration
increments the disconnected-client count and plays `explosion_36x36.png` when
available. Explicitly stopping an activity does not count as a disconnect.
Use **Reset Disconnected Count** in the menu to clear the count.

## Animation file format

Animation files are single horizontal PNG sprite sheets. Supported frame sizes
are 36x36 and 54x36 pixels; image height must equal the frame height and image
width must be a positive multiple of it. Name files with the frame size suffix,
for example `nyan_54x36.png`. The app validates assets on startup and reload;
invalid assets are ignored and logged. Playback runs at 10 frames per second.

## Configuration

On first launch, Nyathing creates its configuration directory and adds these
built-in animations:

- Ghost (`ghost_36x36.png`)
- Nyan Cat (`nyan_54x36.png`)
- Matrix (`matrix_36x36.png`)

Missing bundled animations are also added on later launches without overwriting
your files.

- Configuration: `$XDG_CONFIG_HOME/nyathing/config.toml`, or
  `~/.config/nyathing/config.toml` when `XDG_CONFIG_HOME` is unset.
- Animation directory: `animations/` beside `config.toml`.

The complete initial configuration is:

```toml
# Seconds between client keepalive messages; must be greater than zero.
keepalive_interval_seconds = 5
# Seconds without a keepalive before an activity expires; must be greater than zero.
activity_timeout_seconds = 5
# Whether to launch Nyathing automatically when you log in.
auto_start = false
# Animation filename in the sibling animations directory.
default_animation = "ghost_36x36.png"
```

Keep all four settings in your `config.toml`; Nyathing does not fill in omitted
settings. You can change their values, but both durations must remain positive
numbers, and `default_animation` must name a valid file in `animations/`.
To use Nyan Cat, set it to `nyan_54x36.png`; to use Matrix, set it to
`matrix_36x36.png`.

Use **Reload Configuration and Animations** in the menu after changing
configuration or animation files. Reload clears active client activities and
the disconnected-client count.

## Minimal Python client example

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

## Launch at login

Set `auto_start = true` in `config.toml`, then choose **Reload Configuration and
Animations** from Nyathing's menu. Nyathing installs its own LaunchAgent in
`~/Library/LaunchAgents`; it will start automatically at your next login. No
manual `launchctl` commands are needed.

Set `auto_start = false` and reload to remove the LaunchAgent. If you move
`Nyathing.app`, enable auto-start again and reload so the LaunchAgent records
the app's new location.

## Troubleshooting

Startup and runtime diagnostics are written to
`$XDG_STATE_HOME/nyathing/nyathing.log`, or
`~/.local/state/nyathing/nyathing.log` when `XDG_STATE_HOME` is unset. Startup
errors show an alert with an **Open Log** button. Configuration errors also
offer **Open Configuration**; animation errors offer **Open Animations Folder**.
If the socket path is already in use, quit the existing instance before
launching another. Invalid animation files are reported in the log; correct
them and reload.
