//go:build darwin

package main

// Files using //export must not have definitions in their preamble — the preamble is
// copied into _cgo_export.c alongside the Go definitions, causing duplicate-symbol
// errors. The Objective-C definitions live in capture_darwin.go.

import "C"

import (
	"runtime/cgo"
	"unsafe"
)

//export goFrameCallback
func goFrameCallback(handle C.ulong, data unsafe.Pointer, length C.int) {
	fb := cgo.Handle(uintptr(handle)).Value().(*FrameBuffer)
	jpegData := make([]byte, int(length))
	copy(jpegData, unsafe.Slice((*byte)(data), int(length)))
	fb.Store(jpegData)
}
