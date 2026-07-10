"""File tools: read, write, edit-by-string-replace (ADR 0008).

Errors are raised as exceptions; dispatch converts them to result text for
the model. read_file returns plain content — no line-number prefixes — so
edit_file anchors match byte-for-byte.
"""

from __future__ import annotations

from pathlib import Path

from .registry import tool


@tool(
    description=(
        "Read a text file and return its content. For large files, use "
        "offset/limit to read a specific line range."
    ),
    parameters={
        "type": "object",
        "properties": {
            "path": {"type": "string", "description": "Absolute path to the file."},
            "offset": {
                "type": "integer",
                "description": "1-based line number to start from (default 1).",
            },
            "limit": {
                "type": "integer",
                "description": "Maximum number of lines to return (default all).",
            },
        },
        "required": ["path"],
    },
)
def read_file(path: str, offset: int = 1, limit: int = 0) -> str:
    text = Path(path).read_text()
    if offset <= 1 and limit <= 0:
        return text
    lines = text.splitlines(keepends=True)
    start = max(offset - 1, 0)
    end = start + limit if limit > 0 else len(lines)
    selected = lines[start:end]
    if not selected:
        return f"(no lines in range: file has {len(lines)} lines)"
    return "".join(selected)


@tool(
    description=(
        "Write content to a file, creating parent directories as needed and "
        "overwriting any existing file. For small changes to existing files, "
        "prefer edit_file."
    ),
    parameters={
        "type": "object",
        "properties": {
            "path": {"type": "string", "description": "Absolute path to the file."},
            "content": {"type": "string", "description": "Full file content to write."},
        },
        "required": ["path", "content"],
    },
)
def write_file(path: str, content: str) -> str:
    p = Path(path)
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(content)
    return f"wrote {len(content)} characters to {p}"


@tool(
    description=(
        "Edit a file by replacing an exact string. old_string must appear "
        "exactly once in the file — include enough surrounding context to "
        "make it unique. Read the file first to get the exact text."
    ),
    parameters={
        "type": "object",
        "properties": {
            "path": {"type": "string", "description": "Absolute path to the file."},
            "old_string": {
                "type": "string",
                "description": "Exact text to replace; must be unique in the file.",
            },
            "new_string": {"type": "string", "description": "Replacement text."},
        },
        "required": ["path", "old_string", "new_string"],
    },
)
def edit_file(path: str, old_string: str, new_string: str) -> str:
    p = Path(path)
    text = p.read_text()
    count = text.count(old_string)
    if count == 0:
        raise ValueError(
            "old_string not found in file — re-read the file and copy the exact text"
        )
    if count > 1:
        raise ValueError(
            f"old_string appears {count} times — include more surrounding context to make it unique"
        )
    if old_string == new_string:
        raise ValueError("old_string and new_string are identical")
    p.write_text(text.replace(old_string, new_string, 1))
    return f"edited {p}"


FILE_TOOLS = (read_file, write_file, edit_file)
