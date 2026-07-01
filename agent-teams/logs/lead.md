# lead — activity log

Format: see `logs/README.md`. Append-only, oldest entry first.

<!-- entries appended below -->

## 2026-07-01 — Dispatch round: 5 Open tasks (1 cross-module, 4 [billing])
**Assigned by:** direct request ("work through the open backlog")
**Findings:** Read TASKS.md Open section: one `[inventory+billing]` checkout
task, and four `[billing]` tasks (AddLineItem validation, ApplyLateFee
validation, RenderInvoiceHTML XSS, missing doc comments). No `[inventory]`-only
tasks and no unowned/mistagged tasks this round.
**Decision:**
- The cross-module task needed splitting per the "Handling cross-module
  tasks" procedure — designed a shared contract of three plain fields
  (`ItemID string`, `Quantity int`, `UnitPrice float64`) rather than a shared
  struct type, so neither module imports the other. Inventory is the callee
  (produces the sale data via a new `Checkout` method); billing is the callee
  on the receiving end (accepts the three fields via a new `AddSaleLineItem`
  method). Dispatched both halves concurrently to `inventory-code-agent` and
  `billing-code-agent` since they touch different directories with no shared
  state at build time.
- The four `[billing]` tasks all route to the single `billing-code-agent`
  owner, so — per the "same module → sequential" rule — dispatched them one
  at a time, in file order, after the cross-module billing half landed:
  AddLineItem validation → ApplyLateFee validation → RenderInvoiceHTML XSS →
  doc comments.
- Pulled in `security-auditor` twice, ad hoc: once after the AddLineItem/
  ApplyLateFee validation fixes (financial-calculation code — verify the
  "negative amount/qty silently changes total" gap was actually closed, and
  check whether ApplyLateFee's fee could still slip through), and once after
  the RenderInvoiceHTML fix (HTML output — verify html/template, not
  text/template, is actually in use and the escaping isn't bypassed
  anywhere). Ran the second audit in parallel with dispatching the doc
  comments task to billing-code-agent, since they don't share state.
**Plan:** See Communication log below for the exact sequence.
**Communication:**
- → inventory-code-agent: "Add `Checkout(id string, qty int) (*CheckoutResult, error)`
  to inventory/inventory.go, where `CheckoutResult{ItemID string, Quantity int,
  UnitPrice float64}`. Behave like Sell (decrement stock, reject qty<=0 and
  qty>stock, no partial deduction on error) but return the sale data instead
  of revenue. Do not import billing. Add regression tests."
  ← Added `CheckoutResult` struct and `Checkout` method
  (inventory/inventory.go:60-98), table-driven `TestCheckout` in
  inventory_test.go covering success, qty>stock, qty==0, qty<0 — all pass
  (`go test ./inventory/... -cover`, 57.4%). Flagged (not acted on, correctly
  out of scope): `Sell` itself still has zero qty validation despite
  TASKS.md's Completed section claiming it was fixed — filed as a new Open
  task below.
- → billing-code-agent: "Add `AddSaleLineItem(invoiceID string, itemID string,
  quantity int, unitPrice float64) error` to billing/billing.go. itemID
  becomes part of LineItem.Description; unitPrice must be stored as-is in
  LineItem.Amount (NOT pre-multiplied by quantity, since Total() already
  does Amount*Qty); reject quantity<=0 and unitPrice<0. Do not import
  inventory. Add regression tests."
  ← Added `AddSaleLineItem` (billing/billing.go:64-83, later renumbered as
  other fixes landed), validates before delegating to `AddLineItem`,
  `TestAddSaleLineItem` added asserting Amount==unitPrice (not
  unitPrice*quantity) and Total()==unitPrice*quantity — pass, 58.7% coverage.
- **Contract check:** `CheckoutResult{ItemID, Quantity, UnitPrice}` (inventory)
  vs `AddSaleLineItem(invoiceID, itemID, quantity, unitPrice)` (billing) —
  field names and types line up exactly on both sides; unitPrice is per-unit
  on both ends (inventory returns `item.Price` un-multiplied, billing stores
  it un-multiplied in `Amount`). No mismatch found, no rework needed. Marked
  `[inventory+billing]` task done in TASKS.md.
- → billing-code-agent: "Add validation to AddLineItem: reject amount<0 and
  qty<=0, no line item added on violation. Check compatibility with the just
  added AddSaleLineItem's own pre-validation and with ApplyLateFee's call
  into AddLineItem. Add regression tests."
  ← Added checks at billing.go:52-59 (`amount < 0` and `qty <= 0`, both
  return before append). `TestAddLineItemValidation` added covering negative
  amount, qty==0, qty<0, and a valid-input control case. Confirmed no
  conflict with AddSaleLineItem or regression in its own tests. `go test
  ./billing/... -cover` → 62.0%, all pass.
- → security-auditor: "Verify AddLineItem's new validation actually closes
  the 'negative amount/qty silently changes total' gap, and whether
  ApplyLateFee's negative-fee path is now caught."
  ← Verdict: gap CLOSED. Only append site for LineItem is inside the
  validated AddLineItem (billing.go:59); ApplyLateFee's call at billing.go:103
  now surfaces an error instead of silently corrupting Total() when fee is
  negative. Also flagged two new, lower-severity items unprompted: float64
  rounding drift in Total(), and no upper bound on amount/qty/unitPrice/
  quantity (possible +Inf/precision loss on very large input) — filed both
  as a new Open `[billing]` task below since they weren't part of the
  original ask and weren't fixed in this pass.
- → billing-code-agent: "Add validation to ApplyLateFee: reject
  feePercent<0 early, with a clear error message, before it reaches
  AddLineItem's generic amount check. Add regression tests."
  ← Added check at billing.go:102-105 (rejects `feePercent < 0` before
  computing `total`, so no Total() call and no line item on violation).
  Regression test covers negative feePercent (rejected, no mutation) and a
  valid feePercent (fee line item added, total+fee returned correctly). `go
  test ./billing/...` passes.
- → billing-code-agent: "Fix RenderInvoiceHTML: replace fmt.Sprintf-built
  HTML with html/template so Customer and each line item's Description are
  escaped. Preserve existing output shape. Add a regression test with a
  <script> payload in both fields, asserting the raw tag doesn't appear in
  output."
  ← Rewrote using html/template (billing.go:130-179): package-level parsed
  template, a `renderLineItem` view model with pre-formatted `AmountStr`
  (since html/template's default float formatting doesn't match the old
  "%.2f" output). `TestRenderInvoiceHTMLEscapesUntrustedInput` added,
  injecting `<script>alert(1)</script>` via both customer name and
  line-item description, asserting the raw tag is absent and the escaped
  form is present. `go test ./billing/... -cover` → 85.5%, no regressions.
- → security-auditor (parallel with the doc-comments dispatch below): "Verify
  the RenderInvoiceHTML fix: confirm html/template (not text/template) is
  actually imported, no remaining raw fmt.Sprintf builds HTML, .Customer/
  .Description aren't marked template.HTML (unescaped), and the regression
  test genuinely exercises a <script> payload rather than just a happy path."
  ← Verdict: gap CLOSED. Confirmed `"html/template"` import (billing.go:9),
  no other HTML-building fmt.Sprintf calls in the file, plain `{{.Customer}}`/
  `{{.Description}}` interpolation (no unescaping override), and the test
  (billing_test.go:283-324) injects a real `<script>` payload via both
  fields and asserts both absence of the raw tag and presence of the
  escaped form. Ran the test directly to confirm it passes.
- → billing-code-agent (dispatched in parallel with the security-auditor
  verification above): "Add doc comments to remaining undocumented exported
  symbols in billing.go — re-check current state since several symbols
  picked up docs as a side effect of the validation/XSS fixes already
  landing."
  ← Confirmed AddLineItem, AddSaleLineItem, ApplyLateFee, RenderInvoiceHTML
  already had doc comments from prior fixes; added new ones for LineItem,
  Invoice, Ledger, NewLedger, CreateInvoice, Get, Total, MarkPaid. Doc-only
  change, no test edits; `go test ./...` from repo root confirms both
  packages still pass, no accidental cross-module edits.
**Result:** done — all 5 originally Open tasks completed and checked off in
TASKS.md (1 cross-module split + 4 billing). Two new findings surfaced during
this round were filed as new Open tasks rather than fixed in-pass (out of
scope for their discovering task): `[inventory] Sell still doesn't validate
qty` (flagged by inventory-code-agent) and `[billing] Total's float64
precision / missing upper bounds` (flagged by security-auditor).

