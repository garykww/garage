"""Connectivity smoke test: `python -m harness.smoke`.

Verifies the two behaviors the harness depends on:
1. a plain completion round-trips,
2. the model emits a native tool call when given a tool.
Exits nonzero on failure.
"""

from __future__ import annotations

import json
import sys

from .config import Config
from .llm import LLMClient


def main() -> int:
    client = LLMClient(Config.from_env())
    print(f"model: {client.config.model} @ {client.config.base_url}")

    # 1. plain completion
    msg = client.chat(
        [{"role": "user", "content": "Reply with exactly the word OK and nothing else."}],
        max_tokens=1024,
    )
    content = (msg.get("content") or "").strip()
    print(f"completion: {content!r}  usage={client.last_usage}")
    if "OK" not in content:
        print("FAIL: expected 'OK' in completion", file=sys.stderr)
        return 1

    # 2. native tool call
    tool = {
        "type": "function",
        "function": {
            "name": "get_weather",
            "description": "Get current weather for a city",
            "parameters": {
                "type": "object",
                "properties": {"city": {"type": "string"}},
                "required": ["city"],
            },
        },
    }
    msg = client.chat(
        [{"role": "user", "content": "What is the weather in Paris? Use the tool."}],
        tools=[tool],
    )
    calls = msg.get("tool_calls") or []
    if not calls:
        print(f"FAIL: no tool_calls in response: {msg}", file=sys.stderr)
        return 1
    fn = calls[0]["function"]
    args = json.loads(fn["arguments"])
    print(f"tool call: {fn['name']}({args})")
    if fn["name"] != "get_weather" or "city" not in args:
        print("FAIL: unexpected tool call shape", file=sys.stderr)
        return 1

    client.close()
    print("smoke test passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
