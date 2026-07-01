# Agent logs

Every agent in this project keeps its own append-only log in this folder —
`logs/<agent-name>.md` — capturing what it found, decided, and communicated
on every task it works. Logs never mix between agents: each agent only ever
appends to its own file, the same way `inventory-code-agent` and
`billing-code-agent` only ever edit their own module. Read them in task
order and you can reconstruct exactly what a run of the team did without
re-running anything.

## Format

Append one entry per task or action, oldest first:

```
## YYYY-MM-DD HH:MM — <one-line task summary>
**Assigned by:** lead | direct request | self (ad hoc)
**Findings:** what you observed — the bug, the vulnerability, the coverage
gap, the mismatch — with file:line where relevant.
**Decision:** what you decided to do about it, and why, if there was a
choice to make.
**Plan:** the steps you took or are about to take.
**Communication:**
- → <agent>: what you told them, and why (e.g. handing off a contract, a
  finding, a mismatch to fix).
- ← <agent>: what they told you back.
(omit this block entirely if the task involved no other agent)
**Result:** done | blocked — <reason> | handed back to <agent>
```

## Rules

- Append-only. Never edit or delete a previous entry — if something you
  reported turns out to be wrong, add a new entry that corrects it.
- Log to your own file only, even when the entry is about another agent
  (e.g. `lead` logging what it told `billing-code-agent`) — write that in
  `logs/lead.md`, not `logs/billing-code-agent.md`. `lead` is the only agent
  whose log will regularly name every other agent, since it's the one
  relaying between them.
- Log even when you *don't* act — a task you refused because it crossed
  your module boundary, or a mismatch you're kicking back to another agent,
  belongs in the audit trail just as much as a task you completed.
- Logging is not optional and is not the task itself — do the work first,
  then record it. A log entry with no corresponding code change (for
  inventory-code-agent/billing-code-agent/qa-agent) or no corresponding
  dispatch (for lead) means something went wrong.
