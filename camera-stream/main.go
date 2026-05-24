package main

import (
	"context"
	"log"
	"os"
	"os/signal"
	"sync"
	"syscall"
	"time"
)

func main() {
	log.SetFlags(log.Ltime | log.Lmicroseconds)

	cfg := parseConfig()

	ctx, cancel := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer cancel()

	fb := &FrameBuffer{}

	log.Printf("Pi capture node starting")
	log.Printf("  Video: device %d @ %d fps", cfg.VideoDevice, cfg.FPS)
	log.Printf("  Web:   http://0.0.0.0:%d/", cfg.HTTPPort)

	var wg sync.WaitGroup
	wg.Add(2)
	go captureLoop(ctx, &wg, cfg, fb)
	go serveHTTP(ctx, &wg, cfg, fb)

	<-ctx.Done()
	log.Printf("shutting down...")

	done := make(chan struct{})
	go func() { wg.Wait(); close(done) }()
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		log.Printf("shutdown timeout, forcing exit")
		os.Exit(1)
	}

	log.Printf("stopped.")
}
