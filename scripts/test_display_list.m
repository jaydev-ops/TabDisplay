#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <AppKit/AppKit.h>

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
        NSLog(@"[TEST] Starting CGVirtualDisplay check...");
        
        CGVirtualDisplayDescriptor *descriptor = [[NSClassFromString(@"CGVirtualDisplayDescriptor") alloc] init];
        if (!descriptor) {
            NSLog(@"Error: CGVirtualDisplayDescriptor class not found.");
            return 1;
        }
        
        descriptor.vendorID = 0x1234;
        descriptor.productID = 0x5678;
        descriptor.serialNum = 2;
        descriptor.name = @"TabDisplay-Virtual";
        descriptor.sizeInMillimeters = CGSizeMake(200, 150);
        descriptor.maxPixelsWide = 1920;
        descriptor.maxPixelsHigh = 1080;
        descriptor.queue = dispatch_get_main_queue();
        
        CGVirtualDisplay *display = [[NSClassFromString(@"CGVirtualDisplay") alloc] initWithDescriptor:descriptor];
        if (!display) {
            NSLog(@"Error: Failed to instantiate CGVirtualDisplay");
            return 2;
        }
        
        NSLog(@"Virtual display created! ID: %d", display.displayID);
        
        CGVirtualDisplayMode *mode = [[NSClassFromString(@"CGVirtualDisplayMode") alloc] initWithWidth:1920 height:1080 refreshRate:60.0];
        CGVirtualDisplaySettings *settings = [[NSClassFromString(@"CGVirtualDisplaySettings") alloc] init];
        settings.modes = @[mode];
        
        if (![display applySettings:settings]) {
            NSLog(@"Error: Failed to apply modes settings.");
            return 3;
        }
        
        NSLog(@"Virtual display mode applied. Waiting 2s for registration...");
        [NSThread sleepForTimeInterval:2.0];
        
        // List Active displays
        uint32_t count = 0;
        CGDirectDisplayID list[16];
        CGGetActiveDisplayList(16, list, &count);
        
        NSLog(@"Active display list count: %d", count);
        for (uint32_t i = 0; i < count; i++) {
            CGRect bounds = CGDisplayBounds(list[i]);
            NSLog(@"-> Display %d: ID = %d, Bounds = {%f, %f, %f, %f}", 
                  i, list[i], bounds.origin.x, bounds.origin.y, bounds.size.width, bounds.size.height);
        }
        
        NSLog(@"Deallocating display...");
    }
    return 0;
}
