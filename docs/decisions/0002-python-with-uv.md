# 0002 — Python 3.12+ managed with uv

Date: 2026-07-10 · Status: accepted

## Context

Need a language and toolchain for the harness. Candidates: Python,
TypeScript/Node, Go, Rust.

## Decision

Python ≥3.12, dependencies and virtualenv managed by `uv`, single package
`harness/` under `src/` layout.

## Trade-offs

- **Python** vs **TypeScript**: both fine for I/O-bound agent work. Python wins
  on iteration speed for an experiment and on ecosystem proximity to vLLM
  (same team debugging both sides). TypeScript would win for a rich TUI later —
  accepted risk, revisit if milestone "CLI" outgrows plain text.
- **Python** vs **Go/Rust**: static binaries and real concurrency are
  irrelevant here; the bottleneck is always the LLM round-trip. Not worth the
  iteration cost for an experiment.
- **uv** vs pip/poetry: uv is fast, lockfile-based, and one tool for
  python-version + venv + deps. No downside observed at this scale.

## Consequences

`pyproject.toml` + `uv.lock` at repo root. Anything needing performance later
gets measured first, rewritten never (probably).
