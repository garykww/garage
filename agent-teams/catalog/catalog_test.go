package catalog

import "testing"

func TestAddProductAndGet(t *testing.T) {
	r := NewRegistry()
	r.AddProduct("sku-1", "Blue Widget", 19.99, []string{"widget"})
	p, err := r.Get("sku-1")
	if err != nil {
		t.Fatal(err)
	}
	if p.Name != "Blue Widget" {
		t.Fatalf("expected name Blue Widget, got %s", p.Name)
	}
}

func TestSearch(t *testing.T) {
	r := NewRegistry()
	r.AddProduct("sku-1", "Blue Widget", 19.99, nil)
	r.AddProduct("sku-2", "Red Gadget", 29.99, nil)
	results := r.Search("widget")
	if len(results) != 1 {
		t.Fatalf("expected 1 result, got %d", len(results))
	}
	if results[0].SKU != "sku-1" {
		t.Fatalf("expected sku-1, got %s", results[0].SKU)
	}
}

// No coverage yet for UpdatePrice() — left for the agent team to find and
// fill in.
