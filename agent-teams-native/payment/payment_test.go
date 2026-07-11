package payment

import "testing"

func TestCaptureAndGet(t *testing.T) {
	p := NewProcessor()
	id, err := p.Capture("order-1", 49.99)
	if err != nil {
		t.Fatalf("Capture: %v", err)
	}
	ch, err := p.Get(id)
	if err != nil {
		t.Fatalf("Get: %v", err)
	}
	if ch.Amount != 49.99 || ch.Status != "captured" {
		t.Errorf("Get(%s) = %+v, want Amount 49.99 and Status captured", id, ch)
	}
}

func TestCaptureRejectsBadInput(t *testing.T) {
	p := NewProcessor()
	if _, err := p.Capture("", 10); err == nil {
		t.Errorf("Capture with empty orderID: want error, got nil")
	}
	if _, err := p.Capture("order-1", -5); err == nil {
		t.Errorf("Capture with negative amount: want error, got nil")
	}
}

func TestPartialRefund(t *testing.T) {
	p := NewProcessor()
	id, err := p.Capture("order-1", 100)
	if err != nil {
		t.Fatalf("Capture: %v", err)
	}
	if err := p.Refund(id, 40); err != nil {
		t.Fatalf("Refund: %v", err)
	}
	ch, err := p.Get(id)
	if err != nil {
		t.Fatalf("Get: %v", err)
	}
	if ch.Refunded != 40 || ch.Status != "captured" {
		t.Errorf("after partial refund: %+v, want Refunded 40 and Status captured", ch)
	}
}

func TestRefundRejectsNonPositiveAmount(t *testing.T) {
	p := NewProcessor()
	id, err := p.Capture("order-1", 100)
	if err != nil {
		t.Fatalf("Capture: %v", err)
	}
	if err := p.Refund(id, 0); err == nil {
		t.Errorf("Refund with zero amount: want error, got nil")
	}
	if err := p.Refund(id, -10); err == nil {
		t.Errorf("Refund with negative amount: want error, got nil")
	}
	ch, err := p.Get(id)
	if err != nil {
		t.Fatalf("Get: %v", err)
	}
	if ch.Refunded != 0 || ch.Status != "captured" {
		t.Errorf("after rejected refunds: %+v, want Refunded 0 and Status captured", ch)
	}
}

func TestRefundRejectsOverRefund(t *testing.T) {
	p := NewProcessor()
	id, err := p.Capture("order-1", 100)
	if err != nil {
		t.Fatalf("Capture: %v", err)
	}
	if err := p.Refund(id, 120); err == nil {
		t.Errorf("Refund exceeding captured amount: want error, got nil")
	}
	if err := p.Refund(id, 60); err != nil {
		t.Fatalf("first partial Refund: %v", err)
	}
	// Cumulative: 60 already refunded, another 50 would exceed 100.
	if err := p.Refund(id, 50); err == nil {
		t.Errorf("cumulative refund exceeding captured amount: want error, got nil")
	}
	ch, err := p.Get(id)
	if err != nil {
		t.Fatalf("Get: %v", err)
	}
	if ch.Refunded != 60 || ch.Status != "captured" {
		t.Errorf("after over-refund attempts: %+v, want Refunded 60 and Status captured", ch)
	}
}

func TestRefundRejectsUnknownCharge(t *testing.T) {
	p := NewProcessor()
	if err := p.Refund("ch-missing", 10); err == nil {
		t.Errorf("Refund on unknown charge: want error, got nil")
	}
}

func TestGetRejectsUnknownCharge(t *testing.T) {
	p := NewProcessor()
	ch, err := p.Get("ch-missing")
	if err == nil {
		t.Errorf("Get on unknown charge: want error, got nil")
	}
	if ch != (Charge{}) {
		t.Errorf("Get on unknown charge = %+v, want zero Charge", ch)
	}
}

func TestRefundFullFlipsStatus(t *testing.T) {
	p := NewProcessor()
	id, err := p.Capture("order-1", 100)
	if err != nil {
		t.Fatalf("Capture: %v", err)
	}
	if err := p.Refund(id, 100); err != nil {
		t.Fatalf("full Refund: %v", err)
	}
	ch, err := p.Get(id)
	if err != nil {
		t.Fatalf("Get: %v", err)
	}
	if ch.Refunded != 100 || ch.Status != "refunded" {
		t.Errorf("after full refund: %+v, want Refunded 100 and Status refunded", ch)
	}
}
