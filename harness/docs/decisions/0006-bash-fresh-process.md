# 0006 — bash tool runs a fresh process per call

Date: 2026-07-10 · Status: accepted

## Context

The `bash` tool could keep one persistent shell session (state — cwd, env
vars, background jobs — carries across calls, like a human terminal) or spawn
a fresh `sh -c` per call. The reference tools diverge here; FEATURES.md §5
flagged it as an open question.

## Decision

Fresh `subprocess.run(command, shell=True)` per call, fixed 60s timeout,
stdout+stderr captured and labeled, non-zero exit codes reported in the
result text rather than treated as failures.

## Trade-offs

- **Simplicity**: a persistent session needs a PTY or pipe protocol, prompt
  detection, and hang handling — a project in itself. Fresh process is ~20
  lines and cannot leak state between calls.
- **Cost**: the model can't `cd` or `export` durably; it must use absolute
  paths or chain commands with `&&`. The system prompt (M3) will say so.
  Models are heavily post-trained on this convention already.
- **Timeout**: fixed 60s, not model-controllable, to keep the schema minimal;
  revisit when a real task hits it. On timeout the model gets a clear message
  including any partial rationale for retrying differently.

## Consequences

Long-running/interactive commands are out of scope until a real need appears.
If persistent state becomes the bottleneck in transcripts, a new ADR
supersedes this one.
