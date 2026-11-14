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
// Exact full-size / cover-screen screenshot ratios: 1536x1081 (1.421)
// versus 1536x1056 (1.455). UIKit uses points, same aspect ratio.
// Only apply cover-specific corrections when the active UIWindow confirms it.
static BOOL DuoCover(UIWindow *w) {
    if(!DuoIsFoldable(w))return NO;
    CGSize sz=w.bounds.size;
    CGFloat ratio=MAX(sz.width,sz.height)/MAX(1,MIN(sz.width,sz.height));
    return ratio>1.438f && ratio<1.72f;
}

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

static void ytmV16FixCoverRows(UIWindow *w);
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
// v18: The camera cutout obscures the left side of the 'Music' wordmark.
// Move only small, left-anchored logo/title containers (not the nav root or
// right controls). The native left-to-right structure is unchanged.
static const void *kV18LogoBaseTransformKey=&kV18LogoBaseTransformKey;
static void ytmV18TranslateBrand(UIView *v,CGFloat dx){
    if(!v)return;
    NSValue *orig=objc_getAssociatedObject(v,kV18LogoBaseTransformKey);
    if(!orig){
        orig=[NSValue valueWithCGAffineTransform:v.transform];
        objc_setAssociatedObject(v,kV18LogoBaseTransformKey,orig,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    CGAffineTransform base=orig.CGAffineTransformValue;
    CGAffineTransform desired=CGAffineTransformTranslate(base,dx,0);
    if(!CGAffineTransformEqualToTransform(v.transform,desired))
        v.transform=desired;
}
static void ytmV18PlaceBrand(UIView *nav,UIWindow *w,BOOL home){
    if(!nav||!w)return;
    BOOL active=home && DuoCover(w) && !DuoPortrait(w);
    // Direct-child groups first, so a combined icon/title group moves once.
    BOOL moved=NO;
    for(UIView *v in nav.subviews){
        NSString *cls=NSStringFromClass(v.class);
        if([v isKindOfClass:UIControl.class] ||
           [cls containsString:@"Activity"] ||
           [cls containsString:@"Button"])continue;
        CGRect r=[v convertRect:v.bounds toView:nav];
        if(r.origin.x>-35 && r.origin.x<155 &&
           r.size.width>=42 && r.size.width<245 &&
           r.size.height>=24 && r.size.height<=100){
            ytmV18TranslateBrand(v,active?34.0f:0);
            moved=YES;
        }
    }
    // Some YTM builds wrap the brand inside a full-width container.
    // Only run this fallback when the direct nav children expose no logo.
    if(!moved){
        for(UIView *container in nav.subviews){
            if([container isKindOfClass:UIControl.class])continue;
            if(container.bounds.size.width<nav.bounds.size.width*.72)continue;
            for(UIView *v in container.subviews){
                if([v isKindOfClass:UIControl.class])continue;
                CGRect r=[v convertRect:v.bounds toView:nav];
                if(r.origin.x>-20 && r.origin.x<145 &&
                   r.size.width>=42 && r.size.width<245 &&
                   r.size.height>=24 && r.size.height<=100){
                    ytmV18TranslateBrand(v,active?34.0f:0);
                    moved=YES;
                    break;
                }
            }
            if(moved)break;
        }
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
    // Cover portrait is 466pt wide: v12's 550pt minimum silently skipped it.
    if(navW<400 || navW>1200)return;
    // Apply to BOTH the frames and the native hit rectangles. Previously
    // changing only UIView.transform could be undone by YTM layout.
    // 124pt frees room for the Duo's right-side system-status orb.
    CGFloat offset=0.0f;
    if(home) {
        if(DuoCover(w)) {
            // Preserve the already-working cover PORTRAIT offset. Only the
            // cover landscape changes: align bell/profile at the right edge,
            // with a small 18pt gutter and native hit rectangles.
            offset=DuoPortrait(w)
                   ? MIN(185.0f,MAX(158.0f,navW*0.34f))
                   : 10.0f;
        } else offset=124.0f; // keep unfolded v11 layout unchanged
    }
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
    ytmV18PlaceBrand(nav,w,home);
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
    ytmFindExactViews(DuoCover(w)?(UIView *)w:root,&views,&budget,0);
    BOOL home=(views.nav==nav && ytmVisibleInWindow(views.pivot,w));
    ytmFixHeaderButtons(nav,w,home);
    if(home && DuoCover(w) && !DuoPortrait(w))
        ytmV16FixCoverRows(w);
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
    // A static system material intentionally replaces the interactive
    // UIGlassEffect on the pivot: the latter magnified YTM's built-in
    // selection animation into the giant circular halo seen in screenshots.
    // We still render a one-piece frosted, specular, rounded tab dock, but
    // the native YTM buttons own all taps and their selected states.
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
    if([cls containsString:@"MDCInkView"] ||
       [cls containsString:@"MDCRippleView"] ||
       [cls containsString:@"MDCInkTouchController"]){
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
// v19: raise the five REAL tab hit targets and their glass backing by 8pt.
// Keeping the original transforms avoids cumulative drift during YTM relayout.
static const void *kV19TabBaseKey=&kV19TabBaseKey;
static void ytmV19TabLift(UIView *tab,BOOL active){
    if(!tab)return;
    NSValue *value=objc_getAssociatedObject(tab,kV19TabBaseKey);
    if(!value){
        value=[NSValue valueWithCGAffineTransform:tab.transform];
        objc_setAssociatedObject(tab,kV19TabBaseKey,value,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    CGAffineTransform base=value.CGAffineTransformValue;
    CGAffineTransform desired=active?CGAffineTransformTranslate(base,0,-8.0f):base;
    if(!CGAffineTransformEqualToTransform(tab.transform,desired))
        tab.transform=desired;
}
static void ytmFixGlassDock(YTMDuoViews *views,UIWindow *w,BOOL home){
    UIView *pivot=views->pivot;
    if(!pivot)return;
    UIVisualEffectView *glass=objc_getAssociatedObject(pivot,kGlassDockKey);
    UIView *container=objc_getAssociatedObject(pivot,kGlassContainerKey);
    if(!home || !ytmVisibleInWindow(pivot,w)){
        for(NSUInteger i=0;i<views->itemCount;i++)
            ytmV19TabLift(views->items[i],NO);
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
        ytmV19TabLift(tab,YES);
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
    // Suppress ripple layers newly attached on the pivot container too;
    // YTPivotBarItemViewAccessibilityControl can create these as siblings
    // AFTER the tab view is laid out, not inside an individual tab.
    ytmDisablePivotInk(pivot,0);
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

// A change between the 1.421 (opened) and 1.455 (cover) Duo ratios is an
// actual display geometry switch, NOT a new orientation of the same canvas.
// Request one native layout pass whenever that changes; no recurring forced
// invalidation that could stutter the player.
static const void *kCoverGeometryKey=&kCoverGeometryKey;
static const void *kCoverVerticalOriginKey=&kCoverVerticalOriginKey;
static UIView *ytmFindViewByClass(UIView *root,NSString *type,int depth){
    if(!root||depth>34)return nil;
    if([NSStringFromClass(root.class) isEqualToString:type] &&
       root.window && !root.hidden)return root;
    for(UIView *child in root.subviews){
        UIView *found=ytmFindViewByClass(child,type,depth+1);
        if(found)return found;
    }
    return nil;
}
static void ytmCoverRestoreVertical(UIView *v){
    if(!v)return;
    NSValue *original=objc_getAssociatedObject(v,kCoverVerticalOriginKey);
    if(original && !CGAffineTransformEqualToTransform(v.transform,
                                                      original.CGAffineTransformValue))
        v.transform=original.CGAffineTransformValue;
}
// The cover display's landscape diagnostics showed top navigation y=82
// but chips y=49. In the screenshot the two rows overlap the feed header.
// Normalize the two independent rows to the unfolded layout's top anchor.
// No arbitrary resizing or scaling of the home feed is performed.
static const void *kCoverOriginalClippingKey=&kCoverOriginalClippingKey;
// In v14, the 140pt correction cap silently rejected the actual 164pt
// displaced navigation parent reported by the cover landscape diagnostics.
// More importantly, repeatedly restoring/recorrecting transforms during the
// 0.45s timer could make the header appear to bounce between two positions.
// This v15 implementation computes an ABSOLUTE transform from the current
// UIKit geometry, accounting for our LAST applied offset, without ever
// temporarily resetting the visible transform.
static const void *kV15AppliedYKey=&kV15AppliedYKey;
static CGAffineTransform ytmStoredBaseTransform(UIView *v){
    if(!v)return CGAffineTransformIdentity;
    NSValue *saved=objc_getAssociatedObject(v,kCoverVerticalOriginKey);
    if(!saved){
        saved=[NSValue valueWithCGAffineTransform:v.transform];
        objc_setAssociatedObject(v,kCoverVerticalOriginKey,saved,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return saved.CGAffineTransformValue;
}
static BOOL ytmPlaceAtWindowY(UIView *v,UIWindow *w,CGFloat desired){
    if(!v||!w||v.window!=w)return NO;
    CGAffineTransform base=ytmStoredBaseTransform(v);
    CGFloat prior=[objc_getAssociatedObject(v,kV15AppliedYKey) doubleValue];
    // Native YTM layout can reset a view's transform to its base value.
    // When that happens our previous offset is no longer present in the
    // current CGRect, so do not subtract it twice.
    if(CGAffineTransformEqualToTransform(v.transform,base))prior=0;
    CGRect current=[v convertRect:v.bounds toView:w];
    if(CGRectIsNull(current)||CGRectIsInfinite(current) ||
       current.size.width<25)return NO;
    // 'current' already includes the last transform. Removing only OUR
    // offset recovers UIKit's most recent layout result, even if UIKit
    // adjusted the native frame in the meantime.
    CGFloat nativeY=current.origin.y-prior;
    CGFloat delta=desired-nativeY;
    if(!isfinite(delta)||fabs(delta)>270)return NO;
    CGAffineTransform updated=CGAffineTransformTranslate(base,0,delta);
    if(!CGAffineTransformEqualToTransform(v.transform,updated))
        v.transform=updated;
    objc_setAssociatedObject(v,kV15AppliedYKey,@(delta),
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return YES;
}
static void ytmAlignCoverHeaderPair(UIView *child,UIWindow *w,
                                    CGFloat parentY,CGFloat childY){
    if(!child||!child.superview||!w||!DuoCover(w)||DuoPortrait(w))return;
    UIView *parent=child.superview;
    if(parent==w||parent.bounds.size.width<w.bounds.size.width*.84f)return;
    CGRect p=[parent convertRect:parent.bounds toView:w];
    if(p.size.height<18||p.size.height>150)return;
    // Parent first, then child (in the parent's NEW coordinate system).
    if(!ytmPlaceAtWindowY(parent,w,parentY))return;
    ytmPlaceAtWindowY(child,w,childY);
    if(!objc_getAssociatedObject(parent,kCoverOriginalClippingKey))
        objc_setAssociatedObject(parent,kCoverOriginalClippingKey,
                 @(parent.clipsToBounds?2:1),OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    parent.clipsToBounds=NO;
    parent.layer.masksToBounds=NO;
}
static void ytmRestoreCoverHeaderPair(UIView *child){
    if(!child)return;
    UIView *parent=child.superview;
    ytmCoverRestoreVertical(child);
    ytmCoverRestoreVertical(parent);
    objc_setAssociatedObject(child,kV15AppliedYKey,nil,OBJC_ASSOCIATION_ASSIGN);
    objc_setAssociatedObject(parent,kV15AppliedYKey,nil,OBJC_ASSOCIATION_ASSIGN);
    NSNumber *original=objc_getAssociatedObject(parent,kCoverOriginalClippingKey);
    if(original)parent.clipsToBounds=(original.integerValue==2);
}

// v16: Post-layout COVER-LANDSCAPE row repair in WINDOW coordinates.
// v15 diagnostics proved that the filter view was y23, its parent y56,
// while nav+parent were both y82. These are two separate rows. Moving
// transforms alone left hit-testing and native layout ambiguous.
// Set actual container and child frames, with full 56pt hit regions.
static BOOL gV16RepairingRows=NO;
static BOOL ytmV16SetScreenY(UIView *v,UIWindow *w,CGFloat y){
    if(!v || !v.superview || v.superview==w || v.window!=w)return NO;
    CGRect r=[v convertRect:v.bounds toView:w];
    CGFloat delta=y-r.origin.y;
    if(!isfinite(delta)||fabs(delta)>250)return NO;
    if(fabs(delta)>0.7){
        CGRect f=v.frame;
        f.origin.y+=delta;
        v.frame=f;
    }
    return YES;
}
// v17: The cover landscape JSON reports navParent y=105 and nav y=23,
// while filterParent y=82 and filters y=49. A frame-only move in v16 is
// repeatedly overwritten by YouTube Music's layout constraints.
// Apply stable absolute post-layout transforms to the TWO parent/child pairs
// so the header (y=2) precedes the category chips (y=58). Transform-based
// movement preserves the actual hit-test coordinates.
static void ytmV17UnclipAncestors(UIView *view,UIWindow *window){
    UIView *p=view;
    for(int depth=0;p && p!=window && depth<6;p=p.superview,depth++){
        NSString *cls=NSStringFromClass(p.class);
        if([p isKindOfClass:UIScrollView.class] ||
           [cls containsString:@"Pivot"] ||
           [cls containsString:@"WatchView"])break;
        if(p.clipsToBounds || p.layer.masksToBounds){
            // Only along these verified header paths. Do not unclip
            // the scroll feed, miniplayer, or navigation tabs.
            p.clipsToBounds=NO;
            p.layer.masksToBounds=NO;
        }
    }
}
static void ytmV17AlignPair(UIView *child,UIWindow *w,CGFloat parentY,CGFloat childY){
    if(!child || !child.superview || !w)return;
    UIView *parent=child.superview;
    if(parent==w || parent.window!=w ||
       parent.bounds.size.width<w.bounds.size.width*.80)return;
    CGRect pr=[parent convertRect:parent.bounds toView:w];
    if(pr.size.height<16 || pr.size.height>145)return;
    // Do NOT touch constraints or the frame; move only the two original
    // UIKit view transforms after native layout. v15 stores their base
    // transforms and accounts for previously applied offsets.
    if(!ytmPlaceAtWindowY(parent,w,parentY))return;
    ytmPlaceAtWindowY(child,w,childY);
    ytmV17UnclipAncestors(child,w);
    // Filter stack is only 23pt high while its visible pill controls occupy
    // 56pt. Enlarge the hit region without moving other home feed views.
    if([parent isKindOfClass:NSClassFromString(@"MDCHeaderStackView")] &&
       parent.bounds.size.height<55){
        CGRect bounds=parent.bounds;
        bounds.size.height=56;
        parent.bounds=bounds;
    }
}
static void ytmV16FixCoverRows(UIWindow *w){
    if(gV16RepairingRows || !w || !DuoCover(w) || DuoPortrait(w))return;
    UIView *root=w.rootViewController.viewIfLoaded;
    if(!root)return;
    YTMDuoViews v={0};
    NSUInteger budget=0;
    ytmFindExactViews((UIView*)w,&v,&budget,0);
    if(!ytmVisibleInWindow(v.pivot,w))return;
    UIView *filters=ytmFindViewByClass(w,@"GOONavigationBar",0);
    if(!v.nav || !filters)return;
    gV16RepairingRows=YES;
    @try{
        [UIView performWithoutAnimation:^{
            ytmV17AlignPair(v.nav,w,0,2);
            ytmV17AlignPair(filters,w,56,58);
        }];
    }@finally{gV16RepairingRows=NO;}
}
static void (*oldMDCHeaderStackLayout)(id,SEL);
static void ytmV16MDCHeaderStackLayout(id self,SEL cmd){
    if(oldMDCHeaderStackLayout)oldMDCHeaderStackLayout(self,cmd);
    UIView *view=(UIView*)self;
    UIWindow *w=view.window;
    if(DuoCover(w)&&!DuoPortrait(w))ytmV16FixCoverRows(w);
}
static void ytmCoverMiniReflow(UIView *mini,UIView *pivot,UIWindow *w){
    if(!mini||!pivot||!w||!DuoCover(w)||DuoPortrait(w))return;
    CGRect tab=[pivot convertRect:pivot.bounds toView:w];
    if(!CGRectIntersectsRect(tab,w.bounds) || tab.size.height<38)return;
    CGRect m=[mini convertRect:mini.bounds toView:w];
    CGFloat desiredY=MAX(0,CGRectGetMinY(tab)-64);
    // A correct mini.frame can still be CLIPPED by an undersized parent
    // YTMGradientBackgroundView (as the cover landscape screenshot shows).
    UIView *host=mini.superview;
    CGRect hostRect=host?[host convertRect:host.bounds toView:w]:CGRectNull;
    BOOL hostClipped=host && (hostRect.size.width<w.bounds.size.width*.91 ||
                             hostRect.origin.x>12 ||
                             hostRect.size.height<55 ||
                             fabs(hostRect.origin.y-desiredY)>17);
    BOOL miniDisplaced=(m.size.width<w.bounds.size.width*.91 ||
                        m.origin.x>12 || fabs(m.origin.y-desiredY)>20);
    if(!hostClipped && !miniDisplaced)return;
    CGRect desired=CGRectMake(0,desiredY,w.bounds.size.width,64);
    if(host && [NSStringFromClass(host.class)
                isEqualToString:@"YTMGradientBackgroundView"] &&
       host.superview){
        CGRect newHost=[w convertRect:desired toView:host.superview];
        // Adjust ONLY the clipped mini-player host. Do not move or resize
        // the pivot tabs, scroll feed or unfolded/cover portrait screens.
        host.frame=newHost;
        mini.frame=host.bounds;
    }else if(mini.superview && miniDisplaced){
        mini.frame=[w convertRect:desired toView:mini.superview];
    }
}
// v14: the supplied JSON confirms the mini and its gradient host are both
// full width (678pt), but the screenshot shows a centered ~441pt payload.
// Check ONLY internal mini containers, never replace the working mini view.
// v14 logs expose the precise cause of the 440pt-wide cover mini strip:
// while the YTMMiniPlayerView itself is 678pt wide, its first-level
// collection container is only 344.7pt, followed by two 40pt action buttons
// at x344.7 and x392.7. The child had never been widened because v14's
// "centered" condition was FALSE (the child is left-anchored at x0).
// Rebalance that ONE internal row: collection (W-96), cast, play.
static void ytmFitCoverMiniContents(UIView *mini,UIWindow *w){
    if(!mini||!w||!DuoCover(w)||DuoPortrait(w))return;
    CGFloat W=mini.bounds.size.width;
    if(W<620 || W>800)return; // specifically 678pt cover landscape
    CGRect mr=[mini convertRect:mini.bounds toView:w];
    if(mr.size.height<58||mr.size.height>71 ||
       mr.origin.y<w.bounds.size.height*.48)return;
    UIView *strip=nil;
    UICollectionView *collection=nil;
    NSMutableArray<UIView *> *buttons=[NSMutableArray array];
    for(UIView *v in mini.subviews){
        NSString *name=NSStringFromClass(v.class);
        if([name isEqualToString:@"MDCFloatingButton"] &&
            v.bounds.size.width>=36 && v.bounds.size.width<=50)
            [buttons addObject:v];
        if([name isEqualToString:@"UIView"] && v.bounds.size.width>280 &&
           v.bounds.size.width<W*.76f && v.bounds.size.height>=55){
            for(UIView *child in v.subviews) {
                if([child isKindOfClass:UICollectionView.class]){
                    strip=v;collection=(UICollectionView *)child;break;
                }
            }
        }
    }
    if(!strip||!collection||buttons.count!=2)return;
    [buttons sortUsingComparator:^NSComparisonResult(UIView *a,UIView *b){
        return a.frame.origin.x<b.frame.origin.x?NSOrderedAscending:
               a.frame.origin.x>b.frame.origin.x?NSOrderedDescending:
               NSOrderedSame;
    }];
    CGFloat textWidth=W-96.0f;
    BOOL needsChange=fabs(strip.frame.size.width-textWidth)>3;
    for(NSUInteger i=0;i<2;i++){
        CGFloat targetX=textWidth+48.0f*i;
        if(fabs(buttons[i].frame.origin.x-targetX)>3)needsChange=YES;
    }
    if(!needsChange)return;
    [UIView performWithoutAnimation:^{
        CGRect contentFrame=strip.frame;
        contentFrame.origin.x=0;
        contentFrame.size.width=textWidth;
        strip.frame=contentFrame;
        CGRect collectionFrame=collection.frame;
        collectionFrame.origin.x=0;
        collectionFrame.size.width=textWidth;
        collection.frame=collectionFrame;
        for(NSUInteger i=0;i<buttons.count;i++){
            UIView *button=buttons[i];
            CGRect r=button.frame;
            r.origin.x=textWidth+48.0f*i;
            button.frame=r;
        }
        [collection.collectionViewLayout invalidateLayout];
    }];
    static BOOL logged=NO;
    if(!logged){
        logged=YES;
        NSLog(@"[YTMDuoFix] v15 cover mini row corrected from 344.7 to %.1fpt",textWidth);
    }
}
static void ytmV18StyleMini(UIView *mini,UIWindow *w,BOOL active);
static void (*oldYTMMiniplayerLayout)(id,SEL);
static void ytmMiniplayerLayout(id self,SEL cmd){
    if(oldYTMMiniplayerLayout)oldYTMMiniplayerLayout(self,cmd);
    UIWindow *w=((UIView *)self).window;
    if(w && DuoCover(w)&&!DuoPortrait(w)) {
        ytmFitCoverMiniContents((UIView *)self,w);
        ytmV18StyleMini((UIView *)self,w,YES);
    }
}
// v18: The latest cover capture confirms v17 expanded the independent
// background to the full 678pt, but the actual UICollectionView is STILL
// bgAlpha=1. Remove only the opaque player backgrounds and render an
// untouchable, clear Liquid Glass surface UNDER the native song controls.
static const void *kV17MiniBackdropKey=&kV17MiniBackdropKey;
static const void *kV18MiniGlassKey=&kV18MiniGlassKey;
static const void *kV18MiniSavedColorKey=&kV18MiniSavedColorKey;
static const void *kV18GradientOpacityKey=&kV18GradientOpacityKey;
static const void *kV18SavedOpaqueKey=&kV18SavedOpaqueKey;
static void ytmV18Background(UIView *v,BOOL clear){
    if(!v)return;
    if(clear){
        if(!objc_getAssociatedObject(v,kV18MiniSavedColorKey)){
            id original=v.backgroundColor ?: [NSNull null];
            objc_setAssociatedObject(v,kV18MiniSavedColorKey,original,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        if(v.backgroundColor!=UIColor.clearColor)
            v.backgroundColor=UIColor.clearColor;
    }else{
        id saved=objc_getAssociatedObject(v,kV18MiniSavedColorKey);
        if(saved){
            v.backgroundColor=saved==[NSNull null]?nil:(UIColor *)saved;
            objc_setAssociatedObject(v,kV18MiniSavedColorKey,nil,
                                     OBJC_ASSOCIATION_ASSIGN);
        }
    }
}
static void ytmV18Opaque(UIView *v,BOOL clear){
    if(!v)return;
    NSNumber *saved=objc_getAssociatedObject(v,kV18SavedOpaqueKey);
    if(clear){
        if(!saved)objc_setAssociatedObject(v,kV18SavedOpaqueKey,@(v.opaque),
                              OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        v.opaque=NO;
    }else if(saved){
        v.opaque=saved.boolValue;
        objc_setAssociatedObject(v,kV18SavedOpaqueKey,nil,
                                 OBJC_ASSOCIATION_ASSIGN);
    }
}
static void ytmV18HostGradient(UIView *host,BOOL clear){
    if(!host)return;
    for(CALayer *sub in host.layer.sublayers){
        if(![sub isKindOfClass:CAGradientLayer.class])continue;
        NSNumber *saved=objc_getAssociatedObject(sub,kV18GradientOpacityKey);
        if(clear){
            if(!saved)objc_setAssociatedObject(sub,kV18GradientOpacityKey,
                             @(sub.opacity),OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            if(sub.opacity!=0)sub.opacity=0;
        }else if(saved){
            sub.opacity=saved.floatValue;
            objc_setAssociatedObject(sub,kV18GradientOpacityKey,nil,
                                     OBJC_ASSOCIATION_ASSIGN);
        }
    }
}
static UIVisualEffect *ytmV18ClearGlassEffect(void){
    Class effectClass=NSClassFromString(@"UIGlassEffect");
    SEL selector=NSSelectorFromString(@"effectWithStyle:");
    if(effectClass && [effectClass respondsToSelector:selector]){
        // iOS 26+ SDK enum: clear-style glass (raw value 1).
        id fx=((id(*)(id,SEL,NSInteger))objc_msgSend)(effectClass,selector,1);
        SEL interactive=NSSelectorFromString(@"setInteractive:");
        if(fx && [fx respondsToSelector:interactive])
            ((void(*)(id,SEL,BOOL))objc_msgSend)(fx,interactive,NO);
        if([fx isKindOfClass:UIVisualEffect.class])return fx;
    }
    return [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialDark];
}
static BOOL gV18StylingMini=NO;
static void ytmV18StyleMini(UIView *mini,UIWindow *w,BOOL active){
    if(gV18StylingMini || !mini)return;
    active=active && w && DuoCover(w) && !DuoPortrait(w) &&
           mini.bounds.size.width>650 && mini.bounds.size.width<710;
    gV18StylingMini=YES;
    @try{
        UIVisualEffectView *glass=objc_getAssociatedObject(mini,kV18MiniGlassKey);
        UIView *host=mini.superview;
        UIView *watch=host.superview;
        ytmV18Background(mini,active);
        if(host && [NSStringFromClass(host.class)
                    isEqualToString:@"YTMGradientBackgroundView"]){
            ytmV18Background(host,active);
            ytmV18HostGradient(host,active);
        }
        // The actual black field in v17 was an opaque, empty YTMWatchView
        // sibling. It is now 678pt wide but still black: clear its fill.
        if([NSStringFromClass(watch.class) isEqualToString:@"YTMWatchView"]){
            for(UIView *v in watch.subviews){
                if(objc_getAssociatedObject(v,kV17MiniBackdropKey))
                    ytmV18Background(v,active);
            }
        }
        for(UIView *strip in mini.subviews){
            if(![NSStringFromClass(strip.class) isEqualToString:@"UIView"])
                continue;
            for(UIView *sub in strip.subviews){
                if([sub isKindOfClass:UICollectionView.class]){
                    ytmV18Background(sub,active);
                    ytmV18Opaque(sub,active);
                }
            }
        }
        ytmV18Opaque(mini,active);
        ytmV18Opaque(host,active);
        if(!active){
            if(glass)glass.hidden=YES;
            return;
        }
        if(!glass){
            glass=[[UIVisualEffectView alloc]
                    initWithEffect:ytmV18ClearGlassEffect()];
            glass.userInteractionEnabled=NO; // native playback buttons win
            glass.alpha=1;                   // do not weaken glass render
            glass.clipsToBounds=YES;
            glass.layer.cornerCurve=kCACornerCurveContinuous;
            glass.layer.borderWidth=.6f;
            glass.layer.borderColor=
                [[UIColor whiteColor] colorWithAlphaComponent:.22f].CGColor;
            objc_setAssociatedObject(mini,kV18MiniGlassKey,glass,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        glass.frame=CGRectInset(mini.bounds,7,2);
        glass.layer.cornerRadius=17.0f;
        glass.hidden=NO;
        if(glass.superview!=mini){
            [glass removeFromSuperview];
            [mini insertSubview:glass atIndex:0];
        }else{
            [mini sendSubviewToBack:glass];
        }
    }@finally{gV18StylingMini=NO;}
}
// v17: In the actual cover-landscape JSON the YTMWatchView contains one
// empty, fully opaque UIView at x=118.33 y=320 w=440.67 h=64. This EXACT
// rectangle is the black centered strip in the screenshot. Its sibling
// YTMMiniPlayerView is already full-width, so repair only the rogue backdrop.
static BOOL gV17SurfaceRepairing=NO;
static void ytmV17RepairMiniBackdrop(UIView *watch){
    if(gV17SurfaceRepairing || !watch)return;
    UIWindow *w=watch.window;
    if(!DuoCover(w) || DuoPortrait(w))return;
    CGFloat W=w.bounds.size.width;
    if(W<660 || W>700)return; // user's 678pt cover landscape
    UIView *mini=ytmFindViewByClass(watch,@"YTMMiniPlayerView",0);
    UIView *pivot=ytmFindViewByClass(w,@"YTPivotBarView",0);
    if(!ytmVisibleInWindow(mini,w) || !ytmVisibleInWindow(pivot,w))return;
    CGRect m=[mini convertRect:mini.bounds toView:w];
    if(m.size.width<W*.98 || m.size.height<60 || m.size.height>69)return;
    gV17SurfaceRepairing=YES;
    @try{
        for(UIView *node in watch.subviews){
            if(![node isMemberOfClass:UIView.class] ||
               node.subviews.count!=0 || node.hidden ||
               node.alpha<.9 || !node.backgroundColor)continue;
            CGRect r=[node convertRect:node.bounds toView:w];
            CGFloat bgAlpha=CGColorGetAlpha(node.backgroundColor.CGColor);
            BOOL exact=bgAlpha>.92 &&
              r.size.width>=W*.58 && r.size.width<=W*.75 &&
              r.size.height>=61 && r.size.height<=67 &&
              fabs(r.origin.y-m.origin.y)<2.5 &&
              fabs(CGRectGetMidX(r)-W/2)<5;
            // Once resized, keep it aligned following native layout.
            BOOL already=objc_getAssociatedObject(node,kV17MiniBackdropKey)!=nil;
            if(!exact && !already)continue;
            if(!already)
                objc_setAssociatedObject(node,kV17MiniBackdropKey,@YES,
                        OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            CGRect full=[w convertRect:CGRectMake(0,m.origin.y,W,m.size.height)
                                 toView:watch];
            if(fabs(node.frame.origin.x-full.origin.x)>.5 ||
               fabs(node.frame.size.width-full.size.width)>.5 ||
               fabs(node.frame.origin.y-full.origin.y)>.5){
                [UIView performWithoutAnimation:^{node.frame=full;}];
                NSLog(@"[YTMDuoFix] v17 expanded exact opaque mini backdrop to %.1fpt",W);
            }
            break;
        }
    }@finally{gV17SurfaceRepairing=NO;}
}
static void (*oldYTMWatchViewLayout)(id,SEL);
static void ytmV17WatchViewLayout(id self,SEL cmd){
    if(oldYTMWatchViewLayout)oldYTMWatchViewLayout(self,cmd);
    ytmV17RepairMiniBackdrop((UIView *)self);
}
static NSDictionary *ytmV17BackdropInfo(UIView *mini,UIWindow *w){
    if(!mini||!w)return @{};
    UIView *watch=mini.superview.superview;
    if(![NSStringFromClass(watch.class) isEqualToString:@"YTMWatchView"])
        return @{};
    for(UIView *node in watch.subviews){
        if(objc_getAssociatedObject(node,kV17MiniBackdropKey)){
            CGRect r=[node convertRect:node.bounds toView:w];
            return @{@"x":@(r.origin.x),@"y":@(r.origin.y),
                     @"w":@(r.size.width),@"h":@(r.size.height),
                     @"repaired":@YES};
        }
    }
    return @{};
}
static NSArray *ytmV17AncestorInfo(UIView *node,UIWindow *w){
    NSMutableArray *out=[NSMutableArray array];
    for(int n=0;node && node!=w && n<7;node=node.superview,n++){
        CGRect r=[node convertRect:node.bounds toView:w];
        [out addObject:@{@"class":NSStringFromClass(node.class),
          @"x":@(r.origin.x),@"y":@(r.origin.y),
          @"w":@(r.size.width),@"h":@(r.size.height),
          @"clips":@(node.clipsToBounds),
          @"transformY":@(node.transform.ty)}];
    }
    return out;
}
static NSDictionary *ytmMiniDescendantInfo(UIView *v,UIWindow *w,NSInteger depth){
    CGRect r=[v convertRect:v.bounds toView:w];
    return @{@"type":NSStringFromClass(v.class),
             @"frame":@{@"x":@(r.origin.x),@"y":@(r.origin.y),
                         @"w":@(r.size.width),@"h":@(r.size.height)},
             @"depth":@(depth),@"children":@(v.subviews.count),
             @"clip":@(v.clipsToBounds),@"mask":@(v.layer.masksToBounds),
             @"hidden":@(v.hidden)};
}
static void ytmMiniStructureWalk(UIView *v,UIWindow *w,
                                 NSMutableArray *output,int depth){
    if(!v || depth>3 || output.count>=55)return;
    [output addObject:ytmMiniDescendantInfo(v,w,depth)];
    for(UIView *sub in v.subviews)
        ytmMiniStructureWalk(sub,w,output,depth+1);
}
static NSArray *ytmMiniSnapshot(UIView *mini,UIWindow *w){
    NSMutableArray *items=[NSMutableArray array];
    if(mini)ytmMiniStructureWalk(mini,w,items,0);
    return items;
}
static void ytmCoverRepairHome(UIWindow *w,YTMDuoViews *views,BOOL home){
    if(!w||!views)return;
    NSString *shape=[NSString stringWithFormat:@"%.1fx%.1f",
                     w.bounds.size.width,w.bounds.size.height];
    NSString *oldShape=objc_getAssociatedObject(w,kCoverGeometryKey);
    BOOL sizeChanged=![oldShape isEqualToString:shape];
    if(sizeChanged){
        objc_setAssociatedObject(w,kCoverGeometryKey,shape,
                                 OBJC_ASSOCIATION_COPY_NONATOMIC);
        UIView *root=w.rootViewController.viewIfLoaded;
        [root setNeedsLayout];
        [views->nav setNeedsLayout];
        [views->pivot setNeedsLayout];
        [views->mini setNeedsLayout];
        NSLog(@"[YTMDuoFix] geometry changed to %@ cover=%d",
              shape,DuoCover(w));
    }
    UIView *filters=ytmFindViewByClass(w,@"GOONavigationBar",0);
    if(!DuoCover(w)||!home){
        ytmRestoreCoverHeaderPair(views->nav);
        ytmRestoreCoverHeaderPair(filters);
        ytmV18StyleMini(views->mini,w,NO);
        return;
    }
    if(!DuoPortrait(w)){
        // The cover-landscape screenshot showed header chips around y=180
        // and the Music logo below them. Only correct genuinely displaced
        // header rows; their native x positions and interactions stay intact.
        // v16 moves the actual two row containers/children into
        // non-overlapping 56pt hit regions; no transform-based oscillation.
        ytmV16FixCoverRows(w);
        ytmCoverMiniReflow(views->mini,views->pivot,w);
        ytmFitCoverMiniContents(views->mini,w);
        ytmV17RepairMiniBackdrop(views->mini.superview.superview);
        ytmV18StyleMini(views->mini,w,YES);
    }else{
        ytmRestoreCoverHeaderPair(views->nav);
        ytmRestoreCoverHeaderPair(filters);
        ytmV18StyleMini(views->mini,w,NO);
    }
}
static NSDictionary *ytmScreenRect(UIView *v,UIWindow *w){
    if(!v||!w||v.window!=w)return @{};
    CGRect r=[v convertRect:v.bounds toView:w];
    return @{@"class":NSStringFromClass(v.class),
             @"x":@(r.origin.x),@"y":@(r.origin.y),
             @"w":@(r.size.width),@"h":@(r.size.height),
             @"hidden":@(v.hidden)};
}
// Identify any ADDITIONAL centered presentation at the mini player's
// y=320pt. The user screenshot contains a ~440pt overlay although the
// actual YTMMiniPlayerView and its 582pt collection now span the window.
// Class + frames + background alpha only; never titles or account data.
static void ytmV16AuditMiniOverlayWalk(UIView *node,UIWindow *w,
                CGRect miniFrame,NSMutableArray *results,
                NSUInteger *budget,int depth){
    if(!node||depth>32||(*budget)++>14000||results.count>=100)return;
    if(node.window==w && !node.hidden && node.alpha>0.06f){
        CGRect r=[node convertRect:node.bounds toView:w];
        BOOL nearVertical=CGRectGetMinY(r)<CGRectGetMaxY(miniFrame)+25 &&
                          CGRectGetMaxY(r)>CGRectGetMinY(miniFrame)-16;
        BOOL panelLike=r.size.width>180 &&
              r.size.width<w.bounds.size.width*.98f &&
              r.size.height>35 && r.size.height<150;
        BOOL narrowCenter=CGRectGetMidX(r)>w.bounds.size.width*.20f &&
                          CGRectGetMidX(r)<w.bounds.size.width*.80f;
        if(nearVertical && panelLike && narrowCenter){
            UIView *parent=node.superview;
            CGRect pr=parent?[parent convertRect:parent.bounds toView:w]:CGRectNull;
            [results addObject:@{
              @"class":NSStringFromClass(node.class),
              @"parentClass":parent?NSStringFromClass(parent.class):@"",
              @"x":@(r.origin.x),@"y":@(r.origin.y),
              @"w":@(r.size.width),@"h":@(r.size.height),
              @"parentX":@(CGRectIsNull(pr)?0:pr.origin.x),
              @"parentY":@(CGRectIsNull(pr)?0:pr.origin.y),
              @"parentW":@(CGRectIsNull(pr)?0:pr.size.width),
              @"parentH":@(CGRectIsNull(pr)?0:pr.size.height),
              @"clips":@(node.clipsToBounds),
              @"alpha":@(node.alpha),@"children":@(node.subviews.count),
              @"bgAlpha":@(node.backgroundColor ? CGColorGetAlpha(node.backgroundColor.CGColor) : 0.0f),
              @"depth":@(depth)
            }];
        }
    }
    for(UIView *child in node.subviews){
        if(results.count>=100||*budget>14000)break;
        ytmV16AuditMiniOverlayWalk(child,w,miniFrame,results,budget,depth+1);
    }
}
static NSArray *ytmV16MiniOverlayAudit(UIWindow *w,UIView *mini){
    if(!w||!mini||DuoPortrait(w))return @[];
    NSMutableArray *records=[NSMutableArray array];
    NSUInteger budget=0;
    CGRect mr=[mini convertRect:mini.bounds toView:w];
    for(UIView *child in w.subviews)
        ytmV16AuditMiniOverlayWalk(child,w,mr,records,&budget,0);
    return records;
}
static NSArray *ytmV18NavControls(UIView *nav,UIWindow *w){
    NSMutableArray *a=[NSMutableArray array];
    if(!nav||!w)return a;
    for(UIView *child in nav.subviews){
        CGRect r=[child convertRect:child.bounds toView:w];
        [a addObject:@{
         @"class":NSStringFromClass(child.class),
         @"x":@(r.origin.x),@"y":@(r.origin.y),
         @"w":@(r.size.width),@"h":@(r.size.height),
         @"shifted":@(objc_getAssociatedObject(child,kV18LogoBaseTransformKey)!=nil),
         @"children":@(child.subviews.count)
        }];
    }
    return a;
}
static NSDictionary *ytmV18MiniGlassInfo(UIView *mini,UIWindow *w){
    if(!mini||!w)return @{};
    UIVisualEffectView *glass=objc_getAssociatedObject(mini,kV18MiniGlassKey);
    UIView *container=nil;
    for(UIView *strip in mini.subviews)
        for(UIView *sub in strip.subviews)
            if([sub isKindOfClass:UICollectionView.class])container=sub;
    CGRect r=glass?[glass convertRect:glass.bounds toView:w]:CGRectZero;
    return @{@"enabled":@(glass && !glass.hidden),
             @"effect":glass.effect?NSStringFromClass(glass.effect.class):@"none",
             @"glassFrame":@{@"x":@(r.origin.x),@"y":@(r.origin.y),
                             @"w":@(r.size.width),@"h":@(r.size.height)},
             @"collectionBgAlpha":@(container.backgroundColor ?
                CGColorGetAlpha(container.backgroundColor.CGColor) : 0)};
}
static void ytmSaveCoverGeometry(UIWindow *w,YTMDuoViews *views){
    static NSUInteger counter=0;
    if(!DuoCover(w)||++counter%18!=0)return;
    UIView *filters=ytmFindViewByClass(w,@"GOONavigationBar",0);
    UIEdgeInsets safe=w.safeAreaInsets;
    NSDictionary *data=@{
      @"purpose":@"YTM Duo cover UI geometry (no media/account text)",
      @"screen":@{@"w":@(w.bounds.size.width),@"h":@(w.bounds.size.height)},
      @"safeArea":@{@"top":@(safe.top),@"right":@(safe.right),
                    @"bottom":@(safe.bottom),@"left":@(safe.left)},
      @"nav":ytmScreenRect(views->nav,w),
      @"filters":ytmScreenRect(filters,w),
      @"mini":ytmScreenRect(views->mini,w),
      @"miniHost":ytmScreenRect(views->mini.superview,w),
      @"miniHostParent":ytmScreenRect(views->mini.superview.superview,w),
      @"miniSubtree":ytmMiniSnapshot(views->mini,w),
      @"nearMiniOverlays":ytmV16MiniOverlayAudit(w,views->mini),
      @"miniBackdrop":ytmV17BackdropInfo(views->mini,w),
      @"navAncestors":ytmV17AncestorInfo(views->nav,w),
      @"navControls":ytmV18NavControls(views->nav,w),
      @"miniGlass":ytmV18MiniGlassInfo(views->mini,w),
      @"filterAncestors":ytmV17AncestorInfo(filters,w),
      @"navParent":ytmScreenRect(views->nav.superview,w),
      @"filtersParent":ytmScreenRect(filters.superview,w),
      @"pivot":ytmScreenRect(views->pivot,w),
      @"queue":ytmScreenRect(views->queue,w),
      @"layoutFix":@"v18"
    };
    NSData *json=[NSJSONSerialization dataWithJSONObject:data
                options:NSJSONWritingPrettyPrinted error:NULL];
    if(!json)return;
    NSURL *docs=[[NSFileManager defaultManager]
           URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
    NSString *name=DuoPortrait(w)?@"YTMDuo_cover_portrait.json":
                                    @"YTMDuo_cover_landscape.json";
    [json writeToURL:[docs URLByAppendingPathComponent:name] atomically:YES];
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
            // On the cover display, YouTube Music may place its navigation
            // and mini dock as UIWindow siblings rather than under root.view.
            ytmFindExactViews(DuoCover(w)?(UIView *)w:root,&views,&budget,0);
            BOOL home=ytmVisibleInWindow(views.pivot,w);
            ytmFixHeaderButtons(views.nav,w,home);
            ytmFixQueueOverlay(views.queue,home,views.mini,w);
            ytmCoverRepairHome(w,&views,home);
            ytmFixGlassDock(&views,w,home);
            if(home)ytmSaveCoverGeometry(w,&views);
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
        // Apply header positions AFTER each native YTM nav layout pass,
        // rather than relying solely on a periodic correction.
        swizzleSpecific(NSClassFromString(@"YTMNavigationBarView"),
                        @selector(layoutSubviews),
                        (IMP)ytmNavigationLayout,
                        (IMP *)&oldYTMNavigationLayout);
        // Repair exact mini child geometry directly after YTM's own
        // layout (plus the timer fallback for transient cover rotations).
        swizzleSpecific(NSClassFromString(@"YTMMiniPlayerView"),
                        @selector(layoutSubviews),
                        (IMP)ytmMiniplayerLayout,
                        (IMP *)&oldYTMMiniplayerLayout);
        // The navigation and category rows can be relaid out separately:
        // correct after either native layout, plus the periodic fallback.
        swizzleSpecific(NSClassFromString(@"MDCHeaderStackView"),
                        @selector(layoutSubviews),
                        (IMP)ytmV16MDCHeaderStackLayout,
                        (IMP *)&oldMDCHeaderStackLayout);
        // Correction runs after the native YTMWatchView layout as well
        // as the timer. No other screens or audio layers are modified.
        swizzleSpecific(NSClassFromString(@"YTMWatchView"),
                        @selector(layoutSubviews),
                        (IMP)ytmV17WatchViewLayout,
                        (IMP *)&oldYTMWatchViewLayout);
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
        NSLog(@"[YTMDuoFix] v18 clear mini Liquid Glass and cover-landscape right-aligned navigation; unfolded/audio preserved");
    }
}
