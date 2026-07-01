package reporting

import "testing"

func TestCreateReportAndSetMetric(t *testing.T) {
	r := NewRegistry()
	r.CreateReport("rep-1", "Q1 Sales")
	if err := r.SetMetric("rep-1", "revenue", 100); err != nil {
		t.Fatal(err)
	}
	rep, err := r.Get("rep-1")
	if err != nil {
		t.Fatal(err)
	}
	if rep.Metrics["revenue"] != 100 {
		t.Fatalf("expected revenue 100, got %v", rep.Metrics["revenue"])
	}
}

func TestAverageMetric(t *testing.T) {
	r := NewRegistry()
	r.CreateReport("rep-1", "Q1 Sales")
	r.SetMetric("rep-1", "a", 10)
	r.SetMetric("rep-1", "b", 20)
	avg, err := r.AverageMetric("rep-1")
	if err != nil {
		t.Fatal(err)
	}
	if avg != 15 {
		t.Fatalf("expected average 15, got %v", avg)
	}
}

func TestAverageMetricNoMetrics(t *testing.T) {
	r := NewRegistry()
	r.CreateReport("rep-1", "Q1 Sales")
	avg, err := r.AverageMetric("rep-1")
	if err == nil {
		t.Fatalf("expected error for report with zero metrics, got avg %v", avg)
	}
	if avg != 0 {
		t.Fatalf("expected zero value on error, got %v", avg)
	}
}
