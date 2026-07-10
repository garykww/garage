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
from .transcript import Transcript

SESSIONS_DIR = Path.home() / ".harness" / "sessions"


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

    workdir = Path.cwd()
    agents_md = workdir / "AGENTS.md"
    project_notes = agents_md.read_text() if agents_md.is_file() else None
    system_prompt = build_system_prompt(workdir, project_notes)

    registry = GatedRegistry(
        ToolRegistry([bash, *FILE_TOOLS]),
        Policy(workdir),
        ask=(lambda name, args: True) if auto_yes else _tty_asker,
    )
    client = LLMClient(Config.from_env())
    transcript = Transcript.create(SESSIONS_DIR)
    transcript.write("system", system_prompt)
    transcript.write("user", task)

    turn = 0
    total = {"prompt_tokens": 0, "completion_tokens": 0}

    def on_event(kind: str, data: dict) -> None:
        nonlocal turn
        _on_event(kind, data)
        transcript.write(kind, data)
        if kind == "assistant":
            turn += 1
            usage = client.last_usage or {}
            for k in total:
                total[k] += usage.get(k) or 0
            transcript.write("usage", usage)
            print(
                f"  [turn {turn}: {usage.get('prompt_tokens', '?')} prompt, "
                f"{usage.get('completion_tokens', '?')} completion tokens]",
                file=sys.stderr,
            )

    agent = Agent(client, registry, system_prompt=system_prompt, on_event=on_event)
    result = agent.run(task)
    transcript.write("result", {"stop_reason": result.stop_reason, "turns": result.turns, "total": total})
    transcript.close()

    print()
    if result.stop_reason != "done":
        print(f"stopped: {result.stop_reason} after {result.turns} turns", file=sys.stderr)
        print(f"[transcript: {transcript.path}]", file=sys.stderr)
        return 1
    print(result.text)
    print(
        f"\n[{result.turns} turns, {total['prompt_tokens']} prompt + "
        f"{total['completion_tokens']} completion tokens | transcript: {transcript.path}]",
        file=sys.stderr,
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
