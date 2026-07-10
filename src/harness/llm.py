"""LLM client: the only module that knows HTTP.

Speaks the OpenAI chat-completions wire format directly (ADR 0003).
Messages in and out are plain dicts in the wire shape (ADR 0004).
"""

from __future__ import annotations

from typing import Any

import httpx

from .config import Config

Message = dict[str, Any]


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
    ) -> Message:
        """One completion round-trip. Returns the assistant message dict."""
        body: dict[str, Any] = {
            "model": self.config.model,
            "messages": messages,
            "max_tokens": max_tokens,
        }
        if tools:
            body["tools"] = tools

        try:
            resp = self._http.post("/chat/completions", json=body)
            resp.raise_for_status()
        except httpx.HTTPStatusError as e:
            raise LLMError(f"{e.response.status_code}: {e.response.text}") from e
        except httpx.HTTPError as e:
            raise LLMError(f"request failed: {e!r}") from e

        data = resp.json()
        self.last_usage = data.get("usage")
        try:
            return data["choices"][0]["message"]
        except (KeyError, IndexError) as e:
            raise LLMError(f"unexpected response shape: {data}") from e

    def close(self) -> None:
        self._http.close()
