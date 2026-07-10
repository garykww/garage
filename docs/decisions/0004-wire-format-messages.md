# 0004 — Conversation state is the wire format

Date: 2026-07-10 · Status: accepted

## Context

The agent loop needs a representation for conversation history. Options: a
domain model (Message/ToolCall classes) mapped to/from the API shape, or the
API's own dict shape used directly.

## Decision

The message list is a `list[dict]` in exactly the OpenAI chat-completions
shape. The loop appends assistant responses and tool results as the API
expects to receive them back.

## Trade-offs

- **Replayability**: a logged transcript is byte-for-byte a valid request
  body — sessions can be replayed against the server with `curl`. This is the
  killer feature for a learning repo.
- **No translation bugs**: mapping layers between domain models and wire
  format are a classic source of subtle drift (dropped fields, wrong nesting).
- **Cost**: dicts give no IDE help and no validation; a typo in a key fails at
  the server, not at construction. Mitigation: helper constructors for the
  handful of message shapes, and the smoke test.
- Revisit if/when context management needs rich metadata per message
  (token counts, timestamps) — that may justify a wrapper that still
  serializes 1:1.

## Consequences

Anything non-standard (e.g. the backend's `reasoning` field) is stripped
before a message is sent back, in one well-marked place in the loop.
