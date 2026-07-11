# Backlog

This file is the *seed* for the demo, not the coordination mechanism. In
the sibling `subagent-teams/` app, `TASKS.md` **is** the task list — the
lead re-reads and re-edits it every round. Here, coordination lives in the
native shared task list: the lead reads this file once at kickoff, creates
one task per entry (with the dependencies noted below), and from then on
teammates claim, block on, and complete tasks through the feature itself.
This file just records what was planted, so any fresh session can restage
the demo.

## Tasks to seed

1. **[cart]** `AddItem` (`cart/cart.go`) validates `productID` but not
   `qty` or `unitPrice` — a `qty <= 0` or a negative `unitPrice` is stored
   as-is and silently skews `Total`. Fix the validation and add the
   regression tests `cart/cart_test.go`'s placeholder comment admits are
   missing.

2. **[payment]** `Refund` (`payment/payment.go`) accepts a non-positive
   `amount` and a cumulative refund greater than the captured amount —
   unlike `Capture`, which validates and is tested for it. Fix the
   validation and add the regression tests `payment/payment_test.go`'s
   placeholder comment admits are missing.

3. **[emailer]** `RenderReceiptHTML` (`emailer/emailer.go`) builds HTML
   with `fmt.Sprintf`, so a customer name or receipt line containing
   `<script>` renders unescaped (stored XSS). Rewrite it on
   `html/template` and add a regression test asserting a script payload in
   either field renders escaped.

4. **[qa] — blocked on 1, 2, and 3.** Coverage pass across all three
   modules: run `go test ./... -cover`, close any remaining gaps flagged
   by placeholder comments or untested validation paths, and report
   per-package coverage before and after. Seeding this with dependencies
   demonstrates the native task list's blocking: it stays unclaimable
   until the three fixes complete, then unblocks automatically.

5. **[cart+payment]** Checkout: paying for a cart should produce one
   captured charge whose amount matches `Cart.Total()`, built as one
   `cart/`-side piece and one `payment/`-side piece that share a data
   contract but no imports. The two owners negotiate the contract (field
   names, types, units — unit price vs. line total is a real decision)
   directly over teammate messaging, send the lead the agreed text, and
   implement their halves independently. This is the scenario that is
   *impossible by construction* in `subagent-teams/`, where the lead has
   to design the contract because subagents can't talk to each other.

6. **[payment] — plan approval required.** `Charge.Amount` and
   `Charge.Refunded` are `float64`; migrate the ledger to integer cents to
   eliminate float drift. Architectural enough that the owner must plan
   first: spawn it with required plan approval, and have the lead approve
   only a plan that covers rounding regression tests and the fate of the
   exported API (see CLAUDE.md for the approval criteria).

## Adding a task

Append an entry here before kickoff, or — mid-session — just ask the lead
to add it to the shared task list directly. Tag it with the module it
belongs to; a `[a+b]` tag means the owners negotiate a contract first.
