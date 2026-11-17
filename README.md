# Nyathing

A native macOS menu bar animation player, built with Swift and AppKit.

## Step 2: Configuration and animation manual check

Build and launch from the repository root:

```sh
swift build
swift run nyathing
```

On first launch, Nyathing creates a fully populated configuration at
`$XDG_CONFIG_HOME/nyathing/config.toml`, or `~/.config/nyathing/config.toml`
when `XDG_CONFIG_HOME` is unset, and seeds its sibling `animations/` directory
with the built-in `ghost_36x36.png` sprite sheet. The app reads the four
settings shown in that file; duration values must be positive, and
`default_animation` must name a valid PNG in `animations/`.

Confirm the ghost animates in the menu bar at 10 frames per second and Nyathing
does not appear in the Dock. To check validation, stop the app, make a copy of
the valid PNG, then rename the copy with an unsupported size such as
`bad_40x40.png` or alter the configured default filename to a missing file.
Relaunch and inspect the terminal for the validation error; the app remains
runnable and displays its built-in ghost fallback. Restore the configuration
and asset, then relaunch to verify normal sprite playback. Stop the app with
Control-C and confirm the menu bar icon disappears.

Configuration template:

```toml
# Seconds between client keepalive messages; must be greater than zero.
keepalive_interval_seconds = 5
# Seconds without a keepalive before an activity expires; must be greater than zero.
activity_timeout_seconds = 5
# Whether Nyathing should install a user LaunchAgent (implemented in a later step).
auto_start = false
# Animation filename in the sibling animations directory.
default_animation = "ghost_36x36.png"
```
