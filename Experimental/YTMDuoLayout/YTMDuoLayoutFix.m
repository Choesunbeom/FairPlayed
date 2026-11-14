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

// V8 intentionally uses actual UIWindow point geometry, not screenshot
// pixel values or brittle private player-class names.
// Home controls are discovered directly; no dependency on a pivot class.
//
// Original audio module and the successful fullscreen guard above untouched.
static const void *kDuoV8OriginalTransform=&kDuoV8OriginalTransform;
static const void *kDuoV8AppliedOffset=&kDuoV8AppliedOffset;
static const void *kDuoV8Glass=&kDuoV8Glass;
static const void *kDuoV8GlassEffect=&kDuoV8GlassEffect;
static const void *kDuoV8GlassIndicator=&kDuoV8GlassIndicator;


// Safe recovery v9: no layout resizing, no extra overlay above the five
// native tab controls and no guessing at avatar positions. Retains the
// successful manual fullscreen guard from the earlier module.
//
// This diagnostic records only view class, geometry and structural metadata.
// It does NOT read titles, music, account details or private content.
static NSUInteger gDuoSnapshotCount = 0;
static NSUInteger gDuoLastWindowWidth=0, gDuoLastWindowHeight=0;
static NSUInteger gDuoSnapshotIndex=0;

static BOOL duoContains(NSString *s,NSString *needle) {
    return [s rangeOfString:needle options:NSCaseInsensitiveSearch].location!=NSNotFound;
}
static CGRect duoFrameInWindow(UIView *view,UIWindow *window) {
    if(!view || !window || view.window!=window)return CGRectNull;
    return [view convertRect:view.bounds toView:window];
}
static NSDictionary *duoRectDict(CGRect rect) {
    if(CGRectIsNull(rect) || CGRectIsInfinite(rect))return @{@"invalid":@YES};
    return @{@"x":@(round(rect.origin.x*10)/10.0),
             @"y":@(round(rect.origin.y*10)/10.0),
             @"w":@(round(rect.size.width*10)/10.0),
             @"h":@(round(rect.size.height*10)/10.0)};
}
static BOOL duoVisible(UIView *view) {
    for(UIView *p=view;p;p=p.superview)if(p.hidden||p.alpha<0.05)return NO;
    return YES;
}
static BOOL duoIsTarget(UIView *view,UIWindow *w,CGRect r){
    NSString *cls=NSStringFromClass(view.class);
    BOOL keyclass=duoContains(cls,@"Pivot") ||
                  duoContains(cls,@"Miniplayer") ||
                  duoContains(cls,@"MiniPlayer") ||
                  duoContains(cls,@"Avatar") ||
                  duoContains(cls,@"NavigationBar") ||
                  duoContains(cls,@"Notification") ||
                  duoContains(cls,@"Queue") ||
                  duoContains(cls,@"WatchView") ||
                  duoContains(cls,@"YTMPlayer");
    if(keyclass)return YES;
    if(CGRectIsNull(r))return NO;
    CGFloat width=w.bounds.size.width,height=w.bounds.size.height;
    BOOL inHeader=r.origin.y>=-50 && CGRectGetMidY(r)<110 &&
                  CGRectGetMidX(r)>width*0.62;
    BOOL inBottom=r.origin.y>height-240 && r.size.width>width*.72 &&
                  r.size.height>32 && r.size.height<260;
    BOOL isControl=[view isKindOfClass:UIControl.class] ||
                   duoContains(cls,@"Button");
    if(inHeader && isControl)return YES;
    if(inBottom && (r.size.height>56 || isControl))return YES;
    if([view isKindOfClass:UILabel.class]){
        NSString *value=((UILabel*)view).text?:@"";
        // Detect only the known queue heading. Do not save the text itself.
        if([value containsString:@"현재 재생목록"] ||
           [value localizedCaseInsensitiveContainsString:@"current queue"] ||
           [value localizedCaseInsensitiveContainsString:@"current playlist"])
           return YES;
    }
    return NO;
}
static void duoWalk(UIView *view,UIWindow *w,NSString *parent,
                    NSMutableArray<NSDictionary *> *items,
                    NSUInteger *budget,int depth){
    if(!view || depth>38 || (*budget)++>16000 || items.count>=350)return;
    NSString *cls=NSStringFromClass(view.class);
    CGRect r=duoFrameInWindow(view,w);
    if(duoIsTarget(view,w,r)){
        BOOL isQueueTitle=NO;
        if([view isKindOfClass:UILabel.class]){
            NSString *value=((UILabel*)view).text?:@"";
            isQueueTitle=[value containsString:@"현재 재생목록"] ||
                [value localizedCaseInsensitiveContainsString:@"current queue"] ||
                [value localizedCaseInsensitiveContainsString:@"current playlist"];
        }
        [items addObject:@{
           @"class":cls,
           @"parent":parent?:@"",
           @"frame":duoRectDict(r),
           @"hidden":@(view.hidden),
           @"visible":@(duoVisible(view)),
           @"alpha":@(round(view.alpha*100)/100.0),
           @"interactive":@(view.userInteractionEnabled),
           @"sublayers":@(view.layer.sublayers.count),
           @"children":@(view.subviews.count),
           @"queueHeading":@(isQueueTitle),
           @"depth":@(depth)
        }];
    }
    for(UIView *child in view.subviews){
        if(items.count>=350||*budget>16000)break;
        duoWalk(child,w,cls,items,budget,depth+1);
    }
}
static void duoWriteDiagnostics(void){
    UIApplication *app=UIApplication.sharedApplication;
    if(app.applicationState!=UIApplicationStateActive)return;
    NSMutableArray<NSDictionary *> *views=[NSMutableArray array];
    NSMutableArray<NSDictionary *> *windows=[NSMutableArray array];
    NSUInteger budget=0;
    for(UIWindow *w in app.windows){
        if(w.hidden || !w.rootViewController ||
           w.windowLevel!=UIWindowLevelNormal)continue;
        CGSize sz=w.bounds.size;
        if(sz.width<300||sz.height<300)continue;
        UIEdgeInsets inset=w.safeAreaInsets;
        [windows addObject:@{
          @"bounds":duoRectDict(w.bounds),
          @"safeArea":@{@"top":@(inset.top),@"left":@(inset.left),
                         @"right":@(inset.right),@"bottom":@(inset.bottom)},
          @"rootClass":NSStringFromClass(w.rootViewController.class),
          @"windowLevel":@(w.windowLevel)
        }];
        // Include window-level siblings. Navigation may not be in root.view.
        for(UIView *child in w.subviews)
            duoWalk(child,w,NSStringFromClass(w.class),views,&budget,0);
    }
    if(windows.count==0)return;
    NSUInteger portraitCount=0,landscapeCount=0,queueTitles=0;
    for(NSDictionary *window in windows){
        NSDictionary *rect=window[@"bounds"];
        if([rect[@"h"]doubleValue]>[rect[@"w"]doubleValue])portraitCount++;
        else landscapeCount++;
    }
    for(NSDictionary *view in views)if([view[@"queueHeading"]boolValue])queueTitles++;
    NSDictionary *record=@{
      @"purpose":@"YTM Duo 9.44.2 structural layout diagnostics",
      @"privacy":@"No song/account titles or user identifiers included",
      @"capturedAt":[[NSDate date]description],
      @"snapshot":@(++gDuoSnapshotIndex),
      @"windows":windows,
      @"views":views,
      @"matchedQueueHeadings":@(queueTitles),
      @"portraitWindows":@(portraitCount),
      @"landscapeWindows":@(landscapeCount),
      @"visitedViews":@(budget)
    };
    NSError *jsonError=nil;
    NSData *json=[NSJSONSerialization dataWithJSONObject:record
                     options:NSJSONWritingPrettyPrinted error:&jsonError];
    if(!json)return;
    NSURL *docs=[[NSFileManager defaultManager]
                 URLsForDirectory:NSDocumentDirectory
                 inDomains:NSUserDomainMask].firstObject;
    if(!docs)return;
    // Save one file per orientation, plus a latest snapshot. Accessible in
    // Files > On My iPhone > YouTube Music when UIFileSharingEnabled is true.
    NSString *filename=portraitCount>landscapeCount
       ? @"YTMDuo_portrait_layout.json" : @"YTMDuo_landscape_layout.json";
    [json writeToURL:[docs URLByAppendingPathComponent:filename] atomically:YES];
    [json writeToURL:[docs URLByAppendingPathComponent:@"YTMDuo_latest_layout.json"]
            atomically:YES];
    static BOOL notified=NO;
    if(!notified){
        NSLog(@"[YTMDuoFix] v9 safely restored; layout snapshots in Documents");
        notified=YES;
    }
}
static void duoV9SnapshotTimer(NSTimer *timer){
    (void)timer;
    duoWriteDiagnostics();
}
__attribute__((constructor))static void duoBootstrap(void){
    @autoreleasepool{
        if(![NSBundle.mainBundle.bundleIdentifier
             isEqualToString:@"com.google.ios.youtubemusic"])return;
        // This part fixed automatic fullscreen in prior tested builds.
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
            gLayoutTimer=[NSTimer scheduledTimerWithTimeInterval:4.0
                     repeats:YES block:^(NSTimer *t){duoV9SnapshotTimer(t);}];
            [[NSRunLoop mainRunLoop] addTimer:gLayoutTimer
                                 forMode:NSRunLoopCommonModes];
        });
        NSLog(@"[YTMDuoFix] v9 safe rollback, no layout/volume hooks");
    }
}
