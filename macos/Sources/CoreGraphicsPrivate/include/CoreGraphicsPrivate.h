#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

@interface PrivateDisplayHelper : NSObject

+ (CGDirectDisplayID)createVirtualDisplayWithWidth:(int)width 
                                            height:(int)height 
                                               fps:(int)fps 
                                      outDisplay:(id _Nullable * _Nonnull)outDisplay;

+ (void)destroyVirtualDisplay:(id _Nonnull)display;

@end
