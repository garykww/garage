# Task List

Every task is tagged with the module it belongs to. `[inventory]` and
`[billing]` route to their permanent owners, `inventory-code-agent` and
`billing-code-agent`. Any other module tag (an existing directory, or a new
one this task should create) routes to a fresh, module-scoped session of
`code-agent` — see "Dispatching code-agent sessions" in
`.claude/agents/lead.md`. The `lead` agent reads this file, routes each open
task to whichever agent owns its module, and checks tasks off as the owning
agent/session reports them done. Tasks tagged for different modules have no
shared state, so the lead can dispatch them concurrently; tasks tagged for
the same module are handed to that module's single owner one at a time.

A task can also be tagged `[inventory+billing]` when it genuinely needs both
modules to change. Neither `inventory-code-agent` nor `billing-code-agent` is allowed
to touch the other's directory, so the lead can't just hand a
`[inventory+billing]` task to one of them — see "Handling cross-module
tasks" in `.claude/agents/lead.md` for how it splits these instead.

## Open

- [ ] [inventory] `Sell` still doesn't validate `qty` against current stock
      (`inventory/inventory.go:51-58` accepts `qty <= 0` and `qty` greater
      than stock, and can drive `item.Qty` negative) despite the Completed
      entry below claiming this was fixed. Flagged by `inventory-code-agent`
      while building `Checkout` (which does have the guard) — `Sell` itself
      was left untouched as out of scope for that task. Needs its own fix
      and regression test; `inventory_test.go` has an explicit "no coverage
      yet for Sell()" placeholder comment confirming the gap.
- [ ] [billing] `Total`'s float64 accumulation (`billing/billing.go:104-114`)
      is subject to standard rounding drift over many line items, and
      neither `AddLineItem` nor `AddSaleLineItem` enforce any upper bound on
      `amount`/`qty`/`unitPrice`/`quantity`, so a very large caller-supplied
      value can push `Total()` toward `+Inf` or lose precision with no error
      returned. Flagged by `security-auditor` during the `AddLineItem`
      validation review as low/medium severity, not blocking. Consider
      integer cents or a decimal type, plus sane upper bounds.
- [ ] [shipping] `EstimateCost` (`shipping/shipping.go:55-61`) doesn't
      validate `ratePerKg` or the shipment's `Weight` — a negative rate or a
      shipment created with negative weight produces a negative cost with no
      error. `shipping` has no named owner, so this routes to a fresh
      `code-agent` session scoped to `shipping/`. `shipping_test.go` has an
      explicit "no coverage yet for EstimateCost()" placeholder comment
      confirming the gap.
- [ ] [catalog] `UpdatePrice` (`catalog/catalog.go:37-43`) doesn't validate
      `price` — it accepts a negative price and stores it unchanged, with no
      error. `catalog` has no named owner, so this routes to a fresh
      `code-agent` session scoped to `catalog/`. `catalog_test.go` has an
      explicit "no coverage yet for UpdatePrice()" placeholder comment
      confirming the gap.
- [ ] [notifications] `IncrementRetry` (`notifications/notifications.go:46-53`)
      doesn't validate `by` — a negative `by` silently decrements
      `RetryCount`, including below zero, with no error. `notifications` has
      no named owner, so this routes to a fresh `code-agent` session scoped
      to `notifications/`. `notifications_test.go` has an explicit "no
      coverage yet for IncrementRetry()" placeholder comment confirming the
      gap.
- [ ] [reporting] `AverageMetric` (`reporting/reporting.go:43-53`) divides by
      `len(rep.Metrics)` with no check for zero metrics, so a report with no
      metrics set returns `NaN` with a nil error instead of an error.
      `reporting` has no named owner, so this routes to a fresh `code-agent`
      session scoped to `reporting/`. `reporting_test.go` only covers
      reports with metrics already set — the zero-metrics case that
      triggers the bug isn't tested.
- [ ] [loyalty] `RedeemPoints` (`loyalty/loyalty.go:47-54`) doesn't validate
      `points` — it accepts a non-positive value or a value greater than the
      account's current balance, silently driving `Points` negative with no
      error (unlike `EarnPoints`, which already validates and is tested for
      it). `loyalty` has no named owner, so this routes to a fresh
      `code-agent` session scoped to `loyalty/`. `loyalty_test.go` has an
      explicit "no coverage yet for RedeemPoints()" placeholder comment
      confirming the gap.

## Completed

- [x] [billing] Several exported symbols in `billing/billing.go` have no doc
      comments (`LineItem`, `Invoice`, `Ledger`, `CreateInvoice`, `Get`,
      `AddLineItem`, `Total`, `ApplyLateFee`, `MarkPaid`). Added — remaining
      undocumented symbols (`LineItem`, `Invoice`, `Ledger`, `NewLedger`,
      `CreateInvoice`, `Get`, `Total`, `MarkPaid`) got doc comments;
      `AddLineItem`, `ApplyLateFee`, and `RenderInvoiceHTML` already picked
      theirs up as a side effect of their respective fixes landing earlier
      in this round.
- [x] [billing] `RenderInvoiceHTML` builds HTML with `fmt.Sprintf` instead of
      `html/template`, so a customer name or line-item description
      containing `<script>` renders unescaped (stored XSS). Fixed: rewrote
      to use `html/template` (billing/billing.go:130-179), which
      HTML-escapes `Customer` and each line item's `Description`.
      Regression test added asserting a `<script>` payload in either field
      renders escaped, not raw.
- [x] [billing] `AddLineItem` doesn't validate `amount`/`qty` — a negative
      amount or qty silently changes the invoice total. Fixed: rejects
      `amount < 0` and `qty <= 0` before appending, regression test added.
      Security-auditor confirmed the gap is closed (also confirmed
      `ApplyLateFee`'s call into `AddLineItem` is now protected the same
      way).
- [x] [billing] `ApplyLateFee` doesn't validate `feePercent` — a negative
      value silently discounts the invoice instead of charging a fee. Fixed:
      rejects `feePercent < 0` up front with no line item added and no
      invoice mutation, regression test added.
- [x] [inventory+billing] Add checkout support: selling inventory items
      should be able to produce a matching billing invoice for the same
      sale — same item, same quantity, same unit price on both sides — so a
      customer gets billed for exactly what left the shelf. Split into two
      independently-built halves sharing a contract (ItemID string, Quantity
      int, UnitPrice float64): inventory added `Checkout(id, qty)
      (*CheckoutResult, error)` (inventory/inventory.go), billing added
      `AddSaleLineItem(invoiceID, itemID string, quantity int, unitPrice
      float64) error` (billing/billing.go) that stores unitPrice unmultiplied
      in LineItem.Amount. Neither module imports the other; regression tests
      added on both sides.
- [x] [inventory] `Sell` didn't check quantity against stock, so stock could
      go negative — fixed with validation, regression test added.
- [x] [inventory] `ApplyPricingFormula` shelled out to `sh -c` with
      unsanitized input (command injection) — replaced with an in-process
      expression evaluator, regression tests added for injection attempts.
- [x] [inventory] `Restock` and `ApplyDiscount` had no input validation —
      fixed, regression tests added.
- [x] [inventory] Missing doc comments on exported symbols — added.

## Adding a new task

Append a line under **Open** as `- [ ] [module] description`. `[inventory]`
and `[billing]` go to their named owners. Any other module name routes to a
`code-agent` session scoped to that module — the directory doesn't need to
exist yet if the task is to create it. A tag that isn't a plausible
directory name at all (not existing, not something a new module could
reasonably be called) will be flagged by the lead as unowned instead of
routed.
