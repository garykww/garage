//go:build linux

package main

import (
	"context"
	"fmt"
	"log"
	"sync"
	"time"

	"github.com/blackjack/webcam"
)

// mjpegPixFmt is V4L2_PIX_FMT_MJPEG ('MJPG' fourcc).
const mjpegPixFmt = webcam.PixelFormat(0x47504A4D)

func captureLoop(ctx context.Context, wg *sync.WaitGroup, cfg Config, fb *FrameBuffer) {
	defer wg.Done()

	backoff := time.Second
	const maxBackoff = 30 * time.Second

	for ctx.Err() == nil {
		cam, err := openCamera(cfg)
		if err != nil {
			log.Printf("camera open failed: %v, retrying in %v", err, backoff)
			select {
			case <-ctx.Done():
				return
			case <-time.After(backoff):
			}
			backoff *= 2
			if backoff > maxBackoff {
				backoff = maxBackoff
			}
			continue
		}
		backoff = time.Second

		if err := cam.StartStreaming(); err != nil {
			log.Printf("start streaming: %v", err)
			cam.Close()
			continue
		}
		log.Printf("camera streaming MJPEG")

		fails := 0
		for ctx.Err() == nil {
			if err := cam.WaitForFrame(2); err != nil {
				if ctx.Err() != nil {
					break
				}
				fails++
				log.Printf("wait for frame: %v (%d consecutive)", err, fails)
				if fails >= 10 {
					log.Printf("too many frame-wait failures, reopening camera")
					break
				}
				continue
			}
			fails = 0

			frame, err := cam.ReadFrame()
			if err != nil {
				log.Printf("read frame: %v", err)
				continue
			}
			if len(frame) == 0 {
				continue
			}

			jpegData := make([]byte, len(frame))
			copy(jpegData, frame)
			fb.Store(jpegData)
		}

		cam.StopStreaming()
		cam.Close()
	}
}

func openCamera(cfg Config) (*webcam.Webcam, error) {
	devicePath := fmt.Sprintf("/dev/video%d", cfg.VideoDevice)
	cam, err := webcam.Open(devicePath)
	if err != nil {
		return nil, fmt.Errorf("open %s: %w", devicePath, err)
	}

	actualFmt, _, _, err := cam.SetImageFormat(mjpegPixFmt, 0, 0)
	if err != nil {
		cam.Close()
		return nil, fmt.Errorf("set format on %s: %w", devicePath, err)
	}
	if actualFmt != mjpegPixFmt {
		cam.Close()
		return nil, fmt.Errorf("%s does not support MJPEG (got format 0x%X)", devicePath, actualFmt)
	}

	return cam, nil
}

