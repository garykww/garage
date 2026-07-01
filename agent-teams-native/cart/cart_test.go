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

// No coverage yet for AddItem's qty/unitPrice validation — the planted gap
// in BACKLOG.md. A qty <= 0 or a negative unitPrice is currently stored
// as-is and silently skews Total.
