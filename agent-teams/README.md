# agent-teams

A showcase of Claude Code's **agent teams**: custom subagents defined in
`.claude/agents/`, each scoped to a role with its own system prompt and its
own tool grant, coordinated by a task list and a lead agent instead of one
generalist doing everything in a single undifferentiated context.

This is a demo, not a template library. `ai-agent-personas/` (sibling app in
this repo) is a static collection of persona system prompts for any AI tool.
This app is different: it's a real, buildable multi-package Go module with
live bugs and security flaws planted on purpose, plus an actual
`.claude/agents/` team wired up so you can watch Claude Code use it.

## Subagents vs. agent teams

A **subagent** is the primitive: one `.md` file in `.claude/agents/` — a
name, a description Claude Code matches against your request, a tool grant,
and a system prompt — that runs in its own isolated context and reports
back to whoever dispatched it. Any of the six agents in this project
(`lead`, `inventory-code-agent`, `billing-code-agent`, `code-agent`,
`security-auditor`, `qa-agent`) is, on its own, just a subagent. Nothing
stops you from
dispatching one ad hoc for a single task and never touching the others —
that's a perfectly normal way to use a subagent, and this project's earlier
version (before this rename/restructure) worked exactly that way: four
independent specialists with no relationship to each other beyond sharing a
codebase.

An **agent team** is what you get when several subagents are given a
structure that only makes sense in relation to each other: fixed ownership
(`inventory-code-agent`/`billing-code-agent` each hold exclusive write
access to one module, enforced by instruction rather than by the subagent
mechanism itself), a shared coordination artifact (`TASKS.md` as the
backlog, `logs/` as the audit trail), a role whose entire job is routing and
relaying between the others (`lead`), and rules for what happens when work
doesn't fit cleanly inside one subagent's scope (the `[inventory+billing]`
contract-splitting procedure). None of that is a Claude Code feature you
turn on — it's a convention built on top of the subagent primitive, entirely
in the `.md` files and `TASKS.md`/`logs/` this project defines. Swap out the
task list, the module boundaries, or the lead's routing rules, and you have
a different team; the underlying mechanism (isolated subagents dispatched
via the `Task`/`Agent` tool) is unchanged.

### Trade-offs

| | Standalone subagents | Agent team |
|---|---|---|
| Setup | Drop in one `.md` file, done | `.md` files + `TASKS.md` + `logs/` + a lead's routing rules, all kept in sync |
| One-off request | Direct — dispatch the specialist, get the answer | Indirect — goes through `lead`'s read/route/dispatch/log cycle even for a single task |
| Parallel work on a shared codebase | Nothing stops two agents editing the same file at once if you dispatch them together | Module ownership means concurrent dispatches never collide, by construction |
| Backlog of many tasks over time | You re-explain context and re-decide who does what on every request | `TASKS.md` persists the queue; `lead` re-derives the plan from it each run |
| Work spanning multiple areas | Whoever you ask has to hold the whole thing in one context, or you coordinate the split yourself | `lead` designs the contract and splits it — but only because that procedure was built and tested here first |
| Auditability | Whatever the subagent said back to you, once, in that conversation | `logs/` is a persistent, append-only record you can read after the fact |
| Failure mode | An agent does the wrong thing — contained to that one dispatch | `lead` misroutes a task or misses a contract mismatch — a coordination bug, not a code bug, and it can propagate silently to two agents' otherwise-correct work |
| Guarantees | Whatever the subagent's own prompt promises | Still just instruction-level (see the boundary note above) — the team's structure can look more rigorous than it actually is if you forget that |

Neither is strictly better — a team is worth the overhead exactly when you
have a codebase big enough to split ownership over, a backlog that outlives
one request, or work that genuinely needs more than one specialist's
context. For a single fix in a single file, dispatching one subagent
directly is faster and has nothing extra to get wrong.

This project actually runs both models side by side. `inventory-code-agent`
and `billing-code-agent` are the "named owner" end of that table — a
persistent `.md` file per module, the boundary and any module-specific
knowledge baked in once. `code-agent` (below) is the other end: one generic
template, dispatched fresh per module by `lead`, with no file to add when a
new module shows up. It trades the named agents' "boundary is baked into a
file you can't forget" guarantee for "boundary is whatever `lead` computed
correctly this round" — see "The generic agent" below for how the logs make
that trade legible instead of invisible.

## Layout

Two modules with permanent owners, an open-ended number of modules a
generic agent can pick up, and a shared backlog:

```
agent-teams/
├── inventory/                    # owned exclusively by inventory-code-agent
│   ├── inventory.go
│   └── inventory_test.go
├── billing/                       # owned exclusively by billing-code-agent
│   ├── billing.go
│   └── billing_test.go
├── shipping/                      # no named owner — code-agent(shipping)
│   ├── shipping.go
│   └── shipping_test.go
├── catalog/                       # no named owner — code-agent(catalog)
│   ├── catalog.go
│   └── catalog_test.go
├── notifications/                 # no named owner — code-agent(notifications)
│   ├── notifications.go
│   └── notifications_test.go
├── reporting/                     # no named owner — code-agent(reporting)
│   ├── reporting.go
│   └── reporting_test.go
├── loyalty/                       # no named owner — code-agent(loyalty)
│   ├── loyalty.go
│   └── loyalty_test.go
├── TASKS.md                       # the backlog the lead works from
├── logs/                          # one append-only log per module/agent
│   ├── README.md                    # shared log entry format
│   ├── lead.md
│   ├── inventory-code-agent.md
│   ├── billing-code-agent.md
│   ├── security-auditor.md
│   ├── qa-agent.md
│   └── <module>.md                  # created on demand per code-agent module
└── .claude/agents/
    ├── lead.md                      # reads TASKS.md, assigns and dispatches
    ├── inventory-code-agent.md      # coding agent, inventory/ only
    ├── billing-code-agent.md        # coding agent, billing/ only
    ├── code-agent.md                # generic, one session per other module
    ├── security-auditor.md          # shared, read-only, cross-module
    └── qa-agent.md                  # shared, test-files-only, cross-module
```

## The problems planted on purpose

`inventory/inventory.go`'s original bug (unchecked stock underflow in
`Sell`) and security flaw (`ApplyPricingFormula` shelling out to `sh -c`
with unsanitized input) have already been fixed by `inventory-code-agent` — see
**Completed** in `TASKS.md`. `billing/billing.go` is the fresh half of the
backlog:

| Problem | Where |
|---|---|
| `AddLineItem` doesn't validate `amount`/`qty` — a negative value silently changes the invoice total | `AddLineItem()` |
| `ApplyLateFee` doesn't validate `feePercent` — a negative value silently discounts instead of charging a fee | `ApplyLateFee()` |
| Stored XSS: `RenderInvoiceHTML` builds HTML with `fmt.Sprintf` instead of `html/template`, so customer-controlled strings render unescaped | `RenderInvoiceHTML()` |
| No test coverage for the above, and several exported symbols have no doc comments | whole package |

## The team

| Agent | Owns | Tools |
|---|---|---|
| `lead` | Nothing — reads `TASKS.md`, assigns and dispatches, never edits code | Read, Edit, Task |
| `inventory-code-agent` | `inventory/` only, permanently | Read, Grep, Glob, Write, Edit, Bash |
| `billing-code-agent` | `billing/` only, permanently | Read, Grep, Glob, Write, Edit, Bash |
| `code-agent` | Whatever module it's scoped to for the session — anything except `inventory/`/`billing/` | Read, Grep, Glob, Write, Edit, Bash |
| `security-auditor` | Nothing — shared, read-only, works across every module | Read, Grep, Glob, Bash |
| `qa-agent` | Nothing — shared, works across every module, but only `*_test.go` files | Read, Grep, Glob, Bash, Edit, Write |

`inventory-code-agent` and `billing-code-agent` are both full coding agents (they fix
bugs, add tests, and write docs — no split by concern this time) but each is
bound to one module by an explicit scope rule in its own system prompt: it
will not read, write, or run commands against the other module's directory,
and if a task can't be finished without crossing that line it stops and
reports back instead of making the edit. Because their modules share no
state, the two can safely work at the same time.

**A note on how that boundary is enforced:** there's no path-scoped sandbox
here — `tools:` frontmatter grants a tool repo-wide, it can't restrict Read
or Edit to a subdirectory. The boundary is enforced by instruction (each
agent's prompt states its scope and refuses out-of-scope work) plus the fact
that the two modules never need to touch the same file, so honoring the
boundary costs a well-behaved agent nothing. Treat it the same way you'd
treat a human code-owner convention: strong in practice, not a hard
technical guarantee.

`lead` never touches code — it owns the backlog, not a module. Its job is to
read `TASKS.md`, route each open task by its `[inventory]`/`[billing]` tag
to the matching owner, run independent (different-module) tasks concurrently
and same-module tasks one at a time, and check tasks off as owners report
them done.

## The generic agent

`inventory-code-agent` and `billing-code-agent` don't scale past two
modules without adding a new `.md` file for each one. `code-agent` is the
alternative: a single generic template with no fixed module. `lead` spins up
a *new session* of it for whatever module a task names — including a module
that doesn't exist yet — and can run as many concurrent sessions as it has
distinct modules to assign in a round, with no upper limit the way there
are exactly two named agents. `shipping/`, `catalog/`, `notifications/`,
`reporting/`, and `loyalty/` exist purely to exercise this: none has a named
owner, each has an open task in `TASKS.md`, and dispatching the backlog fans
out to five concurrent `code-agent` sessions —
`code-agent(shipping)`, `code-agent(catalog)`, `code-agent(notifications)`,
`code-agent(reporting)`, `code-agent(loyalty)` — alongside the two named
agents, seven concurrent sessions in one round, with no new agent `.md`
file added to get from two modules to seven.

The trade is what "owns a module" means. For the named agents, the
boundary lives permanently in a file: read `inventory-code-agent.md` once
and you know it can never touch `billing/`. `code-agent` has no such
standing boundary — its scope is whatever the dispatching task said, for
that session only. So the correctness of "no two agents ever touch the same
module at once" moves entirely onto `lead`: before it dispatches anything
concurrently, it has to list every module in play this round and confirm
none overlap (see "Dispatching code-agent sessions" in
`.claude/agents/lead.md`). Get that wrong and there's no file-level
guardrail to catch it — this is the exact "guarantees are instruction-level,
not sandboxed" trade-off from the table above, just relocated from the
worker's prompt to the dispatcher's judgment.

Because a `code-agent` session has no persistent name, `lead` refers to each
one as `code-agent(<module>)` in its own log and in the dispatch itself, and
requires the session to write that same identifier into its own log entry's
`**Assigned by:**` line (in `logs/<module>.md`, never a shared
`logs/code-agent.md` — that would itself be an overlap). Read `logs/lead.md`
and `logs/<module>.md` together and the assignment is traceable from both
ends: `lead`'s entry says what it sent and to which named session, and the
session's entry independently confirms the same module and task before
reporting what it did.

## Shared agents

`security-auditor` and `qa-agent` aren't module owners and don't wait to be
routed a tagged task — anyone on the team can call them in on anything, in
either module, whenever the task calls for it:

- `security-auditor` is read-only. It can safely look at both `inventory/`
  and `billing/` because it never edits anything — it reports severity-rated
  findings and a suggested fix, and whoever called it (the lead, a module
  owner, or you) decides what happens next.
- `qa-agent` can safely touch both modules too, but only files matching
  `*_test.go` — never `inventory.go` or `billing.go`. Test-only writes can
  add coverage but can't change production behavior, so letting it cross the
  module boundary doesn't undermine the "only the owner edits production
  code" rule the way giving it full write access would.

`inventory-code-agent` and `billing-code-agent` can call either one directly for a
second opinion (e.g. "have security-auditor check this before I report the
fix done"), and `lead` can dispatch them ad hoc on top of the regular
backlog — see "Using the shared agents" in `.claude/agents/lead.md`.

## Logs

Every agent keeps its own append-only log — `logs/<agent-name>.md` for the
five named agents, `logs/<module>.md` for `code-agent` sessions — capturing
findings, decisions, the plan followed, and (per `logs/README.md`'s shared
format) a **Communication** block whenever the task involved another agent.
Each agent/session only ever writes to its own file, the same ownership
discipline as the code: `security-auditor` and `qa-agent` are granted
exactly enough write access to append to their own log and nothing more
(`security-auditor` still can't touch any `.go` file), and `lead`'s log is
the one place you'll see every other agent named, since it's the single
channel relaying between them.

Reading `logs/lead.md` after a run is the fastest way to see the whole team
working without re-running anything — in particular, it's where the exact
data contract from a `[inventory+billing]` split gets written down, along
with any mismatch `lead` caught between what `inventory-code-agent` and
`billing-code-agent` each built against it, and — for any module handled by
`code-agent` — which session (`code-agent(<module>)`) got which task. Since
`code-agent` sessions have no persistent name across runs, `logs/lead.md` is
the only place that assignment history lives; `logs/<module>.md` confirms
it independently from the session's own side, since each entry's
`**Assigned by:**` line restates the same module/task `lead` logged.

## Running the demo

From this folder, hand the whole backlog to the lead:

> Use the lead agent to work through TASKS.md.

At the time of writing, `TASKS.md`'s Open section has seven tasks: one
`[inventory]`, one `[billing]`, and five — `[shipping]`, `[catalog]`,
`[notifications]`, `[reporting]`, `[loyalty]` — for modules with no named
owner. Each of the five has one planted validation bug (missing input
checks, the same family as `billing`'s original bugs) and thin test
coverage, same pattern as `inventory`/`billing`. Running the backlog now
should have `lead` dispatch seven sessions concurrently — `inventory-code-agent`,
`billing-code-agent`, and `code-agent(shipping)`, `code-agent(catalog)`,
`code-agent(notifications)`, `code-agent(reporting)`, `code-agent(loyalty)`
— since none of the seven modules share state. To try `code-agent` on a
module that doesn't exist yet, add a task tagged with a genuinely new name
(e.g. `[audit-trail]`) and hand the backlog to `lead` again — it'll create
the directory as part of the session.

You can also go straight to one owner without the lead:

> Have inventory-code-agent fix the Sell validation gap in inventory/inventory.go.

Verify the end state with:

```bash
go build ./...
go vet ./...
go test ./... -cover
```

## The cross-module example

The open `[inventory+billing]` task in `TASKS.md` — wire a sale in
`inventory/` to a matching invoice in `billing/` — can't go to either
coding agent directly: it needs code on both sides, and neither agent is
allowed to read or edit the other's directory to figure out what shape that
code should take.

`lead` handles this with the procedure in "Handling cross-module tasks" in
`.claude/agents/lead.md`: it defines a small shared data contract itself
(e.g. `{ItemID string; Qty int; UnitPrice float64}` crossing the boundary,
with neither package importing the other), splits the task into one
`inventory/`-scoped subtask and one `billing/`-scoped subtask that each
embed that exact contract, dispatches both, and — since `inventory-code-agent`
and `billing-code-agent` have no channel to each other, only to whoever dispatched
them — checks the two results actually agree before marking the task done.
If they don't (say `billing-code-agent` built against a `TotalPrice` field but
`inventory-code-agent` returns `UnitPrice`), `lead` is the one that catches it and
sends the fix back to whichever side needs to change, rather than either
agent discovering the mismatch by reading code it isn't scoped to touch.

Try it directly:

> Use the lead agent to work through the `[inventory+billing]` checkout task
> in TASKS.md.

## Why this matters as a demo

A single agent working across two unrelated modules accumulates a long,
mixed-purpose context and has no structural reason not to cross-edit files
it shouldn't touch. Splitting ownership by module lets two agents work at
the same time with no coordination overhead — they never contend for the
same file — while a lead agent turns a shared backlog into routed,
parallelizable work instead of one linear queue. This is the same
orchestrator/worker pattern this repo's own Claude Code session uses
internally via `fork` and specialist subagent types, applied here at
project scale with a persistent task list instead of a single ad hoc
request.
