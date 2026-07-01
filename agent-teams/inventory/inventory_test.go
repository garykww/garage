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

func TestCheckout(t *testing.T) {
	tests := []struct {
		name        string
		startQty    int
		checkoutQty int
		wantErr     bool
		wantStock   int
	}{
		{
			name:        "successful checkout decrements stock",
			startQty:    5,
			checkoutQty: 2,
			wantErr:     false,
			wantStock:   3,
		},
		{
			name:        "qty greater than stock is rejected, stock unchanged",
			startQty:    5,
			checkoutQty: 6,
			wantErr:     true,
			wantStock:   5,
		},
		{
			name:        "zero qty is rejected, stock unchanged",
			startQty:    5,
			checkoutQty: 0,
			wantErr:     true,
			wantStock:   5,
		},
		{
			name:        "negative qty is rejected, stock unchanged",
			startQty:    5,
			checkoutQty: -1,
			wantErr:     true,
			wantStock:   5,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			inv := New()
			inv.AddItem("sku-1", "Widget", 10, tt.startQty)

			result, err := inv.Checkout("sku-1", tt.checkoutQty)

			if tt.wantErr {
				if err == nil {
					t.Fatalf("expected error, got nil (result: %+v)", result)
				}
			} else {
				if err != nil {
					t.Fatalf("unexpected error: %v", err)
				}
				if result.ItemID != "sku-1" {
					t.Fatalf("expected ItemID sku-1, got %s", result.ItemID)
				}
				if result.Quantity != tt.checkoutQty {
					t.Fatalf("expected Quantity %d, got %d", tt.checkoutQty, result.Quantity)
				}
				if result.UnitPrice != 10 {
					t.Fatalf("expected UnitPrice 10, got %f", result.UnitPrice)
				}
			}

			item, err := inv.Get("sku-1")
			if err != nil {
				t.Fatal(err)
			}
			if item.Qty != tt.wantStock {
				t.Fatalf("expected stock %d, got %d", tt.wantStock, item.Qty)
			}
		})
	}
}

// No coverage yet for Sell() or ApplyPricingFormula() — left for the
// agent team to find and fill in.
