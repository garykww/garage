package main

import (
	"context"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestIndexHTMLContent(t *testing.T) {
	if !strings.Contains(indexHTML, `src="/stream"`) {
		t.Fatal("index page must reference /stream")
	}
	if !strings.Contains(indexHTML, "<!DOCTYPE html>") {
		t.Fatal("index page must be valid HTML")
	}
}

func TestStreamMJPEGContentType(t *testing.T) {
	var fb FrameBuffer
	fb.Store([]byte{0xFF, 0xD8, 0xFF, 0xD9})

	ctx, cancel := context.WithCancel(context.Background())
	req := httptest.NewRequest("GET", "/stream", nil).WithContext(ctx)
	rec := httptest.NewRecorder()

	done := make(chan struct{})
	go func() {
		streamMJPEG(rec, req, &fb)
		close(done)
	}()

	time.Sleep(50 * time.Millisecond)
	cancel()
	<-done

	ct := rec.Header().Get("Content-Type")
	if !strings.HasPrefix(ct, "multipart/x-mixed-replace") {
		t.Fatalf("unexpected Content-Type: %q", ct)
	}
	if !strings.Contains(ct, "boundary=frame") {
		t.Fatalf("missing boundary in Content-Type: %q", ct)
	}
}

func TestStreamMJPEGFrame(t *testing.T) {
	var fb FrameBuffer
	frame := []byte{0xFF, 0xD8, 0x00, 0x01, 0x02, 0xFF, 0xD9}
	fb.Store(frame)

	ctx, cancel := context.WithCancel(context.Background())
	req := httptest.NewRequest("GET", "/stream", nil).WithContext(ctx)
	rec := httptest.NewRecorder()

	done := make(chan struct{})
	go func() {
		streamMJPEG(rec, req, &fb)
		close(done)
	}()

	time.Sleep(50 * time.Millisecond)
	cancel()
	<-done

	body := rec.Body.String()
	if !strings.Contains(body, "--frame\r\n") {
		t.Fatal("expected --frame boundary in body")
	}
	if !strings.Contains(body, "Content-Type: image/jpeg") {
		t.Fatal("expected Content-Type: image/jpeg in part header")
	}
	if !strings.Contains(body, "Content-Length: 7") {
		t.Fatalf("expected Content-Length: 7, body was: %q", body)
	}
}

func TestStreamMJPEGNoFrame(t *testing.T) {
	var fb FrameBuffer // empty

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Millisecond)
	defer cancel()
	req := httptest.NewRequest("GET", "/stream", nil).WithContext(ctx)
	rec := httptest.NewRecorder()

	streamMJPEG(rec, req, &fb) // returns when context expires

	if strings.Contains(rec.Body.String(), "--frame") {
		t.Fatal("should not have written any frame when buffer is empty")
	}
}

func TestStreamMJPEGSkipsDuplicateVersion(t *testing.T) {
	var fb FrameBuffer
	fb.Store([]byte{0xFF, 0xD8, 0xFF, 0xD9})

	ctx, cancel := context.WithCancel(context.Background())
	req := httptest.NewRequest("GET", "/stream", nil).WithContext(ctx)
	rec := httptest.NewRecorder()

	done := make(chan struct{})
	go func() {
		streamMJPEG(rec, req, &fb)
		close(done)
	}()

	// No new frames stored — only the initial one should appear once.
	time.Sleep(50 * time.Millisecond)
	cancel()
	<-done

	body := rec.Body.String()
	count := strings.Count(body, "--frame")
	if count != 1 {
		t.Fatalf("expected exactly 1 frame boundary, got %d", count)
	}
}
