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

// No coverage yet for Refund's validation — the planted gap in BACKLOG.md.
// Refund currently accepts a non-positive amount and a total refund greater
// than the captured amount, unlike Capture, which validates and is tested
// for it.
