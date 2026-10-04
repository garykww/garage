# Dell S3225QS Control

A native macOS menu bar app for the **Dell S3225QS**, controlling its **hardware brightness and built-in speaker volume** over HDMI or DisplayPort. Built and tested with an M2 Max MacBook Pro.

Project folder: `~/Workspace/garage/dell-s3225qs-control`.

## Run

Open `dist/Dell S3225QS Control.app`, then click the sun icon in the menu bar. Drag either slider and release to apply. Brightness presets are 25%, 50%, 75%, and 100%. Each change is read back from the monitor before it is reported as successful.

The volume slider changes the monitor’s built-in speaker level. Select the Dell as the output in macOS Sound settings to send audio to it. This app does not change the system’s selected output or play any sound.

For startup at login, add the app in **System Settings → General → Login Items**. Keep the app at the same location, or move it to Applications first.

## Build and test

Requires Apple Silicon, macOS 13+, and Xcode or the Swift command-line tools. No downloaded Swift package dependencies.

```sh
swift test
zsh build.sh
open "dist/Dell S3225QS Control.app"
```

`build.sh` creates a locally ad-hoc-signed app. It is not notarized for distribution to other Macs.

## Repository CI

Run `bash ci.sh` from this folder. Garage's existing workflow detects this app-local script automatically:

- On Ubuntu, Swift 5.9+ builds and tests the platform-independent `DisplayProtocol` target (packet framing, checksum validation, feature selection, and value decoding).
- On macOS, the same script also builds the native app and verifies its signature and bundle metadata.
- HDMI hardware checks are manual, so CI never changes a connected monitor's settings.

All targets and scripts live inside `dell-s3225qs-control`; there are no sibling-project dependencies. `.build`, `.swiftpm`, and `dist` are ignored. The shared workflows are unchanged.

Use a branch named `claude/<description>-<5-character-id>` and a PR containing only this app's files, as required by garage's `CLAUDE.md`.

## Command line

The app executable also supports terminal use:

```sh
"dist/Dell S3225QS Control.app/Contents/MacOS/DellS3225QSControl" list
"dist/Dell S3225QS Control.app/Contents/MacOS/DellS3225QSControl" get
"dist/Dell S3225QS Control.app/Contents/MacOS/DellS3225QSControl" set 50
"dist/Dell S3225QS Control.app/Contents/MacOS/DellS3225QSControl" volume-get
"dist/Dell S3225QS Control.app/Contents/MacOS/DellS3225QSControl" volume-set 20
```

With multiple monitors, append the numeric ID printed by `list` to any get/set command. IDs are valid for the current connection and may change after reconnecting. Without an ID, CLI commands target the first discovered external monitor. Quit the menu bar app before using CLI commands to avoid competing DDC requests.

`self-test [display-id]` temporarily changes brightness by one percentage point and volume by one point, verifies both, and restores their original percentages. It attempts restoration on errors; a disconnected or unresponsive display can prevent restoration. Intended for this Dell’s 0–100 scales.

## Monitor setup

- Enable **Others → DDC/CI → On** in the Dell’s own menu.
- Disable HDR if hardware brightness is unavailable; this Dell locks brightness while processing HDR content.
- Enable the monitor’s speakers to hear its HDMI/DisplayPort audio.
- Click Refresh after changing settings or reconnecting. The app also refreshes after display changes and wake.

An unavailable control stays disabled, with an explanation. There is no software overlay dimming fallback. Brightness and volume are independent: one can work even when the other is unavailable.

## Implementation and limits

SwiftUI/AppKit interface, IOKit display discovery, and dynamically loaded private `IOAVService` I²C functions. DDC/CI VCP `0x10` controls brightness and `0x62` controls speaker volume. Commands run off the UI thread, include protocol checksums, validate reply feature/value ranges, retry reads, and verify writes. Values scale against the maximum reported by the monitor.

Supports discoverable external Apple Silicon DCP display services. Intel Macs, DisplayLink docks, global keyboard media-key interception, and Apple built-in displays are outside this version’s scope. Multi-display selection is implemented but only the connected Dell has been hardware-tested. Private macOS interfaces may change with OS updates.

Protocol/API references: [m1ddc](https://github.com/waydabber/m1ddc), [DDC/CI VCP reference](https://www.ddcutil.com/vcpinfo_output/), and [Dell S3225QS manual](https://gzhls.at/blob/ldb/6/1/0/2/7d2a7036b0a5b24de06ca5dd18981c83cba8.pdf). Dell S3225QS Control is a separate Swift implementation and does not require MonitorControl, BetterDisplay, or m1ddc to be installed.

## Verified on this Mac

On 2026-10-04, the release executable detected **DELL S3225QS** and passed hardware read/write/read-back checks:

- Brightness: **50% → 51% → 50%**, original restored.
- Speaker volume: **1% → 0% → 1%**, original restored.
- Four unit tests cover request framing, 16-bit values, volume feature selection, and malformed/unsupported replies.

The app was launched locally. Automated visual inspection was unavailable because computer-use permissions were not granted.
