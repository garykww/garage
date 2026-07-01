# Task List

Every task is tagged with the module it belongs to (`[inventory]` or
`[billing]`). The `lead` agent reads this file, routes each open task to the
subagent that owns that module (`inventory-code-agent` or `billing-code-agent`), and
checks tasks off as the owning agent reports them done. Tasks tagged for
different modules have no shared state, so the lead can dispatch them
concurrently; tasks tagged for the same module are handed to that module's
single owner one at a time.

A task can also be tagged `[inventory+billing]` when it genuinely needs both
modules to change. Neither `inventory-code-agent` nor `billing-code-agent` is allowed
to touch the other's directory, so the lead can't just hand a
`[inventory+billing]` task to one of them — see "Handling cross-module
tasks" in `.claude/agents/lead.md` for how it splits these instead.

## Open

- [ ] [inventory+billing] Add checkout support: selling inventory items
      should be able to produce a matching billing invoice for the same
      sale — same item, same quantity, same unit price on both sides — so a
      customer gets billed for exactly what left the shelf. Neither module
      currently knows the other exists; do not have `inventory-code-agent` import
      `billing` or vice versa.

- [ ] [billing] `AddLineItem` doesn't validate `amount`/`qty` — a negative
      amount or qty silently changes the invoice total. Add validation and a
      regression test.
- [ ] [billing] `ApplyLateFee` doesn't validate `feePercent` — a negative
      value silently discounts the invoice instead of charging a fee. Add
      validation and a regression test.
- [ ] [billing] `RenderInvoiceHTML` builds HTML with `fmt.Sprintf` instead of
      `html/template`, so a customer name or line-item description
      containing `<script>` renders unescaped (stored XSS). Fix and add a
      regression test.
- [ ] [billing] Several exported symbols in `billing/billing.go` have no doc
      comments (`LineItem`, `Invoice`, `Ledger`, `CreateInvoice`, `Get`,
      `AddLineItem`, `Total`, `ApplyLateFee`, `MarkPaid`). Add them.

## Completed

- [x] [inventory] `Sell` didn't check quantity against stock, so stock could
      go negative — fixed with validation, regression test added.
- [x] [inventory] `ApplyPricingFormula` shelled out to `sh -c` with
      unsanitized input (command injection) — replaced with an in-process
      expression evaluator, regression tests added for injection attempts.
- [x] [inventory] `Restock` and `ApplyDiscount` had no input validation —
      fixed, regression tests added.
- [x] [inventory] Missing doc comments on exported symbols — added.

## Adding a new task

Append a line under **Open** as `- [ ] [module] description`. The module tag
must match an existing top-level module directory (`inventory` or `billing`)
so the lead can route it — tasks for a module with no owning agent will be
left unassigned.
