"""E2E tests hit the live vLLM server. Opt in with HARNESS_E2E=1 (ADR 0007)."""

import json
import os
from pathlib import Path

import pytest

from harness.agent import Agent
from harness.approval import GatedRegistry, Policy
from harness.config import Config
from harness.llm import LLMClient
from harness.prompt import build_system_prompt
from harness.tools import ToolRegistry

if os.environ.get("HARNESS_E2E") != "1":
    pytest.skip(
        "e2e tests need the live LLM server; set HARNESS_E2E=1 to run",
        allow_module_level=True,
    )

TRANSCRIPT_DIR = Path(".e2e-transcripts")


@pytest.fixture(scope="session")
def client():
    c = LLMClient(Config.from_env())
    yield c
    c.close()


@pytest.fixture
def agent_factory(client, tmp_path, request):
    """Build agents rooted at tmp_path; dump every transcript after the test.

    A failed e2e run without a transcript is undebuggable (ADR 0007 —
    investigate, don't retry).
    """
    agents: list[Agent] = []

    def make(tools, max_turns: int = 10, ask=None, **agent_kwargs) -> Agent:
        registry = ToolRegistry(tools)
        if ask is not None:
            registry = GatedRegistry(registry, Policy(tmp_path), ask)
        a = Agent(
            client,
            registry,
            system_prompt=build_system_prompt(tmp_path),
            max_turns=max_turns,
            **agent_kwargs,
        )
        agents.append(a)
        return a

    yield make
    TRANSCRIPT_DIR.mkdir(exist_ok=True)
    for i, a in enumerate(agents):
        suffix = f"-{i}" if i else ""
        path = TRANSCRIPT_DIR / f"{request.node.name}{suffix}.json"
        path.write_text(json.dumps(a.messages, indent=2))
