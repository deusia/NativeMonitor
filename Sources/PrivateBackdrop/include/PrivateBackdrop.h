#import <AppKit/AppKit.h>
NS_ASSUME_NONNULL_BEGIN
@interface NMPrivateBackdropView : NSView
@property(readonly, copy) NSString *effectStatus;
- (void)setPresented:(BOOL)presented animated:(BOOL)animated;
@end
NS_ASSUME_NONNULL_END
