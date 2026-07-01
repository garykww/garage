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

- [ ] [billing] Low-severity, non-blocking items surfaced by `security-auditor`
      during the final verification pass on the `Total`/bounds fix (see
      Completed entry below): (1) `Ledger.CreateInvoice`
      (`billing/billing.go:63-67`) still returns the live `*Invoice` pointer,
      asymmetric with `Get`'s new copy contract — a caller can set
      `inv.Status = "paid"` directly, bypassing `MarkPaid`. (2) `Total`'s
      `float64(totalCents)/100` conversion (`billing/billing.go:217`) loses
      integer-cent precision above ~$90T, below the ~$92.2 quadrillion
      overflow-detection ceiling the new check guards — a single
      max-magnitude line item can already approach this. Neither is
      blocking; worth a future pass.

## Completed

- [x] [billing] `Total`'s float64 accumulation (`billing/billing.go:104-114`)
      was subject to standard rounding drift over many line items, and
      neither `AddLineItem` nor `AddSaleLineItem` enforced any upper bound on
      `amount`/`qty`/`unitPrice`/`quantity`, so a very large caller-supplied
      value could push `Total()` toward `+Inf` or lose precision with no
      error returned. Flagged by `security-auditor` as low/medium severity.
      Fixed in two passes: first pass added `MaxLineItemAmount`/
      `MaxLineItemQty` constants, NaN/Inf/upper-bound rejection in
      `AddLineItem`/`AddSaleLineItem`, and switched `Total` to int64-cents
      accumulation (`billing/billing.go:62-160`ish). A follow-up
      `security-auditor` review found this only partially closed the gap —
      `Ledger.Get` returned the live `*Invoice` with an exported `LineItems`
      slice, letting callers bypass validation by appending directly, and
      the cents accumulator had no cap on line-item count (~93 max-magnitude
      items would silently overflow int64). Second pass fixed both:
      `Invoice.lineItems` unexported (`billing.go:35`) with a defensive-copy
      `LineItems()` accessor (`billing.go:43-47`); `Ledger.Get` now returns a
      value copy with an independently-copied `lineItems` slice
      (`billing.go:92-100`); `Total`'s accumulation loop now detects int64
      overflow and errors instead of wrapping (`billing.go:207-216`).
      Regression tests: `TestGetReturnsCopyNotLiveInvoice`
      (billing_test.go:444-483) and
      `TestTotalRejectsIntegerOverflowFromManyLineItems`
      (billing_test.go:497-518), plus the first-pass precision/bounds tests.
      Independently verified fully closed by a second `security-auditor`
      pass (`go test ./... -run 'TestGetReturnsCopyNotLiveInvoice|TestTotalRejectsIntegerOverflowFromManyLineItems'
      -v` and full suite both pass, 88.9% coverage). Two new low-severity,
      non-blocking observations surfaced during the final audit were filed
      as a new Open `[billing]` task rather than fixed in this pass.
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
- [x] [inventory] `Sell` still didn't validate `qty` against current stock
      (`inventory/inventory.go:51-58` accepted `qty <= 0` and `qty` greater
      than stock, driving `item.Qty` negative), despite the earlier Completed
      entry above claiming this was fixed — `Sell` had been left untouched
      as out of scope when `Checkout` picked up the guard. Fixed:
      `inventory/inventory.go:51-68` now rejects `qty <= 0` and
      `qty > item.Qty` before mutating stock. Regression test `TestSell`
      added to `inventory_test.go`, replacing the "no coverage yet for
      Sell()" placeholder; full suite passes
      (`agent-teams-demo/inventory`, 68.6% coverage).
- [x] [shipping] `EstimateCost` (`shipping/shipping.go:55-61`) didn't
      validate `ratePerKg` or the shipment's `Weight`, so a negative rate or
      shipment weight produced a negative cost with no error. Fixed by a
      fresh `code-agent` session scoped to `shipping/`:
      `shipping/shipping.go:53-70` now rejects negative `ratePerKg` and
      negative `Weight`. Regression tests added at
      `shipping/shipping_test.go:28-56`, replacing the "no coverage yet for
      EstimateCost()" placeholder; full suite passes
      (`agent-teams-demo/shipping`, 84.6% coverage). New log file created:
      `logs/shipping-code-agent.md`.
- [x] [catalog] `UpdatePrice` (`catalog/catalog.go:37-43`) didn't validate
      `price`, accepting a negative price and storing it unchanged with no
      error. Fixed by a fresh `code-agent` session scoped to `catalog/`:
      `catalog/catalog.go:40-42` now rejects `price < 0` before mutation.
      Regression tests added to `catalog_test.go`, replacing the "no
      coverage yet for UpdatePrice()" placeholder; full suite passes
      (`agent-teams-demo/catalog`, 90.5% coverage). New log file created:
      `logs/catalog-code-agent.md`.
- [x] [notifications] `IncrementRetry` (`notifications/notifications.go:46-53`)
      didn't validate `by`, so a negative `by` silently decremented
      `RetryCount` below zero with no error. Fixed by a fresh `code-agent`
      session scoped to `notifications/`: `notifications/notifications.go:47-50`
      now rejects negative `by` before mutation. Regression tests added to
      `notifications_test.go`, replacing the "no coverage yet for
      IncrementRetry()" placeholder; full suite passes
      (`agent-teams-demo/notifications`, 85.0% coverage). New log file
      created: `logs/notifications-code-agent.md`.
- [x] [reporting] `AverageMetric` (`reporting/reporting.go:43-53`) divided by
      `len(rep.Metrics)` with no check for zero metrics, returning `NaN`
      with a nil error instead of an error. Fixed by a fresh `code-agent`
      session scoped to `reporting/`: `reporting/reporting.go:48-50` now
      returns an error when `len(rep.Metrics) == 0`. Regression test
      `TestAverageMetricNoMetrics` added at `reporting_test.go:34-43`; full
      suite passes (`agent-teams-demo/reporting`, 86.4% coverage). New log
      file created: `logs/reporting-code-agent.md`.
- [x] [loyalty] `RedeemPoints` (`loyalty/loyalty.go:47-54`) didn't validate
      `points`, accepting a non-positive value or a value greater than the
      account's current balance and silently driving `Points` negative.
      Fixed by a fresh `code-agent` session scoped to `loyalty/`:
      `loyalty/loyalty.go:47-61` now rejects `points <= 0` and
      `points > a.Points` before mutation, mirroring `EarnPoints`'s
      validation style. Regression tests added to `loyalty_test.go`,
      replacing the "no coverage yet for RedeemPoints()" placeholder; full
      suite passes (`agent-teams-demo/loyalty`, 87.5% coverage). New log
      file created: `logs/loyalty-code-agent.md`.

## Adding a new task

Append a line under **Open** as `- [ ] [module] description`. `[inventory]`
and `[billing]` go to their named owners. Any other module name routes to a
`code-agent` session scoped to that module — the directory doesn't need to
exist yet if the task is to create it. A tag that isn't a plausible
directory name at all (not existing, not something a new module could
reasonably be called) will be flagged by the lead as unowned instead of
routed.
