"""Command-line interface for macos_file_label."""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

import macos_file_label as mfl

COLORS = "red, orange, yellow, green, blue, purple, gray"


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="macos-file-label",
        description=(
            "Show or set the macOS Finder color label of a file or folder."
        ),
    )
    parser.add_argument("path", nargs="?", help="file or directory")
    parser.add_argument(
        "color",
        nargs="?",
        default=None,
        help=f"one of {COLORS} (or 'none' to clear the label)",
    )
    parser.add_argument(
        "--list",
        action="store_true",
        dest="list_colors",
        help="list the available colors and exit",
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)

    if args.list_colors:
        print(f"Available colors: {COLORS} (use 'none' to clear)")
        return 0

    if args.path is None:
        print(
            "error: the following arguments are required: path",
            file=sys.stderr,
        )
        return 2

    path = Path(args.path)
    if not path.exists():
        print(f"error: {path} does not exist", file=sys.stderr)
        return 1

    if args.color is None:
        print(mfl.get_label(path))
        return 0

    color = args.color.lower()
    if color in mfl.CLEAR_ALIASES:
        mfl.clear_label(path)
        print("none")
        return 0

    try:
        name = mfl.set_label(path, color)
    except ValueError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2
    except mfl.LabelError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    except FileNotFoundError:
        print(
            "error: the xattr tool was not found (macOS only)",
            file=sys.stderr,
        )
        return 1

    print(name)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
