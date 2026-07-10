# Feature brainstorm: what a real harness has that we don't

Status: brainstorm, 2026-07-10. Compares this harness against the two
reference implementations — Claude Code and OpenAI Codex CLI — to find what
they both converged on (probably essential), where they diverge (a real
design choice to make), and what is product polish we can skip.

## 1. Where Claude Code and Codex agree (convergent = essential)

Both independently arrived at these. Strong signal each one is load-bearing.

| Feature | Claude Code | Codex CLI | Our status |
|---|---|---|---|
| Agent loop w/ native tool calls | yes | yes | planned (M3) |
| Shell tool | persistent-ish bash, background tasks | exec w/ sandbox | planned (M2) |
| File read/edit tools | Read + exact-string Edit | apply_patch (diff format) | planned (M4) |
| Search tools (grep/glob) | dedicated tools | model just uses shell | **gap — decide** |
| System prompt w/ environment | cwd, git state, OS, date injected | same | **gap — not in design** |
| Project memory file | CLAUDE.md | AGENTS.md | **gap** |
| Permission / approval gate | modes + allowlists + hooks | untrusted/on-request/never + OS sandbox | **gap — not in design** |
| Context compaction | auto-compact + /compact | auto-compact | planned (M6) |
| Session persistence & resume | resume/continue | codex resume | partially planned (M5 transcripts) |
| Non-interactive mode for CI | `claude -p` | `codex exec` | trivially ours (M5 CLI is this) |
| Streaming output | yes | yes | planned (M7) |
| MCP client | yes | yes | out of scope for now |
| Parallel tool calls in one turn | yes | yes | **gap — loop design must allow it** |
| Cost/token telemetry | /cost, statusline | /status | partial (last_usage) |

## 2. Where they diverge (real design choices, ADR material)

- **Edit mechanism.** Claude Code: exact-string replace (`old_string` must be
  unique) — simple, model-friendly, fails loudly. Codex: unified-diff-ish
  `apply_patch` — one call for many hunks, but a stricter format for the model
  to emit. Weaker local models flub diff syntax more than string matching →
  lean string-replace for our Qwen backend.
- **Safety model.** Claude Code: permission prompts in the harness (ask the
  human per tool class). Codex: OS-level sandbox (seatbelt/landlock) so the
  model can run freely inside a cage. Sandboxing is stronger but
  platform-specific; prompting is portable and teaches more about harness UX.
- **Search.** Claude Code ships Grep/Glob as first-class tools (keeps huge
  outputs structured, saves tokens); Codex lets the model shell out to
  ripgrep. Shelling out is free once bash exists — start there, add dedicated
  tools only if transcripts show the model wasting tokens on bad grep.
- **Extensibility.** Claude Code: hooks, skills/slash-commands, subagents —
  a whole platform. Codex: leaner, config-file oriented. For an experiment,
  lean is right.

## 3. Features neither of us should skip — proposed roadmap changes

Ordered by learning-value-per-line-of-code:

1. **System prompt + environment context (new, before M3).** The single
   highest-leverage lever on agent quality, and currently absent from the
   design. Inject: role, cwd, OS, date, tool-use guidance. This is where
   "prompt engineering the harness" lives.
2. **Parallel tool calls (fold into M3).** The API returns `tool_calls` as an
   array; the loop must execute all and return one result per id — this is a
   correctness requirement, not a feature.
3. **Approval gate (new milestone, after M4).** Before executing `bash`,
   classify (read-only allowlist vs everything else) and ask y/n on the
   terminal. Minimal version of the Claude Code model; OS sandboxing noted as
   the road not taken.
4. **AGENTS.md project memory (cheap, with M5).** Read a file from the
   workspace root into the system prompt. ~10 lines of code, big behavioral
   payoff, and de-facto industry standard.
5. **Retry with backoff on transient LLM errors (fold into M3).** One flaky
   response shouldn't kill a 20-turn session.
6. **Turn/telemetry display (fold into M5).** Print per-turn token usage and
   running total; we already keep `last_usage`.

## 4. Deliberately skipped (product polish, low learning value)

TUI/rich rendering, IDE integrations, MCP client, hooks system, subagents,
multi-provider support, image inputs, web search/fetch tools, checkpointing/
rewind, git-worktree isolation. Each is noted in one line so the decision is
recorded; none teaches us about the core loop.

## 5. Open questions

- Does Qwen3.6-35B reliably emit *parallel* tool calls, or one at a time?
  Measure before designing around it.
- The `reasoning` field: show it to the user (Codex shows summaries), or
  hide it? Cheap to print behind a `--verbose` flag first.
- Persistent shell session (state carries across bash calls) vs fresh process
  per call — Claude Code and Codex differ here too; fresh-per-call is simpler
  and probably fine until proven otherwise.
