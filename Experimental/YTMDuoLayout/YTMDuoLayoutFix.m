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
static const void *kDuoV8Glass=&kDuoV8Glass;
static const void *kDuoV8GlassEffect=&kDuoV8GlassEffect;
static const void *kDuoV8GlassIndicator=&kDuoV8GlassIndicator;

static BOOL duoOnscreen(UIView *v, UIWindow *w){
    if(!v || v.window!=w)return NO;
    for(UIView *p=v;p;p=p.superview){
        if(p.hidden || p.alpha<0.08)return NO;
    }
    CGRect r=[v convertRect:v.bounds toView:w];
    return r.size.width>=8 && r.size.height>=8 &&
           CGRectIntersectsRect(r,w.bounds);
}
static BOOL duoSystemOwned(UIView *v){
    NSString *cls=NSStringFromClass(v.class);
    return [cls containsString:@"StatusBar"] ||
           [cls containsString:@"_UIBattery"] ||
           [cls containsString:@"UIRemoteKeyboard"] ||
           [cls containsString:@"UIInputSet"];
}
static BOOL duoBottomTabs(UIView *v,UIWindow *w,NSUInteger *count,
        NSMutableArray<UIView*> *items,NSUInteger *visited,int depth){
    if(!v || depth>35 || (*visited)++>12000)return NO;
    if(duoSystemOwned(v) || v.hidden || v.alpha<0.08)return NO;
    NSString *cls=NSStringFromClass(v.class);
    BOOL matching=[cls containsString:@"PivotBarItemView"] ||
                  [cls containsString:@"PivotBarItemAccessibilityControl"];
    if(matching && duoOnscreen(v,w)){
        CGRect r=[v convertRect:v.bounds toView:w];
        if(CGRectGetMidY(r)>w.bounds.size.height-112 &&
           r.size.width>=25 && r.size.width<w.bounds.size.width*.5){
            (*count)++;
            if(items) [items addObject:v];
        }
    }
    for(UIView *sub in v.subviews)duoBottomTabs(sub,w,count,items,visited,depth+1);
    return *count>=3;
}
static BOOL duoHome(UIWindow *w,NSMutableArray<UIView*> *items){
    NSUInteger n=0,budget=0;
    UIView *root=w.rootViewController.viewIfLoaded;
    if(!root)return NO;
    duoBottomTabs(root,w,&n,items,&budget,0);
    // Several YTM variants use generic controls instead of a pivot-bar item
    // class. Use the actual home tab titles as a fallback, not coordinates
    // that could match fullscreen video playback.
    if(n<3){
        NSArray<NSString*> *names=@[@"홈",@"샘플",@"검색",@"보관함",@"다운로드"];
        NSMutableSet *found=[NSMutableSet set];
        NSMutableArray *stack=[NSMutableArray arrayWithObject:root];
        NSUInteger cap=0;
        while(stack.count && ++cap<12000){
            UIView *v=stack.lastObject;
            [stack removeLastObject];
            if(v.hidden)continue;
            if([v isKindOfClass:UILabel.class]){
                NSString *txt=((UILabel*)v).text?:@"";
                if([names containsObject:txt]){
                    CGRect r=[v convertRect:v.bounds toView:w];
                    if(CGRectGetMidY(r)>w.bounds.size.height-112)
                        [found addObject:txt];
                }
            }
            [stack addObjectsFromArray:v.subviews];
        }
        return found.count>=3;
    }
    return YES;
}
static UIView *duoTapRoot(UIView *v,UIWindow *w){
    CGRect rect=[v convertRect:v.bounds toView:w];
    UIView *best=v;
    for(UIView *p=v.superview;p && p!=w;p=p.superview){
        CGRect q=[p convertRect:p.bounds toView:w];
        if(q.size.width>110 || q.size.height>110 ||
           fabs(CGRectGetMidX(q)-CGRectGetMidX(rect))>22)break;
        if(p.userInteractionEnabled && ([p isKindOfClass:UIControl.class] ||
                                        p.gestureRecognizers.count))best=p;
    }
    return best;
}
static void duoSetOriginalOffset(UIView *v,CGFloat dx){
    if(!v)return;
    NSValue *saved=objc_getAssociatedObject(v,kDuoV8OriginalTransform);
    if(!saved){
        saved=[NSValue valueWithCGAffineTransform:v.transform];
        objc_setAssociatedObject(v,kDuoV8OriginalTransform,saved,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    CGAffineTransform original=saved.CGAffineTransformValue;
    CGAffineTransform target=CGAffineTransformTranslate(original,dx,0);
    if(!CGAffineTransformEqualToTransform(target,v.transform))v.transform=target;
}
typedef struct {
    __unsafe_unretained UIView *avatar;
    __unsafe_unretained UIView *bell;
    __unsafe_unretained UIView *fallback;
    CGFloat avatarX,bellX,fallbackX;
} DuoHeaderHits;
static void duoScanHeader(UIView *v,UIWindow *w,DuoHeaderHits *hits,
                          NSUInteger *budget,int depth){
    if(!v || depth>36 || (*budget)++>10000 || v.hidden ||
       v.alpha<0.08 || duoSystemOwned(v))return;
    CGRect r=[v convertRect:v.bounds toView:w];
    if(r.origin.y>110 || CGRectGetMaxY(r)<0)return;
    NSString *cls=NSStringFromClass(v.class);
    CGFloat mid=CGRectGetMidX(r);
    BOOL reasonable=r.size.width>=15&&r.size.width<104 &&
                    r.size.height>=15&&r.size.height<104 &&
                    mid>w.bounds.size.width*.61;
    if(reasonable && duoOnscreen(v,w)){
        BOOL avatar=[cls containsString:@"AvatarAccount"] ||
                   [cls containsString:@"AccountAvatar"] ||
                   [cls containsString:@"AccountIdentityView"];
        NSString *hint=[NSString stringWithFormat:@"%@ %@",
            v.accessibilityLabel?:@"",v.accessibilityIdentifier?:@""].lowercaseString;
        BOOL bell=[cls containsString:@"Notification"] ||
                  [cls containsString:@"Bell"] ||
                  [hint containsString:@"알림"] ||
                  [hint containsString:@"notification"];
        if(avatar && mid>hits->avatarX){
            hits->avatar=v;hits->avatarX=mid;
        }else if(bell && mid>hits->bellX){
            hits->bell=v;hits->bellX=mid;
        }else if(([v isKindOfClass:UIControl.class] ||
                 [cls containsString:@"NavigationButton"] ||
                 [cls containsString:@"QTMButton"]) &&
                 mid>hits->fallbackX && CGRectGetMidY(r)<94){
            hits->fallback=v;hits->fallbackX=mid;
        }
    }
    for(UIView *child in v.subviews)
        duoScanHeader(child,w,hits,budget,depth+1);
}
static void duoRepairHeader(UIWindow *w){
    DuoHeaderHits hits={0};
    hits.avatarX=hits.bellX=hits.fallbackX=-CGFLOAT_MAX;
    NSUInteger budget=0;
    // Search all application-owned windows, not just rootVC.view. YTM's
    // navigation overlay is sometimes attached as a sibling of rootVC.view.
    for(UIView *v in w.subviews)duoScanHeader(v,w,&hits,&budget,0);
    UIView *avatar=hits.avatar?hits.avatar:hits.fallback;
    if(!avatar)return;
    avatar=duoTapRoot(avatar,w);
    CGRect ar=[avatar convertRect:avatar.bounds toView:w];
    // Use original untransformed right edge to avoid jitter after repeated
    // layout passes. A fixed offset is appropriate for the Duo status orb.
    CGFloat margin=MAX(83,w.safeAreaInsets.right+69);
    CGFloat desiredRight=w.bounds.size.width-margin;
    CGFloat shift=MAX(64,MIN(125,CGRectGetMaxX(ar)-desiredRight+64));
    UIView *bell=hits.bell?duoTapRoot(hits.bell,w):nil;
    if(!bell){
        // Fallback: nearest tappable sibling left of the profile in the
        // same row (the navigation notification bell).
        NSMutableArray<UIView*> *candidates=[NSMutableArray array];
        NSUInteger n=0;
        UIView *parent=avatar.superview?avatar.superview:w;
        NSMutableArray<UIView*> *stack=[NSMutableArray arrayWithObject:parent];
        while(stack.count && ++n<1500){
            UIView *v=stack.lastObject;[stack removeLastObject];
            if(v!=avatar && v.userInteractionEnabled &&
               ( [v isKindOfClass:UIControl.class] ||
                 [NSStringFromClass(v.class) containsString:@"Button"]) &&
                 duoOnscreen(v,w)){
                CGRect r=[v convertRect:v.bounds toView:w];
                CGFloat dx=CGRectGetMidX(ar)-CGRectGetMidX(r);
                if(dx>19 && dx<110 &&
                   fabs(CGRectGetMidY(ar)-CGRectGetMidY(r))<28)
                   [candidates addObject:v];
            }
            [stack addObjectsFromArray:v.subviews];
        }
        CGFloat gap=CGFLOAT_MAX;
        for(UIView *v in candidates){
            CGRect r=[v convertRect:v.bounds toView:w];
            CGFloat d=CGRectGetMidX(ar)-CGRectGetMidX(r);
            if(d<gap){gap=d;bell=v;}
        }
    }
    duoSetOriginalOffset(avatar,-shift);
    if(bell && bell!=avatar &&
       ![bell isDescendantOfView:avatar] &&
       ![avatar isDescendantOfView:bell])
        duoSetOriginalOffset(bell,-shift);
}

static UIVisualEffect *duoNativeGlassEffect(void){
    Class glass=NSClassFromString(@"UIGlassEffect");
    SEL factory=NSSelectorFromString(@"effectWithStyle:");
    if(glass && [glass respondsToSelector:factory]){
        id effect=((id(*)(id,SEL,NSInteger))objc_msgSend)(glass,factory,0);
        if([effect isKindOfClass:UIVisualEffect.class])return effect;
    }
    return [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialDark];
}
static UIView *duoMakeFloatingDock(UIWindow *w){
    UIView *shell=[[UIView alloc]initWithFrame:CGRectZero];
    shell.userInteractionEnabled=NO; shell.opaque=NO;
    shell.backgroundColor=UIColor.clearColor;
    shell.layer.shadowColor=UIColor.blackColor.CGColor;
    shell.layer.shadowOpacity=0.33;
    shell.layer.shadowRadius=13;
    shell.layer.shadowOffset=CGSizeMake(0,4);
    UIVisualEffectView *glass=[[UIVisualEffectView alloc]initWithEffect:duoNativeGlassEffect()];
    glass.userInteractionEnabled=NO;glass.clipsToBounds=YES;
    glass.layer.cornerCurve=kCACornerCurveContinuous;
    glass.layer.borderWidth=0.6;
    glass.layer.borderColor=[UIColor.whiteColor colorWithAlphaComponent:0.33].CGColor;
    // Placed ABOVE native buttons, so keep visual translucency. Original
    // buttons and their controls remain unmodified and fully tappable.
    glass.alpha=0.40;
    [shell addSubview:glass];
    objc_setAssociatedObject(shell,kDuoV8GlassEffect,glass,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    UIView *topLine=[[UIView alloc]initWithFrame:CGRectZero];
    topLine.userInteractionEnabled=NO;
    topLine.backgroundColor=[UIColor.whiteColor colorWithAlphaComponent:0.16];
    [shell addSubview:topLine];
    objc_setAssociatedObject(shell,kDuoV8GlassIndicator,topLine,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [w addSubview:shell];
    objc_setAssociatedObject(w,kDuoV8Glass,shell,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return shell;
}
static void duoRepairDock(UIWindow *w,BOOL isHome,NSArray<UIView*> *tabs){
    UIView *shell=objc_getAssociatedObject(w,kDuoV8Glass);
    if(!isHome){shell.hidden=YES;return;}
    if(!shell)shell=duoMakeFloatingDock(w);
    CGFloat width=w.bounds.size.width;
    CGFloat bottom=MAX(w.safeAreaInsets.bottom,8);
    CGFloat y=w.bounds.size.height-bottom-56;
    CGRect bar=CGRectMake(9,y,width-18,47);
    if(!CGRectEqualToRect(shell.frame,bar))shell.frame=bar;
    shell.layer.cornerRadius=23.5;
    UIVisualEffectView *glass=objc_getAssociatedObject(shell,kDuoV8GlassEffect);
    glass.frame=shell.bounds;
    glass.layer.cornerRadius=23.5;
    UIView *topLine=objc_getAssociatedObject(shell,kDuoV8GlassIndicator);
    topLine.frame=CGRectMake(17,1,width-52,0.7);
    shell.hidden=NO;
    [w bringSubviewToFront:shell];
}
typedef struct{
    __unsafe_unretained UIView *panel;
    CGFloat score;
    CGFloat bottom;
} DuoPanelChoice;
static void duoScanMiniPanel(UIView *v,UIWindow *w,DuoPanelChoice *choice,
                             NSUInteger *budget,int depth){
    if(!v || depth>36 || (*budget)++>12000 || v.hidden ||
       v.alpha<0.08 || duoSystemOwned(v))return;
    CGRect r=[v convertRect:v.bounds toView:w];
    CGFloat H=w.bounds.size.height,W=w.bounds.size.width;
    CGFloat h=r.size.height;
    CGFloat expectedBottom=H-MAX(w.safeAreaInsets.bottom,8)-57;
    BOOL candidate=r.size.width>=W*.80 &&
         r.size.width<W*1.15 && h>70 && h<165 &&
         r.origin.y>H*.57 && r.origin.y<H*.89 &&
         fabs(CGRectGetMaxY(r)-expectedBottom)<38;
    if(candidate && duoOnscreen(v,w)){
        NSString *cls=NSStringFromClass(v.class);
        CGFloat score=fabs(CGRectGetMaxY(r)-expectedBottom)*1.5+
                      fabs(h-102)*0.5+
                      fabs(r.size.width-W)*0.1;
        if([cls containsString:@"MiniPlayer"] ||
           [cls containsString:@"ModularPlayerBar"] ||
           [cls containsString:@"PlayerBar"])score-=30;
        if(v.layer.cornerRadius>=5)score-=6;
        if([v isKindOfClass:UIScrollView.class] ||
           [cls containsString:@"Pivot"] ||
           [cls containsString:@"Shelf"] ||
           [cls containsString:@"Collection"])score+=100;
        if(score<choice->score){
            choice->panel=v;choice->score=score;
            choice->bottom=CGRectGetMaxY(r);
        }
    }
    for(UIView *child in v.subviews)
        duoScanMiniPanel(child,w,choice,budget,depth+1);
}
static void duoShrinkView(UIView *v,CGFloat height){
    if(!v || v.frame.size.height<=height+6)return;
    for(NSLayoutConstraint *c in v.constraints){
        if(!c.active || c.relation!=NSLayoutRelationEqual)continue;
        if(c.firstAttribute==NSLayoutAttributeHeight &&
            c.firstItem==v && c.constant>height+10 &&
            c.constant<175) c.constant=height;
    }
    CGRect f=v.frame;
    f.origin.y+=f.size.height-height; // pin to existing lower edge
    f.size.height=height;
    v.frame=f;
    v.clipsToBounds=YES;
}
static void duoRepairPortraitPlayer(UIWindow *w){
    if(w.bounds.size.height<=w.bounds.size.width)return;
    DuoPanelChoice choice={0};
    choice.score=CGFLOAT_MAX;
    NSUInteger budget=0;
    for(UIView *v in w.rootViewController.viewIfLoaded.subviews)
        duoScanMiniPanel(v,w,&choice,&budget,0);
    if(!choice.panel)return;
    // The screenshot's invalid tray is approximately 95pt tall (not the
    // 130pt assumed by v7). Reduce to a conventional 43pt mini-player bar.
    if(choice.panel.bounds.size.height>70)
        duoShrinkView(choice.panel,43);
}
static void duoV8Tick(NSTimer *timer){
    (void)timer;
    if(gDuoTickInProgress)return;
    gDuoTickInProgress=YES;
    @try{
        for(UIWindow *w in UIApplication.sharedApplication.windows){
            if(!DuoIsFoldable(w)||w.hidden ||
               w.windowLevel!=UIWindowLevelNormal)continue;
            NSMutableArray<UIView*> *tabs=[NSMutableArray array];
            BOOL home=duoHome(w,tabs);
            if(home){
                duoRepairHeader(w);
                duoRepairPortraitPlayer(w);
            }
            duoRepairDock(w,home,tabs);
        }
    }@catch(NSException *e){
        NSLog(@"[YTMDuoFix] v8 nonfatal layout exception %@",e.reason);
    }
    gDuoTickInProgress=NO;
}
__attribute__((constructor))static void duoBootstrap(void){
    @autoreleasepool{
        if(![NSBundle.mainBundle.bundleIdentifier
             isEqualToString:@"com.google.ios.youtubemusic"])return;
        // Existing, tested explicit-fullscreen-only behavior unchanged.
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
            gLayoutTimer=[NSTimer scheduledTimerWithTimeInterval:0.7
                             repeats:YES block:^(NSTimer *t){duoV8Tick(t);}];
            [[NSRunLoop mainRunLoop]addTimer:gLayoutTimer
                                    forMode:NSRunLoopCommonModes];
        });
        NSLog(@"[YTMDuoFix] v8 screen-point geometry based repair enabled");
    }
}
