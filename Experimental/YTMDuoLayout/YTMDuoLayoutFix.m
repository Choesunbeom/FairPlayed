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
                             NSMutableArray *tabItems,NSUInteger *budget){
    if(!v || (*budget)++>6500)return;
    NSString *n=NSStringFromClass(v.class);
    if([n containsString:@"YTMNavigationBarView"]) [headers addObject:v];
    if([n containsString:@"YTPivotBarView"]||
       [n containsString:@"YTFloatingPivotBarView"]) [pivots addObject:v];
    if([n containsString:@"YTMMiniPlayerView"]||
       [n containsString:@"YTMOfflineMiniPlayerView"]) [minis addObject:v];
    if([n isEqualToString:@"YTPivotBarItemView"] ||
       [n hasSuffix:@"PivotBarItemView"]) [tabItems addObject:v];
    for(UIView *child in v.subviews){
        if(*budget>6500)break;
        collectViewTypes(child,headers,pivots,minis,tabItems,budget);
    }
}

static void findButtons(UIView *root,NSMutableArray<UIView *> *buttons,int depth) {
    if(!root||depth>28)return;
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
// Profile is a real YTMAvatarAccountView, often not a UIControl.
// Restrict scan to app content: system status indicators are not in rootVC.view.
static void duoHeaderFind(UIView *v,UIWindow *w,
       NSMutableArray<UIView *> *avatars, NSMutableArray<UIView *> *buttons,
       NSUInteger *budget,int depth){
    if(!v || depth>28 || (*budget)++>2500 || !viewVisible(v,w))return;
    CGRect r=[v convertRect:v.bounds toView:w];
    if(r.origin.y>112 || CGRectGetMaxY(r)<0)return;
    NSString *cls=NSStringFromClass(v.class);
    BOOL small=r.size.width>=16 && r.size.width<105 &&
               r.size.height>=15 && r.size.height<105 &&
               CGRectGetMidX(r)>w.bounds.size.width*0.58;
    if(small && [cls containsString:@"YTMAvatarAccountView"]){
        [avatars addObject:v];
    }else if(small){
        NSString *aid=v.accessibilityIdentifier.lowercaseString?:@"";
        if([v isKindOfClass:UIControl.class] ||
            [cls containsString:@"NavigationBarButton"] ||
            [cls containsString:@"QTMButton"] ||
            [cls containsString:@"Notification"] ||
            [aid containsString:@"notification"]) [buttons addObject:v];
    }
    for(UIView *child in v.subviews)
        duoHeaderFind(child,w,avatars,buttons,budget,depth+1);
}
static UIView *duoHeaderTapRoot(UIView *v,UIWindow *w){
    UIView *best=v;
    CGRect r=[v convertRect:v.bounds toView:w];
    for(UIView *p=v.superview;p && p!=w;p=p.superview){
        CGRect q=[p convertRect:p.bounds toView:w];
        if(q.size.width>116 || q.size.height>108 ||
           fabs(CGRectGetMidX(q)-CGRectGetMidX(r))>23)break;
        if(p.userInteractionEnabled &&
           ([p isKindOfClass:UIControl.class] || p.gestureRecognizers.count))
            best=p;
    }
    return best;
}
static void fixHeaderByGeometry(UIView *root,UIWindow *w){
    if(!root||!DuoIsFoldable(w))return;
    NSMutableArray *avatars=[NSMutableArray array];
    NSMutableArray *buttons=[NSMutableArray array];
    NSUInteger budget=0;
    duoHeaderFind(root,w,avatars,buttons,&budget,0);
    UIView *avatar=nil;
    CGFloat x=-CGFLOAT_MAX;
    for(UIView *v in avatars){
        CGRect r=[v convertRect:v.bounds toView:w];
        if(CGRectGetMidX(r)>x && CGRectGetMidX(r)>w.bounds.size.width*0.70){
            x=CGRectGetMidX(r);avatar=v;
        }
    }
    if(!avatar){
        for(UIView *v in buttons){
            CGRect r=[v convertRect:v.bounds toView:w];
            if(CGRectGetMidY(r)>MAX(67,w.safeAreaInsets.top+24))continue;
            if(CGRectGetMidX(r)>x && CGRectGetMidX(r)>w.bounds.size.width*0.80){
                x=CGRectGetMidX(r);avatar=v;
            }
        }
    }
    if(!avatar)return;
    avatar=duoHeaderTapRoot(avatar,w);
    CGRect ar=[avatar convertRect:avatar.bounds toView:w];
    if(CGRectGetMidY(ar)>101)return;
    CGFloat reserve=MAX(82,w.safeAreaInsets.right+65);
    CGFloat shift=MIN(132,MAX(67,CGRectGetMaxX(ar)-(w.bounds.size.width-reserve)+6));
    UIView *bell=nil; CGFloat best=CGFLOAT_MAX;
    for(UIView *v in buttons){
        UIView *t=duoHeaderTapRoot(v,w);
        if(t==avatar || [t isDescendantOfView:avatar] ||
           [avatar isDescendantOfView:t])continue;
        CGRect r=[t convertRect:t.bounds toView:w];
        CGFloat dx=CGRectGetMidX(ar)-CGRectGetMidX(r);
        if(dx>19 && dx<108 &&
           fabs(CGRectGetMidY(ar)-CGRectGetMidY(r))<28 && dx<best){
            bell=t;best=dx;
        }
    }
    duoShift(avatar,-shift);
    if(bell)duoShift(bell,-shift);
    static BOOL logged=NO;
    if(!logged){
        logged=YES;
        NSLog(@"[YTMDuoFix] moved header avatar=%@ bell=%@ by %.0fpt",
              NSStringFromClass(avatar.class),
              bell?NSStringFromClass(bell.class):@"none",shift);
    }
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
// Put native Liquid Glass INSIDE each real pivot button, beneath its icon
// and label. The glass view never receives touches: all original actions work.
static void fixTabItemGlass(UIView *item, UIWindow *w){
    if(!viewVisible(item,w) || !DuoIsFoldable(w))return;
    CGRect r=[item convertRect:item.bounds toView:w];
    CGFloat h=w.bounds.size.height;
    if(CGRectGetMidY(r)<h-125 ||
       r.size.width<32 || r.size.width>220 ||
       r.size.height<33 || r.size.height>125)return;
    UIVisualEffectView *glass=objc_getAssociatedObject(item,kDuoGlassKey);
    if(!glass || ![glass isKindOfClass:UIVisualEffectView.class]){
        glass=[[UIVisualEffectView alloc]initWithEffect:systemGlass()];
        glass.userInteractionEnabled=NO;
        glass.clipsToBounds=YES;
        glass.alpha=1;
        if(@available(iOS 13.0,*))glass.layer.cornerCurve=kCACornerCurveContinuous;
        [item insertSubview:glass atIndex:0];
        objc_setAssociatedObject(item,kDuoGlassKey,glass,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        item.opaque=NO;
        item.backgroundColor=UIColor.clearColor;
    }
    CGRect bounds=CGRectInset(item.bounds,4,5);
    bounds.size.height=MIN(bounds.size.height,53);
    glass.frame=bounds;
    glass.layer.cornerRadius=MIN(22,bounds.size.height/2);
    glass.hidden=NO;
    [item sendSubviewToBack:glass];
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
        // Some Music builds render their five home tabs without
        // YTPivotBarItemView children. Keep five individual glass capsules
        // behind those controls rather than painting one opaque full bar.
        NSUInteger fallbackCount=5;
        while(glasses.count<fallbackCount)[glasses addObject:createGlass(pivot)];
        CGFloat slice=pivot.bounds.size.width/fallbackCount;
        for(NSUInteger i=0;i<glasses.count;i++){
            UIVisualEffectView *glass=glasses[i];
            glass.hidden=i>=fallbackCount;
            if(i>=fallbackCount)continue;
            CGFloat itemHeight=MIN(53,MAX(40,pivot.bounds.size.height-12));
            glass.frame=CGRectMake(i*slice+7,(pivot.bounds.size.height-itemHeight)/2,
                                   MAX(20,slice-14),itemHeight);
            glass.layer.cornerRadius=MIN(23,itemHeight/2);
            [pivot sendSubviewToBack:glass];
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
// The portrait bug is often an oversized HOST container around an otherwise
// correctly sized mini-player, not the YTMMiniPlayerView itself. Walk upward
// until we find the nearest oversized bottom dock and compact THAT view.
static void fixMiniplayer(UIView *mini,UIWindow *w){
    if(!DuoPortrait(w)||!viewVisible(mini,w))return;
    CGRect miniRect=[mini convertRect:mini.bounds toView:w];
    if(miniRect.size.width<w.bounds.size.width*0.58 ||
       miniRect.origin.y<w.bounds.size.height*0.48)return;
    UIView *target=nil;
    UIView *candidate=mini;
    for(int i=0;i<5 && candidate && candidate!=w;i++,candidate=candidate.superview){
        CGRect r=[candidate convertRect:candidate.bounds toView:w];
        NSString *cls=NSStringFromClass(candidate.class);
        if(r.size.width<w.bounds.size.width*.60 ||
           r.origin.y<w.bounds.size.height*.48 ||
           r.size.height<94 || r.size.height>265)continue;
        if([cls containsString:@"Pivot"]||[cls containsString:@"TabBar"]||
           [cls containsString:@"ScrollView"]||[cls containsString:@"Collection"])
           continue;
        target=candidate;
        break;
    }
    if(!target)return;
    CGFloat limit=64;
    CGRect old=target.frame;
    if(old.size.height<=limit+12)return;
    shrinkConstraintIfNeeded(target,limit);
    if(target.superview)shrinkConstraintIfNeeded(target.superview,limit);
    CGRect adjusted=old;
    adjusted.size.height=limit;
    adjusted.origin.y=CGRectGetMaxY(old)-limit;
    target.frame=adjusted;
    target.clipsToBounds=YES;
    // When a compact child had been pinned to the top of the expanded tray,
    // keep it visible after collapsing that tray.
    if(target!=mini && mini.superview==target && mini.bounds.size.height<=80){
        CGRect child=mini.frame;
        child.origin.y=MAX(0,(limit-child.size.height)/2);
        mini.frame=child;
    }
    NSLog(@"[YTMDuoFix] condensed portrait miniplayer host %@ from %.0f to %.0f",
          NSStringFromClass(target.class),old.size.height,limit);
}
static void collectMiniControllers(UIViewController *vc,
                                   NSMutableArray<UIView *> *minis,int depth){
    if(!vc||depth>22)return;
    NSString *name=NSStringFromClass(vc.class);
    if([name isEqualToString:@"YTMMiniPlayerViewController"]){
        UIView *view=vc.viewIfLoaded;
        if(view && view.window && ![minis containsObject:view])[minis addObject:view];
    }
    for(UIViewController *child in vc.childViewControllers)
        collectMiniControllers(child,minis,depth+1);
    if(vc.presentedViewController)
        collectMiniControllers(vc.presentedViewController,minis,depth+1);
}
static void duoLayoutTick(NSTimer *timer){
    (void)timer;
    if(gDuoTickInProgress)return;
    gDuoTickInProgress=YES;
    @try{
        NSArray<UIWindow *> *windows=UIApplication.sharedApplication.windows;
        for(UIWindow *w in windows){
            if(!DuoIsFoldable(w)||w.hidden)continue;
            UIViewController *rootVC=w.rootViewController;
            if(!rootVC)continue;
            NSMutableArray<UIView *> *headers=[NSMutableArray array];
            NSMutableArray<UIView *> *pivots=[NSMutableArray array];
            NSMutableArray<UIView *> *minis=[NSMutableArray array];
            NSMutableArray<UIView *> *tabItems=[NSMutableArray array];
            NSUInteger budget=0;
            collectViewTypes(w,headers,pivots,minis,tabItems,&budget);
            // v5 stopped HERE when it could not find YTPivotBarView,
            // silently disabling the header, mini, and glass fixes.
            // Never make any fix depend on the others.
            BOOL isHome=(headers.count>0||pivots.count>0||
                         tabItems.count>=3||minis.count>0);
            if(isHome)fixHeaderByGeometry(rootVC.viewIfLoaded,w);
            for(UIView *v in headers)fixHeader(v,w);
            for(UIView *v in pivots)fixPivot(v,w);
            for(UIView *v in tabItems)fixTabItemGlass(v,w);
            if(DuoPortrait(w)){
                collectMiniControllers(rootVC,minis,0);
                for(UIView *v in minis)fixMiniplayer(v,w);
            }
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
            gLayoutTimer=[NSTimer scheduledTimerWithTimeInterval:0.65 repeats:YES block:^(NSTimer *timer){
                duoLayoutTick(timer);
            }];
            [[NSRunLoop mainRunLoop] addTimer:gLayoutTimer forMode:NSRunLoopCommonModes];
        });
        NSLog(@"[YTMDuoFix] Duo v6 independent home header/mini/native glass + manual fullscreen guard installed");
    }
}
