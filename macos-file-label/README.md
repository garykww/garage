# macos-file-label

Read and set the macOS Finder color label (red, orange, yellow, green,
blue, purple, gray) of any file or folder from the command line.

Finder stores labels in the 32-byte `com.apple.FinderInfo` extended
attribute; the color lives in the low three bits of the last byte. This
tool flips those bits via the `xattr` CLI and preserves every other byte,
so Finder's other metadata is left untouched. No `setfile` (deprecated)
and no Objective-C needed.

## Install

```bash
pip install -e .
```

## Usage

```bash
macos-file-label photo.png            # show current label
macos-file-label photo.png red        # set the red label
macos-file-label ~/Projects blue      # works on folders too
macos-file-label photo.png none       # clear the label
macos-file-label --list               # available colors
```

Or without installing:

```bash
python -m macos_file_label photo.png yellow
```

Colors: `red`, `orange`, `yellow`, `green`, `blue`, `purple`, `gray`
(`grey` accepted as an alias).

## As a library

```python
from macos_file_label import get_label, set_label, clear_label

set_label("report.pdf", "green")   # -> "green"
get_label("report.pdf")            # -> "green"
clear_label("report.pdf")
```

## Notes

- macOS only (Finder labels and the `xattr` tool are not available
  elsewhere).
- `set_label` creates the `FinderInfo` attribute from scratch if it does
  not exist yet; `clear_label` only zeroes the label bits and keeps the
  attribute.
- On volumes where extended attributes are disabled, writes fail with a
  clear error message.

## Development

```bash
python3 -m venv .venv && . .venv/bin/activate
pip install -e ".[dev]"
pytest --tb=short
```

Tests mock the `xattr` subprocess calls so the suite runs on any OS,
including the Linux CI runner.
