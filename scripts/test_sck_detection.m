#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>

@interface CGVirtualDisplayDescriptor : NSObject
@property(nonatomic) unsigned int vendorID;
@property(nonatomic) unsigned int productID;
@property(nonatomic) unsigned int serialNum;
@property(nonatomic, retain) NSString *name;
@property(nonatomic) struct CGSize sizeInMillimeters;
@property(nonatomic) unsigned int maxPixelsWide;
@property(nonatomic) unsigned int maxPixelsHigh;
@property(nonatomic, retain) dispatch_queue_t queue;
@end

@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(unsigned int)width height:(unsigned int)height refreshRate:(double)refresh;
@end

@interface CGVirtualDisplaySettings : NSObject
@property(nonatomic, retain) NSArray *modes;
@end

@interface CGVirtualDisplay : NSObject
@property(nonatomic, readonly) unsigned int displayID;
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@end

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        NSLog(@"[TEST] Initializing CGVirtualDisplay for ScreenCaptureKit verification...");
        
        CGVirtualDisplayDescriptor *descriptor = [[NSClassFromString(@"CGVirtualDisplayDescriptor") alloc] init];
        descriptor.vendorID = 0x1234;
        descriptor.productID = 0x5678;
        descriptor.serialNum = 3;
        descriptor.name = @"TabDisplay-SCK";
        descriptor.sizeInMillimeters = CGSizeMake(200, 150);
        descriptor.maxPixelsWide = 1920;
        descriptor.maxPixelsHigh = 1080;
        descriptor.queue = dispatch_get_main_queue();
        
        CGVirtualDisplay *display = [[NSClassFromString(@"CGVirtualDisplay") alloc] initWithDescriptor:descriptor];
        if (!display) {
            NSLog(@"Failed to initialize virtual display");
            return 1;
        }
        
        CGVirtualDisplayMode *mode = [[NSClassFromString(@"CGVirtualDisplayMode") alloc] initWithWidth:1920 height:1080 refreshRate:60.0];
        CGVirtualDisplaySettings *settings = [[NSClassFromString(@"CGVirtualDisplaySettings") alloc] init];
        settings.modes = @[mode];
        
        if (![display applySettings:settings]) {
            NSLog(@"Failed to apply settings");
            return 2;
        }
        
        unsigned int targetDisplayID = display.displayID;
        NSLog(@"Virtual display active. ID: %d. Querying ScreenCaptureKit shareable content...", targetDisplayID);
        
        [NSThread sleepForTimeInterval:1.0];
        
        dispatch_semaphore_t sem = dispatch_semaphore_create(0);
        
        [SCShareableContent getShareableContentWithCompletionHandler:^(SCShareableContent * _Nullable shareableContent, NSError * _Nullable error) {
            if (error) {
                NSLog(@"SCShareableContent fetch failed (TCC permission might be missing): %@", error);
            } else {
                BOOL found = NO;
                for (SCDisplay *scDisplay in shareableContent.displays) {
                    if (scDisplay.displayID == targetDisplayID) {
                        found = YES;
                    }
                }
                if (found) {
                    NSLog(@"SUCCESS: ScreenCaptureKit verified CGVirtualDisplay.");
                } else {
                    NSLog(@"FAILURE: ScreenCaptureKit did not detect CGVirtualDisplay.");
                }
            }
            dispatch_semaphore_signal(sem);
        }];
        
        dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)));
    }
    return 0;
}
