#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <math.h>

// YTMUltimate 9.44.2 / original Duo IPA (build with iOS SDK 27.1).
// This dylib is a UI-only patch. It deliberately never touches AVAudioSession,
// AVPlayer, AVAudioEngine, or the known-good YTMDualVolume dylib.

static const void *kDuoGlassKey=&kDuoGlassKey;
static const void *kDuoShiftKey=&kDuoShiftKey;
static CFTimeInterval gExplicitFullScreenUntil=0;
static BOOL gDuoTickInProgress=NO;
static void (*oldWindowEvent)(id,SEL,UIEvent *);
static BOOL (*oldSendAction)(id,SEL,SEL,id,id,UIEvent *);
static void (*oldPresent)(id,SEL,UIViewController *,BOOL,void(^)(void));
static void (*oldWatchFull)(id,SEL);
static void (*oldPlayerFull)(id,SEL);
static void (*oldPlayerToggle)(id,SEL);
static NSTimer *gLayoutTimer;

static BOOL DuoRecognizedWindow(UIWindow *w) {
    if(!w || !w.rootViewController) return NO;
    CGSize sz=w.bounds.size;
    return sz.width>320 && sz.height>320 && sz.width<1250 && sz.height<1250;
}
static BOOL DuoIsFoldable(UIWindow *w) {
    if(!DuoRecognizedWindow(w))return NO;
    CGSize s=w.bounds.size;
    // The unfolded Duo has a squarer viewport than a conventional iPhone.
    CGFloat ratio=MAX(s.width,s.height)/MAX(1,MIN(s.width,s.height));
    return ratio<1.83;
}
static BOOL DuoPortrait(UIWindow *w) {return w && w.bounds.size.height>w.bounds.size.width;}
static BOOL DuoHasFullscreenHint(NSString *value) {
    if(![value isKindOfClass:NSString.class])return NO;
    NSString *s=value.lowercaseString;
    return [s containsString:@"fullscreen"]||[s containsString:@"full.screen"]||
           [s containsString:@"full_screen"]||[s containsString:@"전체화면"]||
           [s containsString:@"전체 화면"]||[s containsString:@"전체화면"];
}
static BOOL DuoEventIsFullscreenTap(UIView *view) {
    for(UIView *v=view;v;v=v.superview) {
        if(DuoHasFullscreenHint(v.accessibilityIdentifier)||
           DuoHasFullscreenHint(v.accessibilityLabel))return YES;
    }
    return NO;
}
static void DuoAllowFullscreen(void) {
    gExplicitFullScreenUntil=CACurrentMediaTime()+3.0;
}
static BOOL DuoFullscreenAllowed(void){
    return CACurrentMediaTime()<=gExplicitFullScreenUntil;
}
static void duoWindowSendEvent(id self,SEL cmd,UIEvent *event){
    if(event.type==UIEventTypeTouches) {
        for(UITouch *t in event.allTouches) {
            if(t.phase!=UITouchPhaseEnded)continue;
            UIWindow *w=t.window;
            if(!DuoIsFoldable(w))continue;
            CGPoint p=[t locationInView:w];
            BOOL bottomRight=p.x>=w.bounds.size.width-85 &&
                             p.y>=w.bounds.size.height-110;
            if(DuoEventIsFullscreenTap(t.view)||bottomRight) {
                DuoAllowFullscreen();
            }
        }
    }
    if(oldWindowEvent)oldWindowEvent(self,cmd,event);
}
static BOOL duoSendAction(id self,SEL cmd,SEL action,id target,id sender,UIEvent *event){
    NSString *name=NSStringFromSelector(action);
    if(DuoHasFullscreenHint(name))DuoAllowFullscreen();
    if([sender isKindOfClass:UIView.class]&&DuoEventIsFullscreenTap(sender))
        DuoAllowFullscreen();
    return oldSendAction?oldSendAction(self,cmd,action,target,sender,event):NO;
}
static BOOL isProtectedFullscreen(UIViewController *vc){
    if(!vc)return NO;
    NSString *name=NSStringFromClass(vc.class);
    return [name isEqualToString:@"YTMFullscreenVideoViewController"]||
           [name isEqualToString:@"YTFullScreenOverlayViewController"]||
           [name isEqualToString:@"YTFullscreenVideoViewController"];
}
static void duoPresentVC(id self, SEL cmd, UIViewController *vc, BOOL animated,
                         void (^completion)(void)) {
    UIWindow *window=((UIViewController *)self).viewIfLoaded.window;
    // Suppress unwanted AUTO modal fullscreen (e.g. Duo geometry changes).
    // Manual fullscreen tap remains allowed for three seconds.
    if(DuoIsFoldable(window)&&isProtectedFullscreen(vc)&&!DuoFullscreenAllowed()) {
        NSLog(@"[YTMDuoFix] skipped automatic fullscreen presentation: %@",NSStringFromClass(vc.class));
        if(completion)completion();
        return;
    }
    if(oldPresent)oldPresent(self,cmd,vc,animated,completion);
}
static void duoWatchPresentFull(id self,SEL cmd) {
    UIViewController *vc=(UIViewController *)self;
    if(DuoIsFoldable(vc.viewIfLoaded.window)&&!DuoFullscreenAllowed()) {
        NSLog(@"[YTMDuoFix] ignored unsolicited presentFullScreenPlayer");
        return;
    }
    if(oldWatchFull)oldWatchFull(self,cmd);
}
static void duoPlayerPresentFull(id self,SEL cmd) {
    UIViewController *vc=(UIViewController *)self;
    if(DuoIsFoldable(vc.viewIfLoaded.window)&&!DuoFullscreenAllowed())return;
    if(oldPlayerFull)oldPlayerFull(self,cmd);
}
static void duoPlayerToggle(id self,SEL cmd) {
    UIViewController *vc=(UIViewController *)self;
    if(DuoIsFoldable(vc.viewIfLoaded.window)&&!DuoFullscreenAllowed())return;
    if(oldPlayerToggle)oldPlayerToggle(self,cmd);
}

static void swizzleSpecific(Class cls,SEL sel,IMP newImp,IMP *oldImp) {
    if(!cls)return;
    Method m=class_getInstanceMethod(cls,sel);
    if(!m)return;
    IMP existing=method_getImplementation(m);
    if(class_addMethod(cls,sel,newImp,method_getTypeEncoding(m)))
        *oldImp=existing;
    else *oldImp=method_setImplementation(m,newImp);
    NSLog(@"[YTMDuoFix] hooked %@ %@",NSStringFromClass(cls),NSStringFromSelector(sel));
}
static BOOL viewVisible(UIView *v,UIWindow *w){
    if(!v||!w||!v.window)return NO;
    for(UIView *n=v;n;n=n.superview)if(n.hidden||n.alpha<0.1)return NO;
    CGRect r=[v convertRect:v.bounds toView:w];
    return r.size.width>12&&r.size.height>8&&CGRectIntersectsRect(r,w.bounds);
}
static void collectViewTypes(UIView *v,NSMutableArray *headers,
                             NSMutableArray *pivots,NSMutableArray *minis,
                             NSUInteger *budget){
    if(!v||(*budget)++>4000)return;
    NSString *n=NSStringFromClass(v.class);
    if([n isEqualToString:@"YTMNavigationBarView"]) [headers addObject:v];
    if([n isEqualToString:@"YTPivotBarView"]||[n isEqualToString:@"YTFloatingPivotBarView"])
        [pivots addObject:v];
    if([n isEqualToString:@"YTMMiniPlayerView"]||
       [n isEqualToString:@"YTMOfflineMiniPlayerView"]) [minis addObject:v];
    for(UIView *child in v.subviews){
        if(*budget>4000)break;
        collectViewTypes(child,headers,pivots,minis,budget);
    }
}

static void findButtons(UIView *root,NSMutableArray<UIView *> *buttons,int depth) {
    if(!root||depth>16)return;
    NSString *name=NSStringFromClass(root.class);
    BOOL candidate=[root isKindOfClass:UIControl.class] ||
                   [name containsString:@"Account"] ||
                   [name containsString:@"Avatar"] ||
                   [name containsString:@"Notification"] ||
                   [name containsString:@"Bell"] ||
                   [name containsString:@"Button"];
    if(candidate) [buttons addObject:root];
    for(UIView *sub in root.subviews)findButtons(sub,buttons,depth+1);
}
static void duoShift(UIView *v,CGFloat translation){
    if(!v)return;
    // Store original transform on first application, not a repeated delta.
    NSValue *original=objc_getAssociatedObject(v,kDuoShiftKey);
    if(!original){
        original=[NSValue valueWithCGAffineTransform:v.transform];
        objc_setAssociatedObject(v,kDuoShiftKey,original,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    CGAffineTransform base=original.CGAffineTransformValue;
    CGAffineTransform intended=CGAffineTransformTranslate(base,translation,0);
    if(!CGAffineTransformEqualToTransform(v.transform,intended))v.transform=intended;
}
static void fixHeader(UIView *header,UIWindow *w){
    if(!viewVisible(header,w))return;
    NSMutableArray *buttons=[NSMutableArray array];
    findButtons(header,buttons,0);
    UIView *account=nil,*notify=nil;
    CGFloat maxX=-CGFLOAT_MAX;
    for(UIView *button in buttons){
        if(!viewVisible(button,w))continue;
        CGRect r=[button convertRect:button.bounds toView:w];
        if(r.origin.y>110||CGRectGetMidX(r)<w.bounds.size.width*0.55)continue;
        NSString *name=NSStringFromClass(button.class);
        NSString *aid=button.accessibilityIdentifier.lowercaseString?:@"";
        NSString *label=button.accessibilityLabel.lowercaseString?:@"";
        if([name containsString:@"AccountButton"]||
           [aid containsString:@"account"]||[aid containsString:@"avatar"]||
           [label containsString:@"계정"]||[label containsString:@"프로필"]) {
            if(CGRectGetMidX(r)>maxX){maxX=CGRectGetMidX(r);account=button;}
        }
        if([aid containsString:@"notification"]||[aid containsString:@"bell"]||
           [label containsString:@"notification"]||[label containsString:@"알림"]||
           [name containsString:@"NotificationButton"])notify=button;
    }
    if(!account){
        // YTM builds in which the account avatar is hosted by a generic
        // QTMButton: pick the rightmost button in the top home header.
        for(UIView *button in buttons){
            if(!viewVisible(button,w))continue;
            CGRect r=[button convertRect:button.bounds toView:w];
            if(r.origin.y<112 && CGRectGetMidX(r)>maxX &&
               CGRectGetMidX(r)>w.bounds.size.width*0.72 &&
               r.size.width<85) { maxX=CGRectGetMidX(r);account=button; }
        }
    }
    if(!account)return;
    CGRect ar=[account convertRect:account.bounds toView:w];
    if(!notify){
        CGFloat best=CGFLOAT_MAX;
        for(UIView *button in buttons){
            if(button==account||!viewVisible(button,w))continue;
            CGRect r=[button convertRect:button.bounds toView:w];
            CGFloat dx=CGRectGetMidX(ar)-CGRectGetMidX(r);
            CGFloat dy=fabs(CGRectGetMidY(ar)-CGRectGetMidY(r));
            if(dx>15 && dx<110 && dy<32 && dx<best){best=dx;notify=button;}
        }
    }
    // Keep the two right buttons left of the iPhone Duo status island.
    CGFloat pad=MIN(78,MAX(48,w.bounds.size.width*0.135));
    duoShift(account,-pad);
    if(notify&&notify!=account)duoShift(notify,-pad);
}

// UIKit SDK 27.1: UIGlassEffect is created with +effectWithStyle:,
// NOT -initWithStyle:. A real system material uses alpha == 1.
// Geometry fallback for YTM 9.44, where profile/bell controls may sit
// in a generic header view instead of YTMNavigationBarView. Select only the
// TWO rightmost interactive items in the very top row, never the filter chips.
static void fixHeaderByGeometry(UIView *root, UIWindow *w){
    if(!root||!DuoIsFoldable(w))return;
    NSMutableArray<UIView *> *buttons=[NSMutableArray array];
    findButtons(root,buttons,0);
    CGFloat width=w.bounds.size.width;
    CGFloat shift=MIN(76,MAX(56,width*0.105));
    UIView *right=nil,*second=nil;
    CGFloat rightX=-CGFLOAT_MAX,secondX=-CGFLOAT_MAX;
    CGFloat rightY=-1;
    for(UIView *button in buttons) {
        if(!viewVisible(button,w))continue;
        CGRect r=[button convertRect:button.bounds toView:w];
        if(r.size.width<19||r.size.width>85||r.size.height<18||r.size.height>83)
            continue;
        CGFloat y=CGRectGetMidY(r);
        // Bell/avatar are near the system clock; the category chips are
        // on the second row and must never be moved.
        if(y<8 || y>MIN(57,w.safeAreaInsets.top+32))continue;
        NSString *cls=NSStringFromClass(button.class);
        if([cls containsString:@"StatusBar"]||[cls containsString:@"Battery"]||
           [cls containsString:@"Wifi"]||[cls containsString:@"Signal"])continue;
        CGFloat originalX=CGRectGetMidX(r);
        if(objc_getAssociatedObject(button,kDuoShiftKey))originalX+=shift;
        if(originalX<width-145 || originalX>width+10)continue;
        if(originalX>rightX){
            second=right;secondX=rightX;
            right=button;rightX=originalX;rightY=y;
        } else if(originalX>secondX && fabs(originalX-rightX)>19 &&
                  (rightY<0 || fabs(y-rightY)<24)) {
            second=button;secondX=originalX;
        }
    }
    if(right)duoShift(right,-shift);
    if(second && second!=right &&
       fabs(rightX-secondX)>20 && fabs(rightX-secondX)<125)
        duoShift(second,-shift);
}

static UIVisualEffect *systemGlass(void){
    if(@available(iOS 26.0,*)){
        Class cls=NSClassFromString(@"UIGlassEffect");
        SEL factory=NSSelectorFromString(@"effectWithStyle:");
        if(cls && [cls respondsToSelector:factory]){
            id effect=((id(*)(id,SEL,NSInteger))objc_msgSend)(cls,factory,0);
            if([effect isKindOfClass:UIVisualEffect.class])return effect;
        }
    }
    return [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThinMaterialDark];
}
static void collectPivotItems(UIView *root,NSMutableArray<UIView *> *items,int depth){
    if(depth>10)return;
    NSString *n=NSStringFromClass(root.class);
    if([n isEqualToString:@"YTPivotBarItemView"]){
        [items addObject:root];return;
    }
    for(UIView *v in root.subviews)collectPivotItems(v,items,depth+1);
}
static UIVisualEffectView *createGlass(UIView *pivot){
    UIVisualEffectView *g=[[UIVisualEffectView alloc]initWithEffect:systemGlass()];
    g.userInteractionEnabled=NO;
    g.clipsToBounds=YES;
    g.layer.cornerRadius=19;
    if(@available(iOS 13.0,*))g.layer.cornerCurve=kCACornerCurveContinuous;
    g.alpha=1.0;
    [pivot insertSubview:g atIndex:0];
    return g;
}
static void fixPivot(UIView *pivot,UIWindow *w){
    if(!viewVisible(pivot,w))return;
    NSMutableArray<UIView *> *items=[NSMutableArray array];
    collectPivotItems(pivot,items,0);
    NSMutableArray<UIVisualEffectView *> *glasses=objc_getAssociatedObject(pivot,kDuoGlassKey);
    if(!glasses){
        glasses=[NSMutableArray array];
        objc_setAssociatedObject(pivot,kDuoGlassKey,glasses,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    NSUInteger n=items.count;
    // Only make 1..8 individual glass buttons; preserve native tap actions.
    if(n>=3&&n<=8){
        while(glasses.count<n)[glasses addObject:createGlass(pivot)];
        for(NSUInteger i=0;i<glasses.count;i++){
            UIVisualEffectView *glass=glasses[i];
            if(i>=n){glass.hidden=YES;continue;}
            UIView *item=items[i];
            CGRect rect=[item convertRect:item.bounds toView:pivot];
            if(rect.size.width<=8 || rect.size.height<=8){glass.hidden=YES;continue;}
            rect=CGRectInset(rect,5,3);
            rect.size.height=MIN(rect.size.height,51);
            glass.hidden=NO;
            glass.frame=rect;
            glass.layer.cornerRadius=MIN(21,rect.size.height/2);
            [pivot sendSubviewToBack:glass];
        }
    } else {
        if(glasses.count==0)[glasses addObject:createGlass(pivot)];
        for(NSUInteger i=0;i<glasses.count;i++){
            UIVisualEffectView *glass=glasses[i];
            glass.hidden=i!=0;
            if(i==0){
                glass.frame=CGRectInset(pivot.bounds,10,4);
                glass.layer.cornerRadius=23;
                [pivot sendSubviewToBack:glass];
            }
        }
    }
    pivot.backgroundColor=UIColor.clearColor;
    pivot.opaque=NO;
}

static void shrinkConstraintIfNeeded(UIView *v,CGFloat limit){
    for(NSLayoutConstraint *c in v.constraints){
        if(!c.active || c.relation!=NSLayoutRelationEqual)continue;
        if(c.firstAttribute!=NSLayoutAttributeHeight ||
           (c.firstItem!=v && c.secondItem!=v))continue;
        if(c.constant>limit+15 && c.constant<280)c.constant=limit;
    }
}
static void fixMiniplayer(UIView *mini,UIWindow *w){
    if(!DuoPortrait(w)||!viewVisible(mini,w))return;
    CGRect inWindow=[mini convertRect:mini.bounds toView:w];
    if(inWindow.size.width<w.bounds.size.width*.60||
       inWindow.origin.y<w.bounds.size.height*.5)return;
    // Foldable compact-portrait can incorrectly use the expanded tray size.
    // Clamp only the outlier (>90pt), never touch a correctly sized mini bar.
    CGFloat limit=66.0;
    if(mini.bounds.size.height<92 || mini.bounds.size.height>300)return;
    shrinkConstraintIfNeeded(mini,limit);
    if(mini.superview)shrinkConstraintIfNeeded(mini.superview,limit);
    CGRect f=mini.frame;
    CGFloat oldMaxY=CGRectGetMaxY(f);
    f.size.height=limit;
    f.origin.y=oldMaxY-limit;
    if(!CGRectEqualToRect(f,mini.frame)){
        mini.frame=f;
        mini.clipsToBounds=YES;
    }
}
static void duoLayoutTick(NSTimer *timer){
    (void)timer;
    if(gDuoTickInProgress)return;
    gDuoTickInProgress=YES;
    @try{
        UIApplication *app=UIApplication.sharedApplication;
        NSArray<UIWindow *> *windows=app.windows;
        for(UIWindow *w in windows){
            if(!DuoIsFoldable(w) || w.hidden)continue;
            NSMutableArray *headers=[NSMutableArray array];
            NSMutableArray *pivots=[NSMutableArray array];
            NSMutableArray *minis=[NSMutableArray array];
            NSUInteger budget=0;
            collectViewTypes(w,headers,pivots,minis,&budget);
            if(pivots.count==0)continue;
            for(UIView *v in headers)fixHeader(v,w);
            for(UIView *v in pivots)fixPivot(v,w);
            for(UIView *v in minis)fixMiniplayer(v,w);
        }
    }@catch(NSException *e){
        NSLog(@"[YTMDuoFix] nonfatal layout exception %@",e.reason);
    }
    gDuoTickInProgress=NO;
}

__attribute__((constructor))static void duoBootstrap(void) {
    @autoreleasepool {
        if(![NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.google.ios.youtubemusic"])
            return;
        swizzleSpecific(UIWindow.class,@selector(sendEvent:),(IMP)duoWindowSendEvent,
                        (IMP *)&oldWindowEvent);
        swizzleSpecific(UIApplication.class,@selector(sendAction:to:from:forEvent:),
                        (IMP)duoSendAction,(IMP *)&oldSendAction);
        swizzleSpecific(UIViewController.class,@selector(presentViewController:animated:completion:),
                        (IMP)duoPresentVC,(IMP *)&oldPresent);
        swizzleSpecific(NSClassFromString(@"YTMWatchViewController"),@selector(presentFullScreenPlayer),
                        (IMP)duoWatchPresentFull,(IMP *)&oldWatchFull);
        swizzleSpecific(NSClassFromString(@"YTPlayerViewController"),@selector(presentFullScreenPlayer),
                        (IMP)duoPlayerPresentFull,(IMP *)&oldPlayerFull);
        swizzleSpecific(NSClassFromString(@"YTPlayerViewController"),@selector(toggleFullscreen),
                        (IMP)duoPlayerToggle,(IMP *)&oldPlayerToggle);
        dispatch_async(dispatch_get_main_queue(), ^{
            gLayoutTimer=[NSTimer scheduledTimerWithTimeInterval:0.35 repeats:YES block:^(NSTimer *timer){
                duoLayoutTick(timer);
            }];
            [[NSRunLoop mainRunLoop] addTimer:gLayoutTimer forMode:NSRunLoopCommonModes];
        });
        NSLog(@"[YTMDuoFix] Duo home header/mini/glass + manual fullscreen guard installed");
    }
}
