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

func TestIncrementRetryNegativeByRejected(t *testing.T) {
	r := NewRegistry()
	r.Queue("note-1", "user@example.com", "hello")
	n, _ := r.Get("note-1")
	n.RetryCount = 3

	if _, err := r.IncrementRetry("note-1", -1); err == nil {
		t.Fatal("expected error for negative by, got nil")
	}
	if n.RetryCount != 3 {
		t.Fatalf("expected RetryCount unchanged at 3, got %d", n.RetryCount)
	}
}

func TestIncrementRetryValidBy(t *testing.T) {
	r := NewRegistry()
	r.Queue("note-1", "user@example.com", "hello")

	count, err := r.IncrementRetry("note-1", 2)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if count != 2 {
		t.Fatalf("expected count 2, got %d", count)
	}

	count, err = r.IncrementRetry("note-1", 0)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if count != 2 {
		t.Fatalf("expected count unchanged at 2, got %d", count)
	}

	n, _ := r.Get("note-1")
	if n.RetryCount != 2 {
		t.Fatalf("expected RetryCount 2, got %d", n.RetryCount)
	}
}
