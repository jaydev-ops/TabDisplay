#import "include/CoreGraphicsPrivate.h"

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

@implementation PrivateDisplayHelper

+ (CGDirectDisplayID)createVirtualDisplayWithWidth:(int)width 
                                            height:(int)height 
                                               fps:(int)fps 
                                      outDisplay:(id _Nullable * _Nonnull)outDisplay {
    
    CGVirtualDisplayDescriptor *descriptor = [[NSClassFromString(@"CGVirtualDisplayDescriptor") alloc] init];
    if (!descriptor) return 0;
    
    descriptor.vendorID = 0x1234;
    descriptor.productID = 0x5678;
    descriptor.serialNum = 1;
    descriptor.name = @"TabDisplay-Virtual";
    descriptor.sizeInMillimeters = CGSizeMake(200, 150);
    descriptor.maxPixelsWide = width;
    descriptor.maxPixelsHigh = height;
    descriptor.queue = dispatch_get_main_queue();
    
    CGVirtualDisplay *display = [[NSClassFromString(@"CGVirtualDisplay") alloc] initWithDescriptor:descriptor];
    if (!display) return 0;
    
    CGVirtualDisplayMode *mode = [[NSClassFromString(@"CGVirtualDisplayMode") alloc] initWithWidth:width height:height refreshRate:fps];
    CGVirtualDisplaySettings *settings = [[NSClassFromString(@"CGVirtualDisplaySettings") alloc] init];
    settings.modes = @[mode];
    
    if (![display applySettings:settings]) {
        return 0;
    }
    
    *outDisplay = display;
    return display.displayID;
}

+ (void)destroyVirtualDisplay:(id)display {
    // Simply releasing the reference deallocates CGVirtualDisplay and removes the screen
    // Objective-C ARC will automatically release display when the reference drops to 0.
}

@end
