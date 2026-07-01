# agent-teams-native

A showcase of Claude Code's native, experimental **[agent
teams](https://code.claude.com/docs/en/agent-teams)** feature
(`CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS`): real teammate sessions, a shared
task list with dependencies and file-locked claiming, direct peer-to-peer
messaging, plan approval, and hook-enforced quality gates.

This is the counterpart to the sibling app
[`subagent-teams/`](../subagent-teams/), which builds the same kind of
team out of the subagent primitive alone — markdown backlog, instruction-
level ownership, a lead relaying every message. This app stages the same
kind of codebase (a small multi-package Go module with bugs planted on
purpose) so you can run both and see exactly what the native machinery
replaces. Several scenarios below are *impossible by construction* over
there; that's the point of having both.

## What "native" changes

| | `subagent-teams/` (convention) | This app (native feature) |
|---|---|---|
| Workers | One-shot subagent dispatches; report to dispatcher only | Full independent Claude Code sessions you can watch and message |
| Task list | `TASKS.md`, hand-edited by the lead | Shared task list with dependencies, blocking, and file-locked claiming |
| Peer communication | None — the lead is the sole channel, by construction | Any teammate messages any other by name (`SendMessage`) |
| Cross-module contract | Lead designs it, splits the task, checks both halves | The two owners negotiate it directly; lead reviews |
| "Done" means | Lead reads the report and decides to believe it | `TaskCompleted` hook runs build + tests and blocks red completions |
| Risky changes | Dispatch and hope the prompt was specific enough | Teammate works in plan mode until the lead approves the plan |
| Lead | A subagent (`lead.md`) anyone dispatches | Always the main session — the feature doesn't allow nested teams |

That last row is why there's no `lead.md` agent here: a teammate can't
spawn teammates, so the lead role can't live in an agent definition. Its
playbook lives in [`CLAUDE.md`](CLAUDE.md) instead, which every session in
this folder (lead and teammates alike) loads automatically.

## Setup

The feature flag ships in this folder's `.claude/settings.json`, so it's
on for any session started here:

```bash
cd agent-teams-native
claude
```

Requirements and knobs:

- **Claude Code v2.1.178+** (this README follows the docs as of that
  version; the feature is experimental and moving).
- **Display mode**: default is in-process — teammates appear in the agent
  panel below the prompt (arrow keys to select, Enter to view/message,
  Escape to interrupt). For one pane per teammate, set `teammateMode` to
  `"auto"` in `~/.claude/settings.json` or run `claude --teammate-mode
  auto` inside tmux or iTerm2 (with the `it2` CLI).
- **Teammate model**: teammates don't inherit `/model` by default — set
  "Default teammate model" in `/config`, or just say it in the kickoff
  prompt ("use Sonnet for the owners"). Fix-and-test tasks like this
  backlog are a good fit for a cheaper worker model under a stronger lead.
- **Permissions**: teammates start with the lead's permission mode, and
  their permission prompts bubble up to the lead session. Pre-approving
  `go build`/`go test`/`go vet` saves friction.

## Layout

```
agent-teams-native/
├── cart/                    # planted: AddItem skips qty/unitPrice validation
├── payment/                 # planted: Refund allows over-refund & negative amounts
├── emailer/                 # planted: RenderReceiptHTML is fmt.Sprintf XSS
├── BACKLOG.md               # seed for the native task list (see below)
├── CLAUDE.md                # team conventions + the lead's playbook
└── .claude/
    ├── settings.json        # feature flag + hook registrations
    ├── hooks/
    │   ├── task-completed-gate.sh   # blocks completion while build/tests are red
    │   └── teammate-idle-gate.sh    # blocks idling while go vet is unhappy
    └── agents/
        ├── module-owner.md      # generic owner, module assigned at spawn
        ├── security-auditor.md  # shared, read-only reviewer
        └── qa-agent.md          # shared, *_test.go files only
```

The agent definitions double as teammate roles: the docs' recommended way
to define reusable teammates is a plain subagent definition, referenced by
name at spawn time ("spawn a teammate using the module-owner agent type").
The definition's `tools` allowlist and body carry over; team coordination
tools (`SendMessage`, task management) are always added on top. One
caveat: `skills` and `mcpServers` frontmatter are ignored for teammates.

Unlike `subagent-teams/`, there is no per-module owner file and no generic
`code-agent` dispatched with a scope-in-the-prompt — one `module-owner`
definition covers every module, because a teammate is a *named, persistent
session* ("cart-owner") rather than an anonymous one-shot dispatch, so the
assignment tracking that consumed half of the sibling's `lead.md` comes
for free. There's also no `logs/` convention: the transcript of each
teammate session and the task list itself are the audit trail.

## The scenarios

Each scenario is one thing the native feature does that the convention
version can't. `BACKLOG.md` seeds all of them; run them together or
cherry-pick.

### 1. Work the backlog (shared task list, self-claiming, dependencies)

> Read BACKLOG.md, seed the shared task list from it, and spawn three
> module-owner teammates — cart-owner, payment-owner, emailer-owner — to
> work through it. Let them claim their own tasks.

Watch for: the QA task (blocked on all three fixes) staying unclaimable
until the last fix completes, then unblocking automatically; teammates
claiming work without the lead routing anything; task claiming staying
race-free because the feature file-locks it. In `subagent-teams/` all of
this is the lead hand-editing `TASKS.md` and hoping it listed the modules
correctly before dispatching in parallel.

### 2. Peer-negotiated contract (the headline)

> Have cart-owner and payment-owner take the [cart+payment] checkout task.
> They should negotiate the data contract directly with each other before
> either implements, and send me the agreed contract.

In `subagent-teams/`, the equivalent `[inventory+billing]` task needs a
whole procedure ("Handling cross-module tasks" in its `lead.md`): the lead
designs the contract, splits the task, and diff-checks the halves, because
subagents have no channel to each other. Here the owners just... talk.
Compare the two transcripts — the negotiation (unit price vs. line total,
who validates) happens between the two agents that own the consequences,
and the lead only verifies the agreed text against both implementations.

### 3. Plan approval on the risky task

> Spawn payment-owner with required plan approval for the integer-cents
> migration task. Only approve a plan that includes rounding regression
> tests and spells out what happens to the exported Charge fields.

The teammate stays in read-only plan mode until the lead approves;
rejections go back with feedback and the teammate revises. The approval
criteria the lead applies are the ones in `CLAUDE.md` — edit those to
steer it.

### 4. Quality gates that actually block

No prompt needed — the hooks in `.claude/hooks/` are always on:

- **`TaskCompleted`** runs `go build ./...` and `go test ./...`; exit
  code 2 blocks the completion and feeds the failure output back to the
  teammate. This is the enforced version of the sibling's honor-system
  rule ("verify the report references a passing test" — a rule that lived
  in a prompt and relied on the lead reading carefully).
- **`TeammateIdle`** runs `go vet ./...` and keeps a teammate working if
  vet is unhappy.

To see the gate fire, ask a teammate to mark its task complete while a
test is deliberately red.

### 5. Adversarial debate (optional)

> Cart totals and captured charge amounts disagree for some carts. Spawn
> three teammates to investigate competing hypotheses — float accumulation
> in Total, validation gaps letting bad lines in, contract mismatch in the
> checkout code — and have them message each other to try to disprove each
> other's theories before reporting a consensus.

Best run *after* scenario 2 has landed checkout code to investigate. This
is the docs' "competing hypotheses" pattern: the debate structure fights
the single-investigator habit of anchoring on the first plausible theory.

## Verify the end state

```bash
go build ./...
go vet ./...
go test ./... -cover
```

All three pass on the pristine planted state too — the bugs are
validation and escaping gaps that the thin tests deliberately don't reach
(each `*_test.go` says so in a "No coverage yet for ..." comment), so a
red suite always means work in progress, which is what lets the
TaskCompleted gate use the full suite as its check.

## Known rough edges

The feature is experimental; the demo inherits its limitations:

- **No resumption of in-process teammates** — `/resume` won't restore
  them; tell the lead to spawn replacements. (`BACKLOG.md` + the persisted
  task list is what makes restaging cheap.)
- **Task status can lag** — a teammate sometimes finishes without marking
  its task complete, leaving dependents blocked; nudge it or update the
  task yourself.
- **The lead may jump in and implement** instead of waiting — "wait for
  your teammates to finish" usually fixes it.
- **One team per session, no nesting, lead is fixed** — see the table up
  top; this shapes the whole design (lead playbook in `CLAUDE.md`, no
  `lead.md` agent).
- **Token cost scales linearly with teammates.** Three owners is the
  right size here; the sibling app's seven-way fan-out would be paying
  for parallelism this backlog doesn't need.
