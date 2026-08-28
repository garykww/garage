"""Read and set macOS Finder color labels.

Finder labels live in the 32-byte ``com.apple.FinderInfo`` extended
attribute. The label color is stored in the low three bits of the final
byte (offset 31)::

    0 = none, 1 = red, 2 = orange, 3 = yellow, 4 = green,
    5 = blue, 6 = purple, 7 = gray

Every other byte of the attribute is preserved, so Finder's other
metadata (creation date, volume id, custom-icon flag, ...) is untouched.
"""

from __future__ import annotations

import subprocess
from pathlib import Path

FINDER_INFO_ATTR = "com.apple.FinderInfo"
FINDER_INFO_SIZE = 32
LABEL_OFFSET = 31
LABEL_MASK = 0x07

_LABELS = {
    "red": 1,
    "orange": 2,
    "yellow": 3,
    "green": 4,
    "blue": 5,
    "purple": 6,
    "gray": 7,
    "grey": 7,  # alias
}
_NAME_BY_VALUE = {
    0: "none",
    1: "red",
    2: "orange",
    3: "yellow",
    4: "green",
    5: "blue",
    6: "purple",
    7: "gray",
}
CLEAR_ALIASES = {"none", "clear", "off"}


class LabelError(Exception):
    """Raised when a label cannot be applied."""


def label_value(color: str) -> int:
    """Return the numeric FinderInfo value for *color*."""
    try:
        return _LABELS[color.lower()]
    except KeyError:
        valid = ", ".join(sorted(set(_LABELS)))
        raise ValueError(
            f"unknown label color {color!r} (choose from: {valid})"
        ) from None


def label_name(value: int) -> str:
    """Return the canonical color name for a FinderInfo label value."""
    try:
        return _NAME_BY_VALUE[value & LABEL_MASK]
    except KeyError:
        raise LabelError(f"unknown label value {value}") from None


def encode_label(finder_info: bytes, color: str) -> bytes:
    """Return *finder_info* with the label bits set to *color*.

    The input is truncated or zero-padded to 32 bytes; every byte except
    the label bits of byte 31 is preserved.
    """
    value = label_value(color)
    data = bytearray(finder_info[:FINDER_INFO_SIZE])
    data += b"\x00" * (FINDER_INFO_SIZE - len(data))
    data[LABEL_OFFSET] = (data[LABEL_OFFSET] & ~LABEL_MASK) | value
    return bytes(data)


def decode_label(finder_info: bytes | None) -> str:
    """Return the color name encoded in *finder_info* ('none' when absent)."""
    if not finder_info or len(finder_info) <= LABEL_OFFSET:
        return "none"
    return label_name(finder_info[LABEL_OFFSET])


def read_finder_info(path: Path | str) -> bytes | None:
    """Return the raw FinderInfo bytes for *path*, or None when unset."""
    proc = subprocess.run(
        ["xattr", "-px", FINDER_INFO_ATTR, str(path)],
        capture_output=True,
        text=True,
    )
    hex_data = proc.stdout.strip()
    if not hex_data:
        return None
    return bytes.fromhex(hex_data)


def write_finder_info(path: Path | str, data: bytes) -> None:
    """Replace the FinderInfo xattr on *path* with *data*.

    Note the argument order of ``xattr -w``: name first, then value.
    """
    proc = subprocess.run(
        ["xattr", "-wx", FINDER_INFO_ATTR, data.hex(), str(path)],
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0:
        raise LabelError(
            proc.stderr.strip() or f"xattr exited with {proc.returncode}"
        )


def get_label(path: Path | str) -> str:
    """Return the current label color name for *path*."""
    return decode_label(read_finder_info(path))


def set_label(path: Path | str, color: str) -> str:
    """Set *color* on *path* and return the canonical color name."""
    data = read_finder_info(path)
    write_finder_info(path, encode_label(data or b"", color))
    return label_name(label_value(color))


def clear_label(path: Path | str) -> None:
    """Reset the label bits on *path* to zero (FinderInfo is kept)."""
    data = read_finder_info(path)
    if data is None:
        return
    data = bytearray(data[:FINDER_INFO_SIZE].ljust(FINDER_INFO_SIZE, b"\x00"))
    data[LABEL_OFFSET] &= ~LABEL_MASK
    write_finder_info(path, bytes(data))
