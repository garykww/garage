# posted-notes-widget

Sticky notes that live on your macOS desktop — a free-form board pinned just
above the desktop icons, plus a WidgetKit widget mirroring your latest notes
in Notification Center.

Two targets in one Xcode project:

- **PostedNotes** — a Dock-less background app (`LSUIElement`) that draws the
  board: a translucent panel sitting behind all normal windows.
  - Double-click empty board space (or hit **+**) to create a note and type
    directly into it.
  - Drag notes to arrange them; drag empty board space to move the whole board.
  - Hover a note and click **✕** to delete; a note left empty deletes itself.
  - Right-click the board for **New Note** / **Quit**.
- **PostedNotesWidget** — a WidgetKit extension showing your latest notes as
  sticky-note cards in small (1 note), medium (2), and large (5) sizes.

Notes (text + board position) are stored as JSON in the shared App Group
container, so the widget and app read the same file. The app reloads widget
timelines on every change; the widget also refreshes hourly so relative
timestamps stay fresh.

Widgets themselves can't accept text input (WidgetKit only allows buttons and
toggles via App Intents) — that's why note creation happens on the board, not
in the widget.

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

To add the widget: run the app once, then right-click the desktop →
**Edit Widgets…** → search "Posted Notes".

## Signing / app group

App-group data sharing only works when both targets are signed with a real
development certificate and the group ID is team-prefixed (`TEAMID.name`) —
ad-hoc signatures are silently denied and the widget would always see zero
notes. The team ID is hardcoded in `project.yml` and `Shared/NotesStore.swift`;
change both to build on another machine. CI (`ci.sh`) builds with
`CODE_SIGNING_ALLOWED=NO` and skips cleanly on non-macOS runners, so it never
needs the certificate.
