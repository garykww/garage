"""Approval gate (ADR 0009): policy between the loop and tool execution.

Deny-by-default: the classifier only ever grants a narrow, parseable,
read-only subset; everything else asks. Denials return to the model as
tool-result text, mirroring tool errors.
"""

from __future__ import annotations

import json
import re
import shlex
from pathlib import Path
from typing import Any, Callable

from .tools import ToolRegistry

# Read-only programs safe to run unprompted. Deliberately narrow: no
# interpreters (python can do anything), no network, no archivers.
SAFE_BASH_COMMANDS = frozenset(
    "ls cat head tail wc grep rg find pwd echo printf which env uname date "
    "stat file du df ps diff sort uniq tr cut basename dirname realpath "
    "true false type xxd hexdump".split()
)

# Substrings that can smuggle writes or execution into a "safe" command.
_UNSAFE_SUBSTRINGS = (">", "$(", "`", "<(", ">(")

_SEGMENT_SPLIT = re.compile(r"&&|\|\||\||;|\n")

# Asker: called with (tool_name, parsed_args); True means run it.
Asker = Callable[[str, dict[str, Any]], bool]


def bash_is_safe(command: str) -> bool:
    """True only for pipelines of allowlisted read-only programs."""
    if any(s in command for s in _UNSAFE_SUBSTRINGS):
        return False
    for segment in _SEGMENT_SPLIT.split(command):
        segment = segment.strip()
        if not segment:
            continue
        try:
            words = shlex.split(segment)
        except ValueError:
            return False
        if not words or "=" in words[0] or words[0] not in SAFE_BASH_COMMANDS:
            return False
    return True


class Policy:
    """Decide per tool call: "allow" (run unprompted) or "ask"."""

    def __init__(self, workdir: Path | str):
        self.workdir = Path(workdir).resolve()

    def decide(self, tool_name: str, args: dict[str, Any]) -> str:
        if tool_name == "read_file":
            return "allow"
        if tool_name == "bash":
            return "allow" if bash_is_safe(str(args.get("command", ""))) else "ask"
        if tool_name in ("write_file", "edit_file"):
            path = Path(str(args.get("path", ""))).resolve()
            return "allow" if path.is_relative_to(self.workdir) else "ask"
        return "ask"  # unknown tools are nobody's to auto-approve


class GatedRegistry:
    """Wraps a ToolRegistry with the same interface; the loop can't tell."""

    def __init__(self, registry: ToolRegistry, policy: Policy, ask: Asker):
        self._registry = registry
        self._policy = policy
        self._ask = ask

    def schemas(self) -> list[dict[str, Any]]:
        return self._registry.schemas()

    def dispatch(self, tool_call: dict[str, Any]) -> dict[str, Any]:
        name = tool_call["function"]["name"]
        try:
            args = json.loads(tool_call["function"]["arguments"] or "{}")
            if not isinstance(args, dict):
                args = {}
        except json.JSONDecodeError:
            # let the registry produce its usual parse-error result
            return self._registry.dispatch(tool_call)

        if self._policy.decide(name, args) == "ask" and not self._ask(name, args):
            return {
                "role": "tool",
                "tool_call_id": tool_call["id"],
                "content": (
                    "denied: the user declined to allow this tool call. "
                    "Do not retry it verbatim — adapt your approach or report why it was needed."
                ),
            }
        return self._registry.dispatch(tool_call)
