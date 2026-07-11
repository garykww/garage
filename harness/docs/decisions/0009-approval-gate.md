# 0009 — Approval gate: harness-level policy, denial as information

Date: 2026-07-10 · Status: accepted

## Context

The agent runs arbitrary shell commands and writes files unattended. The
reference tools diverge (FEATURES.md §2): Claude Code gates in the harness
(permission prompts, allowlists); Codex cages the process in an OS sandbox
(seatbelt/landlock). We deferred this until the agent could do real damage —
it now can.

## Decision

A policy layer between the loop and tool execution, no OS sandbox:

- **`Policy.decide(tool, args) → allow | ask`**, with rules:
  - `read_file`: always allow.
  - `bash`: allow only commands that parse as pipelines of allowlisted
    read-only programs (ls, cat, grep, find, ...) with no redirects, no
    command substitution, no env-assignment prefixes. Anything unparseable
    or unrecognized → ask. Deny-by-default classification: false "ask" is a
    minor annoyance, false "allow" is the failure mode.
  - `write_file` / `edit_file`: allow inside the agent's working directory,
    ask outside it.
  - unknown tools: ask.
- **`GatedRegistry`** wraps `ToolRegistry` with the same interface (schemas /
  dispatch), so the agent loop stays untouched — gating is composition, not
  a loop feature.
- **Denial is a tool result**, not an exception: the model sees "denied: the
  user declined..." and can adapt or report, mirroring how tool errors work.
- The asker is a callable; the CLI wires it to an interactive y/N prompt on
  /dev/tty (`--yes` auto-approves everything; tests inject fakes).

## Trade-offs

- **Harness gate vs OS sandbox**: a sandbox is stronger (catches what the
  classifier misses) but platform-specific and opaque; the gate is portable,
  inspectable, and teaches the actual design problem (what *should* run
  unprompted?). A malicious model defeats the gate; a confused one is caught —
  the realistic threat here. Sandbox noted as the upgrade path.
- **String classification of bash is unwinnable in general** (base64, exotic
  quoting). Mitigated by deny-by-default: the classifier only ever *grants*
  a narrow, parseable, read-only subset; everything else asks a human.
- **Prompting on /dev/tty** keeps stdin free for the task text; when no tty
  exists (CI), unapproved calls are denied rather than hanging.

## Consequences

Interactive runs get y/N prompts for mutating commands; `--yes` restores
old behavior explicitly. E2e tests run with programmatic askers. If
transcripts show prompt fatigue, the fix is richer policy (e.g. remembered
approvals), a new ADR.
