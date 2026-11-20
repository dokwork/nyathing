# Nyathing


![nyathing-fancy.png](assets/nyathing-fancy.png)
[![CI](https://github.com/dokwork/nyathing/actions/workflows/ci.yml/badge.svg)](https://github.com/dokwork/nyathing/actions/workflows/ci.yml)
[![Latest release](https://img.shields.io/github/v/release/dokwork/nyathing)](https://github.com/dokwork/nyathing/releases/latest)

Nyathing brings background processes to life with playful animations in the
macOS menu bar. Clients start an animation when work begins and stop it when the
task is done.

## 🢃 Install

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

<p align="right"><img src="assets/nyathing-server.png" alt="nyathing-server" height=80></p>

Nyathing exposes a local API over a Unix domain stream socket. The socket path is
`$XDG_RUNTIME_DIR/nyathing.sock` when `XDG_RUNTIME_DIR` is set; otherwise it is
`$TMPDIR/nyathing-<uid>.sock` (usually `/tmp`). The socket is restricted to the
current user, and the server checks the connecting process's user ID.

Exchange UTF-8 JSON Lines: send one JSON object followed by a newline (`\n`);
Nyathing returns one JSON object followed by a newline for each request. A
connection can carry multiple request/response pairs, and multiple clients may
connect at the same time. Request lines are limited to 1 MiB.

For the complete message formats, field requirements, and response schemas,
see [Server communication protocol](#server-communication-protocol). 

## Nyathing CLI

<p align="right"><img src="assets/nyathing-cli.png" alt="nyathing-cli" height=85></p>

Nyathing provides a command-line utility for wrapping long-running terminal
commands in an animation.

For example, show an animation while waiting five seconds, with or without a
custom animation:

```sh
  nyathing sleep 5
  nyathing --animation nyan sleep 5
```

`--animation` (or `-a`) selects an animation. A short name without the frame
size suffix or `.png` (for example, `nyan`) is looked up in Nyathing's user
animation directory. If multiple valid files share that name, Nyathing chooses
the frame with the largest pixel area. Any other value is treated as a path to
an animation file; relative paths are resolved from the current directory.
Without `--animation`, the CLI uses the short name `nyathing`, regardless of
the configured server default.

Set `--animation` to `random` to choose a random valid animation from the user
animations directory for that run.

If valid files named `random_<width>x<height>.png` exist, Nyathing plays the
largest matching animation. Otherwise, it chooses randomly from valid user
animations. If none are available, Nyathing uses its built-in ghost animation:

```sh
  nyathing --animation random sleep 5
```

Quote paths containing spaces as usual in your shell. Relative command paths
are resolved from the current working directory.

List valid installed animations by short name with:

```sh
  nyathing list
```

### Manage activities directly

Use `client` commands to control an activity without wrapping a process:

```sh
nyathing client start --animation nyan --description "Test"
nyathing client keepalive ACTIVITY_ID
nyathing client stop ACTIVITY_ID
```

`start` prints the activity ID. Send `keepalive` at least once per requested
interval (5 seconds by default), and use `stop` when done.
The server starts automatically if it is not already running; abandoned
activities expire according to `max_wait_time`. `start` also accepts
`--keepalive-interval SECONDS` to override the default for that activity.

To view available options or check the installed version:

```sh
  nyathing --help
  nyathing --version
```

## ❯ Shell completion

Nyathing can generate completion scripts for Zsh and Bash. Add the appropriate
command to your shell configuration file to enable completion in new shells.

For Zsh, add this to `~/.zshrc`:

```sh
  autoload -Uz compinit
  compinit
  eval "$(nyathing completion zsh)"
```

For Bash, add this to `~/.bashrc`:

```sh
  eval "$(nyathing completion bash)"
```

The completion script offers Nyathing commands and options, including server
subcommands. It fetches available animations with `nyathing list` when
completing an animation argument, so the suggestions reflect installed files.

## Animation file format

Animation files are horizontal PNG sprite sheets. The filename suffix declares
the dimensions of each frame, for example `nyan_64x48.png`. Each dimension must
be between 16 and 256 pixels, with an aspect ratio no greater than 3:1. The
image height must match the declared frame height, and its width must be a
positive multiple of the declared frame width. Sheets may contain at most 120
frames and 4 million pixels total. Frames are scaled to fit the menu bar. The
app validates assets on startup and when settings are accepted; invalid assets
are ignored and logged. Playback runs at 10 frames per second.

## ⚙ Configuration

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
# Maximum seconds to wait since the last client keepalive.
max_wait_time = 60
# Whether to launch Nyathing automatically when you log in.
auto_start = false
# Animation filename (or "random") used when a client omits the animation field.
default_animation = "nyathing_36x36.png"
```

Keep all three settings in your `config.toml`; Nyathing does not fill in omitted
settings. Set `max_wait_time` to a positive number of seconds and `auto_start`
to `true` or `false`. Clients use a default keepalive interval of 5 seconds,
which they can override per activity. Activities expire after the smaller of
twice that interval and `max_wait_time`. Set `default_animation` to a valid
filename in `animations/` or to `random` to select a random animation per activity.
Requests with an explicit animation use it; missing or unavailable requested
animations fall back to the built-in ghost.
Choose **Edit Configuration** from the menu to change these settings with
visual controls. **Accept** saves the configuration and reloads settings and
animations; this also clears active activities and the disconnected-client
count. **Cancel** closes the editor without applying changes. Accepting the
current settings also reloads animation files changed outside the editor.

## {} Server communication protocol

The server communicates over a Unix domain `SOCK_STREAM` socket using UTF-8
JSON Lines. Each message is a JSON object followed by `\n`; each request
receives exactly one response. A connection may carry multiple sequential
request/response pairs. A request line may be at most 1 MiB. The socket is
accessible only to the current user, whose identity is also checked when
connecting.

### Request messages

Every request has this common envelope:

```json
{
  "command": "<command-name>"
}
```

The `command` property is required and must be a string. The following command
messages are supported:

| Command | Description |
| --- | --- |
| `start` | Starts an activity and returns its identifier. |
| `keepalive` | Refreshes an activity's expiration timer. |
| `stop` | Ends an activity without counting it as a disconnect. |

#### `start` request

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `command` | string | Yes | Must be `start`. |
| `animation` | string | No | Short name searched in the server's animation directory, or a path to a PNG sprite sheet. Defaults to the server's configured animation. Invalid explicit values return an error. |
| `description` | string | No | Description shown for the activity. If omitted or not a string, the server uses its default description. |
| `keepalive_interval_seconds` | number | No | Positive, finite interval in seconds at which the client promises to send keepalives. Defaults to 5 seconds. The activity expires after the smaller of twice this interval and the server's configured `max_wait_time`. |

A short name without a frame-size suffix or `.png` is resolved in the server's
animation directory. Other values are treated as file paths; relative paths
are resolved from the server process's current working directory. `random`
selects a random valid animation, falling back to the built-in ghost if none
are available.

Examples:

```json
{"command":"start","animation":"nyan","keepalive_interval_seconds":5}
```
or
```json
{"command":"start","animation":"nyan","description":"make test","keepalive_interval_seconds":5}
```

#### `keepalive` request

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `command` | string | Yes | Must be `keepalive`. |
| `activity_id` | string (UUID) | Yes | Identifier returned by the corresponding `start` request. |

Example:

```json
{"command":"keepalive","activity_id":"<activity-id>"}
```

Send keepalives periodically at the interval specified in the `start` request.
If the server does not receive one within the smaller of twice that interval
and `max_wait_time`, the activity expires and increments the
disconnected-client count.

#### `stop` request

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `command` | string | Yes | Must be `stop`. |
| `activity_id` | string (UUID) | Yes | Identifier returned by the corresponding `start` request. Stopping an activity does not count as a disconnect. |

Example:

```json
{"command":"stop","activity_id":"<activity-id>"}
```

### Response messages

A successful `start` response contains the activity identifier:

```json
{"ok":true,"activity_id":"<activity-id>"}
```

Successful `keepalive` and `stop` responses are:

```json
{"ok":true}
```

A failed request returns an error response:

```json
{"ok":false,"error":"<error-message>"}
```

Errors include malformed requests, unknown commands or activity identifiers,
invalid keepalive intervals, per-activity timeout overrides, and oversized
request lines. An activity expires after the smaller of twice its keepalive
interval and the configured `max_wait_time`. Expiration increments the
disconnected-client count; an explicit `stop` does not.

## ✦ Minimal Python client example

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
    activity = command({
        "command": "start",
        "animation": "nyan",
        "keepalive_interval_seconds": 5,
    })["activity_id"]
    command({"command": "keepalive", "activity_id": activity})
    command({"command": "stop", "activity_id": activity})
```

## Launch at login

In the **Edit Configuration** window, enable **Launch Nyathing at login** and
click **Accept**. Nyathing installs its own LaunchAgent in
`~/Library/LaunchAgents`; it will start automatically at your next login. No
manual `launchctl` commands are needed.

Disable **Launch Nyathing at login** in **Edit Configuration** and click
**Accept** to remove the LaunchAgent. If you move
`Nyathing.app`, enable auto-start again and click **Accept** so the LaunchAgent
records the app's new location.

## ⚡︎ Troubleshooting

Startup and runtime diagnostics are written to
`$XDG_STATE_HOME/nyathing/nyathing.log`, or
`~/.local/state/nyathing/nyathing.log` when `XDG_STATE_HOME` is unset. Startup
errors show an alert with an **Open Log** button. Configuration errors also
offer **Open Configuration**. Invalid animation files are logged and ignored.
If the socket path is already in use, quit the existing instance before
launching another. After correcting animation files, click **Accept** in the
**Edit Configuration** window to reload them.

## ⚒ Build from source

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
