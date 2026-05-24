package main

import (
	"context"
	"fmt"
	"log"
	"net/http"
	"sync"
	"time"
)

const indexHTML = `<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<title>Pi Stream</title>
<style>
* { margin: 0; padding: 0; box-sizing: border-box; }
body { background: #000; display: flex; justify-content: center; align-items: center; height: 100vh; }
img { max-width: 100%; max-height: 100vh; }
</style>
</head>
<body>
<img src="/stream" alt="camera stream">
</body>
</html>`

func serveHTTP(ctx context.Context, wg *sync.WaitGroup, cfg Config, fb *FrameBuffer) {
	defer wg.Done()

	mux := http.NewServeMux()
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		fmt.Fprint(w, indexHTML)
	})
	mux.HandleFunc("/stream", func(w http.ResponseWriter, r *http.Request) {
		streamMJPEG(w, r, fb)
	})

	srv := &http.Server{Addr: fmt.Sprintf(":%d", cfg.HTTPPort), Handler: mux}

	go func() {
		<-ctx.Done()
		srv.Close()
	}()

	if err := srv.ListenAndServe(); err != http.ErrServerClosed {
		log.Printf("http server: %v", err)
	}
}

func streamMJPEG(w http.ResponseWriter, r *http.Request, fb *FrameBuffer) {
	w.Header().Set("Content-Type", "multipart/x-mixed-replace; boundary=frame")

	var lastVersion uint64
	for {
		select {
		case <-r.Context().Done():
			return
		default:
		}

		data, ver, ok := fb.Load()
		if !ok || ver == lastVersion {
			time.Sleep(5 * time.Millisecond)
			continue
		}
		lastVersion = ver

		fmt.Fprintf(w, "--frame\r\nContent-Type: image/jpeg\r\nContent-Length: %d\r\n\r\n", len(data))
		if _, err := w.Write(data); err != nil {
			return
		}
		fmt.Fprint(w, "\r\n")
		if f, ok := w.(http.Flusher); ok {
			f.Flush()
		}
	}
}
