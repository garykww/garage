package billing

import "testing"

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

// No coverage yet for AddLineItem's missing amount/qty validation,
// ApplyLateFee's missing feePercent validation, or RenderInvoiceHTML's
// unescaped output — left for the agent team to find and fill in.
