"""Backend configuration, from environment variables with .env fallback."""

from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class Config:
    base_url: str
    api_key: str
    model: str

    @classmethod
    def from_env(cls) -> "Config":
        _load_dotenv(Path(".env"))
        try:
            return cls(
                base_url=os.environ["VLLM_BASE_URL"].rstrip("/"),
                api_key=os.environ["VLLM_API_KEY"],
                model=os.environ["VLLM_MODEL"],
            )
        except KeyError as e:
            raise SystemExit(
                f"Missing {e.args[0]} — copy .env.example to .env and fill it in."
            ) from None


def _load_dotenv(path: Path) -> None:
    # Deliberately minimal (KEY=VALUE lines, # comments); real env vars win.
    if not path.is_file():
        return
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        os.environ.setdefault(key.strip(), value.strip())
