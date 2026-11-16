#import <AppKit/AppKit.h>
NS_ASSUME_NONNULL_BEGIN
@interface NMPrivateBackdropView : NSView
@property(readonly, copy) NSString *effectStatus;
- (void)configureWithBlurRadius:(double)radius opacity:(double)opacity dimming:(double)dimming fadesEdges:(BOOL)fadesEdges;
- (void)setPresented:(BOOL)presented animated:(BOOL)animated;
@end
NS_ASSUME_NONNULL_END
