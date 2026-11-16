#import "PrivateBackdrop.h"
#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>
static BOOL Put(id object, NSString *key, id value) {
    @try { [object setValue:value forKey:key]; return YES; }
    @catch (NSException *e) { NSLog(@"不支持 %@: %@", key, e.name); return NO; }
}
static CGImageRef Mask(size_t w, size_t h, BOOL fadesEdges) {
    if(w==0 || h==0 || w>4096 || h>4096) return NULL;
    NSMutableData *data = [NSMutableData dataWithLength:w*h*4];
    uint8_t *p=data.mutableBytes;
    for(size_t y=0;y<h;y++) for(size_t x=0;x<w;x++) {
        double qx=fabs(x+.5-w/2.)-w/2.+64, qy=fabs(y+.5-h/2.)-h/2.+64;
        double d=hypot(fmax(qx,0),fmax(qy,0))+fmin(fmax(qx,qy),0)-64;
        double t=fadesEdges ? fmin(1,fmax(0,-d/fmin(160, fmin(w,h)/3.))) : 1;
        uint8_t a=round(255*t*t*(3-2*t));
        size_t k=(y*w+x)*4; p[k]=a;p[k+1]=a;p[k+2]=a;p[k+3]=a;
    }
    CGColorSpaceRef cs=CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx=CGBitmapContextCreate(p,w,h,8,w*4,cs,(CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    if(!ctx){CGColorSpaceRelease(cs);return NULL;}
    CGImageRef image=CGBitmapContextCreateImage(ctx); CGContextRelease(ctx);CGColorSpaceRelease(cs);return image;
}

// 多个区域共享同一窗口的合成配置，最后一个区域移除时才恢复。
@interface NMBackdropWindowState : NSObject
@property NSUInteger users;
@property id oldFlatten;
@property id oldHosting;
@property BOOL available;
@end
@implementation NMBackdropWindowState
@end
static NSMapTable<NSWindow *, NMBackdropWindowState *> *WindowStates(void) {
    static NSMapTable *states;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ states=[NSMapTable weakToStrongObjectsMapTable]; });
    return states;
}

@interface NMPrivateBackdropView ()
@property CALayer *backdrop;
@property id blur;
@property CALayer *dimming;
@property(readwrite, copy) NSString *effectStatus;
@property NSSize maskSize;
@property(weak) NSWindow *configuredWindow;
@property double blurRadius;
@property double effectOpacity;
@property double dimmingStrength;
@property BOOL fadesEdges;
@property BOOL presentationInitialized;
@property BOOL presented;
@end
@implementation NMPrivateBackdropView
-(instancetype)initWithFrame:(NSRect)frame {
    if((self=[super initWithFrame:frame])) {
        self.wantsLayer=YES;
        _blurRadius=2;_effectOpacity=1;_dimmingStrength=1;_fadesEdges=YES;
        self.effectStatus=@"私有背景接口不可用；区域模糊已关闭";
        Class cls=NSClassFromString(@"CABackdropLayer"), filter=NSClassFromString(@"CAFilter");
        SEL selector=NSSelectorFromString(@"filterWithType:");
        if(!cls || ![filter respondsToSelector:selector]) return self;
        self.backdrop=[cls layer];
        self.blur=((id(*)(id,SEL,id))objc_msgSend)(filter,selector,@"variableBlur");
        if(!self.blur) return self;
        BOOL ok=Put(self.blur,@"inputRadius",@2) && Put(self.blur,@"inputNormalizeEdges",@YES)
            && Put(self.backdrop,@"windowServerAware",@YES)
            && Put(self.backdrop,@"allowsInPlaceFiltering",@NO);
        if(!ok) {self.backdrop=nil;return self;}
        Put(self.backdrop,@"scale",@1);Put(self.backdrop,@"bleedAmount",@24);
        self.backdrop.filters=@[self.blur];
        self.backdrop.hidden=YES;
        [self.layer addSublayer:self.backdrop];
        // 暗化与模糊共用渐变轮廓，外围透明，避免独立灰色矩形边界。
        self.dimming=[CALayer layer];
        [self updateDimming];
        self.dimming.mask=[CALayer layer];
        self.dimming.hidden=YES;
        [self.layer addSublayer:self.dimming];
        self.effectStatus=@"私有渐变模糊 · 无录屏 · 系统升级可能失效";
    }return self;
}
-(void)configureWithBlurRadius:(double)radius opacity:(double)opacity dimming:(double)dimming fadesEdges:(BOOL)fadesEdges {
    radius=isfinite(radius) ? fmin(30,fmax(0,radius)) : 2;
    opacity=isfinite(opacity) ? fmin(1,fmax(0,opacity)) : 1;
    dimming=isfinite(dimming) ? fmin(2,fmax(0,dimming)) : 1;
    [CATransaction begin];[CATransaction setDisableActions:YES];
    if(self.blurRadius!=radius) {
        self.blurRadius=radius;
        if(self.blur && !Put(self.blur,@"inputRadius",@(radius))) {
            self.backdrop.filters=nil;self.dimming.hidden=YES;
            self.effectStatus=@"模糊参数不可用；区域模糊已关闭";
        }
    }
    if(self.effectOpacity!=opacity) {
        self.effectOpacity=opacity;
        for(CALayer *layer in self.layer.sublayers) {
            [layer removeAnimationForKey:@"presentationOpacity"];
            layer.opacity=(!self.presentationInitialized || self.presented) ? opacity : 0;
        }
    }
    if(self.dimmingStrength!=dimming) {self.dimmingStrength=dimming;[self updateDimming];}
    if(self.fadesEdges!=fadesEdges) {
        self.fadesEdges=fadesEdges;self.maskSize=NSZeroSize;self.needsLayout=YES;
    }
    [CATransaction commit];
}
-(void)setPresented:(BOOL)presented animated:(BOOL)animated {
    if(self.presentationInitialized && self.presented==presented) {
        if(!animated) {
            [self.backdrop removeAnimationForKey:@"presentationOpacity"];
            [self.dimming removeAnimationForKey:@"presentationOpacity"];
        }
        return;
    }
    BOOL shouldAnimate=animated && self.presentationInitialized;
    self.presentationInitialized=YES;
    self.presented=presented;
    for(CALayer *layer in self.backdrop && self.dimming ? @[self.backdrop, self.dimming] : @[]) {
        float from=layer.presentationLayer ? layer.presentationLayer.opacity : layer.opacity;
        [layer removeAnimationForKey:@"presentationOpacity"];
        [CATransaction begin];[CATransaction setDisableActions:YES];
        layer.opacity=presented ? self.effectOpacity : 0;
        [CATransaction commit];
        if(shouldAnimate) {
            CABasicAnimation *animation=[CABasicAnimation animationWithKeyPath:@"opacity"];
            animation.fromValue=@(from);animation.toValue=@(layer.opacity);
            animation.duration=0.36;
            animation.timingFunction=[CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
            [layer addAnimation:animation forKey:@"presentationOpacity"];
        }
    }
}
-(void)updateDimming {
    BOOL dark=[[self.effectiveAppearance bestMatchFromAppearancesWithNames:@[NSAppearanceNameAqua, NSAppearanceNameDarkAqua]] isEqualToString:NSAppearanceNameDarkAqua];
    [CATransaction begin];[CATransaction setDisableActions:YES];
    self.dimming.backgroundColor=[NSColor colorWithWhite:0 alpha:(dark ? 0.18 : 0.06)*self.dimmingStrength].CGColor;
    [CATransaction commit];
}
-(void)viewDidChangeEffectiveAppearance {
    [super viewDidChangeEffectiveAppearance];
    [self updateDimming];
}
-(NSView *)hitTest:(NSPoint)point {return nil;}
-(void)viewWillMoveToWindow:(NSWindow *)window {
    if(self.configuredWindow && self.configuredWindow!=window) {
        NMBackdropWindowState *state=[WindowStates() objectForKey:self.configuredWindow];
        if(state && --state.users==0) {
            if(state.oldFlatten) Put(self.configuredWindow,@"shouldAutoFlattenLayerTree",state.oldFlatten);
            if(state.oldHosting) Put(self.configuredWindow,@"canHostLayersInWindowServer",state.oldHosting);
            [WindowStates() removeObjectForKey:self.configuredWindow];
        }
        self.configuredWindow=nil;
    }
    [super viewWillMoveToWindow:window];
}
-(void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    NSWindow *window=self.window;
    if(!window || !self.backdrop || window==self.configuredWindow) return;
    NMBackdropWindowState *state=[WindowStates() objectForKey:window];
    if(!state) {
        state=[NMBackdropWindowState new];
        [WindowStates() setObject:state forKey:window];
        @try {
            state.oldFlatten=[window valueForKey:@"shouldAutoFlattenLayerTree"];
            state.oldHosting=[window valueForKey:@"canHostLayersInWindowServer"];
            state.available=Put(window,@"shouldAutoFlattenLayerTree",@NO)
                && Put(window,@"canHostLayersInWindowServer",@NO)
                && Put(window,@"canHostLayersInWindowServer",@YES);
        } @catch(NSException *e) {NSLog(@"私有窗口合成不可用: %@",e.name);}
    }
    state.users++;
    self.configuredWindow=window;
    if(!state.available) {
        self.backdrop.filters=nil;self.dimming.hidden=YES;
        self.effectStatus=@"窗口合成接口不可用；区域模糊已关闭";
    }
    self.needsLayout=YES;
}
-(void)layout {
    [super layout];
    if(!self.backdrop) return;
    NSSize size=NSMakeSize(ceil(self.bounds.size.width),ceil(self.bounds.size.height));
    [CATransaction begin];[CATransaction setDisableActions:YES];
    self.backdrop.frame=self.bounds;
    self.dimming.frame=self.bounds;
    self.dimming.mask.frame=self.dimming.bounds;
    if(!NSEqualSizes(size,self.maskSize)) {
        self.maskSize=size;
        CGImageRef image=Mask(size.width,size.height,self.fadesEdges);
        BOOL ok=image && Put(self.blur,@"inputMaskImage",(__bridge id)image);
        self.backdrop.hidden=!ok;
        self.dimming.mask.contents=ok ? (__bridge id)image : nil;
        self.dimming.hidden=!ok || self.backdrop.filters.count==0;
        if(image) CGImageRelease(image);
        if(!ok) self.effectStatus=@"背景尺寸不可用；区域模糊已关闭";
    }
    [CATransaction commit];
}
@end
