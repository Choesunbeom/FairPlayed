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
    if(isAV&&origAVPlayerSetVolume)origAVPlayerSetVolume(player,@selector(setVolume:),scaled);
    else if(!isAV&&origAudioPlayerSetVolume)origAudioPlayerSetVolume(player,@selector(setVolume:),scaled);
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
    PDSTMForceMix(@"AVPlayer.play");
    PDSTMTrackPlayer(pdstmAVPlayers,self);
    PDSTMApplyPlayerVolume(self,YES);
    if(origAVPlayerPlay)origAVPlayerPlay(self,cmd);
}
static void hookAVPlayerPlayRate(id self,SEL cmd,float rate) {
    PDSTMForceMix(@"AVPlayer.playImmediatelyAtRate:");
    PDSTMTrackPlayer(pdstmAVPlayers,self);
    PDSTMApplyPlayerVolume(self,YES);
    if(origAVPlayerPlayRate)origAVPlayerPlayRate(self,cmd,rate);
}
static void hookAudioPlayerSetVolume(id self,SEL cmd,float value) {
    objc_setAssociatedObject(self,kVolumeOriginalKey,@(value),OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    PDSTMTrackPlayer(pdstmAudioPlayers,self);
    if(origAudioPlayerSetVolume)origAudioPlayerSetVolume(self,cmd,value*PDSTMVolume());
}
static BOOL hookAudioPlayerPlay(id self,SEL cmd) {
    PDSTMForceMix(@"AVAudioPlayer.play");
    PDSTMTrackPlayer(pdstmAudioPlayers,self);
    PDSTMApplyPlayerVolume(self,NO);
    return origAudioPlayerPlay?origAudioPlayerPlay(self,cmd):NO;
}
static NSString *PDSTMStatus(void) {
    AVAudioSession *s=[AVAudioSession sharedInstance];
    return s.isOtherAudioPlaying ? @"다른 앱 오디오 감지됨" : @"다른 앱 오디오 감지 안 됨";
}
static NSString *PDSTMSessionDescription(void) {
    AVAudioSession *s=[AVAudioSession sharedInstance];
    BOOL mix=(s.categoryOptions & AVAudioSessionCategoryOptionMixWithOthers)!=0
            || [s.category isEqualToString:AVAudioSessionCategoryAmbient];
    return [NSString stringWithFormat:
        @"외부 오디오: %@\n앱 식별: iOS에서 제공하지 않음\n\n현재 카테고리: %@\n오디오 혼합 옵션: %@\n앱 내 볼륨 조절 지원: AVPlayer/AVAudioPlayer\n\n음악이 멈춘다면 먼저 YouTube Music을 재생한 다음 YouTube 영상을 재생하고, 이 화면에서 혼합 옵션이 켜져 있는지 확인하세요.",
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
static NSArray *PDSTMOrderedCategories(id self,SEL cmd) {
    NSArray *items=originalOrderedCategories?originalOrderedCategories(self,cmd):@[];
    // YouGroupSettings uses group type=1 for Tweaks. Gonerino also adds
    // the legacy shared Tweaks group (0x70737974).
    NSInteger type=NSNotFound;
    @try {type=[[self valueForKey:@"type"] integerValue];} @catch(NSException *e){}
    if(type==1 || type==0x70737974) return PDSTMAppendCategory(items);
    return items;
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
static id PDSTMToggleItem(void) {
    Class row=objc_getClass("YTSettingsSectionItem");
    SEL sel=NSSelectorFromString(@"switchItemWithTitle:titleDescription:accessibilityIdentifier:switchOn:switchBlock:");
    NSString *explanation=@"다른 앱의 음악과 YouTube 동영상 소리를 함께 재생합니다. 음악이 멈추는 경우 앱을 재실행한 뒤 사용하세요.";
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
    if(!delegate) {NSLog(@"[PDSTM] settings delegate unavailable");return;}
    id item=PDSTMToggleItem();
    NSMutableArray *rows=[NSMutableArray array];
    if(item)[rows addObject:item];
    Class ic=objc_getClass("YTIIcon");
    id icon=ic?[ic new]:nil;
    // Use native settings icon when supported. Other tweaks already use
    // iconType to choose their sidebar icon; a gear icon is a safe fallback.
    if(icon && [icon respondsToSelector:@selector(setIconType:)]) {
        ((void(*)(id,SEL,NSInteger))objc_msgSend)(icon,@selector(setIconType:),28);
    }
    SEL withIcon=NSSelectorFromString(@"setSectionItems:forCategory:title:icon:titleDescription:headerHidden:");
    SEL withoutIcon=NSSelectorFromString(@"setSectionItems:forCategory:title:titleDescription:headerHidden:");
    if(icon && [delegate respondsToSelector:withIcon]) {
        ((void(*)(id,SEL,id,NSInteger,id,id,id,BOOL))objc_msgSend)(delegate,withIcon,rows,PDSTMCategory,@"PleaseDontStopTheMusic",icon,nil,NO);
    } else if([delegate respondsToSelector:withoutIcon]) {
        ((void(*)(id,SEL,id,NSInteger,id,id,BOOL))objc_msgSend)(delegate,withoutIcon,rows,PDSTMCategory,@"PleaseDontStopTheMusic",nil,NO);
    }
    NSLog(@"[PDSTM] native Tweaks category added (id=%ld, rows=%lu)",(long)PDSTMCategory,(unsigned long)rows.count);
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
static void PDSTMInstallNativeSettings(void) {
    Class group=objc_getClass("YTSettingsGroupData");
    Class order=objc_getClass("YTAppSettingsPresentationData");
    Class mgr=objc_getClass("YTSettingsSectionItemManager");
    PDSTMHookClass(group,@selector(tweaks),(IMP)PDSTMTweaks,(IMP*)&originalTweaks,YES);
    PDSTMHookClass(group,@selector(orderedCategories),(IMP)PDSTMOrderedCategories,(IMP*)&originalOrderedCategories,NO);
    PDSTMHookClass(order,@selector(settingsCategoryOrder),(IMP)PDSTMCategoryOrder,(IMP*)&originalSettingsCategoryOrder,YES);
    PDSTMHookClass(mgr,@selector(updateSectionForCategory:withEntry:),(IMP)PDSTMUpdateSection,(IMP*)&originalUpdateSection,NO);
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
        PDSTMInstallNativeSettings();
    }
}
