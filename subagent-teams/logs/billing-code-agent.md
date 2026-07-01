# billing-code-agent — activity log

Format: see `logs/README.md`. Append-only, oldest entry first.

<!-- entries appended below -->

## 2026-07-01 00:00 — Add AddSaleLineItem for cross-module checkout support
**Assigned by:** lead (split of "[inventory+billing] Add checkout support" from TASKS.md)
**Findings:** No existing hook for recording an inventory sale as an invoice
line item. `AddLineItem` (billing/billing.go:44) still has no amount/qty
validation (a separately tracked gap), so it was unsafe to call directly
from new financial-calculation code without adding validation at the call
site.
**Decision:** Added a new exported method `AddSaleLineItem(invoiceID,
itemID string, quantity int, unitPrice float64) error` at
billing/billing.go:64 rather than modifying `AddLineItem` itself, to keep
this change scoped to the checkout task. `AddSaleLineItem` validates
`quantity > 0` and `unitPrice >= 0` itself before delegating to
`AddLineItem`, so it is safe regardless of whether `AddLineItem`'s own
validation follow-up lands before or after this change. Per the contract
handed down by the lead, `unitPrice` is stored as-is in `LineItem.Amount`
(per-unit, not pre-multiplied by quantity) since `Total()` already
multiplies Amount * Qty. Description is built as `fmt.Sprintf("Item %s",
itemID)` so the raw inventory item ID stays visible/recoverable on the
invoice.
**Plan:** Implemented `AddSaleLineItem` in billing/billing.go:64-83; added
doc comment. Added table-driven `TestAddSaleLineItem` in
billing/billing_test.go:28 covering (1) successful sale — asserts
`LineItem.Amount == unitPrice` (not unitPrice*quantity), `LineItem.Qty ==
quantity`, and `Total()` reflects unitPrice*quantity; (2) quantity <= 0
rejected (zero and negative cases); (3) negative unitPrice rejected. Ran
`gofmt -w`, then `go build ./... && go vet ./... && go test ./billing/...
-cover` — all clean, coverage 58.7%. Did not touch inventory/ — this task
only required implementing the billing-side function receiving the three
plain fields (ItemID, Quantity, UnitPrice) from inventory's
`CheckoutResult`; no import of the inventory package was needed or added.
**Communication:**
- ← lead: handed down the data contract — inventory's `Checkout(id, qty)`
  returns `CheckoutResult{ItemID string, Quantity int, UnitPrice float64}`,
  and an external (out-of-scope) caller passes those three fields into this
  new `AddSaleLineItem` method. Contract was unambiguous; implemented
  exactly as specified, no escalation needed.
**Result:** done

## 2026-07-01 00:15 — Validate amount/qty in AddLineItem
**Assigned by:** lead (TASKS.md: "`AddLineItem` doesn't validate
`amount`/`qty` — a negative amount or qty silently changes the invoice
total.")
**Findings:** `AddLineItem` (billing/billing.go:44, pre-change) appended a
`LineItem` unconditionally — a negative `amount` would silently reduce
`Total()` (billing.go:75-85 sums `Amount * Qty`), and `qty <= 0` would
either zero out or flip the sign of that line's contribution. No guard
existed. `AddSaleLineItem` (billing.go:64) already pre-validates
`quantity > 0` and `unitPrice >= 0` before delegating to `AddLineItem`, so
its bounds are equal-or-stricter than the new checks — no conflict.
`ApplyLateFee` (billing.go:87) calls `AddLineItem(invoiceID, "Late fee",
fee, 1)` with a `fee` that can currently go negative since `feePercent` is
unvalidated (separate open task) — my new validation will now correctly
start rejecting negative late fees. Left `ApplyLateFee` untouched per the
lead's note that it's a separate follow-up task.
**Decision:** Added validation directly inside `AddLineItem` rather than
only at call sites, so every current and future caller gets the guarantee.
Reject `amount < 0` and `qty <= 0`, each with a descriptive
`fmt.Errorf`, added before the line item is appended so no item is added
and the invoice is left unchanged on either violation.
**Plan:** Edited billing/billing.go:44-59 — added doc comment to
`AddLineItem` and the two validation checks. Added table-driven
`TestAddLineItemValidation` in billing/billing_test.go covering: negative
amount rejected (no line item added, `Total()` stays 0), qty == 0
rejected, qty < 0 rejected, and a valid call succeeds with `Total()`
correctly reflecting amount*qty. Updated the stale trailing comment in
billing_test.go that previously flagged this gap as uncovered. Ran
`go build ./... && go vet ./... && go test ./billing/... -cover -v` (all
pass, including `TestAddSaleLineItem` — no regression) and `go test ./...`
across the repo (billing + inventory both pass). Coverage 62.0%.
**Result:** done

## 2026-07-01 00:30 — Validate feePercent in ApplyLateFee
**Assigned by:** lead (TASKS.md: "`ApplyLateFee` doesn't validate
`feePercent` — a negative value silently discounts the invoice instead of
charging a fee.")
**Findings:** `ApplyLateFee` (billing/billing.go:97-107, pre-change)
computed `fee := total * feePercent / 100` with no bound check on
`feePercent`. A negative `feePercent` produced a negative `fee`, which
`AddLineItem` (now guarded per the prior 2026-07-01 00:15 entry) would
reject with a generic "invalid amount for line item \"Late fee\": ..."
error — correct in effect but the error message doesn't name the actual
input problem (negative `feePercent`) and only surfaces two calls deep.
**Decision:** Added an explicit `feePercent < 0` check at the top of
`ApplyLateFee`, before `Total()` is even called, returning a specific
`fmt.Errorf` naming the invoice and the bad feePercent. This is
belt-and-suspenders with the `AddLineItem` guard (kept both, per the
task's instruction) — early validation gives a clearer, more specific
error and avoids any wasted work computing `Total()` on a request that's
going to be rejected anyway.
**Plan:** Edited billing/billing.go:97-102 — added a doc comment to
`ApplyLateFee` (previously undocumented) and the negative-feePercent
guard, returning before any line item is added or the invoice is touched.
Added table-driven `TestApplyLateFeeValidation` in billing_test.go
covering: negative feePercent rejected with no late-fee line item added
and `Total()` unchanged at the pre-existing line item's value, and a valid
feePercent (10% on a $100 invoice) correctly adds a "Late fee" line item
of amount 10 and returns/totals 110. Removed the stale comment noting this
gap as uncovered (left the RenderInvoiceHTML note in place — untouched,
separate task). Ran `go build ./... && go vet ./... && go test
./billing/... -cover` — all pass, coverage 73.1%.
**Result:** done

## 2026-07-01 00:45 — Fix stored XSS in RenderInvoiceHTML
**Assigned by:** lead (TASKS.md: "`RenderInvoiceHTML` builds HTML with
`fmt.Sprintf` instead of `html/template`, so a customer name or line-item
description containing `<script>` renders unescaped (stored XSS). Fix and
add a regression test."), citing an earlier `security-auditor` finding.
**Findings:** `RenderInvoiceHTML` (billing/billing.go:128-139, pre-change)
built its HTML fragment with `fmt.Sprintf("<h1>Invoice %s</h1><p>Customer:
%s</p><ul>", inv.ID, inv.Customer)` and, per line item,
`fmt.Sprintf("<li>%s: $%.2f x %d</li>", li.Description, li.Amount,
li.Qty)` — `inv.Customer` and `li.Description` were interpolated raw with
no escaping. `CreateInvoice` (billing.go:34) takes `customer` directly
from the caller with no sanitization, and `AddLineItem`/`AddSaleLineItem`
(billing.go:52, 78) likewise accept `description`/`itemID` unsanitized
(`AddSaleLineItem` builds `description` as `fmt.Sprintf("Item %s",
itemID)`, so a malicious `itemID` flows straight through) — so a customer
name or description containing `<script>alert(1)</script>` rendered as
live, unescaped markup in the returned HTML: a confirmed stored-XSS
sink. No prior test coverage existed for this method at all.
**Decision:** Replaced the `fmt.Sprintf` string-building with
`html/template`, per the task's instruction, rather than hand-rolling
escaping — `html/template` auto-escapes per HTML context and is the
standard-library-correct fix. Kept the exact same output shape (h1 with
invoice ID, p with customer, ul of "Description: $Amount x Qty" items) so
existing consumers see identical structure, just escaped. Introduced a
small `renderLineItem` view-model struct carrying a pre-formatted
`AmountStr` (via `fmt.Sprintf("%.2f", ...)`) because `html/template`'s
default float formatting doesn't reproduce the historical "%.2f" output
exactly — this preserves byte-for-byte amount formatting while still
routing `Description` through the escaping template.
**Plan:** Edited billing/billing.go:130-179 — added a package-level
`invoiceHTMLTemplate` (`html/template`, parsed once via `template.Must`),
the `renderLineItem` struct, and rewrote `RenderInvoiceHTML` to build a
view model and `Execute` the template into a `strings.Builder`, returning
a wrapped error if template execution fails (it shouldn't, given a fixed
template and simple struct data, but `Execute` can error). Added doc
comments to the new template var, `renderLineItem`, and expanded
`RenderInvoiceHTML`'s existing doc comment to note the escaping guarantee.
Added `TestRenderInvoiceHTMLEscapesUntrustedInput` to
billing/billing_test.go (table-driven, two cases: malicious customer name,
malicious line-item description, each using
`<script>alert(1)</script>`), asserting the raw `<script>` tag is absent
from output (`strings.Contains(out, "<script>")` is false) and the escaped
form `&lt;script&gt;alert(1)&lt;/script&gt;` is present. Removed the
now-stale "No coverage yet for RenderInvoiceHTML's unescaped output"
comment that flagged this gap. Ran `gofmt -l billing/` (clean), then
`go build ./... && go vet ./... && go test ./billing/... -cover` and `go
test ./... -cover` from repo root — all pass, no regressions in the
existing suite (`TestAddSaleLineItem`, `TestApplyLateFeeValidation`,
etc.), billing coverage now 85.5%. Did not touch inventory/.
**Communication:**
- ← lead: relayed a `security-auditor` finding confirming this was a real,
  currently-exploitable stored XSS via `AddSaleLineItem`'s
  unsanitized-`itemID` → `Description` → unescaped-HTML path; used that to
  scope the regression test to both the customer-name and
  line-item-description injection points.
**Result:** done

## 2026-07-01 22:20 — Add missing Go doc comments to exported symbols in billing.go
**Assigned by:** lead (TASKS.md [billing] item)
**Findings:** Re-checked billing/billing.go against the task's original list
(`LineItem`, `Invoice`, `Ledger`, `CreateInvoice`, `Get`, `AddLineItem`,
`Total`, `ApplyLateFee`, `MarkPaid`). Confirmed `AddLineItem` (line 61),
`AddSaleLineItem` (line 80), `ApplyLateFee` (line 116), and
`RenderInvoiceHTML` (line 165) already carry doc comments from prior
validation/XSS-fix work, as the task note said. Still missing doc comments:
`LineItem` (type, was line 13), `Invoice` (type, was line 19), `Ledger`
(type, was line 26), `NewLedger` (func, was line 30), `CreateInvoice`
(method, was line 34), `Get` (method, was line 40), `Total` (method, was
line 89), and `MarkPaid` (method, was line 121).
**Decision:** Doc-only task, no behavior change. Wrote each comment
starting with the symbol name per Go convention (`// LineItem represents...`
style), describing purpose/invariants briefly, consistent with the tone of
the existing comments on `AddLineItem`/`ApplyLateFee`/`RenderInvoiceHTML`.
No test changes — existing tests should (and do) pass untouched.
**Plan:** Edited billing/billing.go, adding doc comments at:
- `LineItem` type: billing.go:13-15 (comment above type at old line 13,
  now lines 13-20 with comment)
- `Invoice` type: billing.go:22-24 (now lines 22-29 with comment)
- `Ledger` type: billing.go:31-32 (now lines 31-35 with comment)
- `NewLedger` func: billing.go:37 (now lines 37-40 with comment)
- `CreateInvoice` method: billing.go:42-44 (now lines 42-49 with comment)
- `Get` method: billing.go:51-52 (now lines 51-59 with comment)
- `Total` method: billing.go:102-103 (now lines 102-114 with comment)
- `MarkPaid` method: billing.go:136-137 (now lines 136-145 with comment)
Verified no duplication against the already-documented symbols
(`AddLineItem`, `AddSaleLineItem`, `ApplyLateFee`, `RenderInvoiceHTML`,
plus the unexported `invoiceHTMLTemplate` and `renderLineItem`, which also
already had comments) — left those untouched. Ran
`go build ./... && go vet ./... && go test ./billing/... -cover` (pass,
85.5% coverage, unchanged) and `go test ./...` from repo root (both
billing and inventory packages pass, confirming no accidental cross-module
edits). Did not touch billing_test.go or inventory/.
**Result:** done
