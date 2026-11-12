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


// Play mixing support. Do not call the high-level setter recursively from its
// own hook; apply using original implementations so reentrant hooks are safe.
static BOOL (*origSetCategory1)(id,SEL,NSString*,NSError**);
static BOOL (*origSetCategory2)(id,SEL,NSString*,NSString*,AVAudioSessionCategoryOptions,NSError**);
static BOOL (*origSetCategory3)(id,SEL,NSString*,NSString*,AVAudioSessionRouteSharingPolicy,AVAudioSessionCategoryOptions,NSError**);
static BOOL (*origSetCategory4)(id,SEL,NSString*,AVAudioSessionCategoryOptions,NSError**);
static BOOL (*origSetActive1)(id,SEL,BOOL,NSError**);
static BOOL (*origSetActive2)(id,SEL,BOOL,AVAudioSessionSetActiveOptions,NSError**);
static __thread BOOL pdstmConfiguring;
static NSString *const PDSTMVolumeKey=@"PDSTMYouTubeVolume";
static const void *kVolumeOriginalKey=&kVolumeOriginalKey;
static NSHashTable *pdstmAVPlayers;
static NSHashTable *pdstmAudioPlayers;
static void PDSTMForceMix(NSString *reason);

static BOOL PDSTMIsMixableCategory(NSString *c) {
    return [c isEqualToString:AVAudioSessionCategoryPlayback] ||
           [c isEqualToString:AVAudioSessionCategoryPlayAndRecord] ||
           [c isEqualToString:AVAudioSessionCategoryMultiRoute];
}
static NSString *PDSTMNormalizedCategory(NSString *category) {
    return PDSTMEnabled() && [category isEqualToString:AVAudioSessionCategorySoloAmbient]
          ? AVAudioSessionCategoryAmbient : category;
}
static AVAudioSessionCategoryOptions PDSTMNormalizedOptions(NSString *cat,AVAudioSessionCategoryOptions options) {
    if(!PDSTMEnabled())return options;
    // Ducking/spoken-audio interruption can still silence the music source.
    options&=~(AVAudioSessionCategoryOptionDuckOthers|AVAudioSessionCategoryOptionInterruptSpokenAudioAndMixWithOthers);
    if(PDSTMIsMixableCategory(cat))options|=AVAudioSessionCategoryOptionMixWithOthers;
    return options;
}
static BOOL hookCategory1(id self,SEL cmd,NSString *category,NSError **error) {
    if(!origSetCategory1)return NO;
    if(pdstmConfiguring||!PDSTMEnabled())return origSetCategory1(self,cmd,category,error);
    category=PDSTMNormalizedCategory(category);
    if([category isEqualToString:AVAudioSessionCategoryAmbient])return origSetCategory1(self,cmd,category,error);
    if(PDSTMIsMixableCategory(category)&&origSetCategory2){
        return origSetCategory2(self,@selector(setCategory:mode:options:error:),
                 category,((AVAudioSession*)self).mode,
                 PDSTMNormalizedOptions(category,((AVAudioSession*)self).categoryOptions),error);
    }
    return origSetCategory1(self,cmd,category,error);
}
static BOOL hookCategory2(id self,SEL cmd,NSString *category,NSString *mode,AVAudioSessionCategoryOptions options,NSError **error) {
    if(!origSetCategory2)return NO;
    if(pdstmConfiguring)return origSetCategory2(self,cmd,category,mode,options,error);
    category=PDSTMNormalizedCategory(category);
    return origSetCategory2(self,cmd,category,mode,PDSTMNormalizedOptions(category,options),error);
}
static BOOL hookCategory3(id self,SEL cmd,NSString *category,NSString *mode,AVAudioSessionRouteSharingPolicy policy,AVAudioSessionCategoryOptions options,NSError **error) {
    if(!origSetCategory3)return NO;
    if(pdstmConfiguring)return origSetCategory3(self,cmd,category,mode,policy,options,error);
    category=PDSTMNormalizedCategory(category);
    return origSetCategory3(self,cmd,category,mode,policy,PDSTMNormalizedOptions(category,options),error);
}
static BOOL hookCategory4(id self,SEL cmd,NSString *category,AVAudioSessionCategoryOptions options,NSError **error) {
    if(!origSetCategory4)return NO;
    if(pdstmConfiguring)return origSetCategory4(self,cmd,category,options,error);
    category=PDSTMNormalizedCategory(category);
    return origSetCategory4(self,cmd,category,PDSTMNormalizedOptions(category,options),error);
}
static void PDSTMForceMix(NSString *reason) {
    if(!PDSTMEnabled()||pdstmConfiguring)return;
    pdstmConfiguring=YES;
    AVAudioSession *s=[AVAudioSession sharedInstance];
    NSString *category=PDSTMNormalizedCategory(s.category);
    AVAudioSessionCategoryOptions requested=PDSTMNormalizedOptions(category,s.categoryOptions);
    BOOL mustChange=![category isEqualToString:s.category] || requested!=s.categoryOptions;
    if(mustChange) {
        NSError *error=nil;
        BOOL ok=NO;
        if(origSetCategory2)ok=origSetCategory2(s,@selector(setCategory:mode:options:error:),category,s.mode,requested,&error);
        else ok=[s setCategory:category mode:s.mode options:requested error:&error];
        NSLog(@"[PDSTM] %@ category %@ mode %@ opts=%lu success=%d error=%@",reason,category,s.mode,(unsigned long)requested,ok,error);
    }
    pdstmConfiguring=NO;
}
static BOOL hookActive1(id self,SEL cmd,BOOL active,NSError **error) {
    if(active)PDSTMForceMix(@"setActive:");
    return origSetActive1?origSetActive1(self,cmd,active,error):NO;
}
static BOOL hookActive2(id self,SEL cmd,BOOL active,AVAudioSessionSetActiveOptions options,NSError **error) {
    if(active)PDSTMForceMix(@"setActive:withOptions:");
    return origSetActive2?origSetActive2(self,cmd,active,options,error):NO;
}

// Relative volume: only the YouTube-process AVPlayer and AVAudioPlayer
// instances can be controlled. iOS does not expose third-party music
// apps' individual volume through this app.
static void (*origAVPlayerSetVolume)(id,SEL,float);
static void (*origAVPlayerPlay)(id,SEL);
static void (*origAVPlayerPlayRate)(id,SEL,float);
static void (*origAudioPlayerSetVolume)(id,SEL,float);
static BOOL (*origAudioPlayerPlay)(id,SEL);
static float PDSTMVolume(void) {
    id saved=[[NSUserDefaults standardUserDefaults] objectForKey:PDSTMVolumeKey];
    return saved?fmaxf(0.f,fminf(1.f,[saved floatValue])):1.f;
}
static void PDSTMSetSavedVolume(float value) {
    [[NSUserDefaults standardUserDefaults] setFloat:fmaxf(0.f,fminf(1.f,value)) forKey:PDSTMVolumeKey];
}
static float PDSTMDesiredVolume(id player) {
    NSNumber *saved=objc_getAssociatedObject(player,kVolumeOriginalKey);
    return saved?saved.floatValue:1.f;
}
static void PDSTMTrackPlayer(NSHashTable *table,id player) {
    if(!table||!player)return;
    @synchronized(table){[table addObject:player];}
}
static void PDSTMApplyPlayerVolume(id player,BOOL isAV) {
    float scaled=PDSTMDesiredVolume(player)*PDSTMVolume();
    // Avoid redundant volume writes during player startup; a needless
    // setVolume: may cause extra video/audio renderer reconfiguration.
    if(isAV&&origAVPlayerSetVolume) {
        float current=((AVPlayer *)player).volume;
        if(fabsf(current-scaled)>0.005f) origAVPlayerSetVolume(player,@selector(setVolume:),scaled);
    } else if(!isAV&&origAudioPlayerSetVolume) {
        float current=((AVAudioPlayer *)player).volume;
        if(fabsf(current-scaled)>0.005f) origAudioPlayerSetVolume(player,@selector(setVolume:),scaled);
    }
}
static void PDSTMApplyAllVolumes(void) {
    NSArray *players=nil;
    @synchronized(pdstmAVPlayers) {players=pdstmAVPlayers.allObjects;}
    for(id player in players)PDSTMApplyPlayerVolume(player,YES);
    @synchronized(pdstmAudioPlayers) {players=pdstmAudioPlayers.allObjects;}
    for(id player in players)PDSTMApplyPlayerVolume(player,NO);
}
static void hookAVPlayerSetVolume(id self,SEL cmd,float value) {
    objc_setAssociatedObject(self,kVolumeOriginalKey,@(value),OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    PDSTMTrackPlayer(pdstmAVPlayers,self);
    if(origAVPlayerSetVolume)origAVPlayerSetVolume(self,cmd,value*PDSTMVolume());
}
static void hookAVPlayerPlay(id self,SEL cmd) {
    // Session category/activation hooks already handle mixing; do not
    // reconfigure AVAudioSession at first video play (reduces startup churn).
    PDSTMTrackPlayer(pdstmAVPlayers,self);
    if(PDSTMVolume()<0.999f)PDSTMApplyPlayerVolume(self,YES);
    if(origAVPlayerPlay)origAVPlayerPlay(self,cmd);
}
static void hookAVPlayerPlayRate(id self,SEL cmd,float rate) {
    PDSTMTrackPlayer(pdstmAVPlayers,self);
    if(PDSTMVolume()<0.999f)PDSTMApplyPlayerVolume(self,YES);
    if(origAVPlayerPlayRate)origAVPlayerPlayRate(self,cmd,rate);
}
static void hookAudioPlayerSetVolume(id self,SEL cmd,float value) {
    objc_setAssociatedObject(self,kVolumeOriginalKey,@(value),OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    PDSTMTrackPlayer(pdstmAudioPlayers,self);
    if(origAudioPlayerSetVolume)origAudioPlayerSetVolume(self,cmd,value*PDSTMVolume());
}
static BOOL hookAudioPlayerPlay(id self,SEL cmd) {
    PDSTMTrackPlayer(pdstmAudioPlayers,self);
    if(PDSTMVolume()<0.999f)PDSTMApplyPlayerVolume(self,NO);
    return origAudioPlayerPlay?origAudioPlayerPlay(self,cmd):NO;
}
static NSString *PDSTMStatus(void) {
    AVAudioSession *s=[AVAudioSession sharedInstance];
    return s.isOtherAudioPlaying ? @"🟢 다른 앱의 음악 재생 중" : @"🔴 다른 앱의 음악 재생 감지 안 됨";
}
static NSString *PDSTMSessionDescription(void) {
    AVAudioSession *s=[AVAudioSession sharedInstance];
    BOOL mix=(s.categoryOptions & AVAudioSessionCategoryOptionMixWithOthers)!=0
            || [s.category isEqualToString:AVAudioSessionCategoryAmbient];
    return [NSString stringWithFormat:
        @"다른 앱의 음악 감지: %@\n재생 앱 식별: iOS에서 제공하지 않음\n\n현재 카테고리: %@\n오디오 혼합 옵션: %@\n앱 내 볼륨 조절 지원: AVPlayer/AVAudioPlayer\n\n음악이 멈춘다면 먼저 다른 앱의 음악을 재생한 다음 YouTube 영상을 재생하고, 이 화면에서 혼합 옵션이 켜져 있는지 확인하세요.",
        s.isOtherAudioPlaying?@"재생 감지":@"감지 안 됨",s.category,
        mix?@"켜짐":@"꺼짐"];
}
// Native YouTube Settings integration, using the same categories API as
// YTweaks, Gonerino and YouGroupSettings. This places an entry in Tweaks
// instead of relying on an overlay or an unrelated YTPlus view controller.
#import <objc/message.h>
static const NSInteger PDSTMCategory = 0x70647374; // 'pdst'
static NSArray *(*originalTweaks)(id,SEL);
static NSArray *(*originalOrderedCategories)(id,SEL);
static NSArray *(*originalSettingsCategoryOrder)(id,SEL);
static void (*originalUpdateSection)(id,SEL,NSUInteger,id);

static NSArray *PDSTMAppendCategory(NSArray *source) {
    NSMutableArray *items=[source isKindOfClass:NSArray.class] ? [source mutableCopy] : [NSMutableArray array];
    if(![items containsObject:@(PDSTMCategory)]) [items addObject:@(PDSTMCategory)];
    return items.copy;
}
static NSArray *PDSTMTweaks(id cls,SEL cmd) {
    return PDSTMAppendCategory(originalTweaks?originalTweaks(cls,cmd):nil);
}
static NSArray *PDSTMRemoveCategory(NSArray *items) {
    if(![items isKindOfClass:NSArray.class])return @[];
    if(![items containsObject:@(PDSTMCategory)])return items;
    NSMutableArray *result=items.mutableCopy;
    [result removeObject:@(PDSTMCategory)];
    return result.copy;
}
// YTSettingsGroupData group 0x70737974 is the actual Tweaks group.
// Group type 1 is an Account group in this YouTube build, so it MUST NOT
// receive our category. The old "type==1" branch caused the duplicate entry.
static const NSUInteger PDSTMTweaksGroupType=0x70737974;
static NSArray *PDSTMOrderedForType(NSArray *items,NSUInteger groupType) {
    return groupType==PDSTMTweaksGroupType ?
        PDSTMAppendCategory(items) : PDSTMRemoveCategory(items);
}
static NSArray *PDSTMOrderedCategories(id self,SEL cmd) {
    NSArray *items=originalOrderedCategories?originalOrderedCategories(self,cmd):@[];
    NSUInteger groupType=NSNotFound;
    @try {groupType=[[self valueForKey:@"type"] unsignedIntegerValue];}
    @catch(NSException *e) {}
    return PDSTMOrderedForType(items,groupType);
}
// Some builds call orderedCategoriesForGroupType: directly, bypassing
// orderedCategories. Filter here as well so Account can never show PDSTM.
static NSArray *(*originalOrderedForGroupType)(id,SEL,NSUInteger);
static NSArray *PDSTMOrderedForGroupType(id self,SEL cmd,NSUInteger groupType) {
    NSArray *items=originalOrderedForGroupType?
        originalOrderedForGroupType(self,cmd,groupType):@[];
    return PDSTMOrderedForType(items,groupType);
}
static NSArray *(*originalAccountCategories)(id,SEL);
static NSArray *PDSTMAccountCategories(id self,SEL cmd) {
    return PDSTMRemoveCategory(originalAccountCategories?
        originalAccountCategories(self,cmd):@[]);
}
static NSArray *PDSTMCategoryOrder(id cls,SEL cmd) {
    NSArray *items=originalSettingsCategoryOrder?originalSettingsCategoryOrder(cls,cmd):@[];
    NSMutableArray *result=[items mutableCopy]?:[NSMutableArray array];
    if(![result containsObject:@(PDSTMCategory)]) {
        NSUInteger pos=[result indexOfObject:@(1)];
        [result insertObject:@(PDSTMCategory) atIndex:(pos==NSNotFound?result.count:MIN(pos+1,result.count))];
    }
    return result.copy;
}
static id PDSTMDelegate(id manager) {
    for(NSString *key in @[@"_dataDelegate",@"_settingsViewControllerDelegate"]) {
        @try {
            id vc=[manager valueForKey:key];
            if(vc && [vc respondsToSelector:@selector(setSectionItems:forCategory:title:icon:titleDescription:headerHidden:)])return vc;
            if(vc && [vc respondsToSelector:@selector(setSectionItems:forCategory:title:titleDescription:headerHidden:)])return vc;
        }@catch(NSException *e){}
    }
    return nil;
}

@interface PDSTMVolumeController : UIViewController
@property(nonatomic,strong) UISlider *volumeSlider;
@property(nonatomic,strong) UILabel *valueLabel;
@end
@implementation PDSTMVolumeController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor=UIColor.systemBackgroundColor;
    self.title=@"음악·영상 음량 균형";
    self.navigationItem.rightBarButtonItem=[[UIBarButtonItem alloc] initWithTitle:@"완료" style:UIBarButtonItemStyleDone target:self action:@selector(closeVolume:)];
    UIVisualEffectView *glass=[[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterial]];
    glass.translatesAutoresizingMaskIntoConstraints=NO;
    glass.layer.cornerRadius=22;
    glass.clipsToBounds=YES;
    [self.view addSubview:glass];

    UILabel *title=[UILabel new];
    title.translatesAutoresizingMaskIntoConstraints=NO;
    title.text=@"YouTube 영상 음량";
    title.font=[UIFont preferredFontForTextStyle:UIFontTextStyleTitle2];
    title.adjustsFontForContentSizeCategory=YES;

    self.valueLabel=[UILabel new];
    self.valueLabel.translatesAutoresizingMaskIntoConstraints=NO;
    self.valueLabel.textAlignment=NSTextAlignmentRight;
    self.valueLabel.textColor=UIColor.secondaryLabelColor;
    self.valueLabel.font=[UIFont monospacedDigitSystemFontOfSize:18 weight:UIFontWeightSemibold];

    self.volumeSlider=[UISlider new];
    self.volumeSlider.translatesAutoresizingMaskIntoConstraints=NO;
    self.volumeSlider.minimumValue=0.f;
    self.volumeSlider.maximumValue=1.f;
    self.volumeSlider.value=PDSTMVolume();
    self.volumeSlider.accessibilityLabel=@"유튜브 영상 상대 음량";
    [self.volumeSlider addTarget:self action:@selector(changeVolume:) forControlEvents:UIControlEventValueChanged];

    UILabel *detail=[UILabel new];
    detail.translatesAutoresizingMaskIntoConstraints=NO;
    detail.numberOfLines=0;
    detail.font=[UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    detail.textColor=UIColor.secondaryLabelColor;
    detail.text=@"다른 앱의 음악: 개별 음량 변경 불가\nYouTube 영상(이 앱): 지원되는 AVPlayer/AVAudioPlayer 재생기에 한해 위 비율 적용\n\n※ YouTube가 별도의 오디오 엔진을 사용하면 이 슬라이더가 실제 음량에 반영되지 않을 수 있습니다.";

    UIStackView *stack=[[UIStackView alloc] initWithArrangedSubviews:@[title,self.valueLabel,self.volumeSlider,detail]];
    stack.axis=UILayoutConstraintAxisVertical;
    stack.spacing=14;
    stack.translatesAutoresizingMaskIntoConstraints=NO;
    [glass.contentView addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [glass.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor constant:18],
        [glass.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor constant:-18],
        [glass.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:28],
        [stack.leadingAnchor constraintEqualToAnchor:glass.contentView.leadingAnchor constant:20],
        [stack.trailingAnchor constraintEqualToAnchor:glass.contentView.trailingAnchor constant:-20],
        [stack.topAnchor constraintEqualToAnchor:glass.contentView.topAnchor constant:22],
        [stack.bottomAnchor constraintEqualToAnchor:glass.contentView.bottomAnchor constant:-24],
        [self.volumeSlider.heightAnchor constraintGreaterThanOrEqualToConstant:32]
    ]];
    [self updateVolumeLabel];
}
- (void)updateVolumeLabel {
    self.valueLabel.text=[NSString stringWithFormat:@"YouTube %d%%",(int)lroundf(self.volumeSlider.value*100.f)];
}
- (void)changeVolume:(UISlider *)sender {
    PDSTMSetSavedVolume(sender.value);
    PDSTMApplyAllVolumes();
    [self updateVolumeLabel];
}
- (void)closeVolume:(id)sender {
    [self dismissViewControllerAnimated:YES completion:nil];
}
@end
static UIViewController *PDSTMVisibleController(id manager) {
    id vc=PDSTMDelegate(manager);
    if(![vc isKindOfClass:UIViewController.class]){
        for(UIWindow *w in UIApplication.sharedApplication.windows){
            if(w.isKeyWindow){vc=w.rootViewController;break;}
        }
    }
    if(![vc isKindOfClass:UIViewController.class])return nil;
    UIViewController *presenter=(UIViewController*)vc;
    while(presenter.presentedViewController)presenter=presenter.presentedViewController;
    return presenter;
}
static void PDSTMOpenVolume(id manager) {
    UIViewController *from=PDSTMVisibleController(manager);
    if(!from)return;
    PDSTMVolumeController *vc=[PDSTMVolumeController new];
    UINavigationController *navigation=[[UINavigationController alloc] initWithRootViewController:vc];
    navigation.modalPresentationStyle=UIModalPresentationPageSheet;
    [from presentViewController:navigation animated:YES completion:nil];
}
static void PDSTMShowStatus(id manager) {
    UIViewController *from=PDSTMVisibleController(manager);
    if(!from)return;
    // Force a refresh before the user inspects the session diagnostic.
    PDSTMForceMix(@"status view");
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"오디오 상태 점검"
        message:PDSTMSessionDescription() preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"확인" style:UIAlertActionStyleDefault handler:nil]];
    [from presentViewController:alert animated:YES completion:nil];
}
static id PDSTMSimpleRow(NSString *title,NSString *desc,NSString *key,id detail,id action) {
    Class cls=objc_getClass("YTSettingsSectionItem");
    SEL sel=NSSelectorFromString(@"itemWithTitle:titleDescription:accessibilityIdentifier:detailTextBlock:selectBlock:");
    if(!cls||![cls respondsToSelector:sel])return nil;
    typedef id(*Create)(id,SEL,id,id,id,id,id);
    return ((Create)objc_msgSend)(cls,sel,title,desc,key,detail,action);
}

// Update the colored state inline without requiring the user to tap a row.
// Only update labels when the other-audio state actually changes.
static NSTimer *pdstmMusicStatusTimer;
static NSString *pdstmLastVisibleState;
static void PDSTMUpdateVisibleStatus(UIView *root,NSString *state,NSUInteger depth) {
    if(!root || depth>20)return;
    if([root isKindOfClass:UILabel.class]) {
        UILabel *label=(UILabel *)root;
        NSString *current=label.text?:@"";
        if(([current hasPrefix:@"🟢 "]||[current hasPrefix:@"🔴 "])
            && [current containsString:@"다른 앱의 음악"]
            && ![current isEqualToString:state]) {
            label.text=state;
            [label setNeedsLayout];
        }
    }
    for(UIView *v in root.subviews)PDSTMUpdateVisibleStatus(v,state,depth+1);
}
static void PDSTMStartMusicStatusMonitor(void) {
    if(pdstmMusicStatusTimer)return;
    pdstmLastVisibleState=PDSTMStatus();
    pdstmMusicStatusTimer=[NSTimer scheduledTimerWithTimeInterval:1.25 repeats:YES block:^(NSTimer *timer) {
        NSString *now=PDSTMStatus();
        if([now isEqualToString:pdstmLastVisibleState])return;
        pdstmLastVisibleState=now;
        for(UIWindow *win in UIApplication.sharedApplication.windows) {
            if(!win.isHidden)PDSTMUpdateVisibleStatus(win,now,0);
        }
    }];
}

static id PDSTMStatusItem(id manager) {
    id detail=^NSString* {return PDSTMStatus();};
    id action=^BOOL(id cell,NSUInteger row) {
        dispatch_async(dispatch_get_main_queue(), ^{PDSTMShowStatus(manager);});
        return NO;
    };
    return PDSTMSimpleRow(@"다른 앱의 음악 상태",
        @"어느 앱의 음악인지 식별할 수는 없으며, iOS가 감지한 다른 앱의 오디오 상태를 표시합니다. 눌러서 오디오 세션을 확인하세요.",
        @"PDSTMOtherAudioStatus",detail,action);
}
static id PDSTMVolumeItem(id manager) {
    id detail=^NSString* {
        return [NSString stringWithFormat:@"YouTube %d%% · 다른 앱의 음악 음량은 변경 불가",(int)lroundf(PDSTMVolume()*100.f)];
    };
    id action=^BOOL(id cell,NSUInteger row) {
        dispatch_async(dispatch_get_main_queue(), ^{PDSTMOpenVolume(manager);});
        return NO;
    };
    return PDSTMSimpleRow(@"영상·음악 음량 균형",
        @"YouTube 영상의 상대 음량을 조절합니다. 지원되는 AVPlayer/AVAudioPlayer에만 적용됩니다.",
        @"PDSTMVolume",detail,action);
}
// Dedicated waveform icon. We also set Gonerino's shared icon attachment
// so the icon survives native YouTube UI updates.
static const void *kPDSTMIconKey=&kPDSTMIconKey;
static UIImage *(*origPDSTMIconWithColor)(id,SEL,UIColor*);
static UIImage *(*origPDSTMIconWithSelected)(id,SEL,BOOL);
static UIImage *PDSTMIconWithColor(id self,SEL cmd,UIColor *color) {
    UIImage *image=objc_getAssociatedObject(self,kPDSTMIconKey);
    if(image)return color?[image imageWithTintColor:color renderingMode:UIImageRenderingModeAlwaysOriginal]:image;
    return origPDSTMIconWithColor?origPDSTMIconWithColor(self,cmd,color):nil;
}
static UIImage *PDSTMIconWithSelected(id self,SEL cmd,BOOL selected) {
    UIImage *image=objc_getAssociatedObject(self,kPDSTMIconKey);
    if(image)return image;
    return origPDSTMIconWithSelected?origPDSTMIconWithSelected(self,cmd,selected):nil;
}
static id PDSTMToggleItem(void) {
    Class row=objc_getClass("YTSettingsSectionItem");
    SEL sel=NSSelectorFromString(@"switchItemWithTitle:titleDescription:accessibilityIdentifier:switchOn:switchBlock:");
    NSString *explanation=@"다른 앱의 음악과 YouTube 영상의 소리를 함께 재생합니다. 음악이 멈추면 앱을 다시 실행한 뒤 시도하세요.";
    if(row && [row respondsToSelector:sel]) {
        typedef id (*MakeSwitch)(id,SEL,NSString*,NSString*,NSString*,BOOL,id);
        id handler=^BOOL(id cell,BOOL enabled) {
            [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:kPDSTMKey];
            NSLog(@"[PDSTM] settings changed to %@",enabled?@"ON":@"OFF");
            return YES;
        };
        return ((MakeSwitch)objc_msgSend)(row,sel,@"동시 재생",explanation,@"PDSTMEnabled",PDSTMEnabled(),handler);
    }
    // Fallback for older YouTube builds that have no switchItem factory:
    // selecting the native settings row toggles the saved preference.
    sel=NSSelectorFromString(@"itemWithTitle:titleDescription:accessibilityIdentifier:detailTextBlock:selectBlock:");
    if(row && [row respondsToSelector:sel]) {
        typedef id(*MakeItem)(id,SEL,NSString*,NSString*,NSString*,id,id);
        id value=^NSString*{return PDSTMEnabled()?@"켜짐":@"꺼짐";};
        id onSelect=^BOOL(id cell,NSUInteger idx){
            [[NSUserDefaults standardUserDefaults] setBool:!PDSTMEnabled() forKey:kPDSTMKey];
            return YES;
        };
        return ((MakeItem)objc_msgSend)(row,sel,@"동시 재생",explanation,@"PDSTMEnabled",value,onSelect);
    }
    return nil;
}
static void PDSTMUpdateSection(id manager,SEL cmd,NSUInteger category,id entry) {
    if(category!=PDSTMCategory) {
        if(originalUpdateSection)originalUpdateSection(manager,cmd,category,entry);
        return;
    }
    id delegate=PDSTMDelegate(manager);
    if(!delegate){ NSLog(@"[PDSTM] settings delegate unavailable"); return; }
    dispatch_async(dispatch_get_main_queue(), ^{PDSTMStartMusicStatusMonitor();});
    NSMutableArray *rows=[NSMutableArray array];
    for(id item in @[PDSTMToggleItem()?:[NSNull null],
                     PDSTMStatusItem(manager)?:[NSNull null],
                     PDSTMVolumeItem(manager)?:[NSNull null]]) {
        if(item!=[NSNull null])[rows addObject:item];
    }
    Class ic=objc_getClass("YTIIcon");
    id icon=ic?[ic new]:nil;
    if(icon) {
        UIImageSymbolConfiguration *config=[UIImageSymbolConfiguration configurationWithPointSize:24 weight:UIImageSymbolWeightMedium];
        UIImage *waveform=[[UIImage systemImageNamed:@"waveform" withConfiguration:config] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
        if(waveform){
            objc_setAssociatedObject(icon,kPDSTMIconKey,waveform,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(icon,(const void*)sel_registerName("settingsIntegrationIconImage"),waveform,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        if([icon respondsToSelector:@selector(setIconType:)]) ((void(*)(id,SEL,NSInteger))objc_msgSend)(icon,@selector(setIconType:),28);
    }
    SEL withIcon=NSSelectorFromString(@"setSectionItems:forCategory:title:icon:titleDescription:headerHidden:");
    SEL withoutIcon=NSSelectorFromString(@"setSectionItems:forCategory:title:titleDescription:headerHidden:");
    if(icon && [delegate respondsToSelector:withIcon]) {
        ((void(*)(id,SEL,id,NSInteger,id,id,id,BOOL))objc_msgSend)(delegate,withIcon,rows,PDSTMCategory,@"PleaseDontStopTheMusic",icon,nil,NO);
    } else if([delegate respondsToSelector:withoutIcon]) {
        ((void(*)(id,SEL,id,NSInteger,id,id,BOOL))objc_msgSend)(delegate,withoutIcon,rows,PDSTMCategory,@"PleaseDontStopTheMusic",nil,NO);
    }
    NSLog(@"[PDSTM] Tweaks category %ld with %lu items, status=%@",(long)PDSTMCategory,(unsigned long)rows.count,PDSTMStatus());
}
static void PDSTMHookClass(Class cls,SEL sel,IMP replacement,IMP *orig,BOOL isClass) {
    if(!cls)return;
    Class target=isClass?object_getClass(cls):cls;
    Method method=class_getInstanceMethod(target,sel);
    if(method && class_getMethodImplementation(target,sel)) {
        MSHookMessageEx(target,sel,replacement,orig);
        NSLog(@"[PDSTM] hook %@ on %@",NSStringFromSelector(sel),NSStringFromClass(cls));
    }
}

// iPhone Duo fullscreen placement, independent of music-settings UI.
//
// v6 only watched YTWatchFullscreenViewController's own view; the real video
// often lives in a different controller / render surface in YouTube 21.44.4.
// v7 tracks visible scenes' windows, discovers the live rendering surface and
// queries the official UIKit hinge division in the WINDOW coordinate system.
// No user-facing Flex option is registered under PleaseDontStopTheMusic.
static const char kPDSTMFlexOriginalTransformKey;
static NSHashTable *pdstmMovedVideoViews;
static NSHashTable *pdstmMovedControlViews;
static const char kPDSTMFlexControlOriginalTransformKey;
static NSTimer *pdstmFlexGlobalTimer;
static CGRect PDSTMActiveHorizontalHingeInWindow(UIWindow *window) {
    if(!window || window.hidden || ![window respondsToSelector:@selector(reservedRegionsOfKind:options:)])return CGRectNull;
    Class kindClass=objc_getClass("UIViewReservedRegionKind");
    SEL divisionKind=NSSelectorFromString(@"divisionRegionKind");
    if(!kindClass || ![kindClass respondsToSelector:divisionKind])return CGRectNull;
    id kind=((id(*)(id,SEL))objc_msgSend)(kindClass,divisionKind);
    if(!kind)return CGRectNull;
    SEL query=NSSelectorFromString(@"reservedRegionsOfKind:options:");
    NSArray *regions=((NSArray *(*)(id,SEL,id,NSUInteger))objc_msgSend)(window,query,kind,0);
    CGRect bounds=window.bounds;
    for(id region in regions) {
        BOOL active=[region respondsToSelector:@selector(isActive)]?
            ((BOOL(*)(id,SEL))objc_msgSend)(region,@selector(isActive)):
            ([region respondsToSelector:@selector(active)]?
                ((BOOL(*)(id,SEL))objc_msgSend)(region,@selector(active)):YES);
        if(!active || ![region respondsToSelector:@selector(frame)])continue;
        CGRect frame=((CGRect(*)(id,SEL))objc_msgSend)(region,@selector(frame));
        if(CGRectGetWidth(frame)>CGRectGetHeight(frame)*2.0
           && CGRectGetWidth(frame)>CGRectGetWidth(bounds)*0.6
           && CGRectGetMinY(frame)>CGRectGetHeight(bounds)*0.15
           && CGRectGetMinY(frame)<CGRectGetHeight(bounds)*0.85) {
            return frame;
        }
    }
    return CGRectNull;
}
static NSInteger PDSTMVideoCandidateScore(UIView *view) {
    NSString *name=NSStringFromClass(view.class);
    NSString *layerName=NSStringFromClass(view.layer.class);
    if([name containsString:@"YTGLMediaPlayerView"])return 12;
    if([name containsString:@"YTVideoView"])return 11;
    if([name containsString:@"YTPlayerRenderingView"])return 10;
    if([name containsString:@"AVPlayerView"])return 9;
    if([layerName containsString:@"AVPlayerLayer"])return 12;
    if([layerName containsString:@"AVSampleBufferDisplayLayer"])return 12;
    if([name containsString:@"GLMedia"] || [name containsString:@"VideoRenderer"])return 9;
    if([name containsString:@"YTPlayerView"])return 5;
    return 0;
}
static void PDSTMFindFullscreenVideo(UIView *root,UIWindow *window,CGRect hinge,
                                  NSUInteger depth,UIView **bestView,CGFloat *bestScore) {
    if(!root || depth>28 || root.hidden || root.alpha<0.03)return;
    NSInteger priority=PDSTMVideoCandidateScore(root);
    if(priority && root.superview) {
        // All previously applied transforms were restored before scanning.
        // Never mutate candidate views during a search: v7 could corrupt the
        // layout of a different renderer when the fullscreen view was rebuilt.
        CGRect rect=[root convertRect:root.bounds toView:window];
        CGFloat width=CGRectGetWidth(rect),height=CGRectGetHeight(rect);
        if(isfinite(width)&&isfinite(height)
           && width>CGRectGetWidth(window.bounds)*0.66
           && height>CGRectGetHeight(window.bounds)*0.16
           // A reopened fullscreen player can be ENTIRELY below the hinge.
           // v7's cross-hinge-only filter rejected it and left it at bottom.
           && CGRectIntersectsRect(rect,window.bounds)) {
            // Prefer the actual render surface over its full-screen wrapper.
            CGFloat score=(CGFloat)priority*1000.0
                 + fmin(400.0,width/CGRectGetWidth(window.bounds)*140.0)
                 - fabs(CGRectGetMidY(rect)-CGRectGetMidY(window.bounds))*0.07;
            if(score>*bestScore){*bestScore=score;*bestView=root;}
        }
    }
    for(UIView *child in root.subviews) {
        PDSTMFindFullscreenVideo(child,window,hinge,depth+1,bestView,bestScore);
    }
}
static void PDSTMRestoreFlexForView(UIView *view) {
    if(!view)return;
    NSValue *base=objc_getAssociatedObject(view,&kPDSTMFlexOriginalTransformKey);
    if(!base)return;
    [UIView performWithoutAnimation:^{
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        view.transform=base.CGAffineTransformValue;
        [CATransaction commit];
    }];
    objc_setAssociatedObject(view,&kPDSTMFlexOriginalTransformKey,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

// v8: Leave YouTube's native control hierarchy and button actions intact.
// Move the small visual/control groups, not their fullscreen overlay root.
// Relocated controls remain interactive because UIKit hit-testing follows
// transforms on the group. This is intentionally conservative.
static BOOL PDSTMIsNativeControlOverlay(UIView *view) {
    NSString *c=NSStringFromClass(view.class);
    return [c containsString:@"YTMainAppControlsOverlayView"] ||
           [c containsString:@"YTMainAppVideoPlayerOverlayView"] ||
           [c containsString:@"YTInlinePlayerBarContainerView"] ||
           [c containsString:@"YTPlayerControlsOverlay"] ||
           [c containsString:@"YTFullscreenControls"];
}
static BOOL PDSTMIsVideoOrSubtitle(UIView *view) {
    NSString *c=NSStringFromClass(view.class);
    return PDSTMVideoCandidateScore(view)>0 ||
           [c containsString:@"Subtitle"] ||
           [c containsString:@"Caption"] ||
           [c containsString:@"TimedText"] ||
           [c containsString:@"VideoRenderer"] ||
           [c containsString:@"PlayerLayer"];
}
static BOOL PDSTMHasControlContent(UIView *view,NSUInteger depth) {
    if(!view || depth>6)return NO;
    if([view isKindOfClass:UIControl.class] ||
       [view isKindOfClass:UILabel.class])return YES;
    if(PDSTMIsVideoOrSubtitle(view))return NO;
    for(UIView *child in view.subviews) {
        if(PDSTMHasControlContent(child,depth+1))return YES;
    }
    return NO;
}
static void PDSTMRestoreControl(UIView *view) {
    NSValue *old=objc_getAssociatedObject(view,&kPDSTMFlexControlOriginalTransformKey);
    if(old) {
        view.transform=old.CGAffineTransformValue;
        objc_setAssociatedObject(view,&kPDSTMFlexControlOriginalTransformKey,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}
static void PDSTMMoveToWindowY(UIView *view,UIWindow *window,CGFloat newCenterY,const char *key) {
    if(!view || !view.superview)return;
    CGRect rect=[view convertRect:view.bounds toView:window];
    CGFloat deltaY=newCenterY-CGRectGetMidY(rect);
    if(!isfinite(deltaY)||fabs(deltaY)<3.0||
        fabs(deltaY)>CGRectGetHeight(window.bounds)*0.8)return;
    CGAffineTransform base=view.transform;
    objc_setAssociatedObject(view,key,[NSValue valueWithCGAffineTransform:base],OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    CGPoint a=[view.superview convertPoint:CGPointZero toView:window];
    CGPoint b=[window convertPoint:CGPointMake(a.x,a.y+deltaY) toView:view.superview];
    CGPoint c=[window convertPoint:a toView:view.superview];
    view.transform=CGAffineTransformConcat(base,CGAffineTransformMakeTranslation(b.x-c.x,b.y-c.y));
}
static BOOL PDSTMHasVideoAncestor(UIView *view,UIView *render) {
    for(UIView *ancestor=render;ancestor;ancestor=ancestor.superview) {
        if(view==ancestor)return YES;
    }
    return NO;
}
static void PDSTMRelocateControlsInSubtree(UIView *view,UIView *overlayRoot,
                                          UIWindow *window,CGRect hinge,
                                          UIView *render,NSUInteger depth) {
    if(!view || depth>25 || view.hidden || view.alpha<0.02)return;
    // An overlay can own both the video surface and all player buttons.
    // Do not move its ancestor container, but DO descend into its other
    // branches or the lower controls will never be discovered.
    if(view==render)return;
    BOOL containsRender=PDSTMHasVideoAncestor(view,render);
    if(PDSTMIsVideoOrSubtitle(view) && !containsRender)return;
    CGRect frame=[view convertRect:view.bounds toView:window];
    CGFloat fullHeight=CGRectGetHeight(window.bounds);
    CGFloat hingeTop=CGRectGetMinY(hinge);
    CGFloat hingeBottom=CGRectGetMaxY(hinge);
    CGFloat bottomHeight=fullHeight-hingeBottom;
    CGFloat centerY=CGRectGetMidY(frame);
    CGFloat height=CGRectGetHeight(frame),width=CGRectGetWidth(frame);
    if(view!=overlayRoot && !containsRender &&
       height>9 && height<fmin(180.0,fullHeight*0.23) &&
       width>12 && width<CGRectGetWidth(window.bounds)*1.08 &&
       CGRectGetMaxY(frame)>-12 &&
       centerY<hingeBottom+12 &&
       PDSTMHasControlContent(view,0)) {
        CGFloat destination=0;
        CGFloat earlyBoundary=hingeTop*0.27;
        if(centerY<earlyBoundary) {
            // Fullscreen header/title/action controls -> bottom half top.
            CGFloat fraction=fmax(0.0,fmin(1.0,centerY/fmax(1.0,earlyBoundary)));
            destination=hingeBottom + 27 + fraction*fmin(bottomHeight*0.20,90);
        } else {
            // Middle transport buttons -> lower center; leave lower
            // progress/scrubber and toolbars in their original positions.
            CGFloat fraction=(centerY-earlyBoundary)/fmax(1.0,hingeBottom-earlyBoundary);
            fraction=fmax(0.0,fmin(1.0,fraction));
            destination=hingeBottom + bottomHeight*(0.30+0.17*fraction);
        }
        destination=fmin(fullHeight-height*0.5-16,destination);
        destination=fmax(hingeBottom+height*0.5+10,destination);
        PDSTMMoveToWindowY(view,window,destination,&kPDSTMFlexControlOriginalTransformKey);
        if(objc_getAssociatedObject(view,&kPDSTMFlexControlOriginalTransformKey))
            [pdstmMovedControlViews addObject:view];
        return; // A moved group carries its children; never double-translate.
    }
    for(UIView *child in view.subviews) {
        PDSTMRelocateControlsInSubtree(child,overlayRoot,window,hinge,render,depth+1);
    }
}
static BOOL PDSTMIsAncestorOfView(UIView *ancestor,UIView *descendant) {
    for(UIView *v=descendant;v;v=v.superview) if(v==ancestor)return YES;
    return NO;
}
static void PDSTMCollectNativeControlOverlays(UIView *view,NSMutableArray *overlays,NSUInteger depth) {
    if(!view||depth>28||view.hidden||view.alpha<0.02)return;
    if(PDSTMIsNativeControlOverlay(view)) {
        BOOL alreadyInside=NO;
        for(UIView *existing in overlays) {
            if(PDSTMIsAncestorOfView(existing,view)) {
                alreadyInside=YES;
                break;
            }
        }
        if(!alreadyInside) {
            // If the new overlay owns a previous match, prefer this root.
            for(UIView *prior in overlays.copy) {
                if(PDSTMIsAncestorOfView(view,prior))[overlays removeObject:prior];
            }
            [overlays addObject:view];
            return;
        }
    }
    for(UIView *child in view.subviews) PDSTMCollectNativeControlOverlays(child,overlays,depth+1);
}
static void PDSTMRelocateFullscreenControls(UIWindow *window,CGRect hinge,UIView *render) {
    if(!window || !render)return;
    NSMutableArray *roots=[NSMutableArray array];
    PDSTMCollectNativeControlOverlays(window,roots,0);
    for(UIView *root in roots) {
        CGRect area=[root convertRect:root.bounds toView:window];
        // Inline overlays can share these names. Only move controls for
        // a window-sized player overlay in a folded fullscreen layout.
        if(CGRectGetWidth(area)<CGRectGetWidth(window.bounds)*0.70)continue;
        if(CGRectGetHeight(area)<CGRectGetHeight(window.bounds)*0.43)continue;
        PDSTMRelocateControlsInSubtree(root,root,window,hinge,render,0);
    }
}

static void PDSTMRunFlexGlobalPass(void) {
    if(!NSThread.isMainThread)return;
    if(!pdstmMovedVideoViews)pdstmMovedVideoViews=[NSHashTable weakObjectsHashTable];
    if(!pdstmMovedControlViews)pdstmMovedControlViews=[NSHashTable weakObjectsHashTable];
    // Every pass starts with YouTube's original geometry. A previous
    // fullscreen transform can never become the next entry's baseline.
    // Perform restore, measurement and relocation in one disabled-actions
    // transaction so the user does not see the intermediate layout.
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    for(UIView *view in pdstmMovedControlViews.allObjects)PDSTMRestoreControl(view);
    [pdstmMovedControlViews removeAllObjects];
    for(UIView *view in pdstmMovedVideoViews.allObjects)PDSTMRestoreFlexForView(view);
    [pdstmMovedVideoViews removeAllObjects];
    UIView *chosen=nil;
    CGRect desiredHinge=CGRectNull;
    UIWindow *chosenWindow=nil;
    CGFloat bestScore=-CGFLOAT_MAX;
    for(UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if(![scene isKindOfClass:UIWindowScene.class]||scene.activationState!=UISceneActivationStateForegroundActive)continue;
        for(UIWindow *window in ((UIWindowScene *)scene).windows) {
            if(window.hidden || window.alpha<0.03 || window.windowLevel!=UIWindowLevelNormal)continue;
            CGRect hinge=PDSTMActiveHorizontalHingeInWindow(window);
            if(CGRectIsNull(hinge))continue;
            UIView *candidate=nil;
            CGFloat localScore=-CGFLOAT_MAX;
            PDSTMFindFullscreenVideo(window,window,hinge,0,&candidate,&localScore);
            if(candidate && localScore>bestScore){
                chosen=candidate;desiredHinge=hinge;chosenWindow=window;bestScore=localScore;
            }
        }
    }
    // No hinge or fullscreen video means every modified view is now
    // restored, including transitions out of fullscreen.
    if(!chosen||!chosenWindow){
        [CATransaction commit];
        return;
    }
    NSValue *original=objc_getAssociatedObject(chosen,&kPDSTMFlexOriginalTransformKey);
    if(!original) {
        original=[NSValue valueWithCGAffineTransform:chosen.transform];
        objc_setAssociatedObject(chosen,&kPDSTMFlexOriginalTransformKey,original,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    [pdstmMovedVideoViews addObject:chosen];
    CGRect current=[chosen convertRect:chosen.bounds toView:chosenWindow];
    CGFloat upperPaneHeight=CGRectGetMinY(desiredHinge)-6.0;
    CGFloat videoCenterY=CGRectGetMidY(current);
    CGFloat offsetY=upperPaneHeight*0.5-videoCenterY;
    if(CGRectGetMaxY(current)>upperPaneHeight+6 &&
       isfinite(offsetY) &&
       fabs(offsetY)<CGRectGetHeight(chosenWindow.bounds)*0.80) {
        PDSTMMoveToWindowY(chosen,chosenWindow,videoCenterY+offsetY,&kPDSTMFlexOriginalTransformKey);
    }
    PDSTMRelocateFullscreenControls(chosenWindow,desiredHinge,chosen);
    [CATransaction commit];
}
static void PDSTMStartFlexWindowTracking(void) {
    if(pdstmFlexGlobalTimer)return;
    pdstmMovedVideoViews=[NSHashTable weakObjectsHashTable];
    pdstmFlexGlobalTimer=[NSTimer scheduledTimerWithTimeInterval:0.55 repeats:YES block:^(NSTimer *t) {
        PDSTMRunFlexGlobalPass();
    }];
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
        object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
            PDSTMRunFlexGlobalPass();
        }];
    NSLog(@"[PDSTM] Duo Flex v8: per-pass reset, full-window video search and native controls lower pane");
}

static void PDSTMInstallNativeSettings(void) {
    Class group=objc_getClass("YTSettingsGroupData");
    Class order=objc_getClass("YTAppSettingsPresentationData");
    Class mgr=objc_getClass("YTSettingsSectionItemManager");
    PDSTMHookClass(group,@selector(tweaks),(IMP)PDSTMTweaks,(IMP*)&originalTweaks,YES);
    PDSTMHookClass(group,@selector(orderedCategories),(IMP)PDSTMOrderedCategories,(IMP*)&originalOrderedCategories,NO);
    PDSTMHookClass(group,@selector(orderedCategoriesForGroupType:),(IMP)PDSTMOrderedForGroupType,(IMP*)&originalOrderedForGroupType,NO);
    PDSTMHookClass(group,@selector(accountCategories),(IMP)PDSTMAccountCategories,(IMP*)&originalAccountCategories,NO);
    // No global settingsCategoryOrder hook: it was inserting this item into Account.
    PDSTMHookClass(mgr,@selector(updateSectionForCategory:withEntry:),(IMP)PDSTMUpdateSection,(IMP*)&originalUpdateSection,NO);
    Class icons=objc_getClass("YTIIcon");
    PDSTMHookClass(icons,@selector(iconImageWithColor:),(IMP)PDSTMIconWithColor,(IMP*)&origPDSTMIconWithColor,NO);
    PDSTMHookClass(icons,@selector(iconImageWithSelected:),(IMP)PDSTMIconWithSelected,(IMP*)&origPDSTMIconWithSelected,NO);
    dispatch_async(dispatch_get_main_queue(), ^{PDSTMStartFlexWindowTracking();});
    NSLog(@"[PDSTM] native Tweaks registration group=%@ manager=%@",group,mgr);
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
        pdstmAVPlayers=[NSHashTable weakObjectsHashTable];
        pdstmAudioPlayers=[NSHashTable weakObjectsHashTable];
        Class avPlayer=objc_getClass("AVPlayer");
        Class audioPlayer=objc_getClass("AVAudioPlayer");
        PDSTMHookClass(avPlayer,@selector(setVolume:),(IMP)hookAVPlayerSetVolume,(IMP*)&origAVPlayerSetVolume,NO);
        PDSTMHookClass(avPlayer,@selector(play),(IMP)hookAVPlayerPlay,(IMP*)&origAVPlayerPlay,NO);
        PDSTMHookClass(avPlayer,@selector(playImmediatelyAtRate:),(IMP)hookAVPlayerPlayRate,(IMP*)&origAVPlayerPlayRate,NO);
        PDSTMHookClass(audioPlayer,@selector(setVolume:),(IMP)hookAudioPlayerSetVolume,(IMP*)&origAudioPlayerSetVolume,NO);
        PDSTMHookClass(audioPlayer,@selector(play),(IMP)hookAudioPlayerPlay,(IMP*)&origAudioPlayerPlay,NO);
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note){
            PDSTMForceMix(@"app became active");
        }];
        dispatch_async(dispatch_get_main_queue(), ^{PDSTMForceMix(@"early app startup");});
        PDSTMInstallNativeSettings();
    }
}
