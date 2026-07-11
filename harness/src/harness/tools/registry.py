"""Tool system: definition decorator, registry, dispatch (ADR 0005).

A tool is a plain function returning str, decorated with @tool(...). The
registry produces the OpenAI `tools` array and dispatches `tool_calls` back
to the functions. Errors and truncation are handled here, centrally: tool
failures become result text for the model, never exceptions past dispatch.
"""

from __future__ import annotations

import inspect
import json
from dataclasses import dataclass, field
from typing import Any, Callable

# What the model sees from one tool call is capped here, not in each tool.
# Head-heavy split: beginnings carry the signal (errors, headers), tails catch
# summaries and exit states.
MAX_OUTPUT_CHARS = 10_000
_HEAD, _TAIL = 7_000, 2_000


@dataclass(frozen=True)
class Tool:
    name: str
    description: str
    parameters: dict[str, Any]  # JSON schema, type "object"
    fn: Callable[..., str] = field(repr=False)

    def schema(self) -> dict[str, Any]:
        return {
            "type": "function",
            "function": {
                "name": self.name,
                "description": self.description,
                "parameters": self.parameters,
            },
        }

    def __call__(self, **kwargs: Any) -> str:
        return self.fn(**kwargs)


def tool(description: str, parameters: dict[str, Any]) -> Callable[[Callable[..., str]], Tool]:
    """Declare a tool. Schema is explicit; the function name is the tool name."""

    def wrap(fn: Callable[..., str]) -> Tool:
        t = Tool(name=fn.__name__, description=description, parameters=parameters, fn=fn)
        _check_schema_matches_signature(t)
        return t

    return wrap


def _check_schema_matches_signature(t: Tool) -> None:
    props = set(t.parameters.get("properties", {}))
    required = set(t.parameters.get("required", []))
    params = inspect.signature(t.fn).parameters
    args = set(params)
    if props != args:
        raise TypeError(f"tool {t.name!r}: schema properties {sorted(props)} != function parameters {sorted(args)}")
    if not required <= props:
        raise TypeError(f"tool {t.name!r}: required {sorted(required - props)} not in properties")
    optional_ok = {n for n, p in params.items() if p.default is not inspect.Parameter.empty}
    missing_default = args - required - optional_ok
    if missing_default:
        raise TypeError(f"tool {t.name!r}: non-required parameters {sorted(missing_default)} need defaults")


class ToolRegistry:
    def __init__(self, tools: tuple[Tool, ...] | list[Tool] = ()):
        self._tools: dict[str, Tool] = {}
        for t in tools:
            self.register(t)

    def register(self, t: Tool) -> None:
        if t.name in self._tools:
            raise ValueError(f"duplicate tool name {t.name!r}")
        self._tools[t.name] = t

    def schemas(self) -> list[dict[str, Any]]:
        """The `tools` array for the chat-completions request."""
        return [t.schema() for t in self._tools.values()]

    def dispatch(self, tool_call: dict[str, Any]) -> dict[str, Any]:
        """Execute one entry of an assistant message's tool_calls array.

        Always returns a wire-shape tool result message; failures (unknown
        tool, bad arguments, tool exception) are reported in the content so
        the model can react.
        """
        name = tool_call["function"]["name"]
        try:
            args = json.loads(tool_call["function"]["arguments"] or "{}")
            if not isinstance(args, dict):
                raise ValueError(f"arguments must be an object, got {type(args).__name__}")
        except (json.JSONDecodeError, ValueError) as e:
            return self._result(tool_call, f"error: could not parse arguments: {e}")

        t = self._tools.get(name)
        if t is None:
            known = ", ".join(self._tools) or "none"
            return self._result(tool_call, f"error: unknown tool {name!r}; available tools: {known}")

        try:
            out = t.fn(**args)
        except Exception as e:  # tool bugs are information, not crashes
            out = f"error: {type(e).__name__}: {e}"
        return self._result(tool_call, _truncate(out))

    @staticmethod
    def _result(tool_call: dict[str, Any], content: str) -> dict[str, Any]:
        return {"role": "tool", "tool_call_id": tool_call["id"], "content": content}


def _truncate(text: str) -> str:
    if len(text) <= MAX_OUTPUT_CHARS:
        return text
    elided = len(text) - _HEAD - _TAIL
    return f"{text[:_HEAD]}\n... [{elided} characters truncated] ...\n{text[-_TAIL:]}"
