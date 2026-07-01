package billing

import (
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
				if len(inv.LineItems) != 0 {
					t.Fatalf("expected no line items added, got %d", len(inv.LineItems))
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
			if len(inv.LineItems) != 1 {
				t.Fatalf("expected 1 line item, got %d", len(inv.LineItems))
			}
			li := inv.LineItems[0]
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
				if len(inv.LineItems) != 1 {
					t.Fatalf("expected no late fee line item added, got %d line items", len(inv.LineItems))
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
			if len(inv.LineItems) != 2 {
				t.Fatalf("expected 2 line items (original + late fee), got %d", len(inv.LineItems))
			}
			lateFee := inv.LineItems[1]
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
