# 0001 — Record decisions as ADRs

Date: 2026-07-10 · Status: accepted

## Context

This repo is an experiment whose main output is understanding. The reasoning
behind each choice is as valuable as the code, and reasoning evaporates unless
written down at decision time.

## Decision

Every non-obvious decision gets a numbered file in `docs/decisions/`:
context, the decision, trade-offs considered, consequences. ADRs are
immutable — a changed mind produces a new ADR that marks the old one
*superseded*, so wrong turns stay visible.

## Trade-offs

- **ADR files** vs. **decisions inline in DESIGN.md**: the design doc is a
  living document describing current intent; mixing history into it makes both
  worse. Separate files keep history append-only. Cost: two places to look.
- **Lightweight format** vs. full MADR template: heavyweight templates
  discourage writing. A short fixed skeleton (context / decision / trade-offs /
  consequences) is enough.

## Consequences

Commits that make a choice reference their ADR. Reviewing `docs/decisions/`
in order replays the project's reasoning.
