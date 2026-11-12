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
    return PDSTMEnabled() && s.isOtherAudioPlaying;
}

static BOOL (*origSetCategory1)(id, SEL, NSString *, NSError **);
static BOOL (*origSetCategory2)(id, SEL, NSString *, NSString *, AVAudioSessionCategoryOptions, NSError **);
static BOOL (*origSetCategory3)(id, SEL, NSString *, NSString *, AVAudioSessionRouteSharingPolicy, AVAudioSessionCategoryOptions, NSError **);
static BOOL (*origSetCategory4)(id, SEL, NSString *, AVAudioSessionCategoryOptions, NSError **);
static BOOL (*origSetActive1)(id, SEL, BOOL, NSError **);
static BOOL (*origSetActive2)(id, SEL, BOOL, AVAudioSessionSetActiveOptions, NSError **);
static void (*origSettingsAppeared)(id, SEL, BOOL);

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

@interface UIViewController (PDSTMMenu)
- (void)pdstm_openMusicMenu:(id)sender;
@end
@implementation UIViewController (PDSTMMenu)
- (void)pdstm_openMusicMenu:(id)sender {
    BOOL enabled=PDSTMEnabled();
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"PleaseDontStopTheMusic"
        message:[NSString stringWithFormat:@"동시 재생: %@\n다른 앱의 음악을 듣는 동안 YouTube 동영상을 재생해도 음악이 중단되지 않도록 합니다. 변경 사항은 다음 오디오 재생부터 적용됩니다.",enabled?@"켜짐":@"꺼짐"]
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:enabled?@"끄기":@"켜기" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){
        [[NSUserDefaults standardUserDefaults] setBool:!enabled forKey:kPDSTMKey];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"취소" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}
@end

static const char kMenuFlag;
static void hookSettingsAppearance(id self,SEL cmd,BOOL animated) {
    if(origSettingsAppeared)origSettingsAppeared(self,cmd,animated);
    UIViewController *vc=(UIViewController *)self;
    if(objc_getAssociatedObject(vc,&kMenuFlag))return;
    UIBarButtonItem *button=[[UIBarButtonItem alloc] initWithTitle:@"동시 재생" style:UIBarButtonItemStylePlain target:vc action:@selector(pdstm_openMusicMenu:)];
    NSMutableArray *existing=[vc.navigationItem.rightBarButtonItems mutableCopy];
    if(!existing)existing=[NSMutableArray array];
    [existing addObject:button];
    [vc.navigationItem setRightBarButtonItems:existing animated:NO];
    objc_setAssociatedObject(vc,&kMenuFlag,@YES,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
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
        Class settings=objc_getClass("YTSettingsViewController");
        if(settings)MSHookMessageEx(settings,@selector(viewDidAppear:),(IMP)hookSettingsAppearance,(IMP *)&origSettingsAppeared);
        NSLog(@"[PDSTM] in-app toggle registered (class=%@)",settings);
    }
}
