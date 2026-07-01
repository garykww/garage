# agent-teams-native — team conventions

This folder demos Claude Code's native, experimental **agent teams**
feature. Every session that opens here reads this file — the lead (the
user's main session) and every teammate it spawns — so it holds the rules
for both roles. The feature itself is enabled by
`CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS` in `.claude/settings.json`.

## Everyone

- Module ownership is exclusive. `cart/`, `payment/`, and `emailer/` each
  get at most one `module-owner` teammate at a time, and nobody edits a
  module they don't own. `security-auditor` never edits any file;
  `qa-agent` edits `*_test.go` files only.
- Cross-module work happens by messaging the other module's owner, never
  by editing their files. Modules must not import each other.
- `go build ./...` and `go test ./...` must be green before any task is
  marked complete — a TaskCompleted hook enforces this and will bounce the
  completion back with the failure output if either is red.

## If you are the team lead (the main session)

- Kick off by reading `BACKLOG.md` and creating one task in the shared
  task list per entry, preserving the dependencies it notes (the QA pass
  is blocked on the three fix tasks). After that, the shared task list is
  the source of truth — don't re-edit `BACKLOG.md` to track status.
- Don't implement tasks yourself. Spawn teammates from the agent types in
  `.claude/agents/` and let them claim work. Name module owners after
  their module — `cart-owner`, `payment-owner`, `emailer-owner` — and open
  each spawn prompt with the module it owns.
- For the `[cart+payment]` checkout task: do not design the data contract
  yourself. Tell the two owners to negotiate it directly with each other
  and to send you the agreed contract before either implements. Verify
  both completion reports quote the same field names, types, and units.
- For the `[payment]` integer-cents migration: spawn the owner with
  required plan approval. Approve only a plan that includes regression
  tests for rounding at cent boundaries and states what happens to the
  exported `Charge.Amount` field's type and callers. Reject with specific
  feedback otherwise.
- Wait for teammates to finish rather than doing their tasks; verify each
  completion references a concrete file:line change and a passing test.

## If you are a teammate

- Your spawn prompt names your scope; that is your whole write scope. The
  full rules for your role are in your agent definition
  (`.claude/agents/<your-type>.md`).
- Claim only tasks that match your scope, and keep task status honest —
  claimed when you start, completed only when the work is really done.
- When you agree a cross-module contract with another owner, restate the
  final field names and types verbatim in your completion message so the
  lead can verify both sides against the same text.
