"""The agent loop (DESIGN.md §3.3).

Call the LLM; if the reply has tool calls, execute every one of them (the
API returns an array — parallel calls are wire-protocol correctness), append
one result per call id, repeat. A reply with no tool calls is the answer.

The loop owns the message list: it is the single source of truth for
conversation state, kept in wire shape (ADR 0004). Non-standard response
fields (e.g. this backend's `reasoning`) are stripped here, in one place,
before a message re-enters the conversation.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any, Callable

from .llm import LLMClient, Message
from .tools import ToolRegistry

# Observability hook: called with ("assistant", raw_message) after each LLM
# reply and ("tool_result", {"call": ..., "result": ...}) after each dispatch.
OnEvent = Callable[[str, dict[str, Any]], None]


@dataclass(frozen=True)
class AgentResult:
    text: str
    turns: int
    stop_reason: str  # "done" | "max_turns"


_ELIDED = "[elided to save context — re-run the tool if you need this again]"


class Agent:
    def __init__(
        self,
        client: LLMClient,
        registry: ToolRegistry,
        system_prompt: str,
        max_turns: int = 24,
        on_event: OnEvent | None = None,
        context_budget: int | None = None,
        keep_recent: int = 8,
    ):
        self.client = client
        self.registry = registry
        self.max_turns = max_turns
        self.on_event = on_event or (lambda kind, data: None)
        self.context_budget = context_budget
        self.keep_recent = keep_recent
        self.messages: list[Message] = [{"role": "system", "content": system_prompt}]

    def run(self, task: str) -> AgentResult:
        self.messages.append({"role": "user", "content": task})

        for turn in range(1, self.max_turns + 1):
            msg = self.client.chat(self.messages, tools=self.registry.schemas())
            self.on_event("assistant", msg)

            tool_calls = msg.get("tool_calls") or []
            assistant: Message = {"role": "assistant", "content": msg.get("content")}
            if tool_calls:
                assistant["tool_calls"] = tool_calls
            self.messages.append(assistant)

            if not tool_calls:
                return AgentResult(text=msg.get("content") or "", turns=turn, stop_reason="done")

            for call in tool_calls:
                result = self.registry.dispatch(call)
                self.on_event("tool_result", {"call": call, "result": result})
                self.messages.append(result)

            self._maybe_compact()

        return AgentResult(text="", turns=self.max_turns, stop_reason="max_turns")

    def _maybe_compact(self) -> None:
        """Elide old tool results when measured usage exceeds the budget.

        ADR 0010: messages are blanked, never removed — the protocol needs
        one tool result per tool_call_id, so structure must survive.
        """
        if not self.context_budget:
            return
        usage = self.client.last_usage or {}
        if usage.get("prompt_tokens", 0) <= self.context_budget:
            return
        elidable = self.messages[: -self.keep_recent]
        elided = 0
        for m in elidable:
            content = m.get("content") or ""
            if m["role"] == "tool" and not content.endswith(_ELIDED):
                m["content"] = f"{content[:120]}… {_ELIDED}"
                elided += 1
        if elided:
            self.on_event("compact", {"elided": elided, "prompt_tokens": usage.get("prompt_tokens")})
