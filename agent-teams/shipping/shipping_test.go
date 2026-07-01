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

func TestEstimateCost(t *testing.T) {
	r := NewRegistry()
	r.CreateShipment("ship-1", "order-1", "UPS", 2.5)

	cost, err := r.EstimateCost("ship-1", 4.0)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if cost != 10.0 {
		t.Fatalf("expected cost 10.0, got %v", cost)
	}
}

func TestEstimateCostNegativeRatePerKg(t *testing.T) {
	r := NewRegistry()
	r.CreateShipment("ship-1", "order-1", "UPS", 2.5)

	if _, err := r.EstimateCost("ship-1", -4.0); err == nil {
		t.Fatal("expected error for negative ratePerKg, got nil")
	}
}

func TestEstimateCostNegativeWeight(t *testing.T) {
	r := NewRegistry()
	r.CreateShipment("ship-1", "order-1", "UPS", -2.5)

	if _, err := r.EstimateCost("ship-1", 4.0); err == nil {
		t.Fatal("expected error for negative shipment weight, got nil")
	}
}
