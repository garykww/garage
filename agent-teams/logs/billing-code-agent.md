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

## 2026-07-01 23:00 — Fix Total() rounding drift and add upper bounds to AddLineItem/AddSaleLineItem
**Assigned by:** lead (TASKS.md [billing] item, flagged by `security-auditor`
during the `AddLineItem` validation review, low/medium severity, not
blocking).
**Findings:** `Total` (billing/billing.go:104-114, pre-change) summed
`li.Amount * float64(li.Qty)` directly into a `float64` accumulator across
all line items — ordinary binary floating-point summation, which drifts as
more line items are added (classic `0.1 + 0.2 != 0.3` class of bug).
Separately, neither `AddLineItem` (billing.go:65) nor `AddSaleLineItem`
(billing.go:91) enforced any upper bound on `amount`/`qty`/`unitPrice`/
`quantity`, and did not reject non-finite values — a caller passing
`math.Inf(1)` for `amount` would pass the existing `amount < 0` check (since
`+Inf` is not `< 0`) and get stored, and `math.NaN()` would pass every
numeric comparison silently (NaN compares false to everything), so `Total()`
could return `+Inf` or `NaN` with no error ever returned.
**Decision:** Rather than switching `LineItem.Amount`'s exported field type
to an integer-cents or decimal type (a breaking API change touching every
caller and the HTML-rendering `%.2f` formatting), mitigated the drift inside
`Total()` only: round each line item's `Amount` to the nearest cent with
`math.Round(li.Amount*100)`, accumulate as `int64` cents, then divide back
to `float64` once at the end. This eliminates float-summation drift
entirely (each term is an exact integer, summed exactly, converted back to
float64 exactly once) at the cost of assuming line items don't need
sub-cent precision — true for ordinary currency. Paired this with new
exported bounds, `MaxLineItemAmount` (1e9) and `MaxLineItemQty` (1e6),
enforced in both `AddLineItem` and `AddSaleLineItem`, plus explicit
`math.IsNaN`/`math.IsInf` rejection (the pre-existing `< 0` checks alone
don't catch `+Inf` or `NaN`, as noted above) — this keeps every accepted
line item's contribution to `totalCents` bounded well within `int64` range
(worst case per item is `1e9 * 100 * 1e6 = 1e17`, vs. `int64` max
`~9.2e18`), so no single caller-supplied value can push `Total()` toward
`+Inf`, `NaN`, or silent overflow. Bounding the total *count* of line items
per invoice was out of scope for this task and not addressed.
**Plan:** Edited billing/billing.go:
- Added `"math"` import (billing.go:10).
- Added exported constants `MaxLineItemAmount` and `MaxLineItemQty` with doc
  comments (billing.go:62-74).
- `AddLineItem` (billing.go:76-103): added `math.IsNaN`/`math.IsInf` check,
  `amount > MaxLineItemAmount` check, and `qty > MaxLineItemQty` check;
  updated doc comment to state the new bounds.
- `AddSaleLineItem` (billing.go:105-135): added the same
  NaN/Inf/upper-bound checks on `unitPrice`/`quantity`; updated doc comment.
- `Total` (billing.go:137-160): rewrote accumulation to round each line
  item's `Amount*100` to the nearest cent (`math.Round`), sum as `int64`,
  and divide by 100 once at the end; expanded doc comment to explain why
  (float-summation drift) and the precision/overflow tradeoff.
Added tests in billing/billing_test.go:
- `TestTotalAvoidsFloatAccumulationDrift` (new): asserts `0.1 + 0.2`
  totals to exactly `0.3`, and that 100,000 line items of `$0.01` each sum
  to exactly `$1000.00`. Verified both cases actually fail under the old
  naive `float64` accumulation (checked with a standalone script): naive sum
  gives `0.30000000000000004` (want `0.3`) and `999.9999999992356` (want
  `1000`) respectively — confirming these are real regression tests for the
  fix, not just precision checks that happened to already pass.
- `TestAddLineItemValidation`: added cases for amount above
  `MaxLineItemAmount` (rejected), amount exactly at `MaxLineItemAmount`
  (accepted), qty above `MaxLineItemQty` (rejected), `+Inf` amount
  (rejected), `NaN` amount (rejected).
- `TestAddSaleLineItem`: added cases for unit price above
  `MaxLineItemAmount` (rejected), quantity above `MaxLineItemQty`
  (rejected), `+Inf` unit price (rejected).
Ran `go build ./... && go vet ./... && go test ./billing/... -cover -v`
from the repo's `agent-teams/` root — all 22 subtests pass, billing coverage
88.2% (up from 85.5%). Also ran `go build ./... && go vet ./...` across the
whole module (other packages have unrelated in-flight changes from other
agents) to confirm no cross-module breakage; confirmed via `git status`/`git
diff --stat` that my changes touch only `billing/billing.go` and
`billing/billing_test.go`. Did not touch inventory/ or any other module.
**Result:** done

## 2026-07-01 00:00 — Close two gaps in the +Inf/NaN/overflow fix (security-auditor follow-up)
**Assigned by:** lead, relaying a `security-auditor` finding on the previous
entry's fix.
**Findings:** `security-auditor` found the prior fix (bounds/finite checks
in `AddLineItem`/`AddSaleLineItem`, int64-cents accumulation in `Total`)
only partially closed the original +Inf/NaN/overflow finding:
- **Gap 1 [High] (billing.go:28, 54-60, pre-fix):** `Invoice.LineItems` was
  an exported field and `Ledger.Get` returned the ledger's live `*Invoice`
  pointer. Any caller could do
  `inv.LineItems = append(inv.LineItems, LineItem{Amount: math.Inf(1), Qty: 1})`
  after calling `Get`, appending a malformed, unvalidated `LineItem`
  straight into the stored invoice — completely bypassing
  `AddLineItem`/`AddSaleLineItem`'s validation and reintroducing the exact
  +Inf/NaN problem the previous fix targeted, since `Total` had no defense
  against malformed items already sitting in the slice.
- **Gap 2 [Medium] (billing.go:154-158, pre-fix):** `Total`'s int64-cents
  accumulation was bounded per line item (≤ 1e9 × 100 × 1e6 = 1e17 cents),
  but nothing capped the *number* of line items per invoice. int64 max is
  ~9.22e18, so ~93 max-magnitude line items would silently wrap
  `totalCents` past int64 max — Go integer overflow is silent, not a panic
  — producing a negative or garbage total with no error.
**Decision:**
- Gap 1: unexported `Invoice.LineItems` to `Invoice.lineItems`, and added an
  exported `Invoice.LineItems()` accessor method that returns a defensive
  copy of the slice (so callers can still read line items, including from
  `html/template`'s separate `renderLineItem` view-model path, which was
  already unaffected since it builds its own local struct). Split `Ledger`'s
  internal lookup into an unexported `get` (returns the live pointer, used
  only by `Ledger`'s own methods: `AddLineItem`, `Total`, `MarkPaid`,
  `RenderInvoiceHTML`) and the exported `Get` (returns a copy of the
  invoice, with `lineItems` deep-copied, so mutating the returned
  `*Invoice` — fields or line items — never reaches the ledger's stored
  data). This closes the bypass for external callers at compile time
  (`lineItems` isn't reachable outside the package at all) and for any
  caller reachable via `Get` at the copy-semantics level (mutating the
  returned pointer is a no-op on the stored invoice either way). While in
  there, fixed a bug my own change would otherwise have introduced:
  `MarkPaid` originally called `Get`, and once `Get` returns a copy instead
  of the live pointer, setting `Status` on that copy would silently stop
  persisting — routed `MarkPaid` through the new internal `get` instead so
  the mutation still lands on the stored invoice.
- Gap 2: chose overflow *detection* in `Total`'s accumulation loop over a
  hard cap on line-item count (`MaxLineItems`), because a hard count cap
  would have broken the existing, legitimate
  `TestTotalAvoidsFloatAccumulationDrift` case (100,000 small $0.01 line
  items, which is fine — no overflow risk at that magnitude) — the actual
  risk is specifically about the *combination* of item count and
  per-item magnitude, which a flat count cap can't distinguish and a
  running-sum overflow check can. Since `AddLineItem`/`AddSaleLineItem`
  already reject negative amounts, every line item's contribution to
  `totalCents` is `>= 0`, so the running total should only ever increase;
  the loop now checks `newTotal < totalCents` after each addition (a
  standard signed-overflow tell when both addends are non-negative) and
  returns an error instead of a silently wrapped total.
**Plan:** Edited `billing/billing.go`:
- `Invoice` (billing.go:23-37): unexported `LineItems` → `lineItems`; doc
  comment explains why.
- Added `Invoice.LineItems()` accessor (billing.go:39-47): returns a
  defensive copy.
- Added `Ledger.get` (billing.go:69-80, unexported, live pointer, internal
  use only) alongside the existing `Ledger.Get` (billing.go:82-100, now
  returns a copy with `lineItems` deep-copied); doc comments on both explain
  the split and why it closes the bypass.
- `AddLineItem` (billing.go:121, 141): switched to `l.get`; appends to
  `inv.lineItems`.
- `Total` (billing.go:177-218): switched to `l.get`; rewrote the
  accumulation loop to detect and reject overflow (`newTotal < totalCents`
  check) instead of a bare `+=`; expanded doc comment to explain the
  ~93-item wraparound risk and why the check is safe (all contributions are
  non-negative).
- `MarkPaid` (billing.go:242-249): switched from `l.Get` to `l.get` so
  `Status` mutations persist now that `Get` returns a copy (see Decision
  above — this was a latent bug my own Gap-1 fix would have introduced if
  left on `Get`).
- `RenderInvoiceHTML` (billing.go:273-279): switched to `l.get` and
  `inv.lineItems` (its own local `renderLineItem`/`data` view-model types
  are unrelated to `Invoice` and needed no changes; `html/template` still
  ranges over the local `data.LineItems` field, which was never affected by
  this change).
Updated `billing/billing_test.go`: replaced every direct
`inv.LineItems`/`inv.LineItems[i]` field access with
`inv.LineItems()`/`inv.LineItems()[i]` method calls (`TestAddLineItemValidation`,
`TestAddSaleLineItem`, `TestApplyLateFeeValidation`) to match the new
accessor. Added two new regression tests:
- `TestGetReturnsCopyNotLiveInvoice`: calls `Get`, then — from inside the
  `billing` package, the only place this compiles at all now — mutates the
  returned `*Invoice`'s unexported `lineItems` (appending a `math.Inf(1)`
  line item, exactly the auditor's repro) and its `Status`, then re-`Get`s
  the invoice and checks `Total` to prove the ledger's stored invoice was
  completely unaffected. Doc comment on the test explains why this is the
  right thing to assert given the test file shares `package billing` (so
  unexporting alone doesn't block it the way it would from outside the
  package — the copy-on-`Get` semantics is what's actually being proven).
- `TestTotalRejectsIntegerOverflowFromManyLineItems`: adds 200 line items
  each at `MaxLineItemAmount`/`MaxLineItemQty` (well past the ~93-item
  wraparound point) and asserts `Total` returns an error and `0`, not a
  wrapped/garbage total.
Ran `go build ./... && go vet ./... && go test ./billing/... -cover -v`
from the repo's `agent-teams/` root — all tests pass (24 top-level/subtests
across the package), coverage 88.9%. Confirmed via `git status`/`git diff
--stat` that my changes touch only `billing/billing.go` and
`billing/billing_test.go` (other modified files in the working tree —
`catalog/`, `inventory/`, `loyalty/`, `notifications/`, `reporting/`,
`shipping/`, and their logs — are pre-existing in-flight changes from other
agents, not mine). Did not touch `inventory/` or any other module.
**Communication:**
- ← `security-auditor` (relayed via lead): the two-gap finding this entry
  addresses (Gap 1 High: exported `LineItems` field + `Get` returning the
  live pointer bypasses line-item validation; Gap 2 Medium: unbounded
  line-item count can silently overflow `Total`'s int64 accumulator).
- → `security-auditor`: not re-invoked for a second-opinion pass on this
  fix — no agent-invocation tool was available in this session's toolset
  (only file read/write/edit and bash), so I could not actually launch it.
  Flagging this back to the lead: if a second opinion on this
  security-sensitive fix is wanted before it's considered closed, it needs
  to be dispatched from a session that has the capability to call
  `security-auditor`.
**Result:** done
