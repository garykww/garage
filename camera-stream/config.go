package main

import (
	"flag"
	"fmt"
	"os"
	"strconv"
)

type Config struct {
	VideoDevice int
	FPS         int
	HTTPPort    int
}

func envInt(key string, def int) int {
	v := os.Getenv(key)
	if v == "" {
		return def
	}
	n, err := strconv.Atoi(v)
	if err != nil {
		fmt.Fprintf(os.Stderr, "warning: invalid %s=%q, using default %d\n", key, v, def)
		return def
	}
	return n
}

func parseConfig() Config {
	var cfg Config
	flag.IntVar(&cfg.VideoDevice, "video-device", envInt("VIDEO_DEVICE", 0), "Camera device index")
	flag.IntVar(&cfg.FPS, "fps", envInt("CAPTURE_FPS", 15), "Publish FPS")
	flag.IntVar(&cfg.HTTPPort, "http-port", envInt("HTTP_PORT", 8080), "HTTP stream port")
	flag.Parse()
	return cfg
}
