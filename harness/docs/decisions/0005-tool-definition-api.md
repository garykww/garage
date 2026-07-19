# 0005 — Tools are decorated functions with explicit schemas

Date: 2026-07-10 · Status: accepted

## Context

The tool system (DESIGN.md §3.2) needs a way to define a tool once and get
both the API-facing JSON schema and the executable. DESIGN.md originally
hoped to "derive the schema from the signature where possible". Options:

1. Derive schema from type hints + docstring introspection.
2. Pydantic models per tool (schema for free via `model_json_schema()`).
3. Decorator taking an explicit JSON-schema `parameters` dict.

## Decision

Option 3. A tool is a plain function returning `str`, decorated with
`@tool(description=..., parameters={...})`; name comes from the function
name. The registry turns tools into the OpenAI `tools` array and dispatches
`tool_calls` back to the functions.

## Trade-offs

- **Explicit schema** vs derivation: per-parameter *descriptions* are what
  actually steer the model, and no amount of introspection produces them —
  so a hand-written dict is largely unavoidable anyway. Derivation code is
  the fragile kind of magic this repo exists to avoid; writing the schema by
  hand keeps the wire format visible (consistent with ADR 0003/0004).
- vs **pydantic**: free validation and schemas, but a heavyweight dependency
  and a second modeling language between us and the wire. Not while learning.
- Cost: schema and signature can drift apart. Mitigated by a registry check
  at registration time (schema properties must match the function's
  parameters) — cheap, runs at import.

## Consequences

- Tool functions take keyword arguments matching the schema and return the
  string the model will see.
- Dispatch catches all exceptions and returns them as error text in the tool
  result — tools can be written naively (DESIGN.md: "fail softly in tools").
- Output truncation happens centrally in dispatch, not per tool.
- Supersedes the "derived from the signature" line in DESIGN.md §3.2.
