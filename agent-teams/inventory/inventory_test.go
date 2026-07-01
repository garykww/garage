package inventory

import "testing"

func TestAddItem(t *testing.T) {
	inv := New()
	item := inv.AddItem("sku-1", "Widget", 10, 5)
	if item.Qty != 5 {
		t.Fatalf("expected qty 5, got %d", item.Qty)
	}
}

func TestRestock(t *testing.T) {
	inv := New()
	inv.AddItem("sku-1", "Widget", 10, 5)
	qty, err := inv.Restock("sku-1", 3)
	if err != nil {
		t.Fatal(err)
	}
	if qty != 8 {
		t.Fatalf("expected qty 8, got %d", qty)
	}
}

func TestApplyDiscount(t *testing.T) {
	inv := New()
	inv.AddItem("sku-1", "Widget", 100, 5)
	price, err := inv.ApplyDiscount("sku-1", 20)
	if err != nil {
		t.Fatal(err)
	}
	if price != 80 {
		t.Fatalf("expected price 80, got %f", price)
	}
}

func TestTotalValue(t *testing.T) {
	inv := New()
	inv.AddItem("sku-1", "Widget", 10, 5)
	inv.AddItem("sku-2", "Gadget", 20, 2)
	total := inv.TotalValue()
	if total != 90 {
		t.Fatalf("expected total 90, got %f", total)
	}
}

// No coverage yet for Sell() or ApplyPricingFormula() — left for the
// agent team to find and fill in.
