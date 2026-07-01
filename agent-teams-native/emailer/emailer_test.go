package emailer

import "testing"

func TestEnqueueAndPending(t *testing.T) {
	q := NewQueue()
	if err := q.Enqueue("ada@example.com", "Your receipt", "thanks!"); err != nil {
		t.Fatalf("Enqueue: %v", err)
	}
	got := q.Pending()
	if len(got) != 1 || got[0].To != "ada@example.com" {
		t.Errorf("Pending() = %+v, want one message to ada@example.com", got)
	}
}

func TestEnqueueRejectsBadInput(t *testing.T) {
	q := NewQueue()
	if err := q.Enqueue("not-an-address", "subject", "body"); err == nil {
		t.Errorf("Enqueue with bad address: want error, got nil")
	}
	if err := q.Enqueue("ada@example.com", "", "body"); err == nil {
		t.Errorf("Enqueue with empty subject: want error, got nil")
	}
}

// No coverage yet for RenderReceiptHTML's output escaping — the planted
// gap in BACKLOG.md. A customer name or receipt line containing
// "<script>" currently renders raw into the HTML (stored XSS).
