import json

import pytest

from harness.approval import GatedRegistry, Policy, bash_is_safe
from harness.tools import ToolRegistry, tool


@pytest.mark.parametrize(
    "command",
    [
        "ls -la /tmp",
        "cat /etc/hosts | grep local",
        "find . -name '*.py' | head -5 && pwd",
        "echo hello; date",
    ],
)
def test_safe_commands(command):
    assert bash_is_safe(command)


@pytest.mark.parametrize(
    "command",
    [
        "rm -rf /tmp/x",
        "echo hi > file.txt",          # redirect
        "cat $(rm -rf /)",             # command substitution
        "echo `date`",                 # backticks
        "FOO=1 ls",                    # env-assignment prefix
        "python3 -c 'print(1)'",       # interpreter
        "curl http://example.com",     # network
        "ls 'unclosed",                # unparseable
        "ls && rm x",                  # one bad segment poisons all
    ],
)
def test_unsafe_commands(command):
    assert not bash_is_safe(command)


def test_policy_rules(tmp_path):
    p = Policy(tmp_path)
    assert p.decide("read_file", {"path": "/anywhere"}) == "allow"
    assert p.decide("bash", {"command": "ls"}) == "allow"
    assert p.decide("bash", {"command": "rm x"}) == "ask"
    assert p.decide("write_file", {"path": str(tmp_path / "a.txt")}) == "allow"
    assert p.decide("write_file", {"path": "/etc/passwd"}) == "ask"
    assert p.decide("edit_file", {"path": str(tmp_path / "sub" / "b.py")}) == "allow"
    assert p.decide("mystery_tool", {}) == "ask"


@tool(
    description="Record that I ran",
    parameters={"type": "object", "properties": {}, "required": []},
)
def tracer() -> str:
    tracer_runs.append(1)
    return "ran"


tracer_runs: list[int] = []


def make_call(name="tracer", args=None):
    return {"id": "c1", "function": {"name": name, "arguments": json.dumps(args or {})}}


def test_gate_denied_call_never_executes(tmp_path):
    tracer_runs.clear()
    gated = GatedRegistry(ToolRegistry([tracer]), Policy(tmp_path), ask=lambda n, a: False)
    result = gated.dispatch(make_call())
    assert "denied" in result["content"] and result["tool_call_id"] == "c1"
    assert tracer_runs == []


def test_gate_approved_call_executes(tmp_path):
    tracer_runs.clear()
    asked = []
    gated = GatedRegistry(
        ToolRegistry([tracer]), Policy(tmp_path), ask=lambda n, a: asked.append(n) or True
    )
    assert gated.dispatch(make_call())["content"] == "ran"
    assert asked == ["tracer"] and tracer_runs == [1]


def test_gate_allowed_call_skips_asker(tmp_path):
    @tool(
        description="Safe echo",
        parameters={"type": "object", "properties": {"command": {"type": "string"}}, "required": ["command"]},
    )
    def bash(command: str) -> str:
        return "ok"

    gated = GatedRegistry(
        ToolRegistry([bash]),
        Policy(tmp_path),
        ask=lambda n, a: pytest.fail("asker must not be called for allowed calls"),
    )
    assert gated.dispatch(make_call("bash", {"command": "ls"}))["content"] == "ok"


def test_gate_bad_json_falls_through_to_registry(tmp_path):
    gated = GatedRegistry(ToolRegistry([tracer]), Policy(tmp_path), ask=lambda n, a: False)
    bad = {"id": "c1", "function": {"name": "tracer", "arguments": "{broken"}}
    assert "could not parse arguments" in gated.dispatch(bad)["content"]
