# Nyathing


![nyathing-fancy.png](assets/nyathing-fancy.png)
[![CI](https://github.com/dokwork/nyathing/actions/workflows/ci.yml/badge.svg)](https://github.com/dokwork/nyathing/actions/workflows/ci.yml)
[![Latest release](https://img.shields.io/github/v/release/dokwork/nyathing)](https://github.com/dokwork/nyathing/releases/latest)

Nyathing brings background processes to life with playful animations in the
macOS menu bar. Clients start an animation when work begins and stop it when the
task is done.

## Install

Download the installer package from the repository's **Releases** page. Open
the package and follow the Installer prompts to install `Nyathing.app` in
`/Applications`. The installer also creates the `/usr/local/bin/nyathing`
command symlink and requests administrator authorization to make these
system-wide changes.

To remove the installed app and command, run in terminal:

```sh
nyathing uninstall
```

Uninstall requests administrator authorization. It asks
`Remove Nyathing configuration and user animations? [y/N]`; the default is no.
Answering no preserves configuration and animations while still removing the
app and CLI symlink. The app is closed as part of removal.

If the built-in uninstall does not complete, run `make uninstall` from the
repository root. This force-removal fallback requires administrator
authorization and removes the app, CLI command, configuration, and logs.

**👮🏻‍♂️ Note**

The app and package are **unsigned** and not notarized, so macOS may block the
app because it was downloaded from the internet. If macOS blocks it, try opening
the app once, then allow it in **System Settings → Privacy & Security**:

1. Open **System Settings** and select **Privacy & Security**.
2. Scroll to the **Security** section.
3. Click **Open Anyway** next to the message about Nyathing being blocked,
   then confirm when prompted.

The **Open Anyway** option appears after you try to open the app. You may need
to enter your password or confirm with Touch ID.

Alternatively, build and run `Nyathing` locally using the instructions in
[Build from source](#build-from-source); locally built apps are not quarantined.

## Nyathing server

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
  returns `{"ok":true,"activity_id":"…"}`. Optional
  `keepalive_interval_seconds` and `activity_timeout_seconds` fields override
  the corresponding `config.toml` defaults for this activity; both must be
  positive numbers. The animation is identified by
  its filename. The `animation` field is optional; when omitted, Nyathing uses
  the animation selected by `default_animation` in `config.toml`. If a
  requested animation is unavailable or invalid, Nyathing uses the built-in
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

## Run terminal commands with Nyathing

Run a command with `nyathing` to display an animation while it runs. Nyathing
starts the activity, keeps it alive while the command runs, then stops it.

For example, show an animation while waiting five seconds, with or without a
custom animation:

```sh
  nyathing sleep 5
  nyathing --animation nyan sleep 5
```

`--animation` (or `-a`) selects an animation from Nyathing's user animation
directory. You can use the short name before the frame-size suffix and `.png`
(for example, `nyan` instead of `nyan_54x36.png`). If both `nyan_36x36.png`
and `nyan_54x36.png` exist, Nyathing chooses the larger `54x36` animation.
Without `--animation`, the CLI uses `nyathing_36x36.png`, regardless of the
configured server default. Quote paths containing spaces as usual in your shell.
Relative command paths are resolved from the current working directory.

List valid installed animations with:

```sh
  nyathing list
```

To view available options or check the installed version:

```sh
  nyathing --help
  nyathing --version
```

## Animation file format

Animation files are single horizontal PNG sprite sheets. Supported frame sizes
are 36x36 and 54x36 pixels; image height must equal the frame height and image
width must be a positive multiple of it. Name files with the frame size suffix,
for example `nyan_54x36.png`. The app validates assets on startup and reload;
invalid assets are ignored and logged. Playback runs at 10 frames per second.

## Configuration

On first launch, Nyathing creates its configuration directory and adds these
built-in animations:

- Nyathing (`nyathing_36x36.png`)
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
# Animation filename used when a client omits the animation field.
default_animation = "nyathing_36x36.png"
```

Keep all four settings in your `config.toml`; Nyathing does not fill in omitted
settings. Set `auto_start` to `true` or `false`; both durations must be positive
numbers. Set `default_animation` to the filename of a valid animation in the
`animations/` directory. Requests with an explicit animation use it; missing or
unavailable requested animations fall back to the built-in ghost.
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

## Build from source

Requires macOS 12+ and Swift 5.9 or later. Run the commands below from the
repository root.

### Run the server

Build and launch the menu-bar server in the background:

```sh
swift build
swift run nyathing server start
swift run nyathing server status
swift run nyathing server stop
```


### Run the CLI

The CLI runs a command while displaying an activity animation. For example:

```sh
swift run nyathing sleep 5
```

### Install from source

Install the menu-bar app in `/Applications`:

```sh
make install-app
```

To run Nyathing from a terminal, also create the CLI symlink in
`/usr/local/bin`:

```sh
make install-cli-link
```

The CLI symlink requires the app to be installed first. Each command asks
before replacing an existing app or symlink and requires administrator
authorization to install its files.
