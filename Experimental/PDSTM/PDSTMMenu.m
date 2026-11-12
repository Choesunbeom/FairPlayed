// YTPlus adaptation of mikey820/PleaseDontStopTheMusic
// Music mixing only within this sideloaded YouTube process.
// Uses runtime hooks via the already bundled CydiaSubstrate.framework.
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>
#import <dispatch/dispatch.h>

extern void MSHookMessageEx(Class cls, SEL selector, IMP replacement, IMP *result);
static NSString *const kPDSTMKey=@"PDSTMEnabled";
static BOOL PDSTMEnabled(void) {
    return [[NSUserDefaults standardUserDefaults] boolForKey:kPDSTMKey];
}
static BOOL PDSTMShouldMix(AVAudioSession *s) {
    return PDSTMEnabled(); // Do not rely on isOtherAudioPlaying changing during activation.
}

static BOOL (*origSetCategory1)(id, SEL, NSString *, NSError **);
static BOOL (*origSetCategory2)(id, SEL, NSString *, NSString *, AVAudioSessionCategoryOptions, NSError **);
static BOOL (*origSetCategory3)(id, SEL, NSString *, NSString *, AVAudioSessionRouteSharingPolicy, AVAudioSessionCategoryOptions, NSError **);
static BOOL (*origSetCategory4)(id, SEL, NSString *, AVAudioSessionCategoryOptions, NSError **);
static BOOL (*origSetActive1)(id, SEL, BOOL, NSError **);
static BOOL (*origSetActive2)(id, SEL, BOOL, AVAudioSessionSetActiveOptions, NSError **);
static void (*origSettingsPageAppeared)(id, SEL, BOOL);
static void (*origSettingsSplitAppeared)(id, SEL, BOOL);

static BOOL hookCategory1(id self,SEL cmd,NSString *cat,NSError **err) {
    if (PDSTMShouldMix(self)) {
        if ([cat isEqualToString:AVAudioSessionCategorySoloAmbient]) cat=AVAudioSessionCategoryAmbient;
        if ([cat isEqualToString:AVAudioSessionCategoryPlayback]) {
            return [(AVAudioSession *)self setCategory:cat mode:AVAudioSessionModeDefault options:AVAudioSessionCategoryOptionMixWithOthers error:err];
        }
    }
    return origSetCategory1(self,cmd,cat,err);
}
static BOOL hookCategory2(id self,SEL cmd,NSString *cat,NSString *mode,AVAudioSessionCategoryOptions opts,NSError **err) {
    if(PDSTMShouldMix(self)) {
        if([cat isEqualToString:AVAudioSessionCategorySoloAmbient])cat=AVAudioSessionCategoryAmbient;
        opts|=AVAudioSessionCategoryOptionMixWithOthers;
    }
    return origSetCategory2(self,cmd,cat,mode,opts,err);
}
static BOOL hookCategory3(id self,SEL cmd,NSString *cat,NSString *mode,AVAudioSessionRouteSharingPolicy policy,AVAudioSessionCategoryOptions opts,NSError **err) {
    if(PDSTMShouldMix(self)) {
        if([cat isEqualToString:AVAudioSessionCategorySoloAmbient])cat=AVAudioSessionCategoryAmbient;
        opts|=AVAudioSessionCategoryOptionMixWithOthers;
    }
    return origSetCategory3(self,cmd,cat,mode,policy,opts,err);
}
static BOOL hookCategory4(id self,SEL cmd,NSString *cat,AVAudioSessionCategoryOptions opts,NSError **err) {
    if(PDSTMShouldMix(self)) {
        if([cat isEqualToString:AVAudioSessionCategorySoloAmbient])cat=AVAudioSessionCategoryAmbient;
        opts|=AVAudioSessionCategoryOptionMixWithOthers;
    }
    return origSetCategory4(self,cmd,cat,opts,err);
}
static void ensureMixForActivation(AVAudioSession *session, BOOL active) {
    if(!active || !PDSTMShouldMix(session) || (session.categoryOptions & AVAudioSessionCategoryOptionMixWithOthers)) return;
    NSString *cat=session.category;
    if([cat isEqualToString:AVAudioSessionCategorySoloAmbient])cat=AVAudioSessionCategoryAmbient;
    [session setCategory:cat mode:session.mode options:session.categoryOptions | AVAudioSessionCategoryOptionMixWithOthers error:nil];
}
static BOOL hookActive1(id self,SEL cmd,BOOL active,NSError **err) {
    ensureMixForActivation(self,active);
    return origSetActive1(self,cmd,active,err);
}
static BOOL hookActive2(id self,SEL cmd,BOOL active,AVAudioSessionSetActiveOptions opts,NSError **err) {
    ensureMixForActivation(self,active);
    return origSetActive2(self,cmd,active,opts,err);
}


static const char kToggleButton;
static NSString *PDSTMButtonTitle(void) {
    return [NSString stringWithFormat:@"동시 재생 · %@",PDSTMEnabled()?@"켜짐":@"꺼짐"];
}
@interface UIViewController (PDSTMMenu)
- (void)pdstm_openMusicMenu:(id)sender;
@end
@implementation UIViewController (PDSTMMenu)
- (void)pdstm_openMusicMenu:(id)sender {
    BOOL enabled=PDSTMEnabled();
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"동시 재생"
        message:[NSString stringWithFormat:@"현재: %@\nYouTube Music 등 다른 앱에서 음악을 듣는 동안 동영상을 재생해도 음악이 중단되지 않도록 시도합니다. 변경은 다음 재생부터 적용됩니다.",enabled?@"켜짐":@"꺼짐"]
        preferredStyle:UIAlertControllerStyleAlert];
    __weak UIViewController *weakSelf=self;
    [alert addAction:[UIAlertAction actionWithTitle:enabled?@"끄기":@"켜기" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){
        [[NSUserDefaults standardUserDefaults] setBool:!enabled forKey:kPDSTMKey];
        UIButton *btn=objc_getAssociatedObject(weakSelf,&kToggleButton);
        [btn setTitle:PDSTMButtonTitle() forState:UIControlStateNormal];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"닫기" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}
@end
// The actual YTPlus 6.0 screens in YTLite.dylib are YTPSettingsPage and
// YTPSettingsSplitController. The previous YTSettingsViewController hook
// therefore never attached our menu.
static void PDSTMInstallVisibleToggle(UIViewController *vc) {
    if(!vc.isViewLoaded || !vc.view) return;
    UIButton *existing=objc_getAssociatedObject(vc,&kToggleButton);
    if(existing) {
        [existing setTitle:PDSTMButtonTitle() forState:UIControlStateNormal];
        UIView *top=existing;
        while(top.superview && top.superview!=vc.view) top=top.superview;
        if(top.superview==vc.view) [vc.view bringSubviewToFront:top];
        return;
    }
    UIVisualEffectView *glass=[[UIVisualEffectView alloc] initWithEffect:
        [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterial]];
    glass.translatesAutoresizingMaskIntoConstraints=NO;
    glass.layer.cornerRadius=23;
    glass.layer.masksToBounds=YES;
    glass.layer.borderWidth=0.75;
    glass.layer.borderColor=[UIColor.labelColor colorWithAlphaComponent:0.22].CGColor;
    UIButton *button=[UIButton buttonWithType:UIButtonTypeSystem];
    button.translatesAutoresizingMaskIntoConstraints=NO;
    button.titleLabel.font=[UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    button.tintColor=UIColor.labelColor;
    [button setTitleColor:UIColor.labelColor forState:UIControlStateNormal];
    [button setImage:[UIImage systemImageNamed:@"waveform"] forState:UIControlStateNormal];
    [button setTitle:PDSTMButtonTitle() forState:UIControlStateNormal];
    button.contentEdgeInsets=UIEdgeInsetsMake(13,18,13,18);
    button.accessibilityLabel=@"동시 재생 설정";
    [button addTarget:vc action:@selector(pdstm_openMusicMenu:)
         forControlEvents:UIControlEventTouchUpInside];
    [glass.contentView addSubview:button];
    [vc.view addSubview:glass];
    [NSLayoutConstraint activateConstraints:@[
        [button.leadingAnchor constraintEqualToAnchor:glass.contentView.leadingAnchor],
        [button.trailingAnchor constraintEqualToAnchor:glass.contentView.trailingAnchor],
        [button.topAnchor constraintEqualToAnchor:glass.contentView.topAnchor],
        [button.bottomAnchor constraintEqualToAnchor:glass.contentView.bottomAnchor],
        [glass.trailingAnchor constraintEqualToAnchor:vc.view.safeAreaLayoutGuide.trailingAnchor constant:-16],
        [glass.bottomAnchor constraintEqualToAnchor:vc.view.safeAreaLayoutGuide.bottomAnchor constant:-18]
    ]];
    objc_setAssociatedObject(vc,&kToggleButton,button,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    NSLog(@"[PDSTM] attached visible setting to %@",NSStringFromClass(vc.class));
}
static void PDSTMInstallNavToggle(UIViewController *vc) {
    NSMutableArray *items=[vc.navigationItem.rightBarButtonItems mutableCopy]?:[NSMutableArray array];
    for(UIBarButtonItem *i in items) if([i.title isEqualToString:@"동시 재생"]) return;
    UIBarButtonItem *b=[[UIBarButtonItem alloc] initWithTitle:@"동시 재생" style:UIBarButtonItemStylePlain target:vc action:@selector(pdstm_openMusicMenu:)];
    [items addObject:b];
    [vc.navigationItem setRightBarButtonItems:items animated:NO];
}
static void PDSTMPageDidAppear(id self,SEL sel,BOOL animated) {
    if(origSettingsPageAppeared)origSettingsPageAppeared(self,sel,animated);
    PDSTMInstallVisibleToggle((UIViewController *)self);
    PDSTMInstallNavToggle((UIViewController *)self);
}
static void PDSTMSplitDidAppear(id self,SEL sel,BOOL animated) {
    if(origSettingsSplitAppeared)origSettingsSplitAppeared(self,sel,animated);
    PDSTMInstallNavToggle((UIViewController *)self);
}

__attribute__((constructor)) static void PDSTMInit(void) {
    @autoreleasepool {
        [[NSUserDefaults standardUserDefaults] registerDefaults:@{kPDSTMKey:@YES}];
        Class av=objc_getClass("AVAudioSession");
        if(av) {
            MSHookMessageEx(av,@selector(setCategory:error:),(IMP)hookCategory1,(IMP *)&origSetCategory1);
            MSHookMessageEx(av,@selector(setCategory:mode:options:error:),(IMP)hookCategory2,(IMP *)&origSetCategory2);
            MSHookMessageEx(av,@selector(setCategory:mode:routeSharingPolicy:options:error:),(IMP)hookCategory3,(IMP *)&origSetCategory3);
            MSHookMessageEx(av,@selector(setCategory:withOptions:error:),(IMP)hookCategory4,(IMP *)&origSetCategory4);
            MSHookMessageEx(av,@selector(setActive:error:),(IMP)hookActive1,(IMP *)&origSetActive1);
            MSHookMessageEx(av,@selector(setActive:withOptions:error:),(IMP)hookActive2,(IMP *)&origSetActive2);
        }
        Class page=objc_getClass("YTPSettingsPage");
        Class split=objc_getClass("YTPSettingsSplitController");
        if(page)MSHookMessageEx(page,@selector(viewDidAppear:),(IMP)PDSTMPageDidAppear,(IMP *)&origSettingsPageAppeared);
        if(split)MSHookMessageEx(split,@selector(viewDidAppear:),(IMP)PDSTMSplitDidAppear,(IMP *)&origSettingsSplitAppeared);
        NSLog(@"[PDSTM] YTPlus actual settings: page=%@ split=%@",page,split);
    }
}
