package main

import (
	"testing"
)

func TestEnvIntMissing(t *testing.T) {
	t.Setenv("PI_STREAM_TEST_VAR", "")
	if got := envInt("PI_STREAM_TEST_VAR", 42); got != 42 {
		t.Fatalf("expected default 42, got %d", got)
	}
}

func TestEnvIntValid(t *testing.T) {
	t.Setenv("PI_STREAM_TEST_VAR", "99")
	if got := envInt("PI_STREAM_TEST_VAR", 0); got != 99 {
		t.Fatalf("expected 99, got %d", got)
	}
}

func TestEnvIntInvalid(t *testing.T) {
	t.Setenv("PI_STREAM_TEST_VAR", "notanumber")
	if got := envInt("PI_STREAM_TEST_VAR", 7); got != 7 {
		t.Fatalf("expected default 7, got %d", got)
	}
}

func TestEnvIntNegative(t *testing.T) {
	t.Setenv("PI_STREAM_TEST_VAR", "-5")
	if got := envInt("PI_STREAM_TEST_VAR", 0); got != -5 {
		t.Fatalf("expected -5, got %d", got)
	}
}
