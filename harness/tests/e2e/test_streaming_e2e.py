"""Milestone 8 gate: streaming works against the live server.

Graded mechanically: deltas arrive in multiple pieces, their concatenation
equals the returned message, usage still arrives (via stream_options), and
a streamed tool call assembles into valid JSON arguments.
"""

import json

from harness.tools import ToolRegistry
from harness.tools.bash import bash


def test_streamed_completion_matches_deltas(client):
    deltas = []
    msg = client.chat(
        [{"role": "user", "content": "Count from 1 to 30 as plain text, comma separated."}],
        on_text=deltas.append,
    )
    assert len(deltas) > 1, "expected multiple stream chunks"
    assert "".join(deltas) == msg["content"]
    assert "17" in msg["content"]
    assert client.last_usage and client.last_usage["completion_tokens"] > 0


def test_streamed_tool_call_assembles(client, tmp_path):
    registry = ToolRegistry([bash])
    msg = client.chat(
        [{"role": "user", "content": f"Use the bash tool to list the files in {tmp_path}."}],
        tools=registry.schemas(),
        on_text=lambda t: None,
    )
    calls = msg.get("tool_calls") or []
    assert calls and calls[0]["id"], msg
    args = json.loads(calls[0]["function"]["arguments"])
    assert "command" in args
