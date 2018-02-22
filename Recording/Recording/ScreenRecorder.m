//
//  ScreenRecorder.m
//  Recording
//
//  Created by Rageeni Jadam on 21/02/18.
//  Copyright © 2018 Rageeni Jadam. All rights reserved.
//

#define TIME_INTERVAL 0.40
#define FPS 40
#define KBPS 5000

#import "ScreenRecorder.h"
#import <AVFoundation/AVFoundation.h>
#import <QuartzCore/QuartzCore.h>
#import <AssetsLibrary/AssetsLibrary.h>
#import <UIKit/UIKit.h>
#import <sys/time.h>

@interface ScreenRecorder()
@property (strong, nonatomic) AVAssetWriter *videoWriter;
@property (strong, nonatomic) AVAssetWriterInput *videoWriterInput;
@property (strong, nonatomic) AVAssetWriterInputPixelBufferAdaptor *avAdaptor;
@property (strong, nonatomic) CADisplayLink *displayLink;
@property (strong, nonatomic) NSDictionary *outputBufferPoolAuxAttributes;
@property (nonatomic) CFTimeInterval firstTimeStamp;
@property (nonatomic) BOOL isRecording;
@property (strong, nonatomic) AVAudioRecorder *audioRecorder;
@property(nonatomic,retain)AVURLAsset *videoAsset;
@property(nonatomic,retain)AVURLAsset *audioAsset;
@end

@implementation ScreenRecorder
{
    dispatch_queue_t _render_queue;
    dispatch_queue_t _append_pixelBuffer_queue;
    dispatch_semaphore_t _frameRenderingSemaphore;
    dispatch_semaphore_t _pixelAppendSemaphore;
    
    CGSize _viewSize;
    CGFloat _scale;
    
    CGColorSpaceRef _rgbColorSpace;
    CVPixelBufferPoolRef _outputBufferPool;
}

#pragma mark - initializers

+ (instancetype)sharedInstance {
    static dispatch_once_t once;
    static ScreenRecorder *sharedInstance;
    dispatch_once(&once, ^{
        sharedInstance = [[self alloc] init];
    });
    return sharedInstance;
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        _viewSize = [UIApplication sharedApplication].delegate.window.bounds.size;
        _scale = [UIScreen mainScreen].scale;
        // record half size resolution for retina iPads
        if ((UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad) && _scale > 1) {
            _scale = 1.0;
        }
        _isRecording = NO;
        
        _append_pixelBuffer_queue = dispatch_queue_create("ScreenRecorder.append_queue", DISPATCH_QUEUE_SERIAL);
        _render_queue = dispatch_queue_create("ScreenRecorder.render_queue", DISPATCH_QUEUE_SERIAL);
        dispatch_set_target_queue(_render_queue, dispatch_get_global_queue( DISPATCH_QUEUE_PRIORITY_HIGH, 0));
        _frameRenderingSemaphore = dispatch_semaphore_create(1);
        _pixelAppendSemaphore = dispatch_semaphore_create(1);
    }
    return self;
}

#pragma mark - public

- (void)setVideoURL:(NSURL *)videoURL
{
    NSAssert(!_isRecording, @"videoURL can not be changed whilst recording is in progress");
    _videoURL = videoURL;
}

- (BOOL)startRecording
{
    if (!_isRecording) {
        [self setUpWriter];
        _isRecording = (_videoWriter.status == AVAssetWriterStatusWriting);
        [self writeVideoFrame];
        [self setupAudioRecorder];
    }
    return _isRecording;
}

- (void)stopRecordingWithCompletion:(VideoCompletionBlock)completionBlock;
{
    if (_isRecording) {
        _isRecording = NO;
        [self.timer invalidate];
        [self.audioRecorder stop];
        [self completeRecordingSession:completionBlock];
    }
}

#pragma mark - private

-(void)setUpWriter
{
    _rgbColorSpace = CGColorSpaceCreateDeviceRGB();
    
    NSDictionary *bufferAttributes = @{(id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA),
                                       (id)kCVPixelBufferCGBitmapContextCompatibilityKey : @YES,
                                       (id)kCVPixelBufferWidthKey : @(_viewSize.width * _scale),
                                       (id)kCVPixelBufferHeightKey : @(_viewSize.height * _scale),
                                       (id)kCVPixelBufferBytesPerRowAlignmentKey : @(_viewSize.width * _scale * 4)
                                       };
    
    _outputBufferPool = NULL;
    CVPixelBufferPoolCreate(NULL, NULL, (__bridge CFDictionaryRef)(bufferAttributes), &_outputBufferPool);
    
    
    NSError* error = nil;
    _videoWriter = [[AVAssetWriter alloc] initWithURL:self.videoURL ?: [self tempFileURL]
                                             fileType:AVFileTypeQuickTimeMovie
                                                error:&error];
    NSParameterAssert(_videoWriter);
    
    NSInteger pixelNumber = _viewSize.width * _viewSize.height * _scale;
    NSDictionary* videoCompression = @{AVVideoAverageBitRateKey: @(pixelNumber * 11.4)};
    
    NSDictionary* videoSettings = @{AVVideoCodecKey: AVVideoCodecTypeH264,
                                    AVVideoWidthKey: [NSNumber numberWithInt:_viewSize.width*_scale],
                                    AVVideoHeightKey: [NSNumber numberWithInt:_viewSize.height*_scale],
                                    AVVideoCompressionPropertiesKey: videoCompression};
    
    _videoWriterInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:videoSettings];
    NSParameterAssert(_videoWriterInput);
    
    _videoWriterInput.expectsMediaDataInRealTime = YES;
    _videoWriterInput.transform = [self videoTransformForDeviceOrientation];
    
    _avAdaptor = [AVAssetWriterInputPixelBufferAdaptor assetWriterInputPixelBufferAdaptorWithAssetWriterInput:_videoWriterInput sourcePixelBufferAttributes:nil];
    
    [_videoWriter addInput:_videoWriterInput];
    
    [_videoWriter startWriting];
    [_videoWriter startSessionAtSourceTime:kCMTimeZero];
    //    [_videoWriter startSessionAtSourceTime:CMTimeMake(0, 1000)];
}

- (CGAffineTransform)videoTransformForDeviceOrientation
{
    CGAffineTransform videoTransform;
    switch ([UIDevice currentDevice].orientation) {
        case UIDeviceOrientationLandscapeLeft:
            videoTransform = CGAffineTransformMakeRotation(-M_PI_2);
            break;
        case UIDeviceOrientationLandscapeRight:
            videoTransform = CGAffineTransformMakeRotation(M_PI_2);
            break;
        case UIDeviceOrientationPortraitUpsideDown:
            videoTransform = CGAffineTransformMakeRotation(M_PI);
            break;
        default:
            videoTransform = CGAffineTransformIdentity;
    }
    return videoTransform;
}

- (NSURL*)tempFileURL
{
    NSString *outputPath = [NSHomeDirectory() stringByAppendingPathComponent:@"tmp/screenCapture.mp4"];
    [self removeTempFilePath:outputPath];
    return [NSURL fileURLWithPath:outputPath];
}

- (void)removeTempFilePath:(NSString*)filePath
{
    NSFileManager* fileManager = [NSFileManager defaultManager];
    if ([fileManager fileExistsAtPath:filePath]) {
        NSError* error;
        if ([fileManager removeItemAtPath:filePath error:&error] == NO) {
            NSLog(@"Could not delete old recording:%@", [error localizedDescription]);
        }
    }
}

- (void)completeRecordingSession:(VideoCompletionBlock)completionBlock;
{
    dispatch_async(_render_queue, ^{
        dispatch_sync(_append_pixelBuffer_queue, ^{
            
            [_videoWriterInput markAsFinished];
            [_videoWriter finishWritingWithCompletionHandler:^{
                
                void (^completion)(void) = ^() {
                    [self cleanup];
                    dispatch_async(dispatch_get_main_queue(), ^{
                        if (completionBlock) completionBlock();
                    });
                };
                
                if (self.videoURL) {
                    completion();
                } else {
                    //                    ALAssetsLibrary *library = [[ALAssetsLibrary alloc] init];
                    //                    [library writeVideoAtPathToSavedPhotosAlbum:_videoWriter.outputURL completionBlock:^(NSURL *assetURL, NSError *error) {
                    //                        if (error) {
                    //                            NSLog(@"Error copying video to camera roll:%@", [error localizedDescription]);
                    //                        } else {
                    //                            [self removeTempFilePath:_videoWriter.outputURL.path];
                    //                            completion();
                    //                        }
                    //                    }];
                }
                [self mergeAndSave];
            }];
        });
    });
}

- (void)cleanup
{
    self.avAdaptor = nil;
    self.videoWriterInput = nil;
    self.videoWriter = nil;
    self.firstTimeStamp = 0;
    self.outputBufferPoolAuxAttributes = nil;
    CGColorSpaceRelease(_rgbColorSpace);
    CVPixelBufferPoolRelease(_outputBufferPool);
}

- (void)writeVideoFrame
{
    
    if (dispatch_semaphore_wait(_frameRenderingSemaphore, DISPATCH_TIME_NOW) != 0) {
        return;
    }
    dispatch_async(_render_queue, ^{
        if (![_videoWriterInput isReadyForMoreMediaData]) return;
        if (!_avAdaptor.assetWriterInput.readyForMoreMediaData) {
            return;
        }
        
        int targetFPS = FPS;
        int msBeforeNextCapture = 1000 / targetFPS;
        
        struct timeval lastCapture, currentTime, startTime;
        lastCapture.tv_sec = 0;
        lastCapture.tv_usec = 0;
        
        //recording start time
        gettimeofday(&startTime, NULL);
        startTime.tv_usec /= 1000;
        
        NSInteger lastFrame = -1;
        while(_isRecording)
        {
            //            if (((long)[UIApplication sharedApplication].applicationState == UIApplicationStateBackground)) {
            //                return;
            //            }
            //time passed since last capture
            gettimeofday(&currentTime, NULL);
            
            //convert to milliseconds to avoid overflows
            currentTime.tv_usec /= 1000;
            
            unsigned long long diff = (currentTime.tv_usec + (1000 * currentTime.tv_sec) ) - (lastCapture.tv_usec + (1000 * lastCapture.tv_sec) );
            
            // if enough time has passed, capture another shot
            if(diff >= msBeforeNextCapture)
            {
                //time since start
                NSInteger msSinceStart = (currentTime.tv_usec + (1000 * currentTime.tv_sec) ) - (startTime.tv_usec + (1000 * startTime.tv_sec) );
                
                // Generate the frame number
                NSInteger frameNumber = msSinceStart / msBeforeNextCapture;
                CMTime presentTime;
                presentTime = CMTimeMake(frameNumber, targetFPS);
                
                // Frame number cannot be last frames number :P
                NSParameterAssert(frameNumber != lastFrame);
                lastFrame = frameNumber;
                NSLog(@"** %f %d",CMTimeGetSeconds(presentTime),[self.audioRecorder isRecording]);
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self.vc.lbl setText:[NSString stringWithFormat:@"%f",CMTimeGetSeconds(presentTime)]];
                });
                
                [self recoder:presentTime];
                lastCapture = currentTime;
            }
        }
    });
}

- (void)recoder:(CMTime)time {
    CVPixelBufferRef pixelBuffer = NULL;
    CGContextRef bitmapContext = [self createPixelBufferAndBitmapContext:&pixelBuffer];
    
    dispatch_sync(dispatch_get_main_queue(), ^{
        UIGraphicsPushContext(bitmapContext); {
            for (UIWindow *window in [[UIApplication sharedApplication] windows]) {
                [window drawViewHierarchyInRect:CGRectMake(0, 0, _viewSize.width, _viewSize.height) afterScreenUpdates:NO];
            }
        } UIGraphicsPopContext();
    });
    
    
    if (dispatch_semaphore_wait(_pixelAppendSemaphore, DISPATCH_TIME_NOW) == 0) {
        dispatch_async(_append_pixelBuffer_queue, ^{
            BOOL success = [_avAdaptor appendPixelBuffer:pixelBuffer withPresentationTime:time];
            if (!success) {
                NSLog(@"%@",[NSString stringWithFormat:@"Error Code - %ld\nReason - %@\n%@",(long)_videoWriter.status,_videoWriter.error.localizedDescription,_videoWriter.error.localizedFailureReason]);
                NSLog(@"Warning: Unable to write buffer to video");
            }
            CGContextRelease(bitmapContext);
            CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
            CVPixelBufferRelease(pixelBuffer);
            
            dispatch_semaphore_signal(_pixelAppendSemaphore);
        });
    } else {
        CGContextRelease(bitmapContext);
        CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
        CVPixelBufferRelease(pixelBuffer);
    }
    
    dispatch_semaphore_signal(_frameRenderingSemaphore);
    
}
- (CGContextRef)createPixelBufferAndBitmapContext:(CVPixelBufferRef *)pixelBuffer
{
    CVPixelBufferPoolCreatePixelBuffer(NULL, _outputBufferPool, pixelBuffer);
    CVPixelBufferLockBaseAddress(*pixelBuffer, 0);
    
    CGContextRef bitmapContext = NULL;
    bitmapContext = CGBitmapContextCreate(CVPixelBufferGetBaseAddress(*pixelBuffer),
                                          CVPixelBufferGetWidth(*pixelBuffer),
                                          CVPixelBufferGetHeight(*pixelBuffer),
                                          8, CVPixelBufferGetBytesPerRow(*pixelBuffer), _rgbColorSpace,
                                          kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst
                                          );
    CGContextScaleCTM(bitmapContext, _scale, _scale);
    CGAffineTransform flipVertical = CGAffineTransformMake(1, 0, 0, -1, 0, _viewSize.height);
    CGContextConcatCTM(bitmapContext, flipVertical);
    
    return bitmapContext;
}

- (BOOL)setupAudioRecorder {
    NSError *error;
    NSMutableDictionary *settings = [NSMutableDictionary dictionary];
    //        [settings setValue: [NSNumber numberWithInt:kAudioFormatLinearPCM] forKey:AVFormatIDKey];
    [settings setValue: [NSNumber numberWithFloat:8000.0] forKey:AVSampleRateKey];
    [settings setValue: [NSNumber numberWithInt: 1] forKey:AVNumberOfChannelsKey];
    //        [settings setValue: [NSNumber numberWithInt:16] forKey:AVLinearPCMBitDepthKey];
    //        [settings setValue: [NSNumber numberWithBool:NO] forKey:AVLinearPCMIsBigEndianKey];
    //        [settings setValue: [NSNumber numberWithBool:NO] forKey:AVLinearPCMIsFloatKey];
    //        [settings setValue: [NSNumber numberWithInt: AVAudioQualityHigh] forKey:AVEncoderAudioQualityKey];
    
    NSString *outputPath = [NSHomeDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"tmp/audio.wav"]];
    self.audioRecorder = [[AVAudioRecorder alloc] initWithURL:[NSURL fileURLWithPath:outputPath] settings:settings error:&error];
    if (!self.audioRecorder) {
        NSLog(@"Error establishing recorder: %@", error.localizedFailureReason);
        return NO;
    }
    self.audioRecorder.meteringEnabled = YES;
    AVAudioSession  *audioSession = [AVAudioSession sharedInstance];
    NSError *err = nil;
    [audioSession setCategory :AVAudioSessionCategoryRecord error:&err];
    [self.audioRecorder prepareToRecord];
    if (![self.audioRecorder prepareToRecord]) {
        NSLog(@"Error: Prepare to record failed");
        return NO;
    }
    
    [self.audioRecorder record];
    if (![self.audioRecorder record]) {
        NSLog(@"Error: Record failed");
        return NO;
    }
    return YES;
}

- (void)mergeAndSave {
    @try {
        //Create AVMutableComposition Object which will hold our multiple AVMutableCompositionTrack or we can say it will hold our video and audio files.
        AVMutableComposition* mixComposition = [AVMutableComposition composition];
        
        //Now first load your audio file using AVURLAsset. Make sure you give the correct path of your videos.
        
        NSURL *audio_url = [NSURL fileURLWithPath:[NSHomeDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"tmp/audio.wav"]]];
        self.audioAsset = [[AVURLAsset alloc]initWithURL:audio_url options:nil];
        CMTimeRange audio_timeRange = CMTimeRangeMake(kCMTimeZero, self.audioAsset.duration);
        
        //Now we are creating the first AVMutableCompositionTrack containing our audio and add it to our AVMutableComposition object.
        AVMutableCompositionTrack *b_compositionAudioTrack = [mixComposition addMutableTrackWithMediaType:AVMediaTypeAudio preferredTrackID:kCMPersistentTrackID_Invalid];
        [b_compositionAudioTrack insertTimeRange:audio_timeRange ofTrack:[[self.audioAsset tracksWithMediaType:AVMediaTypeAudio] objectAtIndex:0] atTime:kCMTimeZero error:nil];
        
        //Now we will load video file.
        NSURL *video_url = [NSURL fileURLWithPath:[NSHomeDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"tmp/screenCapture.mp4"]]];
        self.videoAsset = [[AVURLAsset alloc]initWithURL:video_url options:nil];
        CMTimeRange video_timeRange = CMTimeRangeMake(kCMTimeZero,self.audioAsset.duration);
        
        //Now we are creating the second AVMutableCompositionTrack containing our video and add it to our AVMutableComposition object.
        AVMutableCompositionTrack *a_compositionVideoTrack = [mixComposition addMutableTrackWithMediaType:AVMediaTypeVideo preferredTrackID:kCMPersistentTrackID_Invalid];
        [a_compositionVideoTrack insertTimeRange:video_timeRange ofTrack:[[self.videoAsset tracksWithMediaType:AVMediaTypeVideo] objectAtIndex:0] atTime:kCMTimeZero error:nil];
        
        //decide the path where you want to store the final video created with audio and video merge.
        NSString *outputFilePath = [NSHomeDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"tmp/res.mp4"]];
        NSURL *outputFileUrl = [NSURL fileURLWithPath:outputFilePath];
        if ([[NSFileManager defaultManager] fileExistsAtPath:outputFilePath])
            [[NSFileManager defaultManager] removeItemAtPath:outputFilePath error:nil];
        
        //Now create an AVAssetExportSession object that will save your final video at specified path.
        AVAssetExportSession* _assetExport = [[AVAssetExportSession alloc] initWithAsset:mixComposition presetName:AVAssetExportPresetHighestQuality];
        _assetExport.outputFileType = @"com.apple.quicktime-movie";
        _assetExport.outputURL = outputFileUrl;
        
        [_assetExport exportAsynchronouslyWithCompletionHandler:
         ^(void ) {
             dispatch_async(dispatch_get_main_queue(), ^{});
         }];
    } @catch (NSException *exception) {
        NSLog(@"Exception In %s reason:%@",__func__,exception.reason);
    }
}

@end

