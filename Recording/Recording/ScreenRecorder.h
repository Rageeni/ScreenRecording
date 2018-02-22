//
//  ScreenRecorder.h
//  Recording
//
//  Created by Rageeni Jadam on 21/02/18.
//  Copyright © 2018 Rageeni Jadam. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "ViewController.h"
typedef void (^VideoCompletionBlock)(void);
@protocol ScreenRecorderDelegate;

@interface ScreenRecorder : NSObject
@property (nonatomic, readonly) BOOL isRecording;
@property (strong, nonatomic) ViewController *vc;
@property (strong, nonatomic) NSTimer *timer;

// delegate is only required when implementing ScreenRecorderDelegate - see below
@property (nonatomic, weak) id <ScreenRecorderDelegate> delegate;

// if saveURL is nil, video will be saved into camera roll
// this property can not be changed whilst recording is in progress
@property (strong, nonatomic) NSURL *videoURL;

+ (instancetype)sharedInstance;
- (BOOL)startRecording;
- (void)stopRecordingWithCompletion:(VideoCompletionBlock)completionBlock;
@end
