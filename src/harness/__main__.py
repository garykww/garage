"""Minimal CLI: `python -m harness [--yes] "task"` (or task on stdin).

Prints each tool call and a result preview as the agent works, then the
final answer. Exits nonzero if the agent hit max_turns.

Mutating tool calls prompt y/N on the terminal (ADR 0009); --yes
auto-approves everything. Without a tty and without --yes, unapproved
calls are denied rather than hanging.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

from .agent import Agent
from .approval import GatedRegistry, Policy
from .config import Config
from .llm import LLMClient
from .prompt import build_system_prompt
from .tools import ToolRegistry
from .tools.bash import bash
from .tools.files import FILE_TOOLS


def _preview(text: str, limit: int = 160) -> str:
    text = " ".join(text.split())
    return text if len(text) <= limit else text[: limit - 3] + "..."


def _on_event(kind: str, data: dict) -> None:
    if kind == "assistant":
        for call in data.get("tool_calls") or []:
            fn = call["function"]
            try:
                args = json.loads(fn["arguments"])
                arg_str = ", ".join(f"{k}={_preview(str(v), 100)!r}" for k, v in args.items())
            except json.JSONDecodeError:
                arg_str = _preview(fn["arguments"])
            print(f"→ {fn['name']}({arg_str})")
    elif kind == "tool_result":
        print(f"  ← {_preview(data['result']['content'])}")


def _tty_asker(name: str, args: dict) -> bool:
    arg_str = ", ".join(f"{k}={_preview(str(v), 200)!r}" for k, v in args.items())
    try:
        with open("/dev/tty", "r+") as tty:
            tty.write(f"allow {name}({arg_str})? [y/N] ")
            tty.flush()
            return tty.readline().strip().lower() in ("y", "yes")
    except OSError:
        print(f"  (no tty — denying {name})", file=sys.stderr)
        return False


def main() -> int:
    argv = sys.argv[1:]
    auto_yes = "--yes" in argv or "-y" in argv
    argv = [a for a in argv if a not in ("--yes", "-y")]
    task = " ".join(argv).strip() or sys.stdin.read().strip()
    if not task:
        print('usage: python -m harness [--yes] "task"  (or task on stdin)', file=sys.stderr)
        return 2

    registry = GatedRegistry(
        ToolRegistry([bash, *FILE_TOOLS]),
        Policy(Path.cwd()),
        ask=(lambda name, args: True) if auto_yes else _tty_asker,
    )
    client = LLMClient(Config.from_env())
    agent = Agent(
        client,
        registry,
        system_prompt=build_system_prompt(Path.cwd()),
        on_event=_on_event,
    )
    result = agent.run(task)
    usage = client.last_usage or {}

    print()
    if result.stop_reason != "done":
        print(f"stopped: {result.stop_reason} after {result.turns} turns", file=sys.stderr)
        return 1
    print(result.text)
    print(
        f"\n[{result.turns} turns, {usage.get('prompt_tokens', '?')} prompt tokens in final turn]",
        file=sys.stderr,
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
