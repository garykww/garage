package shipping

import "testing"

func TestCreateShipment(t *testing.T) {
	r := NewRegistry()
	s := r.CreateShipment("ship-1", "order-1", "UPS", 2.5)
	if s.Status != "pending" {
		t.Fatalf("expected status pending, got %s", s.Status)
	}
}

func TestMarkShippedAndDelivered(t *testing.T) {
	r := NewRegistry()
	r.CreateShipment("ship-1", "order-1", "UPS", 2.5)
	if err := r.MarkShipped("ship-1"); err != nil {
		t.Fatal(err)
	}
	if err := r.MarkDelivered("ship-1"); err != nil {
		t.Fatal(err)
	}
	s, _ := r.Get("ship-1")
	if s.Status != "delivered" {
		t.Fatalf("expected status delivered, got %s", s.Status)
	}
}

// No coverage yet for EstimateCost() — left for the agent team to find and
// fill in.
