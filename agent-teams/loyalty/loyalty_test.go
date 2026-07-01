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

func TestRedeemPointsRejectsNonPositive(t *testing.T) {
	r := NewRegistry()
	r.OpenAccount("acct-1", "cust-1")
	if _, err := r.EarnPoints("acct-1", 50); err != nil {
		t.Fatal(err)
	}

	if _, err := r.RedeemPoints("acct-1", 0); err == nil {
		t.Fatal("expected error for zero points, got nil")
	}
	if _, err := r.RedeemPoints("acct-1", -5); err == nil {
		t.Fatal("expected error for negative points, got nil")
	}

	a, err := r.Get("acct-1")
	if err != nil {
		t.Fatal(err)
	}
	if a.Points != 50 {
		t.Fatalf("expected balance unchanged at 50, got %d", a.Points)
	}
}

func TestRedeemPointsRejectsInsufficientBalance(t *testing.T) {
	r := NewRegistry()
	r.OpenAccount("acct-1", "cust-1")
	if _, err := r.EarnPoints("acct-1", 30); err != nil {
		t.Fatal(err)
	}

	if _, err := r.RedeemPoints("acct-1", 31); err == nil {
		t.Fatal("expected error for points exceeding balance, got nil")
	}

	a, err := r.Get("acct-1")
	if err != nil {
		t.Fatal(err)
	}
	if a.Points != 30 {
		t.Fatalf("expected balance unchanged at 30, got %d", a.Points)
	}
}

func TestRedeemPointsValid(t *testing.T) {
	r := NewRegistry()
	r.OpenAccount("acct-1", "cust-1")
	if _, err := r.EarnPoints("acct-1", 50); err != nil {
		t.Fatal(err)
	}

	points, err := r.RedeemPoints("acct-1", 20)
	if err != nil {
		t.Fatal(err)
	}
	if points != 30 {
		t.Fatalf("expected 30 points remaining, got %d", points)
	}

	a, err := r.Get("acct-1")
	if err != nil {
		t.Fatal(err)
	}
	if a.Points != 30 {
		t.Fatalf("expected account balance 30, got %d", a.Points)
	}
}
