# camera-stream

Streams a camera as MJPEG over HTTP. Runs on Raspberry Pi (Linux/V4L2) and macOS (AVFoundation).

## Usage

```sh
go build -o camera-stream .
./camera-stream
```

Open `http://<host>:8080/` in a browser.

## Connecting to the stream

The `/stream` endpoint is a standard MJPEG multipart stream. Any client that speaks `multipart/x-mixed-replace` can consume it directly.

**VLC**
```sh
vlc http://<host>:8080/stream
```

**ffmpeg**
```sh
ffmpeg -i http://<host>:8080/stream -vcodec copy output.mp4
```

**Python (OpenCV)**
```python
import cv2
cap = cv2.VideoCapture("http://<host>:8080/stream")
while True:
    ret, frame = cap.read()
    if not ret:
        break
    cv2.imshow("stream", frame)
    if cv2.waitKey(1) == ord("q"):
        break
```

**curl** (raw multipart frames to stdout)
```sh
curl http://<host>:8080/stream
```

**Python (raw TCP socket)** — parse JPEG frames without an HTTP library
```python
import socket

BOUNDARY = b"--frame"

sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
sock.connect(("<host>", 8080))
sock.sendall(b"GET /stream HTTP/1.0\r\nHost: <host>\r\n\r\n")

buf = b""
while True:
    buf += sock.recv(65536)
    start = buf.find(b"\xff\xd8")  # JPEG SOI marker
    end = buf.find(b"\xff\xd9")    # JPEG EOI marker
    if start != -1 and end != -1 and end > start:
        jpeg = buf[start : end + 2]
        buf = buf[end + 2 :]
        # process jpeg bytes here
```

**GStreamer** (common on Raspberry Pi)
```sh
gst-launch-1.0 souphttpsrc location=http://<host>:8080/stream \
  ! multipartdemux ! jpegdec ! autovideosink
```

## Options

| Flag | Env | Default | Description |
|---|---|---|---|
| `-video-device` | `VIDEO_DEVICE` | `0` | Camera device index |
| `-fps` | `CAPTURE_FPS` | `15` | Target capture FPS |
| `-http-port` | `HTTP_PORT` | `8080` | HTTP listen port |

## Platform notes

**Linux** — uses V4L2 via `github.com/blackjack/webcam`. The camera must support MJPEG output (`/dev/video0` by default). Reconnects automatically on camera errors.

**macOS** — uses AVFoundation via CGo. Requires Xcode Command Line Tools. macOS will prompt for camera permission on first run. Requires macOS 10.15+.

## Requirements

- Go 1.22+
- **Linux:** a V4L2 camera that outputs MJPEG (most USB webcams and the Pi camera module with `v4l2-ctl --set-fmt-video=pixelformat=MJPG`)
- **macOS:** Xcode Command Line Tools (`xcode-select --install`)
