# Design: an agent harness from scratch

Status: living document. Updated as understanding improves; decisions and their
trade-offs are recorded separately in [decisions/](decisions/).

## 1. What is a harness?

An LLM predicts text. An *agent* is an LLM given the ability to act: it emits
structured tool calls, something executes them, and the results are fed back
until the task is done. The **harness** is that "something" — everything around
the model:

```
┌────────────────────────── harness ──────────────────────────┐
│                                                              │
│   ┌─────────┐    messages     ┌─────────────┐                │
│   │  agent  │ ──────────────▶ │  LLM client │ ──▶ vLLM API   │
│   │  loop   │ ◀────────────── │             │ ◀── response   │
│   └────┬────┘   assistant msg └─────────────┘                │
│        │ tool calls                                          │
│        ▼                                                     │
│   ┌─────────┐                 ┌─────────────┐                │
│   │  tool   │ ──dispatch────▶ │ tools:      │                │
│   │ registry│ ◀──results───── │ bash, read, │                │
│   └─────────┘                 │ write, ...  │                │
│                                └─────────────┘               │
└──────────────────────────────────────────────────────────────┘
```

The interesting problems are all in the harness, not the model:
how tools are described, how results are truncated, how the loop terminates,
how context is kept within budget, how failures surface.

## 2. Goals and non-goals

**Goals**

- Understand every layer by building it: no agent frameworks, no SDK magic.
  Plain HTTP to an OpenAI-compatible endpoint.
- A working coding-agent CLI at the end: give it a task, it edits files and
  runs commands in a workspace until done.
- Every layer small enough to read in one sitting.

**Non-goals**

- Multi-provider support. One backend (vLLM, OpenAI-compatible) is enough to
  learn the shape; abstraction can come later if ever.
- Production concerns: auth, sandboxing beyond basics, rate limiting, retries
  beyond the trivial. Noted where they'd go, not built.
- Multi-agent orchestration — until the single loop is solid.

## 3. Architecture

Layers, each depending only on the ones above it:

### 3.1 LLM client (`harness/llm.py`)

The only piece that knows HTTP. Exposes `chat(messages, tools) -> Message`.
Speaks the OpenAI chat-completions wire format directly (dicts in, dicts out
at first; typed later if it earns it). Handles: auth header, timeouts, the
`reasoning` field our backend returns, and eventually streaming.

### 3.2 Tool system (`harness/tools/`)

A tool is: a name, a description, a JSON-schema for parameters, and a Python
function. A registry maps names to tools and produces the `tools` array for
the API. Design intent:

- Defining a tool should be one decorator on a plain function; the schema is
  derived from the signature where possible.
- Tool *output* is always a string (what the model sees). Truncation policy
  lives here, not in each tool.
- Errors from tools are returned to the model as tool results, never raised
  past the loop — a failed command is information, not a crash.

Initial tool set, in order of addition: `bash`, `read_file`, `write_file`,
`edit_file`. That is enough for a coding agent.

### 3.3 Agent loop (`harness/agent.py`)

The core: append user message → call LLM → if the reply has tool calls,
execute them, append results, repeat → else return the text. Explicit limits:
max turns, max consecutive tool errors. The loop owns the message list — it is
the single source of truth for conversation state.

### 3.4 Context management (later milestone)

131k tokens is a lot but not infinite, and tool output eats it fast. Planned,
in this order of sophistication: per-result truncation → dropping old tool
results → summarization. Token counting starts as a crude `len/4` estimate;
measured against `usage` from the API before anything smarter is built.

### 3.5 CLI (`harness/cli.py`)

Thin. Reads a task from argv or stdin, streams the agent's progress (each tool
call and result summary printed as it happens), exits nonzero on failure.
No TUI until the plain version hurts.

## 4. Guiding constraints

- **Observable by default.** Every LLM request/response and tool invocation can
  be logged verbatim (JSONL). When the agent misbehaves, the transcript is the
  debugging tool.
- **The wire format is the API.** Internal message representation stays close
  to the OpenAI dict shape so a transcript is replayable against the server
  as-is.
- **Fail loudly in the harness, softly in the tools.** Harness bugs should
  crash; tool failures should flow back to the model.

## 5. Milestones

Each milestone is a handful of small commits; each commit leaves `main`
working.

| # | Milestone | Done when |
|---|-----------|-----------|
| 0 | Repo, design, decisions | this document exists |
| 1 | LLM client + smoke test | `python -m harness.smoke` round-trips the server |
| 2 | Tool registry + bash tool | model can run a command and see output |
| 3 | Agent loop | multi-turn task completes end-to-end |
| 4 | File tools (read/write/edit) | agent can make a code change |
| 5 | CLI + transcript logging | usable from the terminal, sessions replayable |
| 6 | Context management | long sessions stay under budget |
| 7 | Streaming output | tokens render as they arrive |

## 6. Backend facts (measured 2026-07-10)

- Endpoint `http://nv-spark-01:8000/v1`, bearer-token auth.
- Model `RedHatAI/Qwen3.6-35B-A3B-NVFP4`, `max_model_len` 131,072.
- Native tool calling confirmed: `tools` param honored, response carries
  `tool_calls` with JSON arguments and `finish_reason: "tool_calls"`.
- Responses include a non-standard `reasoning` field (model thinking) beside
  `content`. The harness must tolerate and may surface it, but must not send
  it back in subsequent turns unless the API requires it.
- vLLM version `0.22.1rc1`.
- The model is a heavy reasoner: a one-word answer cost 249 completion tokens
  (thinking included). Budget `max_tokens` generously — small caps will
  truncate mid-reasoning before any visible output.
