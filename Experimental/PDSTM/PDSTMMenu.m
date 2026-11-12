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
