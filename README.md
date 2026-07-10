# harness

An experiment: build an AI agent harness **from scratch**, one small step at a time.

The goal is not to ship a product but to understand what an agent harness actually
is — the loop, the tool system, the context management — by writing every layer
ourselves against a plain OpenAI-compatible API, with no agent frameworks.

## Methodology

Three rules govern this repo:

1. **Design first.** Nothing gets built before it is written down in
   [docs/DESIGN.md](docs/DESIGN.md). The design doc is updated as understanding
   improves — it describes the current intent, not history.
2. **Small commits.** Every commit is one coherent step of progress that leaves
   the repo in a working state. If a commit is hard to summarize in one line,
   it is too big.
3. **Record every decision.** Non-obvious choices and their trade-offs are
   captured as Architecture Decision Records in
   [docs/decisions/](docs/decisions/). History matters: ADRs are never edited
   to pretend we always knew — they are superseded by new ones.

## LLM backend

Development runs against a local vLLM server:

| | |
|---|---|
| Endpoint | `http://nv-spark-01:8000/v1` (OpenAI-compatible) |
| Model | `RedHatAI/Qwen3.6-35B-A3B-NVFP4` |
| Context window | 131,072 tokens |
| Tool calling | Native (`tools` param, `finish_reason: "tool_calls"`) |
| Extras | Returns a `reasoning` field alongside content |

Configuration lives in `.env` (see `.env.example`). The API key is never
committed.

## Getting started

```sh
cp .env.example .env   # then fill in VLLM_API_KEY
uv sync
uv run python -m harness.smoke   # verify connectivity to the LLM server
```

## Running a task

```sh
cd /some/scratch/dir   # the agent works in your cwd
uv run --project /path/to/harness python -m harness "write fizzbuzz.py and verify it runs"
```

Tool calls stream to the terminal as they happen; the final answer prints at
the end. Exit code is nonzero if the agent gave up.

Read-only commands and writes inside the working directory run unprompted;
anything else asks `allow bash(command=...)? [y/N]` on the terminal
(ADR 0009). Pass `--yes` to auto-approve everything, e.g. in scripts —
without a tty, unapproved calls are denied rather than hanging.

## Tests

```sh
uv run pytest                            # unit tests, offline, fast
HARNESS_E2E=1 uv run pytest tests/e2e    # live capability gates vs the real server
```
