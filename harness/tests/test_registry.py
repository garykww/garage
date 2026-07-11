import json

import pytest

from harness.tools import ToolRegistry, tool
from harness.tools.registry import MAX_OUTPUT_CHARS, _truncate


def make_echo():
    @tool(
        description="Echo text back",
        parameters={
            "type": "object",
            "properties": {
                "text": {"type": "string"},
                "times": {"type": "integer"},
            },
            "required": ["text"],
        },
    )
    def echo(text: str, times: int = 1) -> str:
        return text * times

    return echo


def call(name, /, **args):
    return {"id": "call-1", "function": {"name": name, "arguments": json.dumps(args)}}


def test_schema_shape():
    echo = make_echo()
    assert echo.schema() == {
        "type": "function",
        "function": {
            "name": "echo",
            "description": "Echo text back",
            "parameters": echo.parameters,
        },
    }


def test_schema_signature_mismatch_rejected():
    with pytest.raises(TypeError, match="properties"):
        tool(description="x", parameters={"type": "object", "properties": {"wrong": {}}, "required": []})(
            lambda text: text
        )


def test_optional_param_without_default_rejected():
    def f(a: str, b: str) -> str:
        return a + b

    with pytest.raises(TypeError, match="need defaults"):
        tool(
            description="x",
            parameters={"type": "object", "properties": {"a": {}, "b": {}}, "required": ["a"]},
        )(f)


def test_dispatch_happy_path():
    reg = ToolRegistry([make_echo()])
    result = reg.dispatch(call("echo", text="hi", times=2))
    assert result == {"role": "tool", "tool_call_id": "call-1", "content": "hihi"}


def test_dispatch_unknown_tool():
    reg = ToolRegistry([make_echo()])
    content = reg.dispatch(call("nope"))["content"]
    assert "unknown tool" in content and "echo" in content


def test_dispatch_bad_json_arguments():
    reg = ToolRegistry([make_echo()])
    bad = {"id": "call-1", "function": {"name": "echo", "arguments": "{not json"}}
    assert "could not parse arguments" in reg.dispatch(bad)["content"]


def test_dispatch_tool_exception_becomes_result():
    @tool(description="Always fails", parameters={"type": "object", "properties": {}, "required": []})
    def boom() -> str:
        raise RuntimeError("kaput")

    content = ToolRegistry([boom]).dispatch(call("boom"))["content"]
    assert content == "error: RuntimeError: kaput"


def test_dispatch_wrong_argument_name_becomes_result():
    reg = ToolRegistry([make_echo()])
    assert reg.dispatch(call("echo", wrong="hi"))["content"].startswith("error: TypeError")


def test_truncation_keeps_head_and_tail():
    text = "A" * 8000 + "B" * 8000
    out = _truncate(text)
    assert len(out) < MAX_OUTPUT_CHARS
    assert out.startswith("A") and out.endswith("B") and "truncated" in out
    assert _truncate("short") == "short"


def test_duplicate_registration_rejected():
    with pytest.raises(ValueError, match="duplicate"):
        ToolRegistry([make_echo(), make_echo()])
