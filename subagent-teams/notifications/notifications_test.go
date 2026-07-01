package notifications

import "testing"

func TestQueueAndGet(t *testing.T) {
	r := NewRegistry()
	n := r.Queue("note-1", "user@example.com", "hello")
	if n.Status != "queued" {
		t.Fatalf("expected status queued, got %s", n.Status)
	}
}

func TestMarkSent(t *testing.T) {
	r := NewRegistry()
	r.Queue("note-1", "user@example.com", "hello")
	if err := r.MarkSent("note-1"); err != nil {
		t.Fatal(err)
	}
	n, _ := r.Get("note-1")
	if n.Status != "sent" {
		t.Fatalf("expected status sent, got %s", n.Status)
	}
}

// No coverage yet for IncrementRetry() — left for the agent team to find
// and fill in.
