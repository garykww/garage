package main

import "sync"

type FrameBuffer struct {
	mu      sync.Mutex
	data    []byte
	version uint64
}

func (fb *FrameBuffer) Store(data []byte) {
	fb.mu.Lock()
	fb.data = data
	fb.version++
	fb.mu.Unlock()
}

func (fb *FrameBuffer) Load() (data []byte, version uint64, ok bool) {
	fb.mu.Lock()
	defer fb.mu.Unlock()
	if fb.data == nil {
		return nil, 0, false
	}
	return fb.data, fb.version, true
}
