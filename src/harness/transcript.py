"""Session transcripts: one JSONL file per run.

"Observable by default" (DESIGN.md §4): when the agent misbehaves, the
transcript is the debugging tool. One event per line:

    {"t": "<iso timestamp>", "kind": "...", "data": {...}}

Kinds mirror the loop: "system" and "user" carry prompt text, "assistant"
carries the raw LLM message (including non-standard fields like reasoning,
before the loop strips them), "tool_result" carries the dispatched result,
"usage" carries token counts per turn, "result" closes the session.
"""

from __future__ import annotations

import datetime
import json
from pathlib import Path
from typing import Any


class Transcript:
    def __init__(self, path: Path | str):
        self.path = Path(path)
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self._fh = self.path.open("a")

    @classmethod
    def create(cls, directory: Path | str) -> "Transcript":
        stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
        return cls(Path(directory) / f"{stamp}.jsonl")

    def write(self, kind: str, data: Any) -> None:
        line = {
            "t": datetime.datetime.now().isoformat(timespec="seconds"),
            "kind": kind,
            "data": data,
        }
        self._fh.write(json.dumps(line, ensure_ascii=False) + "\n")
        self._fh.flush()  # a crash must not eat the evidence

    def close(self) -> None:
        self._fh.close()
