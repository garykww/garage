# 0010 — Context management: measured budget, elide old tool results

Date: 2026-07-10 · Status: accepted

## Context

131k tokens sounds infinite; tool output makes it not. Long sessions must
not die at the context wall. DESIGN.md §3.5 planned: per-result truncation
(done, 10k chars) → dropping old tool results → summarization.

## Decision

- **Measure, don't estimate.** The API returns exact `usage.prompt_tokens`
  every turn; the loop compares that to a configurable budget. No len/4
  heuristics.
- **When over budget, elide old tool results in place**: every `tool`
  message outside the most recent window (default: last 8 messages) has its
  content replaced with a short head plus an `[elided]` marker. The system
  prompt, the task, and all assistant messages stay intact.
- Messages are never *removed*: the wire protocol requires one tool result
  per `tool_call_id`, and deleting messages breaks that pairing (the server
  rejects orphaned calls). Blanking content preserves structure.
- Summarization is explicitly deferred: it adds an LLM call, latency, and a
  second nondeterministic system; elision is deterministic and visible in
  transcripts. If the agent starts failing because elided details mattered,
  that is the trigger for a summarization ADR.

## Trade-offs

- **Elision loses information.** Acceptable: old tool output is the
  cheapest information in the conversation to regenerate — the model can
  re-run the tool. The recent window keeps the working set.
- **Assistant messages are never elided** even though reasoning-heavy models
  bloat them: they carry the agent's plan and tool_call structure; token
  math says tool results dominate anyway.
- Budget lives in the Agent (off by default; the CLI sets 100k) so unit
  tests and library users aren't surprised.

## Consequences

The loop emits a "compact" event when it elides, so transcripts show
exactly what the model stopped seeing and when.
