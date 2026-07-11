package cart

import "testing"

func TestAddItemAndTotal(t *testing.T) {
	c, err := New("ada")
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	if err := c.AddItem("book", 2, 10.00); err != nil {
		t.Fatalf("AddItem(book): %v", err)
	}
	if err := c.AddItem("pen", 1, 2.50); err != nil {
		t.Fatalf("AddItem(pen): %v", err)
	}
	if got, want := c.Total(), 22.50; got != want {
		t.Errorf("Total() = %v, want %v", got, want)
	}
}

func TestRemoveItem(t *testing.T) {
	c, err := New("ada")
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	if err := c.AddItem("book", 1, 10.00); err != nil {
		t.Fatalf("AddItem: %v", err)
	}
	if !c.RemoveItem("book") {
		t.Errorf("RemoveItem(book) = false, want true")
	}
	if c.RemoveItem("book") {
		t.Errorf("RemoveItem(book) second call = true, want false")
	}
}

func TestNewRejectsEmptyCustomer(t *testing.T) {
	if _, err := New(""); err == nil {
		t.Errorf("New(\"\") = nil error, want error for empty customer")
	}
	if c, err := New("ada"); err != nil || c == nil {
		t.Errorf("New(\"ada\") = (%v, %v), want a cart and nil error", c, err)
	}
}

func TestAddItemRejectsEmptyProductID(t *testing.T) {
	c, err := New("ada")
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	if err := c.AddItem("", 1, 10.00); err == nil {
		t.Errorf("AddItem(productID=\"\") = nil, want error")
	}
	if len(c.Items) != 0 {
		t.Errorf("invalid line stored: len(Items) = %d, want 0", len(c.Items))
	}
}

func TestAddItemRejectsNonPositiveQty(t *testing.T) {
	c, err := New("ada")
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	for _, qty := range []int{0, -1} {
		if err := c.AddItem("book", qty, 10.00); err == nil {
			t.Errorf("AddItem(qty=%d) = nil, want error", qty)
		}
	}
	if len(c.Items) != 0 {
		t.Errorf("invalid lines stored: len(Items) = %d, want 0", len(c.Items))
	}
	if got := c.Total(); got != 0 {
		t.Errorf("Total() = %v after rejected adds, want 0", got)
	}
}

func TestAddItemRejectsNegativeUnitPrice(t *testing.T) {
	c, err := New("ada")
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	if err := c.AddItem("book", 1, -0.01); err == nil {
		t.Errorf("AddItem(unitPrice=-0.01) = nil, want error")
	}
	if len(c.Items) != 0 {
		t.Errorf("invalid line stored: len(Items) = %d, want 0", len(c.Items))
	}
}

func TestAddItemAllowsZeroUnitPrice(t *testing.T) {
	c, err := New("ada")
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	if err := c.AddItem("freebie", 1, 0); err != nil {
		t.Errorf("AddItem(unitPrice=0) = %v, want nil (free items are valid)", err)
	}
}
