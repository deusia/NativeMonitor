#import "PrivateBackdrop.h"
#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>
static BOOL Put(id object, NSString *key, id value) {
    @try { [object setValue:value forKey:key]; return YES; }
    @catch (NSException *e) { NSLog(@"不支持 %@: %@", key, e.name); return NO; }
}
static CGImageRef Mask(size_t w, size_t h) {
    if(w==0 || h==0 || w>4096 || h>4096) return NULL;
    NSMutableData *data = [NSMutableData dataWithLength:w*h*4];
    uint8_t *p=data.mutableBytes;
    for(size_t y=0;y<h;y++) for(size_t x=0;x<w;x++) {
        double qx=fabs(x+.5-w/2.)-w/2.+64, qy=fabs(y+.5-h/2.)-h/2.+64;
        double d=hypot(fmax(qx,0),fmax(qy,0))+fmin(fmax(qx,qy),0)-64;
        double t=fmin(1,fmax(0,-d/fmin(120, fmin(w,h)/3.)));
        uint8_t a=round(255*t*t*(3-2*t));
        size_t k=(y*w+x)*4; p[k]=a;p[k+1]=a;p[k+2]=a;p[k+3]=a;
    }
    CGColorSpaceRef cs=CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx=CGBitmapContextCreate(p,w,h,8,w*4,cs,(CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    if(!ctx){CGColorSpaceRelease(cs);return NULL;}
    CGImageRef image=CGBitmapContextCreateImage(ctx); CGContextRelease(ctx);CGColorSpaceRelease(cs);return image;
}

@interface NMPrivateBackdropView ()
@property CALayer *backdrop;
@property id blur;
@property CALayer *dimming;
@property(readwrite, copy) NSString *effectStatus;
@property NSSize maskSize;
@property(weak) NSWindow *configuredWindow;
@property id oldFlatten;
@property id oldHosting;
@end
@implementation NMPrivateBackdropView
-(instancetype)initWithFrame:(NSRect)frame {
    if((self=[super initWithFrame:frame])) {
        self.wantsLayer=YES;
        self.effectStatus=@"私有背景接口不可用；区域模糊已关闭";
        Class cls=NSClassFromString(@"CABackdropLayer"), filter=NSClassFromString(@"CAFilter");
        SEL selector=NSSelectorFromString(@"filterWithType:");
        if(!cls || ![filter respondsToSelector:selector]) return self;
        self.backdrop=[cls layer];
        self.blur=((id(*)(id,SEL,id))objc_msgSend)(filter,selector,@"variableBlur");
        if(!self.blur) return self;
        BOOL ok=Put(self.blur,@"inputRadius",@6) && Put(self.blur,@"inputNormalizeEdges",@YES)
            && Put(self.backdrop,@"windowServerAware",@YES)
            && Put(self.backdrop,@"allowsInPlaceFiltering",@NO);
        if(!ok) {self.backdrop=nil;return self;}
        Put(self.backdrop,@"scale",@1);Put(self.backdrop,@"bleedAmount",@24);
        self.backdrop.filters=@[self.blur];
        self.backdrop.hidden=YES;
        [self.layer addSublayer:self.backdrop];
        // 暗化与模糊共用渐变轮廓，外围透明，避免独立灰色矩形边界。
        self.dimming=[CALayer layer];
        self.dimming.backgroundColor=[NSColor colorWithWhite:0 alpha:0.10].CGColor;
        self.dimming.mask=[CALayer layer];
        self.dimming.hidden=YES;
        [self.layer addSublayer:self.dimming];
        self.effectStatus=@"私有渐变模糊 · 无录屏 · 系统升级可能失效";
    }return self;
}
-(NSView *)hitTest:(NSPoint)point {return nil;}
-(void)viewWillMoveToWindow:(NSWindow *)window {
    if(self.configuredWindow && self.configuredWindow!=window) {
        Put(self.configuredWindow,@"shouldAutoFlattenLayerTree",self.oldFlatten);
        Put(self.configuredWindow,@"canHostLayersInWindowServer",self.oldHosting);
        self.configuredWindow=nil;
    }
    [super viewWillMoveToWindow:window];
}
-(void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    NSWindow *window=self.window;
    if(!window || !self.backdrop || window==self.configuredWindow) return;
    @try {
        self.oldFlatten=[window valueForKey:@"shouldAutoFlattenLayerTree"];
        self.oldHosting=[window valueForKey:@"canHostLayersInWindowServer"];
        self.configuredWindow=window;
        BOOL ok=Put(window,@"shouldAutoFlattenLayerTree",@NO)
            && Put(window,@"canHostLayersInWindowServer",@NO)
            && Put(window,@"canHostLayersInWindowServer",@YES);
        if(!ok){self.backdrop.filters=nil;self.dimming.hidden=YES;self.effectStatus=@"窗口合成接口不可用；区域模糊已关闭";}
    } @catch(NSException *e) {
        NSLog(@"私有窗口合成不可用: %@",e.name);
        self.backdrop.filters=nil;self.dimming.hidden=YES;self.effectStatus=@"窗口合成接口不可用；区域模糊已关闭";
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
        CGImageRef image=Mask(size.width,size.height);
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
