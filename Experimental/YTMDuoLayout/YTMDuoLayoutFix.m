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
static const void *kDuoAppliedShiftKey=&kDuoAppliedShiftKey;
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


// v10 - exact view types and frames verified from the Duo's portrait and
// landscape JSON diagnostics (669x951 / 951x669, 82pt top safe area).
// The portrait YTMMiniPlayerView was ALREADY a correct 64pt strip.
// The oversized overlapping view was its YTMWatchView sibling,
// YTMPlayerTabView (y=678, height=805). Never resize the native miniplayer.

static const void *kHeaderOriginalTransformKey = &kHeaderOriginalTransformKey;
static const void *kQueueHiddenByUsKey = &kQueueHiddenByUsKey;
static const void *kGlassDockKey = &kGlassDockKey;
static const void *kGlassContainerKey = &kGlassContainerKey;
static const void *kGlassHairlineKey = &kGlassHairlineKey;
static const void *kGlassSelectionKey = &kGlassSelectionKey;

typedef struct {
    __unsafe_unretained UIView *nav;
    __unsafe_unretained UIView *mini;
    __unsafe_unretained UIView *queue;
    __unsafe_unretained UIView *pivot;
    __unsafe_unretained UIView *items[6];
    NSUInteger itemCount;
} YTMDuoViews;

static BOOL ytmVisibleInWindow(UIView *v, UIWindow *w) {
    if(!v || v.window!=w)return NO;
    for(UIView *p=v;p;p=p.superview)
        if(p.hidden || p.alpha<0.05f)return NO;
    CGRect rect=[v convertRect:v.bounds toView:w];
    return rect.size.width>12 && rect.size.height>12 &&
           CGRectIntersectsRect(rect,w.bounds);
}
static void ytmFindExactViews(UIView *v,YTMDuoViews *out,
                              NSUInteger *budget,int depth) {
    if(!v || depth>32 || (*budget)++>10000)return;
    NSString *cls=NSStringFromClass(v.class);
    if([cls isEqualToString:@"YTMNavigationBarView"])out->nav=v;
    else if([cls isEqualToString:@"YTMMiniPlayerView"])out->mini=v;
    else if([cls isEqualToString:@"YTMPlayerTabView"])out->queue=v;
    else if([cls isEqualToString:@"YTPivotBarView"])out->pivot=v;
    else if([cls isEqualToString:@"YTPivotBarItemView"] &&
            out->itemCount<6)out->items[out->itemCount++]=v;
    for(UIView *child in v.subviews)
        ytmFindExactViews(child,out,budget,depth+1);
}
static void ytmSetHeaderTranslation(UIView *button, CGFloat dx) {
    if(!button)return;
    NSValue *saved=objc_getAssociatedObject(button,kHeaderOriginalTransformKey);
    if(!saved){
        saved=[NSValue valueWithCGAffineTransform:button.transform];
        objc_setAssociatedObject(button,kHeaderOriginalTransformKey,saved,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    CGAffineTransform base=saved.CGAffineTransformValue;
    CGAffineTransform updated=CGAffineTransformTranslate(base,dx,0);
    if(!CGAffineTransformEqualToTransform(button.transform,updated))
        button.transform=updated;
}
static void ytmRestoreHeader(UIView *nav) {
    for(UIView *button in nav.subviews){
        NSValue *saved=objc_getAssociatedObject(button,kHeaderOriginalTransformKey);
        if(saved && !CGAffineTransformEqualToTransform(
                        button.transform,saved.CGAffineTransformValue))
            button.transform=saved.CGAffineTransformValue;
    }
}
static void ytmFixHeaderButtons(UIView *nav,UIWindow *w,BOOL home) {
    if(!nav || !w)return;
    UIView *profile=nil,*activity=nil;
    // Exact classes obtained from the portrait/landscape diagnostic snapshots.
    // Portrait: profile QTMButton x621, bell YTMNavbarActivityButton x573.
    // Landscape: profile x903, bell x855.
    for(UIView *v in nav.subviews) {
        NSString *cls=NSStringFromClass(v.class);
        if([cls isEqualToString:@"QTMButton"] && v.bounds.size.width>=25)
            profile=v;
        else if([cls isEqualToString:@"YTMNavbarActivityButton"])
            activity=v;
    }
    if(!profile||!activity)return;
    CGFloat navW=nav.bounds.size.width;
    if(navW<550 || navW>1200)return;
    // Apply to BOTH the frames and the native hit rectangles. Previously
    // changing only UIView.transform could be undone by YTM layout.
    // 124pt frees room for the Duo's right-side system-status orb.
    CGFloat offset=home ? 124.0f : 0.0f;
    CGRect pf=profile.frame, af=activity.frame;
    CGFloat profileX=navW-48.0f-offset;
    CGFloat activityX=navW-96.0f-offset;
    if(fabs(pf.origin.x-profileX)>0.3) {
        pf.origin.x=profileX;
        profile.frame=pf;
    }
    if(fabs(af.origin.x-activityX)>0.3) {
        af.origin.x=activityX;
        activity.frame=af;
    }
}
// YTMNavigationBarView's own layout frequently resets children AFTER our
// polling fix. Run the precise adjustment immediately after each native
// layout pass as well. The periodic tick is a redundant fallback.
static void (*oldYTMNavigationLayout)(id,SEL);
static void ytmNavigationLayout(id self,SEL cmd) {
    if(oldYTMNavigationLayout)oldYTMNavigationLayout(self,cmd);
    UIView *nav=(UIView *)self;
    UIWindow *w=nav.window;
    if(!DuoIsFoldable(w))return;
    UIView *root=w.rootViewController.viewIfLoaded;
    if(!root)return;
    YTMDuoViews views={0};
    NSUInteger budget=0;
    ytmFindExactViews(root,&views,&budget,0);
    BOOL home=(views.nav==nav && ytmVisibleInWindow(views.pivot,w));
    ytmFixHeaderButtons(nav,w,home);
}
static void ytmFixQueueOverlay(UIView *tab,BOOL home,UIView *mini,UIWindow *w) {
    if(!tab)return;
    NSNumber *patched=objc_getAssociatedObject(tab,kQueueHiddenByUsKey);
    if(!home || !ytmVisibleInWindow(mini,w)) {
        if(patched.boolValue){
            tab.hidden=NO;
            objc_setAssociatedObject(tab,kQueueHiddenByUsKey,nil,
                                     OBJC_ASSOCIATION_ASSIGN);
        }
        return;
    }
    CGRect r=[tab convertRect:tab.bounds toView:w];
    CGRect m=[mini convertRect:mini.bounds toView:w];
    // Restrict to the exact bad state in the supplied portrait log:
    // YTMPlayerTabView y678 height805 covers the real 64pt mini at y805.
    BOOL oversizedPortrait=DuoPortrait(w) &&
        r.size.width>w.bounds.size.width*0.94 &&
        r.size.height>w.bounds.size.height*0.55 &&
        r.origin.y>w.bounds.size.height*0.5 &&
        r.origin.y<w.bounds.size.height*0.85 &&
        m.size.height>=50 && m.size.height<=80 &&
        m.origin.y>w.bounds.size.height*.70;
    if(oversizedPortrait && !tab.hidden){
        tab.hidden=YES; // do NOT modify native mini or home layout constraints
        objc_setAssociatedObject(tab,kQueueHiddenByUsKey,@YES,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        NSLog(@"[YTMDuoFix] hidden oversized portrait YTMPlayerTabView while home mini visible");
    }
}
static UIVisualEffect *ytmGlassMaterial(void){
    if(@available(iOS 26.0,*)){
        Class cls=NSClassFromString(@"UIGlassEffect");
        SEL sel=NSSelectorFromString(@"effectWithStyle:");
        if(cls && [cls respondsToSelector:sel]){
            id effect=((id(*)(id,SEL,NSInteger))objc_msgSend)(cls,sel,0);
            if([effect isKindOfClass:UIVisualEffect.class]) {
                // Native Liquid Glass must be STATIC here. YTM already
                // handles tab gestures; a second interactive glass layer
                // was producing an oversized expanding press halo.
                SEL interactive=NSSelectorFromString(@"setInteractive:");
                if([effect respondsToSelector:interactive])
                    ((void(*)(id,SEL,BOOL))objc_msgSend)(effect,interactive,NO);
                SEL tint=NSSelectorFromString(@"setTintColor:");
                if([effect respondsToSelector:tint])
                    ((void(*)(id,SEL,id))objc_msgSend)(effect,tint,
                      [UIColor.blackColor colorWithAlphaComponent:0.13f]);
                return effect;
            }
        }
    }
    return [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThinMaterialDark];
}
static UIView *ytmTabItemContainer(YTMDuoViews *views,UIView *pivot){
    // All five actual tab views share a single UIView parent (JSON depth 5).
    UIView *container=views->itemCount?views->items[0].superview:nil;
    if(!container || ![container isDescendantOfView:pivot])return nil;
    NSUInteger count=0;
    for(NSUInteger i=0;i<views->itemCount;i++){
        UIView *v=views->items[i];
        if(!v.hidden && v.superview==container && v.bounds.size.width>30)
            count++;
    }
    return count==5?container:nil;
}
// Material Components' ink effect can scale far beyond a 47pt tab and
// visually resembles a huge circle when mixed with Liquid Glass.
// Remove only the decorative ink; leave native tab controls untouched.
static void ytmDisablePivotInk(UIView *view,int depth){
    if(!view || depth>9)return;
    NSString *cls=NSStringFromClass(view.class);
    if([cls containsString:@"MDCInkView"]){
        view.hidden=YES;
        view.alpha=0;
        return;
    }
    for(UIView *sub in view.subviews)ytmDisablePivotInk(sub,depth+1);
}
static BOOL ytmTabSelected(UIView *item){
    if((item.accessibilityTraits & UIAccessibilityTraitSelected)!=0)return YES;
    SEL selected=NSSelectorFromString(@"isSelected");
    if([item respondsToSelector:selected])
        return ((BOOL(*)(id,SEL))objc_msgSend)(item,selected);
    return NO;
}
static void ytmFixGlassDock(YTMDuoViews *views,UIWindow *w,BOOL home){
    UIView *pivot=views->pivot;
    if(!pivot)return;
    UIVisualEffectView *glass=objc_getAssociatedObject(pivot,kGlassDockKey);
    UIView *container=objc_getAssociatedObject(pivot,kGlassContainerKey);
    if(!home || !ytmVisibleInWindow(pivot,w)){
        if(glass)glass.hidden=YES;
        return;
    }
    UIView *target=ytmTabItemContainer(views,pivot);
    if(!target)return;
    if(!glass || container!=target){
        [glass removeFromSuperview];
        glass=[[UIVisualEffectView alloc]initWithEffect:ytmGlassMaterial()];
        glass.userInteractionEnabled=NO;
        glass.clipsToBounds=YES;
        glass.layer.cornerCurve=kCACornerCurveContinuous;
        glass.layer.borderWidth=0.65f;
        glass.layer.borderColor=[UIColor.whiteColor colorWithAlphaComponent:0.23].CGColor;
        [target insertSubview:glass atIndex:0]; // native tap controls on top
        objc_setAssociatedObject(pivot,kGlassDockKey,glass,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(pivot,kGlassContainerKey,target,
                                 OBJC_ASSOCIATION_ASSIGN);
        CALayer *line=[CALayer layer];
        line.backgroundColor=[UIColor.whiteColor colorWithAlphaComponent:0.14].CGColor;
        [glass.layer addSublayer:line];
        objc_setAssociatedObject(pivot,kGlassHairlineKey,line,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        UIView *selection=[[UIView alloc]initWithFrame:CGRectZero];
        selection.userInteractionEnabled=NO;
        selection.backgroundColor=[UIColor.whiteColor colorWithAlphaComponent:0.085];
        selection.layer.cornerCurve=kCACornerCurveContinuous;
        selection.layer.borderColor=[UIColor.whiteColor colorWithAlphaComponent:0.07].CGColor;
        selection.layer.borderWidth=0.55;
        selection.hidden=YES;
        [glass.contentView addSubview:selection];
        objc_setAssociatedObject(pivot,kGlassSelectionKey,selection,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    CGFloat minX=CGFLOAT_MAX,maxX=-CGFLOAT_MAX;
    CGFloat minY=CGFLOAT_MAX,maxY=-CGFLOAT_MAX;
    UIView *activeTab=nil;
    for(NSUInteger i=0;i<views->itemCount;i++){
        UIView *tab=views->items[i];
        if(tab.hidden || tab.superview!=target || tab.bounds.size.width<30)continue;
        CGRect r=[tab convertRect:tab.bounds toView:target];
        minX=MIN(minX,CGRectGetMinX(r)); maxX=MAX(maxX,CGRectGetMaxX(r));
        minY=MIN(minY,CGRectGetMinY(r)); maxY=MAX(maxY,CGRectGetMaxY(r));
        if(ytmTabSelected(tab))activeTab=tab;
        ytmDisablePivotInk(tab,0);
    }
    if(minX==CGFLOAT_MAX)return;
    // The entire native tab strip is 82pt, items are 47pt. One 52pt
    // capsule behind the items is sufficient. Do not create five pills.
    CGRect frame=CGRectMake(minX+10,MAX(2,minY+1),
                            MAX(80,maxX-minX-20),52.0f);
    glass.frame=frame;
    glass.layer.cornerRadius=26.0f;
    CALayer *line=objc_getAssociatedObject(pivot,kGlassHairlineKey);
    line.frame=CGRectMake(19,0.8,MAX(0,frame.size.width-38),0.6);
    glass.hidden=NO;
    [target sendSubviewToBack:glass];
    // Clip any remaining native ink-scale animations to the tab region.
    target.clipsToBounds=YES;
    pivot.clipsToBounds=YES;
    UIView *selection=objc_getAssociatedObject(pivot,kGlassSelectionKey);
    if(activeTab && selection){
        CGRect r=[activeTab convertRect:activeTab.bounds toView:target];
        CGFloat x=CGRectGetMidX(r)-CGRectGetMinX(frame)-r.size.width*0.39f;
        CGFloat width=r.size.width*0.78f;
        x=MAX(6,MIN(x,frame.size.width-width-6));
        CGRect chosen=CGRectMake(x,4.2,width,frame.size.height-8.4f);
        if(!CGRectEqualToRect(selection.frame,chosen))
            [UIView animateWithDuration:0.17 animations:^{
                selection.frame=chosen;
                selection.layer.cornerRadius=chosen.size.height/2;
            }];
        selection.hidden=NO;
    }else if(selection){
        selection.hidden=YES;
    }
}
static void duoV10Tick(NSTimer *timer){
    (void)timer;
    if(gDuoTickInProgress)return;
    gDuoTickInProgress=YES;
    @try{
        for(UIWindow *w in UIApplication.sharedApplication.windows){
            if(!DuoIsFoldable(w)||w.hidden ||
               w.windowLevel!=UIWindowLevelNormal)continue;
            UIView *root=w.rootViewController.viewIfLoaded;
            if(!root)continue;
            YTMDuoViews views={0};
            NSUInteger budget=0;
            ytmFindExactViews(root,&views,&budget,0);
            // Genuine home screen = visible YTPivotBarView at the bottom.
            BOOL home=ytmVisibleInWindow(views.pivot,w);
            ytmFixHeaderButtons(views.nav,w,home);
            ytmFixQueueOverlay(views.queue,home,views.mini,w);
            ytmFixGlassDock(&views,w,home);
        }
    }@catch(NSException *e){
        NSLog(@"[YTMDuoFix] v10 nonfatal layout exception %@",e.reason);
    }
    gDuoTickInProgress=NO;
}
__attribute__((constructor))static void duoBootstrap(void){
    @autoreleasepool{
        if(![NSBundle.mainBundle.bundleIdentifier
             isEqualToString:@"com.google.ios.youtubemusic"])return;
        // Preserve the tested "only manual fullscreen" behavior.
        swizzleSpecific(UIWindow.class,@selector(sendEvent:),
                        (IMP)duoWindowSendEvent,(IMP *)&oldWindowEvent);
        swizzleSpecific(UIApplication.class,
                        @selector(sendAction:to:from:forEvent:),
                        (IMP)duoSendAction,(IMP *)&oldSendAction);
        swizzleSpecific(UIViewController.class,
                        @selector(presentViewController:animated:completion:),
                        (IMP)duoPresentVC,(IMP *)&oldPresent);
        swizzleSpecific(NSClassFromString(@"YTMWatchViewController"),
                        @selector(presentFullScreenPlayer),
                        (IMP)duoWatchPresentFull,(IMP *)&oldWatchFull);
        swizzleSpecific(NSClassFromString(@"YTPlayerViewController"),
                        @selector(presentFullScreenPlayer),
                        (IMP)duoPlayerPresentFull,(IMP *)&oldPlayerFull);
        swizzleSpecific(NSClassFromString(@"YTPlayerViewController"),
                        @selector(toggleFullscreen),
                        (IMP)duoPlayerToggle,(IMP *)&oldPlayerToggle);
        dispatch_async(dispatch_get_main_queue(),^{
            gLayoutTimer=[NSTimer scheduledTimerWithTimeInterval:0.45
                repeats:YES block:^(NSTimer *t){duoV10Tick(t);}];
            [[NSRunLoop mainRunLoop] addTimer:gLayoutTimer
                                     forMode:NSRunLoopCommonModes];
        });
        NSLog(@"[YTMDuoFix] v10 exact-view 669x951 / 951x669 targeted patch loaded");
    }
}
