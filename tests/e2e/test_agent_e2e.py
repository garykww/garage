"""Milestone 3 gate: multi-turn tasks complete end-to-end (ADR 0007).

Each test grades one capability by an observable effect:
- act_and_verify: agent creates a file → graded by disk state.
- gather_across_files: answer needs two tool observations combined →
  graded by a random secret in the final answer.
- error_recovery: the obvious first command fails (wrong filename) →
  agent must adapt (ls, then read the real file) rather than repeat or quit.
"""

import json
import uuid
from pathlib import Path

import pytest

from harness.agent import Agent
from harness.prompt import build_system_prompt
from harness.tools import ToolRegistry
from harness.tools.bash import bash

TRANSCRIPT_DIR = Path(".e2e-transcripts")


@pytest.fixture
def agent(client, tmp_path, request):
    a = Agent(
        client,
        ToolRegistry([bash]),
        system_prompt=build_system_prompt(tmp_path),
        max_turns=10,
    )
    yield a
    # Always dump the transcript: a failed e2e run without one is undebuggable
    # (ADR 0007 — investigate, don't retry).
    TRANSCRIPT_DIR.mkdir(exist_ok=True)
    path = TRANSCRIPT_DIR / f"{request.node.name}.json"
    path.write_text(json.dumps(a.messages, indent=2))


def test_act_and_verify(agent, tmp_path):
    marker = uuid.uuid4().hex[:12]
    result = agent.run(
        f"Create a file named out/result.txt (relative to {tmp_path}) "
        f"containing exactly the line: {marker}"
    )
    assert result.stop_reason == "done", result
    assert (tmp_path / "out" / "result.txt").read_text().strip() == marker
    assert result.turns > 1, "should have used at least one tool turn"


def test_gather_across_files(agent, tmp_path):
    a, b = uuid.uuid4().hex[:8], uuid.uuid4().hex[:8]
    (tmp_path / "part1.txt").write_text(a + "\n")
    (tmp_path / "part2.txt").write_text(b + "\n")
    result = agent.run(
        f"Read {tmp_path}/part1.txt and {tmp_path}/part2.txt and tell me the "
        "two values concatenated (part1 then part2, no separator)."
    )
    assert result.stop_reason == "done", result
    assert a + b in result.text.replace(" ", ""), result.text


def test_error_recovery(agent, tmp_path):
    secret = uuid.uuid4().hex[:12]
    (tmp_path / "data.log").write_text(secret + "\n")  # not data.txt!
    result = agent.run(
        f"Tell me the exact contents of {tmp_path}/data.txt. "
        "If something is off, figure it out from what's in the directory."
    )
    assert result.stop_reason == "done", result
    assert secret in result.text, result.text
    # confirm recovery actually happened: some tool result reported the miss
    tool_contents = [m["content"] for m in agent.messages if m["role"] == "tool"]
    assert any("No such file" in c or "exit code" in c for c in tool_contents), (
        "expected the first attempt to fail"
    )
