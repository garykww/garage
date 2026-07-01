package loyalty

import "testing"

func TestOpenAccountAndEarnPoints(t *testing.T) {
	r := NewRegistry()
	r.OpenAccount("acct-1", "cust-1")
	points, err := r.EarnPoints("acct-1", 50)
	if err != nil {
		t.Fatal(err)
	}
	if points != 50 {
		t.Fatalf("expected 50 points, got %d", points)
	}
}

func TestEarnPointsRejectsNonPositive(t *testing.T) {
	r := NewRegistry()
	r.OpenAccount("acct-1", "cust-1")
	if _, err := r.EarnPoints("acct-1", 0); err == nil {
		t.Fatal("expected error for zero points, got nil")
	}
	if _, err := r.EarnPoints("acct-1", -5); err == nil {
		t.Fatal("expected error for negative points, got nil")
	}
}

// No coverage yet for RedeemPoints() — left for the agent team to find and
// fill in.
