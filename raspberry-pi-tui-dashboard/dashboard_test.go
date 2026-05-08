package main

import (
	"fmt"
	"strings"
	"testing"
	"time"
)

func TestSymbolsConfig(t *testing.T) {
	if len(symbols) == 0 {
		t.Fatal("no symbols configured")
	}
	for _, s := range symbols {
		if strings.TrimSpace(s) == "" {
			t.Error("empty symbol in config")
		}
	}
}

func TestTimezonesConfig(t *testing.T) {
	if len(tzones) == 0 {
		t.Fatal("no timezones configured")
	}
	seen := map[string]bool{}
	for _, tz := range tzones {
		if tz.City == "" {
			t.Errorf("timezone entry missing city name for zone %q", tz.Zone)
		}
		if _, err := time.LoadLocation(tz.Zone); err != nil {
			t.Errorf("invalid timezone %q: %v", tz.Zone, err)
		}
		if seen[tz.Zone] {
			t.Errorf("duplicate timezone: %q", tz.Zone)
		}
		seen[tz.Zone] = true
	}
}

func TestNewsFeedsConfig(t *testing.T) {
	if len(newsFeeds) == 0 {
		t.Fatal("no news feeds configured")
	}
	for _, f := range newsFeeds {
		if f.Name == "" {
			t.Error("feed entry missing name")
		}
		if !strings.HasPrefix(f.URL, "http") {
			t.Errorf("feed %q has non-http URL: %s", f.Name, f.URL)
		}
	}
}

func TestRefreshIntervalIsPositive(t *testing.T) {
	if refreshInterval <= 0 {
		t.Fatalf("refresh interval must be positive, got %v", refreshInterval)
	}
}

func TestParseRSS(t *testing.T) {
	raw := `<?xml version="1.0"?>
<rss version="2.0">
  <channel>
    <title>Test</title>
    <item><title>First Headline</title></item>
    <item><title>Second Headline</title></item>
  </channel>
</rss>`
	titles, err := parseRSS(strings.NewReader(raw))
	if err != nil {
		t.Fatalf("parseRSS error: %v", err)
	}
	if len(titles) != 2 {
		t.Fatalf("expected 2 titles, got %d", len(titles))
	}
	if titles[0] != "First Headline" {
		t.Errorf("expected 'First Headline', got %q", titles[0])
	}
}

func TestClockOffsetFormat(t *testing.T) {
	loc, err := time.LoadLocation("America/New_York")
	if err != nil {
		t.Fatal(err)
	}
	now := time.Now().In(loc)
	_, off := now.Zone()
	h := off / 3600
	mins := off % 3600 / 60
	if mins < 0 {
		mins = -mins
	}
	sign := "+"
	if off < 0 {
		sign = "-"
		h = -h
	}
	result := fmt.Sprintf("UTC%s%02d:%02d", sign, h, mins)
	if !strings.HasPrefix(result, "UTC") {
		t.Errorf("unexpected format: %s", result)
	}
	if result != "UTC-05:00" && result != "UTC-04:00" {
		t.Errorf("unexpected New York offset: %s", result)
	}
}

func TestPadLines(t *testing.T) {
	result := padLines([]string{"a", "b"}, 4)
	rows := strings.Split(result, "\n")
	if len(rows) != 4 {
		t.Errorf("expected 4 rows, got %d", len(rows))
	}
	if rows[2] != "" || rows[3] != "" {
		t.Error("padding rows should be empty")
	}

	result = padLines([]string{"a", "b", "c", "d"}, 2)
	rows = strings.Split(result, "\n")
	if len(rows) != 2 {
		t.Errorf("expected 2 rows after truncation, got %d", len(rows))
	}
}

func TestPadRight(t *testing.T) {
	if got := padRight("hi", 5); got != "hi   " {
		t.Errorf("padRight('hi', 5) = %q, want %q", got, "hi   ")
	}
	if got := padRight("toolong", 3); got != "toolong" {
		t.Errorf("padRight should not truncate, got %q", got)
	}
}
