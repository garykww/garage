# 0008 — File edits by exact-string replacement

Date: 2026-07-10 · Status: accepted

## Context

The agent needs to modify files. The reference tools diverge (FEATURES.md §2):
Claude Code uses exact-string replace (`old_string` → `new_string`, must match
uniquely); Codex uses `apply_patch`, a unified-diff-like format. A third
option is whole-file rewrite via `write_file` only.

## Decision

`edit_file(path, old_string, new_string)` with exact, unique-match semantics:

- 0 matches → error telling the model the string was not found (and to
  re-read the file);
- ≥2 matches → error with the count, telling the model to include more
  surrounding context;
- 1 match → replaced.

`read_file` returns plain file content (no line-number prefixes) so that what
the model sees is byte-identical to what `old_string` must match.

## Trade-offs

- **String replace** vs **diff format**: diffs pack many hunks into one call,
  but demand strict syntax that smaller local models flub (hunk headers,
  context lines, escaping). String matching degrades gracefully: a bad match
  is a clear error the model can react to, not a corrupted patch. With our
  35B backend, robustness beats call efficiency.
- **Unique-match requirement** vs replace-first: silently editing the wrong
  occurrence is the worst failure mode (corrupts code, invisible until later).
  Forcing uniqueness costs the model an occasional retry with more context —
  cheap and self-correcting.
- **No `replace_all`, no line numbers in reads** for now — both are easy
  additions once transcripts show the need (YAGNI).
- **vs whole-file rewrite**: rewriting burns tokens proportional to file size
  and risks the model dropping code it didn't attend to. Kept as a fallback
  (`write_file` exists) but not the primary mechanism.

## Consequences

Multi-site refactors take several edit calls. Truncated `read_file` output
(central 10k cap) can hide the region to edit — offset/limit parameters on
`read_file` mitigate; revisit if transcripts show blind edits.
