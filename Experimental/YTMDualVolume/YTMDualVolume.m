#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <AVFAudio/AVFAudio.h>
#import <MediaPlayer/MediaPlayer.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <math.h>
#import <stdatomic.h>

// Built specifically for the user's YTMUltimate 9.44.2 No-PIP IPA.
// Does NOT alter the iOS audio session, mixWithOthers, or any existing
// YTMusicUltimate, YTMABConfig and ReturnYouTubeMusicDislikes libraries.
// Normal drag controls iOS system volume. 420 ms hold with haptic and drag
// attenuates only the audio renderer, AVAudioEngine mixer, or AVPlayer
// used by the local YouTube Music process. The AudioUnit/renderer
// architecture differs from BitChord's MTAudioProcessingTap.

static NSString *const gainKey = @"Choesunbeom.YTMDualVolume.gain";
static const void *kBaseKey = &kBaseKey;
static const void *kBarKey = &kBarKey;
static _Atomic(float) appGain = 1.0f;

static NSHashTable<AVSampleBufferAudioRenderer *> *renderers;
static NSHashTable<AVAudioMixerNode *> *mixers;
static NSHashTable<AVPlayer *> *players;

static id (*oldAudioRendererInit)(id, SEL);
static void (*oldAudioRendererSetVolume)(id, SEL, float);
static float (*oldAudioRendererGetVolume)(id, SEL);
static id (*oldMixerInit)(id,SEL);
static void (*oldMixerSetVolume)(id,SEL,float);
static float (*oldMixerGetVolume)(id,SEL);
static id (*oldEngineMainMixer)(id,SEL);
static void (*oldAVPlayerSetVolume)(id,SEL,float);
static float (*oldAVPlayerGetVolume)(id,SEL);
static void (*oldAVPlayerPlay)(id,SEL);
static id (*oldAVPlayerInit)(id,SEL);
static void (*oldPlayerControlsLayout)(id,SEL);
static void (*oldNowPlayingAppear)(id,SEL,BOOL);

static float bound(float v) { return isfinite(v) ? fminf(1,fmaxf(0,v)) : 1; }
static float gain(void) { return atomic_load_explicit(&appGain, memory_order_relaxed); }
static NSHashTable *weakTable(void) {return [NSHashTable weakObjectsHashTable];}

static float originalBase(id obj, const void *key, SEL getter, float (*getterIMP)(id,SEL)) {
    NSNumber *n = objc_getAssociatedObject(obj,key);
    if (n) return bound(n.floatValue);
    return getterIMP ? bound(getterIMP(obj,getter)) : 1;
}

static void registerRenderer(AVSampleBufferAudioRenderer *r) {
    if (!r) return;
    @synchronized(renderers) {[renderers addObject:r];}
    float volume=originalBase(r,kBaseKey,@selector(volume),oldAudioRendererGetVolume);
    if (!objc_getAssociatedObject(r,kBaseKey))
        objc_setAssociatedObject(r,kBaseKey,@(volume),OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (oldAudioRendererSetVolume) oldAudioRendererSetVolume(r,@selector(setVolume:),bound(volume*gain()));
}
static id rendererInit(id self,SEL cmd) {
    id result=oldAudioRendererInit?oldAudioRendererInit(self,cmd):nil;
    if(result)registerRenderer(result);
    return result;
}
static void rendererSetVolume(id self,SEL cmd,float v) {
    objc_setAssociatedObject(self,kBaseKey,@(bound(v)),OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    @synchronized(renderers) {[renderers addObject:self];}
    if(oldAudioRendererSetVolume)oldAudioRendererSetVolume(self,cmd,bound(v*gain()));
}

static void registerMixer(AVAudioMixerNode *m) {
    if (!m) return;
    @synchronized(mixers) {[mixers addObject:m];}
    float volume=originalBase(m,kBaseKey,@selector(outputVolume),oldMixerGetVolume);
    if (!objc_getAssociatedObject(m,kBaseKey))
        objc_setAssociatedObject(m,kBaseKey,@(volume),OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (oldMixerSetVolume)oldMixerSetVolume(m,@selector(setOutputVolume:),bound(volume*gain()));
}
static id mixerInit(id self,SEL cmd) {
    id result=oldMixerInit?oldMixerInit(self,cmd):nil;
    if(result)registerMixer(result);
    return result;
}
static void mixerSetVolume(id self,SEL cmd,float v) {
    objc_setAssociatedObject(self,kBaseKey,@(bound(v)),OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    @synchronized(mixers) {[mixers addObject:self];}
    if(oldMixerSetVolume)oldMixerSetVolume(self,cmd,bound(v*gain()));
}
static id engineMainMixer(id self,SEL cmd) {
    id mixer=oldEngineMainMixer?oldEngineMainMixer(self,cmd):nil;
    if(mixer)registerMixer(mixer);
    return mixer;
}

static void registerPlayer(AVPlayer *p) {
    if(!p)return;
    @synchronized(players){[players addObject:p];}
    float volume=originalBase(p,kBaseKey,@selector(volume),oldAVPlayerGetVolume);
    if (!objc_getAssociatedObject(p,kBaseKey))
        objc_setAssociatedObject(p,kBaseKey,@(volume),OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if(oldAVPlayerSetVolume)oldAVPlayerSetVolume(p,@selector(setVolume:),bound(volume*gain()));
}
static id playerInit(id self,SEL cmd) {
    id result=oldAVPlayerInit?oldAVPlayerInit(self,cmd):nil;
    if(result)registerPlayer(result);
    return result;
}
static void playerSetVolume(id self,SEL cmd,float v) {
    objc_setAssociatedObject(self,kBaseKey,@(bound(v)),OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    @synchronized(players){[players addObject:self];}
    if(oldAVPlayerSetVolume)oldAVPlayerSetVolume(self,cmd,bound(v*gain()));
}
static void playerPlay(id self,SEL cmd) {
    registerPlayer(self);
    if(oldAVPlayerPlay)oldAVPlayerPlay(self,cmd);
}

static NSUInteger count(NSHashTable *table) {
    @synchronized(table) {return table.allObjects.count;}
}
static void setAppGain(float level) {
    float next=bound(level);
    atomic_store_explicit(&appGain,next,memory_order_relaxed);
    [NSUserDefaults.standardUserDefaults setFloat:next forKey:gainKey];
    NSArray *rs,*ms,*ps;
    @synchronized(renderers){rs=[renderers.allObjects copy];}
    @synchronized(mixers){ms=[mixers.allObjects copy];}
    @synchronized(players){ps=[players.allObjects copy];}
    for(AVSampleBufferAudioRenderer *r in rs) {
        float base=originalBase(r,kBaseKey,@selector(volume),oldAudioRendererGetVolume);
        if(oldAudioRendererSetVolume) oldAudioRendererSetVolume(r,@selector(setVolume:),bound(base*next));
    }
    for(AVAudioMixerNode *m in ms) {
        float base=originalBase(m,kBaseKey,@selector(outputVolume),oldMixerGetVolume);
        if(oldMixerSetVolume) oldMixerSetVolume(m,@selector(setOutputVolume:),bound(base*next));
    }
    for(AVPlayer *p in ps) {
        float base=originalBase(p,kBaseKey,@selector(volume),oldAVPlayerGetVolume);
        if(oldAVPlayerSetVolume) oldAVPlayerSetVolume(p,@selector(setVolume:),bound(base*next));
    }
    [[NSNotificationCenter defaultCenter]postNotificationName:@"YTMDualVolumeChanged" object:nil];
    NSLog(@"[YTMDualVolume] gain %.2f / renderer %lu / mixer %lu / player %lu",
          next,(unsigned long)rs.count,(unsigned long)ms.count,(unsigned long)ps.count);
}

static void swizzleOnlyClass(Class cls,SEL sel,IMP implementation,IMP *oldIMP) {
    if(!cls)return;
    Method m=class_getInstanceMethod(cls,sel);
    if(!m){NSLog(@"[YTMDualVolume] selector missing %@",NSStringFromSelector(sel));return;}
    IMP original=method_getImplementation(m);
    // Avoid changing NSObject/UIView methods across the whole process.
    if(class_addMethod(cls,sel,implementation,method_getTypeEncoding(m))) {
        *oldIMP=original;
    } else {
        *oldIMP=method_setImplementation(m,implementation);
    }
}

typedef NS_ENUM(NSInteger, TouchMode) {TouchIdle, TouchWaiting, TouchSystem, TouchApp};

@interface YTMDualVolumeOverlay: UIControl
@property(nonatomic,weak)UIView *anchor;
@property(nonatomic,strong)NSTimer *holdTimer;
@property(nonatomic,strong)NSTimer *autoHideTimer;
@property(nonatomic,assign)BOOL controlsVisible;
@property(nonatomic,strong)CADisplayLink *layoutLink;
@property(nonatomic,strong)MPVolumeView *volumeView;
@property(nonatomic,strong)CALayer *systemTrack;
@property(nonatomic,strong)CALayer *systemFill;
@property(nonatomic,strong)CALayer *orangeTrack;
@property(nonatomic,strong)CALayer *orangeFill;
@property(nonatomic,strong)CATextLayer *title;
@property(nonatomic,strong)id notificationToken;
@property(nonatomic,assign)TouchMode mode;
@property(nonatomic,assign)CGPoint beginPoint;
- (instancetype)initWithAnchor:(UIView *)anchor;
- (void)reposition;
- (void)drawTracks;
- (void)revealControls;
- (void)armAutoHide;
- (void)dismissControls;
@end

@implementation YTMDualVolumeOverlay
- (instancetype)initWithAnchor:(UIView *)anchor {
    if(!(self=[super initWithFrame:CGRectZero]))return nil;
    _anchor=anchor;
    self.backgroundColor=UIColor.clearColor;
    self.clipsToBounds=NO;
    self.userInteractionEnabled=YES;
    self.exclusiveTouch=YES;
    _mode=TouchIdle;
    _controlsVisible=NO;

    _volumeView=[[MPVolumeView alloc]initWithFrame:CGRectMake(-35,-35,2,2)];
    _volumeView.showsRouteButton=NO;
    _volumeView.showsVolumeSlider=YES;
    _volumeView.alpha=0.02;
    _volumeView.userInteractionEnabled=NO;
    [self addSubview:_volumeView];

    UIColor *orange=[UIColor colorWithRed:1 green:0.55 blue:0.11 alpha:1];
    _systemTrack=[CALayer layer];_systemFill=[CALayer layer];
    _orangeTrack=[CALayer layer];_orangeFill=[CALayer layer];
    _systemTrack.backgroundColor=[UIColor.whiteColor colorWithAlphaComponent:0.28].CGColor;
    _systemFill.backgroundColor=UIColor.whiteColor.CGColor;
    _orangeTrack.backgroundColor=[orange colorWithAlphaComponent:0.30].CGColor;
    _orangeFill.backgroundColor=orange.CGColor;
    for(CALayer *l in @[_systemTrack,_systemFill,_orangeTrack,_orangeFill]) {
        l.opacity=0.0f; // Invisible by default, without disabling the touch surface
        [self.layer addSublayer:l];
    }

    _title=[CATextLayer layer];
    _title.contentsScale=UIScreen.mainScreen.scale;
    _title.alignmentMode=kCAAlignmentCenter;
    _title.fontSize=10;
    _title.foregroundColor=UIColor.whiteColor.CGColor;
    _title.opacity=0.0f;
    [self.layer addSublayer:_title];
    __weak typeof(self) weakSelf=self;
    _notificationToken=[[NSNotificationCenter defaultCenter]
        addObserverForName:@"YTMDualVolumeChanged" object:nil
        queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
            (void)note;[weakSelf drawTracks];
        }];
    self.isAccessibilityElement=YES;
    self.accessibilityLabel=@"YouTube Music dual volume";
    self.accessibilityHint=@"Drag normally for system volume; hold for haptic then drag for orange app volume.";
    _layoutLink=[CADisplayLink displayLinkWithTarget:self selector:@selector(reposition)];
    if (@available(iOS 15.0,*)) _layoutLink.preferredFrameRateRange=CAFrameRateRangeMake(1,10,10);
    [_layoutLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    [self drawTracks];
    return self;
}
- (void)dealloc {
    [_autoHideTimer invalidate];
    [_holdTimer invalidate];
    [_layoutLink invalidate];
    if(_notificationToken)[NSNotificationCenter.defaultCenter removeObserver:_notificationToken];
}
- (void)reposition {
    UIView *source=self.anchor;
    UIWindow *window=source.window;
    if(!source||!window){
        self.hidden=YES;
        if(self.superview)[self removeFromSuperview];
        return;
    }
    // For landscape / folding screen: overlay stays in the player controls
    // column, not at a hard-coded iPhone screen coordinate.
    CGRect r=[source convertRect:source.bounds toView:window];
    BOOL visible=!source.hidden && source.alpha>0.05 &&
        r.size.width>220 && CGRectIntersectsRect(r,window.bounds);
    for(UIView *v=source.superview;v&&visible;v=v.superview){
        if(v.hidden||v.alpha<0.05)visible=NO;
    }
    if(!visible){self.hidden=YES;[self dismissControls];return;}
    if(self.superview!=window)[window addSubview:self];
    // Narrower and centered: the transparent activation zone sits in the
    // whitespace BETWEEN the seek bar and the playback buttons.
    CGFloat width=MIN(340,MAX(210,r.size.width*0.68));
    CGFloat x=CGRectGetMidX(r)-width/2;
    CGFloat y;
    if(r.size.height>260) y=CGRectGetMaxY(r)-135;
    else y=CGRectGetMinY(r)-37;
    y=MAX(window.safeAreaInsets.top+16,MIN(window.bounds.size.height-window.safeAreaInsets.bottom-28,y));
    x=MAX(10,MIN(window.bounds.size.width-width-10,x));
    CGRect frame=CGRectMake(x,y,width,27);
    if(!CGRectEqualToRect(frame,self.frame))self.frame=frame;
    self.hidden=NO;
    [window bringSubviewToFront:self];
    [self drawTracks];
}
- (void)drawTracks {
    CGFloat w=MAX(1,self.bounds.size.width-12);
    // Two slim tracks below a small transient value caption.
    CGFloat y=14;
    CGFloat sys=bound(AVAudioSession.sharedInstance.outputVolume);
    CGFloat local=gain();
    CGFloat lineHeight=self.mode==TouchApp?4:3;
    self.systemTrack.frame=CGRectMake(6,y,w,4);self.systemTrack.cornerRadius=2;
    self.systemFill.frame=CGRectMake(6,y,w*sys,4);self.systemFill.cornerRadius=2;
    self.orangeTrack.frame=CGRectMake(6,y+6,w,lineHeight);self.orangeTrack.cornerRadius=lineHeight/2;
    self.orangeFill.frame=CGRectMake(6,y+6,w*local,lineHeight);self.orangeFill.cornerRadius=lineHeight/2;
    self.title.frame=CGRectMake(0,-1,self.bounds.size.width,13);
    if(self.mode==TouchApp) {
        self.title.string=[NSString stringWithFormat:@"YT Music %d%%",
          (int)roundf(local*100)];
        self.title.foregroundColor=UIColor.orangeColor.CGColor;
    } else {
        self.title.string=[NSString stringWithFormat:@"시스템 %d%%   ·   YT Music %d%%",
                           (int)roundf(sys*100),(int)roundf(local*100)];
        self.title.foregroundColor=UIColor.whiteColor.CGColor;
    }
}
// Visual layers fade. This UIControl NEVER fades or becomes untouchable:
 // its clear hit area remains ready for the next touch.
- (void)setVisualOpacity:(float)opacity duration:(CFTimeInterval)duration {
    [CATransaction begin];
    [CATransaction setAnimationDuration:duration];
    [CATransaction setAnimationTimingFunction:
        [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut]];
    for(CALayer *l in @[self.systemTrack,self.systemFill,
                       self.orangeTrack,self.orangeFill,self.title]) {
        l.opacity=opacity;
    }
    [CATransaction commit];
}
- (void)revealControls {
    [self.autoHideTimer invalidate];
    self.autoHideTimer=nil;
    if(!self.controlsVisible){
        self.controlsVisible=YES;
        [self drawTracks];
        [self setVisualOpacity:1.0f duration:0.16];
    }
}
- (void)armAutoHide {
    [self.autoHideTimer invalidate];
    self.autoHideTimer=[NSTimer timerWithTimeInterval:1.3 target:self
          selector:@selector(dismissControls) userInfo:nil repeats:NO];
    [NSRunLoop.mainRunLoop addTimer:self.autoHideTimer forMode:NSRunLoopCommonModes];
}
- (void)dismissControls {
    [self.autoHideTimer invalidate];
    self.autoHideTimer=nil;
    if(self.mode!=TouchIdle)return;
    if(self.controlsVisible){
        self.controlsVisible=NO;
        [self setVisualOpacity:0.0f duration:0.26];
    }
}
- (UISlider *)findSlider:(UIView *)view {
    if([view isKindOfClass:UISlider.class])return (UISlider *)view;
    for(UIView *v in view.subviews){UISlider *s=[self findSlider:v];if(s)return s;}
    return nil;
}
- (float)fraction:(CGPoint)p {return bound((p.x-6)/MAX(1,self.bounds.size.width-12));}
- (void)changeSystem:(CGPoint)p {
    UISlider *s=[self findSlider:self.volumeView];
    if(!s){[self.volumeView layoutIfNeeded];s=[self findSlider:self.volumeView];}
    if(!s)return;
    [s setValue:[self fraction:p] animated:NO];
    [s sendActionsForControlEvents:UIControlEventValueChanged];
    [self drawTracks];
}
- (void)changeLocal:(CGPoint)p {
    setAppGain([self fraction:p]);
    [self drawTracks];
}
- (void)cancelTimer {[_holdTimer invalidate];_holdTimer=nil;}
- (void)held {
    self.holdTimer=nil;
    if(self.mode!=TouchWaiting)return;
    self.mode=TouchApp;
    UIImpactFeedbackGenerator *h=[[UIImpactFeedbackGenerator alloc]initWithStyle:UIImpactFeedbackStyleMedium];
    [h prepare];[h impactOccurredWithIntensity:0.8];
    [self drawTracks];
}
- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    (void)event;
    UITouch *t=touches.anyObject;if(!t)return;
    [self cancelTimer];
    self.beginPoint=[t locationInView:self];
    self.mode=TouchWaiting;
    [self revealControls];
    _holdTimer=[NSTimer timerWithTimeInterval:0.42 target:self
                                    selector:@selector(held) userInfo:nil repeats:NO];
    [NSRunLoop.mainRunLoop addTimer:_holdTimer forMode:NSRunLoopCommonModes];
}
- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    (void)event;
    UITouch *t=touches.anyObject;if(!t)return;
    CGPoint pt=[t locationInView:self];
    // A stationary tap ONLY reveals the transient overlay. Tiny touch jitter
    // must never jump the system volume to the tapped position.
    CGFloat dx=pt.x-self.beginPoint.x;
    CGFloat dy=pt.y-self.beginPoint.y;
    if(self.mode==TouchWaiting && fabs(dx)>14.0 && fabs(dx)>fabs(dy)*1.25) {
        [self cancelTimer];
        self.mode=TouchSystem;
    }
    if(self.mode==TouchSystem)[self changeSystem:pt];
    if(self.mode==TouchApp)[self changeLocal:pt];
}
- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    (void)event;
    UITouch *t=touches.anyObject;
    // TouchWaiting = short tap: show volume UI, change NO volume.
    // TouchSystem = deliberate horizontal drag: finish at release position.
    if(t && self.mode==TouchSystem) {
        [self changeSystem:[t locationInView:self]];
    }
    [self cancelTimer];self.mode=TouchIdle;[self drawTracks];
    [self armAutoHide];
}
- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    (void)touches;(void)event;
    [self cancelTimer];self.mode=TouchIdle;[self drawTracks];
    [self armAutoHide];
}
@end

static void attachToView(UIView *view) {
    if(!view)return;
    YTMDualVolumeOverlay *bar=objc_getAssociatedObject(view,kBarKey);
    if(!bar){
        bar=[[YTMDualVolumeOverlay alloc]initWithAnchor:view];
        objc_setAssociatedObject(view,kBarKey,bar,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    [bar reposition];
}
static void playerControlsLayout(id self, SEL cmd) {
    if(oldPlayerControlsLayout)oldPlayerControlsLayout(self,cmd);
    attachToView((UIView *)self);
}
static UIView *findVisibleControls(UIView *root) {
    if(!root)return nil;
    Class controls=objc_getClass("YTMPlayerControlsView");
    if(controls&&[root isKindOfClass:controls]&&root.bounds.size.width>220)return root;
    for(UIView *subview in root.subviews) {
        UIView *match=findVisibleControls(subview);
        if(match)return match;
    }
    return nil;
}
static void nowPlayingAppear(id self,SEL cmd,BOOL animated) {
    if(oldNowPlayingAppear)oldNowPlayingAppear(self,cmd,animated);
    // YTM builds its full-player controls differently on iPad, iPhone,
    // and foldable landscape. Find the real controls when possible;
    // otherwise anchor on the full now-playing page as a safe fallback.
    UIViewController *vc=(UIViewController *)self;
    UIView *view=findVisibleControls(vc.view);
    if(!view && vc.view.bounds.size.height>350)view=vc.view;
    if(view)attachToView(view);
}

__attribute__((constructor))static void YTMDualVolumeStart(void) {
    @autoreleasepool{
        renderers=weakTable();mixers=weakTable();players=weakTable();
        NSUserDefaults *defaults=NSUserDefaults.standardUserDefaults;
        if([defaults objectForKey:gainKey])atomic_store(&appGain,bound([defaults floatForKey:gainKey]));
        swizzleOnlyClass(AVSampleBufferAudioRenderer.class,@selector(init),
                    (IMP)rendererInit,(IMP*)&oldAudioRendererInit);
        swizzleOnlyClass(AVSampleBufferAudioRenderer.class,@selector(setVolume:),
                    (IMP)rendererSetVolume,(IMP*)&oldAudioRendererSetVolume);
        swizzleOnlyClass(AVAudioMixerNode.class,@selector(init),
                    (IMP)mixerInit,(IMP*)&oldMixerInit);
        swizzleOnlyClass(AVAudioMixerNode.class,@selector(setOutputVolume:),
                    (IMP)mixerSetVolume,(IMP*)&oldMixerSetVolume);
        swizzleOnlyClass(AVAudioEngine.class,@selector(mainMixerNode),
                    (IMP)engineMainMixer,(IMP*)&oldEngineMainMixer);
        swizzleOnlyClass(AVPlayer.class,@selector(init),
                    (IMP)playerInit,(IMP*)&oldAVPlayerInit);
        swizzleOnlyClass(AVPlayer.class,@selector(setVolume:),
                    (IMP)playerSetVolume,(IMP*)&oldAVPlayerSetVolume);
        swizzleOnlyClass(AVPlayer.class,@selector(play),
                    (IMP)playerPlay,(IMP*)&oldAVPlayerPlay);
        swizzleOnlyClass(objc_getClass("YTMPlayerControlsView"),@selector(layoutSubviews),
                    (IMP)playerControlsLayout,(IMP*)&oldPlayerControlsLayout);
        swizzleOnlyClass(objc_getClass("YTMNowPlayingViewController"),@selector(viewDidAppear:),
                    (IMP)nowPlayingAppear,(IMP*)&oldNowPlayingAppear);
        NSLog(@"[YTMDualVolume] v4 tap-to-show UI installed gain=%.2f",gain());
    }
}
