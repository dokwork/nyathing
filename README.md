# Nyathing


![nyathing-fancy.png](assets/nyathing-fancy.png)
[![CI](https://github.com/dokwork/nyathing/actions/workflows/ci.yml/badge.svg)](https://github.com/dokwork/nyathing/actions/workflows/ci.yml)
[![Latest release](https://img.shields.io/github/v/release/dokwork/nyathing)](https://github.com/dokwork/nyathing/releases/latest)

Nyathing brings background processes to life with playful animations in the
macOS menu bar. Clients start an animation when work begins and stop it when the
task is done.

## Contents

- [↓ Install from archive](#-install-from-archive)
- [⚒︎ Build from source](#-build-from-source)
- [▤ Nyathing server](#-nyathing-server)
  - [Launch at login](#launch-at-login)
- [⌘ Nyathing client](#-nyathing-client)
  - [How to choose an animation](#how-to-choose-an-animation)
  - [Describe a client](#describe-a-client)
- [>_ Nyathing CLI](#-nyathing-cli)
- [❯ Shell completion](#-shell-completion)
- [⚙ Configuration](#-configuration)
- [▦ Animation file format](#-animation-file-format)
- [⇄ Server communication protocol](#-server-communication-protocol)
- [✦ Examples](#-examples)
  - [Minimal Python client example](#-minimal-python-client-example)
  - [Coding-agent integrations](#-coding-agent-integrations)
    - [Codex](#-codex)
    - [Claude Code](#-claude-code)
- [⚡︎ Troubleshooting](#-troubleshooting)

## ↓ Install from archive

Download `nyathing-macos-arm64.tar.gz` from the latest GitHub Release, then
extract and install it:

```sh
mkdir -p "$HOME/.local/share/nyathing-archive"
tar -xzf ~/Downloads/nyathing-macos-arm64.tar.gz \
  -C "$HOME/.local/share/nyathing-archive"
cd "$HOME/.local/share/nyathing-archive"
PREFIX="$HOME/.local" ./install.sh
```

This installs the command in `~/.local/bin` and the executable and resources
under `~/.local/libexec/nyathing`. Add `~/.local/bin` to your `PATH` if needed.
To uninstall, run `PREFIX="$HOME/.local" ./uninstall.sh` from the extracted
archive. User configuration and animations are kept in `~/.config/nyathing` (or
`$XDG_CONFIG_HOME/nyathing`).

**👮🏻‍♂️ Note**

Nyathing is **unsigned** and not notarized, so macOS may block it because it
was downloaded from the internet. If macOS blocks Nyathing, try running it once
from Terminal, then allow it in **System Settings → Privacy & Security**:

1. Open **System Settings** and select **Privacy & Security**.
2. Scroll to the **Security** section.
3. Click **Open Anyway** next to the message about Nyathing being blocked,
   then confirm when prompted. This option may only appear for app launches.

The **Open Anyway** option may appear after you try to open the app; it may
not be available for a CLI binary. You may need to enter your password or
confirm with Touch ID.

Alternatively, build and run Nyathing locally using the instructions in
[Build from source](#build-from-source); locally built binaries are not quarantined.

## ⚒︎ Build from source

Requires macOS 12+ and Swift 5.9 or later. From the repository root, install
the CLI in `/usr/local/bin` with:

```sh
make install
```

The installer builds Nyathing and asks for administrator authorization to
install the command in `/usr/local/bin` and the executable and resources under
`/usr/local/libexec/nyathing`. To install under
your home directory instead, without administrator authorization, run:

```sh
make install PREFIX="$HOME/.local"
```

This installs the command in `~/.local/bin`; add that directory to your `PATH`
if needed. To uninstall from that prefix, pass it again:

```sh
make uninstall PREFIX="$HOME/.local"
```

Without a custom prefix, use `make uninstall` to remove the default installation
from `/usr/local/bin`. Uninstall keeps user configuration and animations.

## ▤ Nyathing server

<p align="right"><img src="assets/nyathing-server.png" alt="nyathing-server" height=80></p>

Nyathing exposes a local API over a Unix domain stream socket. The socket path is
`$XDG_RUNTIME_DIR/nyathing.sock` when `XDG_RUNTIME_DIR` is set; otherwise it is
`$TMPDIR/nyathing-<uid>.sock` (usually `/tmp`). The socket is restricted to the
current user, and the server checks the connecting process's user ID.

Exchange UTF-8 JSON Lines: send one JSON object followed by a newline (`\n`);
Nyathing returns one JSON object followed by a newline for each request. A
connection can carry multiple request/response pairs, and multiple clients may
connect at the same time. 

For convenience, Nyathing also implements the client side of the protocol. See
[Nyathing client](#nyathing-client) for details.

For the complete message formats, field requirements, and response schemas,
see [Server communication protocol](#server-communication-protocol). 

### Launch at login

In the **Edit Configuration** window, enable **Launch Nyathing at login** and
click **Accept**. Nyathing installs its own LaunchAgent in
`~/Library/LaunchAgents`; it will start automatically at your next login. No
manual `launchctl` commands are needed.

Disable **Launch Nyathing at login** in **Edit Configuration** and click
**Accept** to remove the LaunchAgent. If you move
`Nyathing.app`, enable auto-start again and click **Accept** so the LaunchAgent
records the app's new location.

## ⌘ Nyathing client

<p align="right"><img src="assets/nyathing-client.png" alt="nyathing-client" height=80></p>

For convenience, Nyathing includes a client for communicating with the server
without having to implement the protocol yourself.

Use `client` commands to control an activity without wrapping a process:

```sh
nyathing client start
```

The server starts automatically if it is not already running.
On `start` Nyathing prints the activity ID.

You can provide an ID with `--activity-id`; starting an already active ID fails
with an error:

```sh
nyathing client start --activity-id "$(uuidgen)"
```

Send `keepalive` at least once per requested interval (5 seconds by default) to
keep animation, and use `stop` when done.

```sh
nyathing client keepalive ACTIVITY_ID
nyathing client stop ACTIVITY_ID
```

Abandoned activities expire according to `max_wait_time` (see [Configuration](#-configuration)).
The command `start` also accepts `--keepalive-interval SECONDS` to override the
default for that activity.

### How to choose an animation 

You can explicitly specify an animation on start:

```sh
nyathing client start --animation nyan --description "Test"
```

`--animation` (or `-a`) selects an animation. A short name without the frame
size suffix or `.png` (for example, `nyan`) is looked up in Nyathing's user
animation directory. If multiple valid files share that name, Nyathing chooses
the frame with the largest pixel area. Any other value is treated as a path to
an animation file; relative paths are resolved from the current directory.
See [Animation file format](#-animation-file-format) for more details about file format.
Without `--animation`, a configured default animation is used.

Set `--animation` to `random` to choose a random valid animation from the user
animations directory for that run.

```sh
  nyathing --animation random sleep 5
```

If valid files named `random_<width>x<height>.png` exist, Nyathing plays the
largest matching animation. Otherwise, it chooses randomly from valid user
animations. If none are available, Nyathing uses its built-in ghost animation.

Quote paths containing spaces as usual in your shell. Relative command paths
are resolved from the current working directory.

### Describe a client

Active animations appear in the menu with a shortened version of their
descriptions. Add a description when starting a client to make it easier to
identify the activity:

```sh
nyathing client start --description "Running tests"
```

## >_ Nyathing CLI

<p align="right"><img src="assets/nyathing-cli.png" alt="nyathing-cli" height=85></p>

Nyathing provides a command-line utility for wrapping long-running terminal
commands in an animation.

For example, show an animation while waiting five seconds, with or without a
custom animation:

```sh
  nyathing sleep 5
  nyathing --animation nyan sleep 5
```

The activity description is the command and its arguments (for example,
`sleep 5`). While the command runs, Nyathing sends a keepalive every 5 seconds
to keep the animation active. It stops when the command exits, or expires if
keepalives stop arriving.

To get a list of valid installed animations by short name use:

```sh
  nyathing list
```

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
max_wait_time = 180
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

## ▦ Animation file format

Animation files are horizontal PNG sprite sheets. The filename suffix declares
the dimensions of each frame, for example `nyan_64x48.png`. Each dimension must
be between 16 and 256 pixels, with an aspect ratio no greater than 3:1. The
image height must match the declared frame height, and its width must be a
positive multiple of the declared frame width. Sheets may contain at most 120
frames and 4 million pixels total. Frames are scaled to fit the menu bar. The
app validates assets on startup and when settings are accepted; invalid assets
are ignored and logged. Playback runs at 10 frames per second.

## ⇄ Server communication protocol

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

| Command     | Description                                           |
| ---         | ---                                                   |
| `start`     | Starts an activity and returns its identifier.        |
| `keepalive` | Refreshes an activity's expiration timer.             |
| `stop`      | Ends an activity without counting it as a disconnect. |

#### `start` request

| Field                        | Type   | Required | Description                                                                                                                                                                                                             |
| ---                          | ---    | ---      | ---                                                                                                                                                                                                                     |
| `command`                    | string | Yes      | Must be `start`.                                                                                                                                                                                                        |
| `animation`                  | string | No       | Short name searched in the server's animation directory, or a path to a PNG sprite sheet. Defaults to the server's configured animation. Invalid explicit values return an error.                                       |
| `description`                | string | No       | Description shown for the activity. If omitted or not a string, the server uses its default description.                                                                                                                |
| `keepalive_interval_seconds` | number | No       | Positive, finite interval in seconds at which the client promises to send keepalives. Defaults to 5 seconds. The activity expires after the smaller of twice this interval and the server's configured `max_wait_time`. |
| `activity_id`                 | string | No       | Caller-provided activity ID. Must not match an active activity; otherwise the request fails and names the ID. If omitted, the server generates a UUID. |

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

| Field         | Type          | Required | Description                                               |
| ---           | ---           | ---      | ---                                                       |
| `command`     | string        | Yes      | Must be `keepalive`.                                      |
| `activity_id` | string        | Yes      | ID supplied to or returned by the corresponding `start` request. |

Example:

```json
{"command":"keepalive","activity_id":"<activity-id>"}
```

Send keepalives periodically at the interval specified in the `start` request.
If the server does not receive one within the smaller of twice that interval
and `max_wait_time`, the activity expires and increments the
disconnected-client count.

#### `stop` request

| Field         | Type          | Required | Description                                                                                                    |
| ---           | ---           | ---      | ---                                                                                                            |
| `command`     | string        | Yes      | Must be `stop`.                                                                                                |
| `activity_id` | string (UUID) | Yes      | Identifier returned by the corresponding `start` request. Stopping an activity does not count as a disconnect. |

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

## ✦ Examples

### 🐍 Minimal Python client example

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

### 🤖 Coding-agent integrations

Nyathing's CLI can be called directly from command hooks. The examples below
use `jq` to extract the activity ID from hook JSON on stdin; no helper script
is needed. Install `jq` and make sure it is on `PATH`. Replace `nyathing` with
its absolute path if the hook environment does not include it in `PATH`.

#### <img src="assets/codex_icon.png" alt="" height="22" style="vertical-align: middle;"> Codex

See the [Codex hooks documentation](https://developers.openai.com/codex/hooks).
Add these hooks to `~/.codex/hooks.json`:

```json
{
  "hooks": {
    "UserPromptSubmit": [{
      "hooks": [{
        "type": "command",
        "command": "id=$(jq -r .turn_id) && nyathing client start --activity-id \"$id\" --keepalive-interval 90 >/dev/null"
      }]
    }],
    "PostModelRequest": [{
      "hooks": [{
        "type": "command",
        "command": "id=$(jq -r .turn_id) && nyathing client keepalive \"$id\""
      }]
    }],
    "PreToolUse": [{
      "hooks": [{
        "type": "command",
        "command": "id=$(jq -r .turn_id) && nyathing client keepalive \"$id\""
      }]
    }],
    "PostToolUse": [{
      "hooks": [{
        "type": "command",
        "command": "id=$(jq -r .turn_id) && nyathing client keepalive \"$id\""
      }]
    }],
    "Stop": [{
      "hooks": [{
        "type": "command",
        "command": "id=$(jq -r .turn_id) && nyathing client stop \"$id\""
      }]
    }],
    "Interrupt": [{
      "hooks": [{
        "type": "command",
        "command": "id=$(jq -r .turn_id) && nyathing client stop \"$id\"",
        "timeout": 3
      }]
    }]
  }
}
```

`UserPromptSubmit` starts one activity per turn. Model responses and tool
calls refresh its keepalive; `Stop` and `Interrupt` stop it. The 90-second
keepalive interval gives the activity up to 180 seconds between refreshes,
subject to `max_wait_time`. A single long model request or tool call can still
outlast that timeout. Review and trust the hooks in Codex before using them.

#### <img src="assets/claude-code-icon.png" alt="" height="22" style="vertical-align: middle;"> Claude Code

See the [Claude Code hooks documentation](https://code.claude.com/docs/en/hooks).
Add these hooks to `~/.claude/settings.json`:

```json
{
  "hooks": {
    "UserPromptSubmit": [{
      "hooks": [{
        "type": "command",
        "command": "id=$(jq -r .session_id) && (nyathing client keepalive \"$id\" 2>/dev/null || nyathing client start --activity-id \"$id\" --keepalive-interval 90 >/dev/null)"
      }]
    }],
    "PreToolUse": [{
      "hooks": [{
        "type": "command",
        "command": "id=$(jq -r .session_id) && nyathing client keepalive \"$id\""
      }]
    }],
    "PostToolUse": [{
      "hooks": [{
        "type": "command",
        "command": "id=$(jq -r .session_id) && nyathing client keepalive \"$id\""
      }]
    }],
    "Stop": [{
      "hooks": [{
        "type": "command",
        "command": "id=$(jq -r .session_id) && nyathing client stop \"$id\" || true"
      }]
    }],
    "StopFailure": [{
      "hooks": [{
        "type": "command",
        "command": "id=$(jq -r .session_id) && nyathing client stop \"$id\" || true"
      }]
    }],
    "SessionEnd": [{
      "hooks": [{
        "type": "command",
        "command": "id=$(jq -r .session_id) && nyathing client stop \"$id\" || true"
      }]
    }]
  }
}
```

Claude Code's `session_id` stays the same across turns, so the prompt hook
first refreshes an existing activity and starts it only if it is missing.
Tool hooks refresh keepalive; `Stop` and `StopFailure` stop the activity.
Claude Code does not run `Stop` when you interrupt a turn. In that case, the
activity expires after its keepalive timeout; submitting another prompt in
the same session refreshes it. `SessionEnd` provides final cleanup. For long
assistant output, add this hook to the `hooks` object to refresh keepalive
for each displayed message batch:

```json
{
  "hooks": {
    "MessageDisplay": [{
      "hooks": [{
        "type": "command",
        "command": "id=$(jq -r .session_id) && nyathing client keepalive \"$id\""
      }]
    }]
  }
}
```

This can add command overhead while text streams. Claude Code does not expose
an equivalent of Codex's per-model-request event.

Keepalives are sent at hook boundaries, not on a timer. Configure
`max_wait_time` high enough for the longest gap between hooks. See
[Configuration](#-configuration) for the server-side limit.

## ⚡︎ Troubleshooting

Startup and runtime diagnostics are written to
`$XDG_STATE_HOME/nyathing/nyathing.log`, or
`~/.local/state/nyathing/nyathing.log` when `XDG_STATE_HOME` is unset. Startup
errors show an alert with an **Open Log** button. Configuration errors also
offer **Open Configuration**. Invalid animation files are logged and ignored.
If the socket path is already in use, quit the existing instance before
launching another. After correcting animation files, click **Accept** in the
**Edit Configuration** window to reload them.
