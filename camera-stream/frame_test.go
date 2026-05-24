package main

import (
	"sync"
	"testing"
)

func TestFrameBufferEmpty(t *testing.T) {
	var fb FrameBuffer
	_, _, ok := fb.Load()
	if ok {
		t.Fatal("empty FrameBuffer should return ok=false")
	}
}

func TestFrameBufferStoreLoad(t *testing.T) {
	var fb FrameBuffer
	data := []byte{0xFF, 0xD8, 0xFF, 0xD9}
	fb.Store(data)

	got, ver, ok := fb.Load()
	if !ok {
		t.Fatal("expected ok=true after Store")
	}
	if ver != 1 {
		t.Fatalf("expected version 1, got %d", ver)
	}
	if string(got) != string(data) {
		t.Fatalf("got %v, want %v", got, data)
	}
}

func TestFrameBufferVersionIncrements(t *testing.T) {
	var fb FrameBuffer
	fb.Store([]byte{1})
	fb.Store([]byte{2})
	fb.Store([]byte{3})
	_, ver, _ := fb.Load()
	if ver != 3 {
		t.Fatalf("expected version 3, got %d", ver)
	}
}

func TestFrameBufferLastWins(t *testing.T) {
	var fb FrameBuffer
	fb.Store([]byte{1, 2, 3})
	fb.Store([]byte{9, 9})
	got, _, _ := fb.Load()
	if string(got) != string([]byte{9, 9}) {
		t.Fatalf("expected last stored value, got %v", got)
	}
}

func TestFrameBufferConcurrent(t *testing.T) {
	var fb FrameBuffer
	var wg sync.WaitGroup
	for i := 0; i < 50; i++ {
		wg.Add(2)
		go func(v byte) {
			defer wg.Done()
			fb.Store([]byte{v})
		}(byte(i))
		go func() {
			defer wg.Done()
			fb.Load()
		}()
	}
	wg.Wait()
}
