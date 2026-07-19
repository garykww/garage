# posted-notes-widget

A macOS desktop widget for sticky notes. Post a note in the companion app and it
shows up in a WidgetKit widget on your desktop / Notification Center.

Two targets in one Xcode project:

- **PostedNotes** — a small SwiftUI app: type a note, hit Post (or ⌘↩), delete
  notes with the ✕ button.
- **PostedNotesWidget** — a WidgetKit extension showing your latest notes as
  sticky-note cards, in small (1 note), medium (2), and large (5) sizes.

Notes are stored as JSON in the shared App Group container
(`group.dev.garage.posted-notes`), so the widget and app read the same file.
The app calls `WidgetCenter.reloadAllTimelines()` on every change, and the
widget also refreshes hourly so relative timestamps stay fresh.

## Build & run

Requires Xcode and [xcodegen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`). The `.xcodeproj` is generated, not committed.

```bash
xcodegen generate
open PostedNotes.xcodeproj   # then run the PostedNotes scheme
```

Or from the CLI:

```bash
./ci.sh   # xcodegen generate + xcodebuild (unsigned)
```

After running the app once, add the widget: right-click the desktop →
**Edit Widgets…** → search "Posted Notes".

## Caveats (it's a garage prototype)

- Ad-hoc signed with no development team, so macOS may warn about the App Group
  entitlement on first launch. If the group container is unavailable, storage
  falls back to Application Support — the app still works but the widget won't
  see the notes until proper signing is set up.
- CI (`ci.sh`) skips cleanly on non-macOS runners.
