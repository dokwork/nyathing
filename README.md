# Nyathing

A native macOS menu bar animation player, built with Swift and AppKit.

## Step 3: Menu and runtime-state manual check

Build and launch from the repository root:

```sh
swift build
swift run nyathing
```

Open the main Nyathing menu and verify it provides About, Quit, Reset Disconnected
Count, Reload Configuration and Animations, and Open Configuration. Confirm Open
Configuration opens `config.toml`. Reset clears any visible warning count.

The app currently has no client API or activity generator: those arrive in
step 4. Consequently, active-animation aggregation and timeout warning/explosion
states cannot yet be triggered through the app. Once the API is implemented,
use it to start two distinct animations and multiple activities for one animation;
verify separate status items and an overlaid count for the shared item. Let an
activity time out and verify the warning icon/count and explosion animation.
Also verify warning-only behavior when `explosion_36x36.png` is missing or
invalid, that the count remains after the effect ends, and that reset clears it.
Status-item placement is managed by macOS and visibility may be limited when the
menu bar is crowded.

To check reload behavior, start the app and edit the configuration or animation
files, then choose Reload Configuration and Animations. Confirm the app remains
running, reloads the configured default animation, and clears active animations
and warning count. Quit and relaunch to verify normal startup. The configuration
is created at `$XDG_CONFIG_HOME/nyathing/config.toml`, or
`~/.config/nyathing/config.toml` when `XDG_CONFIG_HOME` is unset; its sibling
`animations/` directory is seeded with `ghost_36x36.png`.

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
