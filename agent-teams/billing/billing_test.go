package billing

import (
	"math"
	"strings"
	"testing"
)

func TestCreateInvoice(t *testing.T) {
	l := NewLedger()
	inv := l.CreateInvoice("inv-1", "Acme Co")
	if inv.Status != "open" {
		t.Fatalf("expected status open, got %s", inv.Status)
	}
}

func TestAddLineItemAndTotal(t *testing.T) {
	l := NewLedger()
	l.CreateInvoice("inv-1", "Acme Co")
	if err := l.AddLineItem("inv-1", "Widgets", 10, 3); err != nil {
		t.Fatal(err)
	}
	total, err := l.Total("inv-1")
	if err != nil {
		t.Fatal(err)
	}
	if total != 30 {
		t.Fatalf("expected total 30, got %v", total)
	}
}

// TestTotalAvoidsFloatAccumulationDrift is a regression test for the
// rounding-drift risk in Total: naively summing float64 dollar amounts
// accumulates binary rounding error (the classic 0.1 + 0.2 != 0.3 problem)
// as more line items are added. Total rounds each line item to the nearest
// cent and accumulates in integer cents instead, so this must come out
// exact.
func TestTotalAvoidsFloatAccumulationDrift(t *testing.T) {
	l := NewLedger()
	l.CreateInvoice("inv-1", "Acme Co")
	if err := l.AddLineItem("inv-1", "A", 0.1, 1); err != nil {
		t.Fatal(err)
	}
	if err := l.AddLineItem("inv-1", "B", 0.2, 1); err != nil {
		t.Fatal(err)
	}
	total, err := l.Total("inv-1")
	if err != nil {
		t.Fatal(err)
	}
	if total != 0.3 {
		t.Fatalf("expected total exactly 0.3, got %v", total)
	}

	// Many small line items summed together should also land on an exact
	// value instead of drifting, e.g. 100,000 items of $0.01 should total
	// exactly $1000.00.
	l2 := NewLedger()
	l2.CreateInvoice("inv-2", "Acme Co")
	const n = 100_000
	for i := 0; i < n; i++ {
		if err := l2.AddLineItem("inv-2", "Penny item", 0.01, 1); err != nil {
			t.Fatal(err)
		}
	}
	total2, err := l2.Total("inv-2")
	if err != nil {
		t.Fatal(err)
	}
	if total2 != 1000.0 {
		t.Fatalf("expected total exactly 1000, got %v", total2)
	}
}

func TestAddLineItemValidation(t *testing.T) {
	tests := []struct {
		name        string
		description string
		amount      float64
		qty         int
		wantErr     bool
	}{
		{
			name:        "rejects negative amount",
			description: "Widgets",
			amount:      -5,
			qty:         2,
			wantErr:     true,
		},
		{
			name:        "rejects zero qty",
			description: "Widgets",
			amount:      10,
			qty:         0,
			wantErr:     true,
		},
		{
			name:        "rejects negative qty",
			description: "Widgets",
			amount:      10,
			qty:         -1,
			wantErr:     true,
		},
		{
			name:        "accepts valid amount and qty",
			description: "Widgets",
			amount:      10,
			qty:         3,
			wantErr:     false,
		},
		{
			name:        "rejects amount above MaxLineItemAmount",
			description: "Widgets",
			amount:      MaxLineItemAmount + 1,
			qty:         1,
			wantErr:     true,
		},
		{
			name:        "accepts amount exactly at MaxLineItemAmount",
			description: "Widgets",
			amount:      MaxLineItemAmount,
			qty:         1,
			wantErr:     false,
		},
		{
			name:        "rejects qty above MaxLineItemQty",
			description: "Widgets",
			amount:      10,
			qty:         MaxLineItemQty + 1,
			wantErr:     true,
		},
		{
			name:        "rejects +Inf amount",
			description: "Widgets",
			amount:      math.Inf(1),
			qty:         1,
			wantErr:     true,
		},
		{
			name:        "rejects NaN amount",
			description: "Widgets",
			amount:      math.NaN(),
			qty:         1,
			wantErr:     true,
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			l := NewLedger()
			l.CreateInvoice("inv-1", "Acme Co")
			err := l.AddLineItem("inv-1", tc.description, tc.amount, tc.qty)
			if tc.wantErr {
				if err == nil {
					t.Fatalf("expected error, got nil")
				}
				inv, getErr := l.Get("inv-1")
				if getErr != nil {
					t.Fatal(getErr)
				}
				if len(inv.LineItems()) != 0 {
					t.Fatalf("expected no line items added, got %d", len(inv.LineItems()))
				}
				total, totalErr := l.Total("inv-1")
				if totalErr != nil {
					t.Fatal(totalErr)
				}
				if total != 0 {
					t.Fatalf("expected total unchanged at 0, got %v", total)
				}
				return
			}
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			total, err := l.Total("inv-1")
			if err != nil {
				t.Fatal(err)
			}
			if total != tc.amount*float64(tc.qty) {
				t.Fatalf("expected total %v, got %v", tc.amount*float64(tc.qty), total)
			}
		})
	}
}

func TestAddSaleLineItem(t *testing.T) {
	tests := []struct {
		name       string
		itemID     string
		quantity   int
		unitPrice  float64
		wantErr    bool
		wantAmount float64
		wantQty    int
		wantTotal  float64
	}{
		{
			name:       "successful sale line item",
			itemID:     "sku-42",
			quantity:   3,
			unitPrice:  9.5,
			wantErr:    false,
			wantAmount: 9.5,
			wantQty:    3,
			wantTotal:  28.5,
		},
		{
			name:      "rejects zero quantity",
			itemID:    "sku-42",
			quantity:  0,
			unitPrice: 9.5,
			wantErr:   true,
		},
		{
			name:      "rejects negative quantity",
			itemID:    "sku-42",
			quantity:  -1,
			unitPrice: 9.5,
			wantErr:   true,
		},
		{
			name:      "rejects negative unit price",
			itemID:    "sku-42",
			quantity:  3,
			unitPrice: -0.01,
			wantErr:   true,
		},
		{
			name:      "rejects unit price above MaxLineItemAmount",
			itemID:    "sku-42",
			quantity:  3,
			unitPrice: MaxLineItemAmount + 1,
			wantErr:   true,
		},
		{
			name:      "rejects quantity above MaxLineItemQty",
			itemID:    "sku-42",
			quantity:  MaxLineItemQty + 1,
			unitPrice: 9.5,
			wantErr:   true,
		},
		{
			name:      "rejects +Inf unit price",
			itemID:    "sku-42",
			quantity:  3,
			unitPrice: math.Inf(1),
			wantErr:   true,
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			l := NewLedger()
			l.CreateInvoice("inv-1", "Acme Co")
			err := l.AddSaleLineItem("inv-1", tc.itemID, tc.quantity, tc.unitPrice)
			if tc.wantErr {
				if err == nil {
					t.Fatalf("expected error, got nil")
				}
				return
			}
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			inv, getErr := l.Get("inv-1")
			if getErr != nil {
				t.Fatal(getErr)
			}
			if len(inv.LineItems()) != 1 {
				t.Fatalf("expected 1 line item, got %d", len(inv.LineItems()))
			}
			li := inv.LineItems()[0]
			if li.Amount != tc.wantAmount {
				t.Fatalf("expected LineItem.Amount %v (per-unit price), got %v", tc.wantAmount, li.Amount)
			}
			if li.Qty != tc.wantQty {
				t.Fatalf("expected LineItem.Qty %v, got %v", tc.wantQty, li.Qty)
			}
			total, err := l.Total("inv-1")
			if err != nil {
				t.Fatal(err)
			}
			if total != tc.wantTotal {
				t.Fatalf("expected total %v, got %v", tc.wantTotal, total)
			}
		})
	}
}

func TestMarkPaid(t *testing.T) {
	l := NewLedger()
	l.CreateInvoice("inv-1", "Acme Co")
	if err := l.MarkPaid("inv-1"); err != nil {
		t.Fatal(err)
	}
	inv, _ := l.Get("inv-1")
	if inv.Status != "paid" {
		t.Fatalf("expected status paid, got %s", inv.Status)
	}
}

func TestApplyLateFeeValidation(t *testing.T) {
	tests := []struct {
		name       string
		feePercent float64
		wantErr    bool
		wantReturn float64
	}{
		{
			name:       "rejects negative feePercent",
			feePercent: -10,
			wantErr:    true,
		},
		{
			name:       "accepts valid feePercent",
			feePercent: 10,
			wantErr:    false,
			wantReturn: 110,
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			l := NewLedger()
			l.CreateInvoice("inv-1", "Acme Co")
			if err := l.AddLineItem("inv-1", "Widgets", 100, 1); err != nil {
				t.Fatal(err)
			}

			got, err := l.ApplyLateFee("inv-1", tc.feePercent)
			if tc.wantErr {
				if err == nil {
					t.Fatalf("expected error, got nil")
				}
				inv, getErr := l.Get("inv-1")
				if getErr != nil {
					t.Fatal(getErr)
				}
				if len(inv.LineItems()) != 1 {
					t.Fatalf("expected no late fee line item added, got %d line items", len(inv.LineItems()))
				}
				total, totalErr := l.Total("inv-1")
				if totalErr != nil {
					t.Fatal(totalErr)
				}
				if total != 100 {
					t.Fatalf("expected total unchanged at 100, got %v", total)
				}
				return
			}
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if got != tc.wantReturn {
				t.Fatalf("expected return %v, got %v", tc.wantReturn, got)
			}
			inv, getErr := l.Get("inv-1")
			if getErr != nil {
				t.Fatal(getErr)
			}
			if len(inv.LineItems()) != 2 {
				t.Fatalf("expected 2 line items (original + late fee), got %d", len(inv.LineItems()))
			}
			lateFee := inv.LineItems()[1]
			if lateFee.Description != "Late fee" {
				t.Fatalf("expected second line item to be Late fee, got %q", lateFee.Description)
			}
			if lateFee.Amount != 10 {
				t.Fatalf("expected late fee amount 10, got %v", lateFee.Amount)
			}
			total, err := l.Total("inv-1")
			if err != nil {
				t.Fatal(err)
			}
			if total != tc.wantReturn {
				t.Fatalf("expected total %v, got %v", tc.wantReturn, total)
			}
		})
	}
}

func TestRenderInvoiceHTMLEscapesUntrustedInput(t *testing.T) {
	const payload = `<script>alert(1)</script>`

	tests := []struct {
		name        string
		customer    string
		description string
	}{
		{
			name:     "escapes malicious customer name",
			customer: payload,
		},
		{
			name:        "escapes malicious line item description",
			customer:    "Acme Co",
			description: payload,
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			l := NewLedger()
			l.CreateInvoice("inv-1", tc.customer)
			if tc.description != "" {
				if err := l.AddLineItem("inv-1", tc.description, 10, 1); err != nil {
					t.Fatal(err)
				}
			}

			out, err := l.RenderInvoiceHTML("inv-1")
			if err != nil {
				t.Fatal(err)
			}
			if strings.Contains(out, "<script>") {
				t.Fatalf("expected script tag to be escaped, got raw markup in output: %s", out)
			}
			if !strings.Contains(out, "&lt;script&gt;alert(1)&lt;/script&gt;") {
				t.Fatalf("expected escaped script tag in output, got: %s", out)
			}
		})
	}
}

// TestGetReturnsCopyNotLiveInvoice is a regression test for a
// security-auditor finding: Invoice.LineItems used to be an exported field,
// and Ledger.Get used to return the ledger's live *Invoice pointer, so any
// caller could do `inv.LineItems = append(inv.LineItems, LineItem{Amount:
// math.Inf(1), ...})` and smuggle a malformed line item straight into the
// invoice, completely bypassing AddLineItem/AddSaleLineItem's validation
// and reintroducing the +Inf/NaN/overflow problem those methods exist to
// prevent.
//
// The fix has two layers: the line items slice is now unexported
// (Invoice.lineItems), so outside this package the append above wouldn't
// even compile any more; and Get now returns a copy of the invoice rather
// than the ledger's live pointer, so mutations to the returned *Invoice
// (including its unexported fields, reachable here only because this test
// file shares billing's package) never reach the ledger's stored data. This
// test proves the second layer, which is the one still reachable from
// within the package and therefore the one an in-package test can actually
// exercise.
func TestGetReturnsCopyNotLiveInvoice(t *testing.T) {
	l := NewLedger()
	l.CreateInvoice("inv-1", "Acme Co")
	if err := l.AddLineItem("inv-1", "Widgets", 10, 2); err != nil {
		t.Fatal(err)
	}

	inv, err := l.Get("inv-1")
	if err != nil {
		t.Fatal(err)
	}

	// Attempt the exact bypass the security-auditor described, plus a plain
	// field mutation for good measure.
	inv.lineItems = append(inv.lineItems, LineItem{Description: "smuggled", Amount: math.Inf(1), Qty: 1})
	inv.Status = "paid"

	// The ledger's stored invoice must be completely unaffected: still one
	// valid line item, still "open", and a finite, correct total.
	fresh, err := l.Get("inv-1")
	if err != nil {
		t.Fatal(err)
	}
	if len(fresh.LineItems()) != 1 {
		t.Fatalf("expected stored invoice to still have 1 line item, got %d", len(fresh.LineItems()))
	}
	if fresh.Status != "open" {
		t.Fatalf("expected stored invoice status unaffected, got %q", fresh.Status)
	}
	total, err := l.Total("inv-1")
	if err != nil {
		t.Fatal(err)
	}
	if total != 20 {
		t.Fatalf("expected total unaffected at 20, got %v", total)
	}
	if math.IsInf(total, 0) || math.IsNaN(total) {
		t.Fatalf("expected finite total, got %v", total)
	}
}

// TestTotalRejectsIntegerOverflowFromManyLineItems is a regression test for
// a security-auditor finding: even though each individual line item's
// contribution to Total's int64 cent accumulator is bounded well within
// int64 range by MaxLineItemAmount/MaxLineItemQty (worst case ~1e17 per
// item), nothing capped the *number* of line items on one invoice. Since
// int64 max is ~9.22e18, roughly 93 max-magnitude line items are enough to
// silently wrap the running total past int64 max -- Go integer overflow is
// silent, not a panic, so without a check this would produce a negative or
// otherwise garbage total instead of an error. Total now detects this (the
// running total should only ever increase, since every accepted line item's
// contribution is non-negative; if it doesn't, it wrapped) and returns an
// error instead.
func TestTotalRejectsIntegerOverflowFromManyLineItems(t *testing.T) {
	l := NewLedger()
	l.CreateInvoice("inv-1", "Acme Co")

	// Comfortably past the ~93-item point where max-magnitude line items
	// wrap an int64 cent total, so the test isn't sensitive to the exact
	// boundary.
	const n = 200
	for i := 0; i < n; i++ {
		if err := l.AddLineItem("inv-1", "Big item", MaxLineItemAmount, MaxLineItemQty); err != nil {
			t.Fatal(err)
		}
	}

	total, err := l.Total("inv-1")
	if err == nil {
		t.Fatalf("expected Total to reject the overflowing sum, got total %v with no error", total)
	}
	if total != 0 {
		t.Fatalf("expected 0 returned alongside the overflow error, got %v", total)
	}
}
