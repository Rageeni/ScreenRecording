//
//  ViewController.m
//  Recording
//
//  Created by Rageeni Jadam on 21/02/18.
//  Copyright © 2018 Rageeni Jadam. All rights reserved.
//

#import "ViewController.h"

@interface ViewController ()

@end

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    [ScreenRecorder sharedInstance].vc = self;
}

- (void)didReceiveMemoryWarning {
    [super didReceiveMemoryWarning];
}

- (IBAction)start:(id)sender {
    [[ScreenRecorder sharedInstance] startRecording];
}

- (IBAction)stop:(id)sender {
    [[ScreenRecorder sharedInstance] stopRecordingWithCompletion:^{
        NSLog(@"Stop");
    }];
}

@end
