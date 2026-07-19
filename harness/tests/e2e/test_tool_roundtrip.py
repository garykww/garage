"""Milestone 2 gate: the model can run a command and see its output.

No agent loop yet — the round trip is driven by hand: ask → model emits a
bash tool call → registry executes it → result appended → model answers.
Graded by side effect: the answer must contain a random value that only
exists in a file the model had to cat (ADR 0007).
"""

import uuid

from harness.tools import ToolRegistry
from harness.tools.bash import bash


def test_bash_tool_roundtrip(client, tmp_path):
    secret = uuid.uuid4().hex[:12]
    (tmp_path / "secret.txt").write_text(secret + "\n")
    registry = ToolRegistry([bash])

    messages = [
        {
            "role": "user",
            "content": (
                f"Use the bash tool to read the file {tmp_path}/secret.txt "
                "and then tell me its exact contents."
            ),
        }
    ]
    msg = client.chat(messages, tools=registry.schemas())
    calls = msg.get("tool_calls") or []
    assert calls, f"model did not call a tool: {msg}"

    messages.append({"role": "assistant", "content": msg.get("content"), "tool_calls": calls})
    results = [registry.dispatch(c) for c in calls]
    assert any(secret in r["content"] for r in results), results
    messages.extend(results)

    final = client.chat(messages, tools=registry.schemas())
    assert secret in (final.get("content") or ""), final
