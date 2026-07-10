"""LLM client: the only module that knows HTTP.

Speaks the OpenAI chat-completions wire format directly (ADR 0003).
Messages in and out are plain dicts in the wire shape (ADR 0004).
"""

from __future__ import annotations

import json
import time
from typing import Any, Callable, Iterable, Iterator

import httpx

from .config import Config

Message = dict[str, Any]

# Streaming callback: receives each content delta as it arrives.
OnText = Callable[[str], None]


class LLMError(Exception):
    """The server returned an error or an unusable response."""


class LLMClient:
    def __init__(self, config: Config, timeout: float = 120.0):
        self.config = config
        self.last_usage: dict[str, Any] | None = None
        self._http = httpx.Client(
            base_url=config.base_url,
            headers={"Authorization": f"Bearer {config.api_key}"},
            timeout=timeout,
        )

    def chat(
        self,
        messages: list[Message],
        tools: list[dict] | None = None,
        max_tokens: int = 4096,
        on_text: OnText | None = None,
    ) -> Message:
        """One completion round-trip. Returns the assistant message dict.

        With on_text set, the request streams (SSE): content deltas are
        passed to the callback as they arrive and the same final message
        shape is returned.
        """
        body: dict[str, Any] = {
            "model": self.config.model,
            "messages": messages,
            "max_tokens": max_tokens,
        }
        if tools:
            body["tools"] = tools

        if on_text is not None:
            return self._chat_stream(body, on_text)

        data = self._post_with_retry(body)
        self.last_usage = data.get("usage")
        try:
            return data["choices"][0]["message"]
        except (KeyError, IndexError) as e:
            raise LLMError(f"unexpected response shape: {data}") from e

    def _chat_stream(self, body: dict[str, Any], on_text: OnText) -> Message:
        # Single attempt, no retry: replaying a half-consumed stream would
        # feed duplicate deltas to on_text.
        body = {**body, "stream": True, "stream_options": {"include_usage": True}}
        try:
            with self._http.stream("POST", "/chat/completions", json=body) as resp:
                if resp.status_code >= 400:
                    resp.read()
                    raise LLMError(f"{resp.status_code}: {resp.text}")
                message, usage = accumulate_stream(iter_sse(resp.iter_lines()), on_text)
        except httpx.HTTPError as e:
            raise LLMError(f"stream failed: {e!r}") from e
        self.last_usage = usage
        return message

    def _post_with_retry(self, body: dict[str, Any], retries: int = 2) -> dict[str, Any]:
        """Retry connection failures and 5xx with linear backoff; 4xx is ours to fix."""
        for attempt in range(retries + 1):
            try:
                resp = self._http.post("/chat/completions", json=body)
                resp.raise_for_status()
                return resp.json()
            except httpx.HTTPStatusError as e:
                if e.response.status_code < 500:
                    raise LLMError(f"{e.response.status_code}: {e.response.text}") from e
                last = LLMError(f"{e.response.status_code}: {e.response.text}")
            except httpx.HTTPError as e:
                last = LLMError(f"request failed: {e!r}")
            if attempt < retries:
                time.sleep(1.0 * (attempt + 1))
        raise last

    def close(self) -> None:
        self._http.close()


def iter_sse(lines: Iterable[str]) -> Iterator[dict[str, Any]]:
    """Parse server-sent-event lines into chunk dicts, stopping at [DONE]."""
    for line in lines:
        line = line.strip()
        if not line.startswith("data:"):
            continue  # comments, blank keep-alives
        payload = line[len("data:"):].strip()
        if payload == "[DONE]":
            return
        yield json.loads(payload)


def accumulate_stream(
    chunks: Iterable[dict[str, Any]], on_text: OnText | None = None
) -> tuple[Message, dict[str, Any] | None]:
    """Fold streamed deltas into a final assistant message + usage.

    Content arrives as text fragments; tool calls arrive keyed by index,
    with the id/name once and the JSON arguments in pieces.
    """
    content_parts: list[str] = []
    tool_calls: dict[int, dict[str, Any]] = {}
    usage: dict[str, Any] | None = None

    for chunk in chunks:
        if chunk.get("usage"):
            usage = chunk["usage"]
        choices = chunk.get("choices") or []
        if not choices:
            continue
        delta = choices[0].get("delta") or {}
        if delta.get("content"):
            content_parts.append(delta["content"])
            if on_text:
                on_text(delta["content"])
        for tc in delta.get("tool_calls") or []:
            slot = tool_calls.setdefault(
                tc.get("index", 0),
                {"id": None, "type": "function", "function": {"name": "", "arguments": ""}},
            )
            if tc.get("id"):
                slot["id"] = tc["id"]
            fn = tc.get("function") or {}
            if fn.get("name"):
                slot["function"]["name"] += fn["name"]
            if fn.get("arguments"):
                slot["function"]["arguments"] += fn["arguments"]

    message: Message = {"role": "assistant", "content": "".join(content_parts) or None}
    if tool_calls:
        message["tool_calls"] = [tool_calls[i] for i in sorted(tool_calls)]
    return message, usage
