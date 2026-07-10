# 0003 — Raw HTTP client, not the openai SDK

Date: 2026-07-10 · Status: accepted

## Context

The vLLM server speaks the OpenAI-compatible chat-completions protocol. The
`openai` Python SDK would work against it out of the box.

## Decision

Talk to the server with plain HTTP (`httpx`), building request bodies and
parsing responses ourselves. Messages are kept as plain dicts in the wire
format.

## Trade-offs

- **From-scratch fidelity**: the point of this repo is to see every moving
  part. The SDK hides exactly the parts we want to learn — request shape,
  streaming (SSE) parsing, tool-call deltas.
- **Cost**: we reimplement things the SDK gives free — retries, typed models,
  SSE handling. Accepted: each is small, and building SSE parsing by hand is a
  feature of the experiment, not a bug.
- **Non-standard fields**: our backend returns `reasoning`; with raw dicts we
  see it immediately instead of it being dropped by SDK models.
- **httpx** vs stdlib `urllib`: httpx costs one dependency but gives sane
  timeouts, connection reuse, and native streaming; stdlib would make the code
  about plumbing instead of about the protocol.

## Consequences

`harness/llm.py` is the single place that knows HTTP. If this ever becomes
more than an experiment, swapping in an SDK is a one-file change.
