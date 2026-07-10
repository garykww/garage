# 0007 — E2E evaluation: live-server tests graded by side effects

Date: 2026-07-10 · Status: accepted

## Context

Unit tests prove the harness plumbing; they say nothing about whether the
*model-plus-harness system* completes tasks. Every change to prompts, tool
descriptions, or loop behavior can silently break agent capability. We need
end-to-end tests, but LLM output is nondeterministic and a live server call
is slow (this model thinks ~250 tokens before saying anything).

## Decision

A separate `tests/e2e/` suite that talks to the real vLLM server:

- **Opt-in**: skipped unless `HARNESS_E2E=1`. `uv run pytest` stays fast and
  offline; `HARNESS_E2E=1 uv run pytest tests/e2e` is the capability gate,
  run before merging harness-behavior changes.
- **Graded by observable effects, not judges**: assertions check side effects
  (a file exists with expected content) or loose substrings in the final
  answer (a value only obtainable by actually running the tool — e.g. the
  content of a random temp file). Never exact-match prose, never LLM-as-judge.
- **One capability per test**, mirroring the milestones: completion → tool
  round-trip → multi-step task → error recovery → file edit. A milestone is
  "done" when its e2e test passes.
- Each test creates its workspace under a tmp dir; nothing touches the repo.

## Trade-offs

- **Live server** vs recorded/mocked responses: recordings (VCR-style) are
  deterministic but test yesterday's model behavior — exactly the wrong
  thing for prompt/tool-description changes, which is what we iterate on.
  Accepted cost: e2e requires the server and occasionally flakes.
- **Side-effect grading** vs LLM-as-judge: judges add a second nondeterministic
  system to debug. Tasks are chosen so success is mechanically checkable —
  this constrains task design, which is fine at this scale.
- **Flakiness policy**: a failing e2e test is signal, not noise — investigate
  the transcript before retrying. If a test flakes >~1 in 5 runs, the fix is
  a better prompt/tool description or an easier task, recorded in git, not a
  retry loop that hides regressions.

## Consequences

- `tests/e2e/conftest.py` owns the skip logic and shared fixtures.
- Unverifiable-by-effect behaviors (tone, reasoning quality) stay untested;
  the transcript log (milestone 6) is the inspection tool for those.
