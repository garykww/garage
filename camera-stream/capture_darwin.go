//go:build darwin

package main

/*
#cgo CFLAGS: -x objective-c -fobjc-arc
#cgo LDFLAGS: -framework AVFoundation -framework CoreMedia -framework CoreVideo -framework CoreImage -framework CoreGraphics -framework Foundation

#import <AVFoundation/AVFoundation.h>
#import <CoreImage/CoreImage.h>
#import <stdint.h>
#import <stdlib.h>

// Declared here; defined via //export in callback_darwin.go (separate file avoids
// conflicting-types error between this extern and the CGo-generated prototype).
extern void goFrameCallback(unsigned long handle, void *data, int length);

@interface CaptureDelegate : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate>
@property (assign) unsigned long handle;
@property (strong) CIContext *ciContext;
@end

@implementation CaptureDelegate
- (instancetype)initWithHandle:(unsigned long)h {
    self = [super init];
    if (self) {
        self.handle = h;
        self.ciContext = [CIContext contextWithOptions:nil];
    }
    return self;
}

- (void)captureOutput:(AVCaptureOutput *)output
didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
       fromConnection:(AVCaptureConnection *)connection {
    CVPixelBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (!pixelBuffer) return;

    CIImage *ciImage = [CIImage imageWithCVPixelBuffer:pixelBuffer];
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    NSData *jpegData = [self.ciContext JPEGRepresentationOfImage:ciImage
                                                    colorSpace:colorSpace
                                                       options:@{}];
    CGColorSpaceRelease(colorSpace);
    if (jpegData) {
        goFrameCallback(self.handle, (void *)jpegData.bytes, (int)jpegData.length);
    }
}
@end

typedef struct {
    void *session;
    void *delegate;
} CaptureSession;

static CaptureSession *startCapture(unsigned long handle, int deviceIndex, int fps) {
    AVCaptureDeviceDiscoverySession *discovery =
        [AVCaptureDeviceDiscoverySession
            discoverySessionWithDeviceTypes:@[
                AVCaptureDeviceTypeBuiltInWideAngleCamera,
                AVCaptureDeviceTypeExternal,
            ]
            mediaType:AVMediaTypeVideo
            position:AVCaptureDevicePositionUnspecified];
    NSArray<AVCaptureDevice *> *devices = discovery.devices;
    if (deviceIndex < 0 || deviceIndex >= (int)devices.count) return NULL;

    AVCaptureDevice *device = devices[deviceIndex];

    NSError *configErr = nil;
    if ([device lockForConfiguration:&configErr]) {
        CMTime duration = CMTimeMake(1, fps);
        device.activeVideoMinFrameDuration = duration;
        device.activeVideoMaxFrameDuration = duration;
        [device unlockForConfiguration];
    }

    NSError *inputErr = nil;
    AVCaptureDeviceInput *input = [AVCaptureDeviceInput deviceInputWithDevice:device
                                                                        error:&inputErr];
    if (!input) return NULL;

    CaptureDelegate *delegate = [[CaptureDelegate alloc] initWithHandle:handle];

    AVCaptureVideoDataOutput *videoOutput = [[AVCaptureVideoDataOutput alloc] init];
    videoOutput.videoSettings = @{
        (NSString *)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA)
    };
    videoOutput.alwaysDiscardsLateVideoFrames = YES;
    dispatch_queue_t queue = dispatch_queue_create("pi.stream.capture", DISPATCH_QUEUE_SERIAL);
    [videoOutput setSampleBufferDelegate:delegate queue:queue];

    AVCaptureSession *session = [[AVCaptureSession alloc] init];
    session.sessionPreset = AVCaptureSessionPresetHigh;
    if (![session canAddInput:input] || ![session canAddOutput:videoOutput]) return NULL;
    [session addInput:input];
    [session addOutput:videoOutput];
    [session startRunning];

    CaptureSession *cs = malloc(sizeof(CaptureSession));
    cs->session  = (__bridge_retained void *)session;
    cs->delegate = (__bridge_retained void *)delegate;
    return cs;
}

static void stopCapture(CaptureSession *cs) {
    if (!cs) return;
    AVCaptureSession *session = (__bridge_transfer AVCaptureSession *)cs->session;
    [session stopRunning];
    CaptureDelegate *delegate __attribute__((unused)) =
        (__bridge_transfer CaptureDelegate *)cs->delegate;
    free(cs);
}
*/
import "C"

import (
	"context"
	"log"
	"runtime/cgo"
	"sync"
)

func captureLoop(ctx context.Context, wg *sync.WaitGroup, cfg Config, fb *FrameBuffer) {
	defer wg.Done()

	handle := cgo.NewHandle(fb)
	defer handle.Delete()

	cs := C.startCapture(C.ulong(handle), C.int(cfg.VideoDevice), C.int(cfg.FPS))
	if cs == nil {
		log.Printf("failed to open camera device %d (check index or system permissions)", cfg.VideoDevice)
		return
	}
	defer C.stopCapture(cs)

	log.Printf("camera streaming via AVFoundation")
	<-ctx.Done()
}
