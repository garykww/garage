"""E2E tests hit the live vLLM server. Opt in with HARNESS_E2E=1 (ADR 0007)."""

import os

import pytest

from harness.config import Config
from harness.llm import LLMClient

if os.environ.get("HARNESS_E2E") != "1":
    pytest.skip(
        "e2e tests need the live LLM server; set HARNESS_E2E=1 to run",
        allow_module_level=True,
    )


@pytest.fixture(scope="session")
def client():
    c = LLMClient(Config.from_env())
    yield c
    c.close()
