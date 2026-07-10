"""Minimal CLI: `python -m harness "task"` (or task on stdin).

Prints each tool call and a result preview as the agent works, then the
final answer. Exits nonzero if the agent hit max_turns.

WARNING: there is no approval gate yet (milestone 5) — the agent runs
shell commands unattended in your current directory. Run real tasks in a
scratch directory.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

from .agent import Agent
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


def main() -> int:
    task = " ".join(sys.argv[1:]).strip() or sys.stdin.read().strip()
    if not task:
        print("usage: python -m harness \"task\"  (or task on stdin)", file=sys.stderr)
        return 2

    client = LLMClient(Config.from_env())
    agent = Agent(
        client,
        ToolRegistry([bash, *FILE_TOOLS]),
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
