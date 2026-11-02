<img src="./.github/logo.png" width="80" />

# TinyHand

[![Latest release](https://img.shields.io/github/v/release/nilbuild/tinyhand?display_name=tag&sort=semver&cacheSeconds=3600)](https://github.com/nilbuild/tinyhand/releases/latest)
[![Platform: macOS](https://img.shields.io/badge/platform-macOS-lightgrey)](https://tinyhand.app)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](./LICENSE)

A tiny hand on a stick that points at things on your Mac screen.

<img src="./.github/banner.jpg" alt="TinyHand: a tiny hand for your Mac" />

[![Download for macOS](https://img.shields.io/badge/Download_for_macOS-000000?style=for-the-badge&logo=apple&logoColor=white)](https://github.com/nilbuild/tinyhand/releases/latest/download/TinyHand.dmg)
[![Visit website](https://img.shields.io/badge/Visit_website-ffffff?style=for-the-badge&logo=safari&logoColor=black)](https://tinyhand.app)

macOS 13 or later, Apple Silicon and Intel.

## Install

Open `TinyHand.dmg`, drag TinyHand to Applications and allow **Accessibility** when asked. It needs that to animate clicks and draw. Screenshot mode also asks for **Screen Recording** permission when you first save a capture.

This fork adds drawing export, native pointer interaction, and freeform screenshots.
The download links above still refer to the upstream release, not these fork features.

## Use

| | |
|---|---|
| Click the menu bar icon, or **⌃⌥H** | Turn the pointer on or off |
| Right-click the menu bar icon | Menu and Settings |
| **Pointer** mode (default) | Click, double-click, right-click, and drag in macOS normally |
| **Draw** mode | Hold and drag to draw without clicking anything underneath |
| **Screenshot** mode | Drag a freeform shape, release, then click **Save** |
| Save button / **Save Drawing as PNG…** in the menu | Export your strokes to a transparent PNG |
| Hold **⌥ Option** in Draw or Screenshot mode | Temporarily interact with the app underneath (configurable in Settings) |
| **⌃⌥X** | Clear the drawing |
| **Esc** | Clear everything and turn the pointer off |

While the pointer is on, a small toolbar at the bottom of the screen lets you pick one of
36 hands or a laser dot, mute the tap sound, or exit.

### Save drawings and screenshots

In **Draw** mode, the save button exports all strokes since the last clear, including
lines that have faded. The PNG is cropped to the artwork with a transparent background;
the desktop and pointer are not included. Strokes on multiple displays retain their
desktop-relative positions. Clear, Esc, and turning the pointer off discard the drawing.

In **Screenshot** mode, draw around the content you want. The outline closes
automatically; click the save button or **Save Selected Area as PNG…** in the menu.
TinyHand captures the current screen contents inside the shape, cropped to its bounds,
with transparency outside it. The pointer, selection outline, toolbar, and drawing
overlays are excluded. A selection stays on the display where it started; draw again to
replace it, or clear it to select on another display.

Both actions open a standard save dialog so you choose the filename and destination.
Cancelling leaves your drawing or selection available to save again. If macOS denies
screen access, allow TinyHand in **System Settings → Privacy & Security → Screen
Recording**, then quit and reopen it if prompted.

### Development

```sh
swift build
swift test
swift run TinyHand --e2e-test
```

The E2E check needs Accessibility permission and a logged-in macOS desktop.
To also verify real PNG saves and record the flow over a privacy-safe native fixture,
grant Screen Recording permission and run `python3 scripts/capture-evidence.py dist/evidence`.
The output directory must not already exist. The fixture covers the primary display
during the recording and is closed when the check finishes.

If SwiftPM reports `safe.bareRepository is 'explicit'`, scope the workaround to the
build command rather than changing your global Git settings:

```sh
GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=safe.bareRepository GIT_CONFIG_VALUE_0=all swift test
```

## License

MIT. See [LICENSE](LICENSE).
